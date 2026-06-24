@preconcurrency import Photos
import SwiftUI
import OSLog

// MARK: - Module-level logger

/// Subsystem-wide logger shared with `AlbumManager.signposter` so the
/// F-04 disambiguation events show up in the same Console filter the
/// performance-perf signposts already use.
private let albumLog = Logger(subsystem: "yves.vogl.pixelcurator", category: "AlbumManager")

// MARK: - AssignResolving (testable seam for SortingCoordinator)

/// A narrow protocol that exposes only the surface `SortingCoordinator` needs
/// to drive accept / assignTo / batchAssign paths: the resolving assign call
/// and the most recent error message.
///
/// Kept separate from `AlbumOperations` (which abstracts undo/redo side
/// effects) so neither mock has to implement the other's surface — the two
/// concerns are independent and tests for one path shouldn't drag in the
/// other. `AlbumManager` conforms to both.
@MainActor
protocol AssignResolving: AnyObject {
    /// Adds an asset to a named album (creating it if missing) and returns
    /// the resolved album `localIdentifier` together with whether the add was
    /// a no-op because the asset was already a member.
    func assignAndResolve(_ asset: PHAsset, toAlbumNamed name: String) async -> AlbumManager.AssignResult

    /// Error from the most recent assign operation, or `nil` on success.
    var lastError: String? { get }
}

/// Reads and writes Photos.app albums via PhotoKit — the iOS/macOS replacement
/// for the Python `photoscript` layer. Writing an asset into an album here makes
/// it appear in the real Photos.app, which is the core "commit" operation.
@MainActor
@Observable
final class AlbumManager: AlbumOperations, AssignResolving {

    /// OSLog signposter for measuring main-thread time inside album reads /
    /// writes. View in Instruments.app → "Logging" template (filter on
    /// subsystem `yves.vogl.pixelcurator`, category `AlbumManager`).
    static let signposter = OSSignposter(subsystem: "yves.vogl.pixelcurator", category: "AlbumManager")

    struct Album: Identifiable, Hashable {
        let id: String          // localIdentifier
        let title: String
        let count: Int
    }

    var albums: [Album] = []
    var lastError: String?

    // MARK: - Dependencies

    /// The PhotoKit seam. Production wiring injects `LivePHPhotoLibraryAdapter`
    /// (the real `PHPhotoLibrary.shared()` singleton); tests inject a fake.
    /// All album mutation funnels through `adapter.performChanges` so the
    /// "every library write goes through performChanges" invariant is enforced
    /// at the seam.
    private let adapter: any PHPhotoLibraryAdapter

    init(adapter: any PHPhotoLibraryAdapter = LivePHPhotoLibraryAdapter()) {
        self.adapter = adapter
    }

    // MARK: - Read

    func loadAlbums() {
        let signpostID = AlbumManager.signposter.makeSignpostID()
        let state = AlbumManager.signposter.beginInterval("loadAlbums", id: signpostID)

        // Yves-reported bug: activating the Albums tab freezes the UI for
        // several seconds on libraries with many albums, because
        // `PHAssetCollection.fetchAssetCollections(...)` is a synchronous
        // PhotoKit call. PR #40 fixed the per-album count side (estimatedAssetCount),
        // but the top-level fetch + enumeration was still running on @MainActor.
        //
        // Surgical fix: keep the fire-and-forget sync signature so the 8
        // existing call sites (assign/remove/etc.) don't need to migrate to
        // async, but spawn a detached Task internally so the PhotoKit work
        // happens off-main. Hop back to @MainActor only to assign `self.albums`.
        // Callers that synchronously read `albums` immediately after invoking
        // `loadAlbums()` will see a transient empty list — but the only such
        // call site (AlbumsListView.task) already has the `didLoadOnce` flag
        // from PR #41 to handle the empty-vs-loading distinction.
        let adapter = self.adapter
        Task {
            let collected = await Task.detached(priority: .userInitiated) { () -> [Album] in
                var result: [Album] = []
                let fetchResult = adapter.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                fetchResult.enumerateObjects { collection, _, _ in
                    let estimated = collection.estimatedAssetCount
                    let count = estimated == NSNotFound
                        ? adapter.fetchAssets(in: collection, options: nil).count
                        : estimated
                    result.append(Album(
                        id: collection.localIdentifier,
                        title: collection.localizedTitle ?? "Untitled",
                        count: count
                    ))
                }
                return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }.value

            self.albums = collected
            AlbumManager.signposter.endInterval("loadAlbums", state)
        }
    }

    /// Returns the `PHAsset.localIdentifier`s of every asset in the album
    /// identified by `albumLocalIdentifier`.
    ///
    /// Uses a direct `PHAssetCollection` fetch by identifier so that no prior
    /// `loadAlbums()` call is required. Returns an empty array if the collection
    /// cannot be found or the app lacks photo-library access.
    func memberAssetIDs(of albumLocalIdentifier: String) -> [String] {
        let signpostID = AlbumManager.signposter.makeSignpostID()
        let state = AlbumManager.signposter.beginInterval("memberAssetIDs", id: signpostID)
        defer { AlbumManager.signposter.endInterval("memberAssetIDs", state) }

        let result = adapter.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = result.firstObject else { return [] }
        var ids: [String] = []
        let assets = adapter.fetchAssets(in: collection, options: nil)
        assets.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    // MARK: - Write

    /// The outcome of an `assignAndResolve` call.
    ///
    /// `.added` and `.alreadyMember` both carry the resolved
    /// `PHAssetCollection.localIdentifier` so callers can record a
    /// duplicate-name-safe undo entry. `.alreadyMember` lets callers skip
    /// recording a phantom decision when the asset was already in the album
    /// before the call (S-1 idempotency).
    enum AssignResult: Equatable {
        case added(albumID: String)
        case alreadyMember(albumID: String)
        case failed
    }

    /// Adds an asset to a named album, creating the album if it does not exist.
    ///
    /// Title-only API kept for `AlbumOperations` protocol parity and for the
    /// Move-rollback path in `AlbumReviewViews`. New call sites that need to
    /// record an undo entry should use `assignAndResolve` instead so that the
    /// resolved `PHAssetCollection.localIdentifier` can be threaded into the
    /// `DecisionLog`.
    func assign(_ asset: PHAsset, toAlbumNamed name: String) async -> Bool {
        switch await assignAndResolve(asset, toAlbumNamed: name) {
        case .added, .alreadyMember:
            return true
        case .failed:
            return false
        }
    }

    /// Adds an asset to a named album (creating it if missing) and returns the
    /// resolved album `localIdentifier` together with whether the add was a
    /// no-op because the asset was already a member.
    ///
    /// - The membership check is performed against the resolved
    ///   `PHAssetCollection` *before* the `performChanges` block so callers can
    ///   skip recording a phantom undo entry on a no-op (S-1).
    /// - The returned `albumID` lets callers record an undo decision that
    ///   targets the exact collection — Photos.app permits duplicate-named
    ///   albums and a title-based undo would otherwise mutate a sibling.
    func assignAndResolve(_ asset: PHAsset, toAlbumNamed name: String) async -> AssignResult {
        do {
            let collection = try await findOrCreateAlbum(named: name)
            let albumID = collection.localIdentifier
            if isAsset(asset, memberOf: collection) {
                return .alreadyMember(albumID: albumID)
            }
            try await adapter.performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.addAssets([asset] as NSArray)
            }
            await waitForLibraryWriteToSettle()
            loadAlbums()
            return .added(albumID: albumID)
        } catch {
            lastError = error.localizedDescription
            return .failed
        }
    }

    /// Adds an asset to the album identified by `albumLocalIdentifier`.
    ///
    /// Used by `DecisionLog.redo()` so a redo targets the exact collection the
    /// original assignment landed in, never a duplicate-named sibling.
    /// Returns `false` (and sets `lastError`) if the album no longer exists or
    /// the Photos change request fails.
    func assign(_ asset: PHAsset, toAlbumWithID albumLocalIdentifier: String) async -> Bool {
        let result = adapter.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = result.firstObject else {
            lastError = "Album not found."
            return false
        }
        if isAsset(asset, memberOf: collection) {
            // Already a member — treat as success so redo is idempotent.
            return true
        }
        do {
            try await adapter.performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.addAssets([asset] as NSArray)
            }
            await waitForLibraryWriteToSettle()
            loadAlbums()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// `true` iff `asset` is currently a member of `collection`.
    // MARK: - macOS write-settle delay

    /// Briefly yields after a `performChanges` write so that the subsequent
    /// `loadAlbums()` fetch sees up-to-date counts.
    ///
    /// On iOS the change notification is delivered before `performChanges`
    /// resumes, so a same-runloop fetch is already consistent. On macOS the
    /// notification fan-out is more loosely coupled to the change request —
    /// in practice an immediate fetch can return stale per-album counts for
    /// ~50–150 ms after a successful write. A user-visible symptom: the toast
    /// says "Moved to <Album>" but the source album's count stays unchanged
    /// until the user navigates away and back.
    ///
    /// Pure delay (rather than blocking on `PHPhotoLibraryChangeObserver`) is
    /// the right primitive here because:
    /// - the change observer is debounced upstream in `PhotoController`, so
    ///   coupling write completion to the observer would re-introduce that
    ///   debounce window;
    /// - the observer fires for every library change, not just the one we
    ///   just made — awaiting "the next observer fire" would race with
    ///   unrelated changes (e.g. iCloud Shared Library);
    /// - the delay is bounded and small enough not to be perceptible.
    ///
    /// No-op on iOS.
    private func waitForLibraryWriteToSettle() async {
        #if os(macOS)
        try? await Task.sleep(for: .milliseconds(150))
        #endif
    }

    private func isAsset(_ asset: PHAsset, memberOf collection: PHAssetCollection) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier = %@", asset.localIdentifier)
        options.fetchLimit = 1
        return adapter.fetchAssets(in: collection, options: options).count > 0
    }

    /// Removes an asset from a named album. Does not delete the album itself.
    /// Returns `false` (and sets `lastError`) if the album does not exist or the
    /// Photos change request fails.
    ///
    /// Note: Photos.app permits multiple albums to share the same title. When
    /// the caller has the collection's `localIdentifier` available, prefer
    /// `remove(_:fromAlbumWithID:)` to avoid mutating a sibling album that
    /// happens to share the name.
    func remove(_ asset: PHAsset, fromAlbumNamed name: String) async -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", name)
        let existing = adapter.fetchAssetCollections(with: .album, subtype: .any, options: options)
        guard let collection = existing.firstObject else {
            lastError = "Album \"\(name)\" not found."
            return false
        }
        return await performRemove(asset, from: collection)
    }

    /// Removes an asset from the album identified by `albumLocalIdentifier`.
    ///
    /// Prefer this over `remove(_:fromAlbumNamed:)` whenever the album's
    /// `localIdentifier` is available: Photos.app permits duplicate-named
    /// albums and a title-based lookup may target the wrong collection.
    func remove(_ asset: PHAsset, fromAlbumWithID albumLocalIdentifier: String) async -> Bool {
        let result = adapter.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = result.firstObject else {
            lastError = "Album not found."
            return false
        }
        return await performRemove(asset, from: collection)
    }

    /// Internal so `AlbumManagerTests` can drive the F-03 membership guard
    /// without needing to fabricate a populated `PHFetchResult` from the
    /// fake adapter (PHFetchResult has no public init). Tests construct a
    /// stub `PHAssetCollection` subclass directly and call this method —
    /// the path under test (the guard) does not depend on the collection's
    /// internal state, only on the fake adapter's `fetchAssets(in:options:)`
    /// returning empty.
    internal func performRemove(_ asset: PHAsset, from collection: PHAssetCollection) async -> Bool {
        // F-03: pre-check membership before the `performChanges` call.
        //
        // PhotoKit's `PHAssetCollectionChangeRequest.removeAssets(_:)` is
        // idempotent at the collection level — passing an asset that is not
        // a member resolves successfully and the change request completes
        // with no error. From `AlbumManager`'s perspective the call returned
        // `true`, which the undo path then converts into a phantom "Removed
        // from <Album>" toast even though the library is unchanged.
        //
        // The fix has to live here (not in `DecisionLog`) so every removal
        // entry point — direct remove from the album detail view, the move
        // flow's source-remove, and `DecisionLog.undo()`'s rollback of a
        // recorded assignment — benefits from the same guard.
        guard isAsset(asset, memberOf: collection) else {
            lastError = "Asset is no longer in the album."
            return false
        }
        do {
            try await adapter.performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.removeAssets([asset] as NSArray)
            }
            await waitForLibraryWriteToSettle()
            loadAlbums()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Tracks in-flight find-or-create work per album name so concurrent
    /// callers serialize on the same `Task` instead of each running an
    /// independent fetch + create, which would race and duplicate the album.
    private var pendingCreations: [String: Task<PHAssetCollection, Error>] = [:]

    /// Resolve an album by title, creating it if missing.
    ///
    /// Photos.app permits multiple albums with identical titles; once a
    /// duplicate exists, the title-based fallback paths (`remove(_:fromAlbumNamed:)`,
    /// `DecisionLog` undo on legacy entries) can no longer disambiguate. Without
    /// the per-name `Task` cache below, two concurrent assigns to the same name
    /// (the batch-select dialog re-tapped, or two suggestion accepts that
    /// happen to target the same fresh name) both miss the existence check and
    /// both issue creationRequests, producing the very duplicate that breaks
    /// downstream lookup.
    ///
    /// Because `AlbumManager` is `@MainActor`, the `pendingCreations`
    /// dictionary writes are serialized; the second caller sees the first
    /// caller's task already in flight and awaits it instead of starting a new
    /// one. If the task throws, both awaiters receive the same error.
    private func findOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        if let inFlight = pendingCreations[name] {
            return try await inFlight.value
        }
        let task = Task { try await actuallyFindOrCreateAlbum(named: name) }
        pendingCreations[name] = task
        defer { pendingCreations[name] = nil }
        return try await task.value
    }

    private func actuallyFindOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        // F-04: Photos.app permits multiple user albums with identical titles.
        // The previous implementation used `existing.firstObject` directly,
        // which is non-deterministic — PhotoKit enumerates collections in
        // creation order on iOS but the order is not part of any public
        // contract and macOS has been observed to differ. Without a tie
        // breaker, two albums called "Sunset" silently bind to whichever
        // PhotoKit emits first.
        //
        // Fix: ask PhotoKit to sort by `creationDate` descending so
        // `firstObject` deterministically resolves to the **most recently
        // created** album of that title. The intuition: when the user types
        // "Sunset" into the custom-album naming sheet, they almost certainly
        // mean the one they made most recently — older duplicates are
        // typically the abandoned half of a forgotten rename.
        //
        // When the lookup actually disambiguates (count > 1) we log the
        // event so we can see in Console whether duplicate-named albums are
        // common enough to warrant a UI-level warning in the naming sheet.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", name)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let existing = adapter.fetchAssetCollections(with: .album, subtype: .any, options: options)
        if existing.count > 1 {
            albumLog.notice("findOrCreateAlbum: disambiguated \(existing.count, privacy: .public) albums titled \"\(name, privacy: .public)\" — picking most recently created")
        }
        if let found = existing.firstObject {
            return found
        }

        // Otherwise create it.
        var placeholder: PHObjectPlaceholder?
        try await adapter.performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier else {
            throw AlbumError.creationFailed
        }
        let created = adapter.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil
        )
        guard let collection = created.firstObject else {
            throw AlbumError.creationFailed
        }
        return collection
    }

    enum AlbumError: LocalizedError {
        case creationFailed
        var errorDescription: String? {
            switch self {
            case .creationFailed: return "Could not create the album."
            }
        }
    }
}
