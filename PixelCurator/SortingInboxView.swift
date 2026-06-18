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

    // MARK: - Batch select state

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchAssignPicker = false

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
                } else if isSelecting {
                    selectionGrid
                } else {
                    reviewCard
                }
            }
            .navigationTitle("Sorting Inbox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityIdentifier("sorting-inbox-view")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSelecting {
                        Button("Cancel") {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    }
                }
                ToolbarItemGroup(placement: .automatic) {
                    if isSelecting {
                        // No undo/redo during select mode
                        EmptyView()
                    } else {
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

                        if !coordinator.isExhausted {
                            Button("Select") {
                                isSelecting = true
                            }
                            .accessibilityIdentifier("inbox-select-toggle")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    toastBanner(toast)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    batchAssignBar
                }
            }
        }
        .task {
            coordinator.buildQueue()
        }
    }

    // MARK: - Selection grid

    private let selectionColumns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    @ViewBuilder
    private var selectionGrid: some View {
        ScrollView {
            LazyVGrid(columns: selectionColumns, spacing: 2) {
                ForEach(coordinator.queue, id: \.localIdentifier) { asset in
                    SelectionThumbnailCell(
                        asset: asset,
                        isSelected: selectedIDs.contains(asset.localIdentifier)
                    )
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIDs.contains(asset.localIdentifier) {
                            selectedIDs.remove(asset.localIdentifier)
                        } else {
                            selectedIDs.insert(asset.localIdentifier)
                        }
                    }
                }
            }
            .padding(2)
        }
        .accessibilityIdentifier("inbox-select-grid")
        // Batch assign confirmation dialog
        .confirmationDialog(
            "Assign to Album",
            isPresented: $showBatchAssignPicker,
            titleVisibility: .visible
        ) {
            ForEach(coordinator.albumManager.albums.prefix(12)) { album in
                Button(album.title) {
                    let assets = coordinator.queue.filter { selectedIDs.contains($0.localIdentifier) }
                    let chosenTitle = album.title
                    Task {
                        let n = await coordinator.batchAssign(assets, toAlbumNamed: chosenTitle)
                        selectedIDs.removeAll()
                        isSelecting = false
                        await showToast("Added \(n) to \(chosenTitle)")
                    }
                }
            }
            Button("➕ New album…") {
                let assets = coordinator.queue.filter { selectedIDs.contains($0.localIdentifier) }
                let chosenTitle = "PixelCurator"
                Task {
                    let n = await coordinator.batchAssign(assets, toAlbumNamed: chosenTitle)
                    selectedIDs.removeAll()
                    isSelecting = false
                    await showToast("Added \(n) to \(chosenTitle)")
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Batch assign bar

    @ViewBuilder
    private var batchAssignBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showBatchAssignPicker = true
            } label: {
                Text("Assign \(selectedIDs.count) to…")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedIDs.isEmpty)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("batch-assign-bar")
        }
        .background(.bar)
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

// MARK: - SelectionThumbnailCell

/// Lazy-loading thumbnail cell for the batch selection grid.
/// Mirrors AlbumThumbnailCell with an added selection overlay.
private struct SelectionThumbnailCell: View {
    @Environment(PhotoController.self) private var library
    let asset: PHAsset
    let isSelected: Bool

    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let image {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.gray.opacity(0.15))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay {
                    if isSelected {
                        Rectangle()
                            .fill(.blue.opacity(0.25))
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.blue, lineWidth: 3)
                    }
                }
                .task(id: asset.localIdentifier) {
                    let scale = 2.0
                    let target = CGSize(
                        width: geo.size.width * scale,
                        height: geo.size.height * scale
                    )
                    image = await library.thumbnail(for: asset, size: target)
                }

                // Checkmark badge
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .blue)
                        .padding(6)
                        .shadow(radius: 2)
                }
            }
        }
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
