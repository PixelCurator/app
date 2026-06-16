import Foundation
import Photos
import SwiftData
import SwiftUI

// MARK: - SortingCoordinator

/// Manages a single inbox-review session: builds a queue of unsorted, embedded
/// photos, exposes the current photo + suggestions, and records accept/skip
/// decisions that advance through the queue.
///
/// **DESIGN DEFAULT — queue definition:** the queue contains photos that (a)
/// have an embedding for the active modelID AND (b) are not already a member of
/// any album. Flag for Yves: "unsorted + embedded" may be too narrow on first
/// run before the indexer completes. Consider a fallback that shows
/// non-embedded photos with a "needs indexing" placeholder.
///
/// **DESIGN DEFAULT — single-card flow:** one photo is shown at a time (not a
/// swipe stack or batch mode). This keeps decision overhead low but means long
/// queues require many taps. Flag for review.
@MainActor
@Observable
final class SortingCoordinator {

    // MARK: - Dependencies

    private let store: EmbeddingStore
    private let suggester: AlbumSuggester
    let albumManager: AlbumManager
    private let photoController: PhotoController
    let modelID: String

    // MARK: - State

    /// Ordered asset IDs eligible for sorting (unsorted + embedded).
    private(set) var queue: [PHAsset] = []

    /// Index into `queue` for the currently displayed photo.
    private(set) var currentIndex: Int = 0

    /// Whether a sorting session is active (queue built, not yet exhausted).
    private(set) var isSorting: Bool = false

    /// Suggestions for the current photo, ranked best-first.
    private(set) var currentSuggestions: [AlbumSuggestion] = []

    /// Number of photos actioned (accepted or assigned) in this session.
    private(set) var sortedCount: Int = 0

    /// Error from the most recent assign operation, or nil.
    var lastAssignError: String?

    // MARK: - Computed

    var current: PHAsset? {
        guard currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var remainingCount: Int {
        max(0, queue.count - currentIndex)
    }

    var totalCount: Int { queue.count }

    var isExhausted: Bool { currentIndex >= queue.count }

    // MARK: - Init

    init(
        store: EmbeddingStore,
        suggester: AlbumSuggester,
        albumManager: AlbumManager,
        photoController: PhotoController,
        modelID: String = CLIPVariant.bundledDefault.modelID
    ) {
        self.store = store
        self.suggester = suggester
        self.albumManager = albumManager
        self.photoController = photoController
        self.modelID = modelID
    }

    // MARK: - Queue building

    /// Builds (or rebuilds) the review queue. Must be called before presenting
    /// `SortingInboxView`. Safe to call again mid-session to refresh.
    func buildQueue() {
        // Compute the set of all album members across all known albums.
        let albumMembers: Set<String> = albumManager.albums.reduce(into: Set()) { result, album in
            result.formUnion(albumManager.memberAssetIDs(of: album.id))
        }

        let embeddedIDs = store.embeddedAssetIDs(modelID: modelID)

        let filteredIDs = SortingCoordinator.filterInbox(
            allAssetIDs: photoController.assets.map(\.localIdentifier),
            embedded: embeddedIDs,
            albumMembers: albumMembers
        )

        // Map filtered IDs back to PHAsset objects, preserving filtered order.
        let assetByID: [String: PHAsset] = Dictionary(
            uniqueKeysWithValues: photoController.assets.map { ($0.localIdentifier, $0) }
        )
        queue = filteredIDs.compactMap { assetByID[$0] }
        currentIndex = 0
        sortedCount = 0
        isSorting = !queue.isEmpty
        recomputeSuggestions()
    }

    // MARK: - Pure inbox filter (testable without PhotoKit)

    /// Returns the ordered subset of `allAssetIDs` that are both embedded and
    /// not already placed in an album. Order is preserved.
    ///
    /// This is a **pure function** — no PhotoKit or SwiftData I/O. Call it
    /// from unit tests by passing synthetic IDs.
    nonisolated static func filterInbox(
        allAssetIDs: [String],
        embedded: Set<String>,
        albumMembers: Set<String>
    ) -> [String] {
        allAssetIDs.filter { id in
            embedded.contains(id) && !albumMembers.contains(id)
        }
    }

    // MARK: - Actions

    /// Accepts a suggestion: assigns the current photo to the suggested album,
    /// then advances to the next photo.
    func accept(_ suggestion: AlbumSuggestion) async {
        guard let asset = current else { return }
        let ok = await albumManager.assign(asset, toAlbumNamed: suggestion.albumTitle)
        if ok {
            sortedCount += 1
            lastAssignError = nil
        } else {
            lastAssignError = albumManager.lastError
        }
        advance()
    }

    /// Assigns the current photo to an explicitly chosen album name (the
    /// "pick other" path), then advances.
    func assignTo(albumNamed name: String) async {
        guard let asset = current else { return }
        let ok = await albumManager.assign(asset, toAlbumNamed: name)
        if ok {
            sortedCount += 1
            lastAssignError = nil
        } else {
            lastAssignError = albumManager.lastError
        }
        advance()
    }

    /// Skips the current photo without assigning it to any album.
    func skip() {
        advance()
    }

    // MARK: - Private

    private func advance() {
        currentIndex += 1
        if currentIndex >= queue.count {
            isSorting = false
        }
        recomputeSuggestions()
    }

    private func recomputeSuggestions() {
        guard let asset = current else {
            currentSuggestions = []
            return
        }
        currentSuggestions = suggester.suggestions(
            for: asset.localIdentifier,
            modelID: modelID,
            store: store,
            albumManager: albumManager
        )
    }
}

// MARK: - Environment key

private struct SortingCoordinatorKey: EnvironmentKey {
    static let defaultValue: SortingCoordinator? = nil
}

extension EnvironmentValues {
    var sortingCoordinator: SortingCoordinator? {
        get { self[SortingCoordinatorKey.self] }
        set { self[SortingCoordinatorKey.self] = newValue }
    }
}
