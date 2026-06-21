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

    /// The coordinator owns the session state. Read from the environment so
    /// the view never captures an orphan after a variant switch (previously
    /// the coordinator was a stored property, which is now ruled out
    /// structurally even though the coordinator is also long-lived).
    ///
    /// The body is gated on a non-nil `sortingCoordinator` at the
    /// `RootTabView` level, so the force-unwrap here is safe in practice.
    @Environment(\.sortingCoordinator) private var injectedCoordinator

    private var coordinator: SortingCoordinator {
        guard let c = injectedCoordinator else {
            fatalError("SortingInboxView presented without a SortingCoordinator in the environment.")
        }
        return c
    }

    // MARK: - Local UI state

    @State private var showAlbumPicker = false
    @State private var toast: String?
    @State private var heroImage: PlatformImage?
    @State private var lastLoadedID: String?

    // MARK: - Batch select state

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchAssignPicker = false

    // MARK: - New-album naming sheet state
    //
    // ONE shared sheet drives both the single-asset and batch flows. The active
    // call site sets `pendingNewAlbumAction` to a closure that receives the
    // trimmed, non-empty name; the sheet invokes it on Create.

    @State private var showNewAlbumSheet = false
    @State private var newAlbumName: String = ""
    @State private var pendingNewAlbumAction: ((String) -> Void)?

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
            .navigationTitle("Light Table")
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
            // Shared "name your new album" sheet — driven by the active call
            // site through `pendingNewAlbumAction`. One sheet, two flows
            // (single-asset review + batch select).
            .sheet(isPresented: $showNewAlbumSheet) {
                newAlbumNameSheet
            }
        }
        .task {
            coordinator.buildQueue()
        }
    }

    // MARK: - New-album naming sheet

    /// A trimmed copy of `newAlbumName`. Empty/whitespace input disables Create.
    private var trimmedNewAlbumName: String {
        newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNewAlbumNameValid: Bool {
        !trimmedNewAlbumName.isEmpty
    }

    /// Set the pending action and reveal the sheet. The shared sheet calls the
    /// action with the trimmed name when the user confirms.
    private func presentNewAlbumSheet(perform action: @escaping (String) -> Void) {
        newAlbumName = ""
        pendingNewAlbumAction = action
        showNewAlbumSheet = true
    }

    @ViewBuilder
    private var newAlbumNameSheet: some View {
        NavigationStack {
            Form {
                TextField("Album name", text: $newAlbumName)
                    .accessibilityIdentifier("new-album-name-field")
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .submitLabel(.done)
                    #endif
                    .onSubmit {
                        if isNewAlbumNameValid { confirmNewAlbum() }
                    }
            }
            .navigationTitle("New Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showNewAlbumSheet = false
                        pendingNewAlbumAction = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { confirmNewAlbum() }
                        .disabled(!isNewAlbumNameValid)
                        .accessibilityIdentifier("new-album-confirm-button")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 160)
        #endif
        .presentationDetents([.medium])
    }

    private func confirmNewAlbum() {
        let name = trimmedNewAlbumName
        guard !name.isEmpty else { return }
        let action = pendingNewAlbumAction
        pendingNewAlbumAction = nil
        showNewAlbumSheet = false
        action?(name)
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
            Button("New album…") {
                let assets = coordinator.queue.filter { selectedIDs.contains($0.localIdentifier) }
                presentNewAlbumSheet { chosenTitle in
                    Task {
                        let n = await coordinator.batchAssign(assets, toAlbumNamed: chosenTitle)
                        selectedIDs.removeAll()
                        isSelecting = false
                        await showToast("Added \(n) to \(chosenTitle)")
                    }
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
            Button("New album…") {
                presentNewAlbumSheet { chosenTitle in
                    Task {
                        await coordinator.assignTo(albumNamed: chosenTitle)
                        await showToast("Added to \(chosenTitle)")
                    }
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
        // Undo failure feedback — without this, a remove-side failure leaves
        // the user staring at an unchanged screen with no idea why.
        .onChange(of: coordinator.decisionLog.lastUndoError) { _, error in
            if let error {
                Task { await showToast(error) }
            }
        }
        .onChange(of: coordinator.decisionLog.lastRedoError) { _, error in
            if let error {
                Task { await showToast(error) }
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
            // Skip is a forward action ("next photo"), not a cancel. Drop the
            // `.cancel` role so VoiceOver doesn't announce it as "Cancel".
            Button {
                coordinator.skip()
            } label: {
                Label("Skip", systemImage: "forward")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("inbox-skip")

            Button {
                showAlbumPicker = true
            } label: {
                Label("Other…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("inbox-other-album")
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
        // HIG: ContentUnavailableView is the canonical empty-state container
        // (iOS 17 / macOS 14+). It handles layout, typography, Dynamic Type,
        // and VoiceOver grouping correctly out of the box.
        ContentUnavailableView(
            "All Sorted",
            systemImage: "tray",
            description: Text("All indexed photos are already sorted into albums. Keep indexing more photos to get suggestions here.")
        )
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
                    // Percent is `verbatim` (locale-neutral, avoids a bare `%`
                    // in a localized format key); only the count phrase is
                    // localized ("%lld similar" → "%lld ähnlich").
                    (Text(verbatim: "\(Int(suggestion.score * 100))% · ")
                        + Text("\(suggestion.supportingCount) similar"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // HIG: minimum 44pt tappable target — matters for motor-control
            // users and for VoiceOver Switch Control. The visual chip height
            // is around 50pt with the current padding, but `frame(minHeight:)`
            // makes the contract explicit so future copy changes can't shrink
            // the hit area below the 44pt threshold.
            .frame(minHeight: 44)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
