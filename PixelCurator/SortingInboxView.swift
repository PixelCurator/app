import SwiftUI
import Photos

// MARK: - SortingInboxView

/// Full-screen review flow: shows one photo at a time, its top suggestions
/// as tappable chips, Skip, and "Choose other album…" via confirmationDialog.
///
/// **DESIGN DEFAULT — single-card flow:** one photo per step, no swipe gesture.
/// Flag for Yves if a swipe-card deck is preferred.
///
/// **DESIGN DEFAULT — suggestion chip UX:** up to 3 top suggestions are shown
/// as labelled buttons with a confidence percentage. Tapping one accepts
/// immediately. Flag for Yves if a two-tap confirm is preferred.
struct SortingInboxView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoController.self) private var library
    @Environment(\.embeddingIndexer) private var embeddingIndexer

    /// The coordinator owns the session state. Passed as a direct reference
    /// because SortingCoordinator is @Observable — SwiftUI tracks changes
    /// automatically without a @Binding.
    var coordinator: SortingCoordinator

    // MARK: - Local UI state

    @State private var showAlbumPicker = false
    @State private var toast: String?
    @State private var heroImage: PlatformImage?
    @State private var lastLoadedID: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isExhausted {
                    if let indexer = embeddingIndexer, indexer.isIndexing {
                        indexingEmptyStateView(indexer: indexer)
                    } else {
                        inboxZeroView
                    }
                } else {
                    reviewCard
                }
            }
            .navigationTitle("Sorting Inbox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        Task { await coordinator.decisionLog.undo() }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!coordinator.decisionLog.canUndo)

                    Button {
                        Task { await coordinator.decisionLog.redo() }
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!coordinator.decisionLog.canRedo)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    toastBanner(toast)
                }
            }
        }
        .task {
            coordinator.buildQueue()
        }
    }

    // MARK: - Review card

    @ViewBuilder
    private var reviewCard: some View {
        VStack(spacing: 0) {
            // Progress line
            progressBar
                .padding(.horizontal)
                .padding(.top, 8)

            // Hero photo
            heroPhotoView
                .padding(.vertical, 12)

            // Suggestion chips
            suggestionChips
                .padding(.horizontal)

            Spacer(minLength: 12)

            // Action row
            actionRow
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        // Album picker (choose other)
        .confirmationDialog(
            "Add to album",
            isPresented: $showAlbumPicker,
            titleVisibility: .visible
        ) {
            ForEach(coordinator.albumManager.albums.prefix(12)) { album in
                Button(album.title) {
                    Task {
                        await coordinator.assignTo(albumNamed: album.title)
                        await showToast("Added to \(album.title)")
                    }
                }
            }
            Button("➕ New album…") {
                Task {
                    await coordinator.assignTo(albumNamed: "PixelCurator")
                    await showToast("Added to PixelCurator")
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // React to assign errors
        .onChange(of: coordinator.lastAssignError) { _, error in
            if let error {
                Task { await showToast(error) }
            }
        }
        // Undo feedback
        .onChange(of: coordinator.decisionLog.lastUndoneAlbumName) { _, name in
            if let name {
                Task { await showToast("Removed from \(name)") }
            }
        }
        // Redo feedback
        .onChange(of: coordinator.decisionLog.lastRedoneAlbumName) { _, name in
            if let name {
                Task { await showToast("Re-added to \(name)") }
            }
        }
        // Load hero image whenever current changes
        .task(id: coordinator.current?.localIdentifier) {
            await loadHeroImage()
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        HStack {
            Text("\(coordinator.sortedCount) sorted")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(coordinator.remainingCount) remaining")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hero photo

    @ViewBuilder
    private var heroPhotoView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.1))

            if let heroImage {
                Image(platformImage: heroImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4/3, contentMode: .fit)
        .padding(.horizontal)
    }

    // MARK: - Suggestion chips

    /// **DESIGN DEFAULT:** shows up to 3 top suggestions as chips.
    @ViewBuilder
    private var suggestionChips: some View {
        let suggestions = Array(coordinator.currentSuggestions.prefix(3))
        if suggestions.isEmpty {
            Text("No suggestions yet — add photos to albums to train suggestions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 10) {
                ForEach(suggestions) { suggestion in
                    SuggestionChip(suggestion: suggestion) {
                        Task {
                            await coordinator.accept(suggestion)
                            await showToast("Added to \(suggestion.albumTitle)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button(role: .cancel) {
                coordinator.skip()
            } label: {
                Label("Skip", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                showAlbumPicker = true
            } label: {
                Label("Other…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Indexing empty state

    /// Shown when the queue is empty but the indexer is still running.
    /// Distinguishes "nothing to sort yet — come back soon" from true inbox zero.
    @ViewBuilder
    private func indexingEmptyStateView(indexer: EmbeddingIndexer) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Indexing \(indexer.indexed)/\(indexer.total)…")
                .font(.title2.bold())
            Text("Suggestions appear as photos are indexed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding()
    }

    // MARK: - Inbox zero

    private var inboxZeroView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Inbox Zero")
                .font(.title2.bold())
            Text("All indexed photos are already sorted into albums. Keep indexing more photos to get suggestions here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }

    // MARK: - Helpers

    private func loadHeroImage() async {
        guard let asset = coordinator.current else {
            heroImage = nil
            lastLoadedID = nil
            return
        }
        // Avoid reloading the same asset (e.g. during suggestion refresh).
        guard asset.localIdentifier != lastLoadedID else { return }
        lastLoadedID = asset.localIdentifier
        heroImage = nil
        let size = CGSize(width: 800, height: 800)
        heroImage = await library.thumbnail(for: asset, size: size)
    }

    @MainActor
    private func showToast(_ message: String) async {
        withAnimation { toast = message }
        try? await Task.sleep(for: .seconds(2))
        withAnimation { toast = nil }
    }

    @ViewBuilder
    private func toastBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - SuggestionChip

/// A single tappable suggestion button showing the album name + confidence %.
private struct SuggestionChip: View {
    let suggestion: AlbumSuggestion
    let onAccept: () -> Void

    var body: some View {
        Button(action: onAccept) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.albumTitle)
                        .font(.body.weight(.medium))
                    Text("\(Int(suggestion.score * 100))% · \(suggestion.supportingCount) similar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
