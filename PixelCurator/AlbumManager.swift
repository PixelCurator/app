@preconcurrency import Photos
import SwiftUI
import OSLog

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

    // MARK: - Read

    func loadAlbums() {
        let signpostID = AlbumManager.signposter.makeSignpostID()
        let state = AlbumManager.signposter.beginInterval("loadAlbums", id: signpostID)
        defer { AlbumManager.signposter.endInterval("loadAlbums", state) }

        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var collected: [Album] = []
        result.enumerateObjects { collection, _, _ in
            // Use PhotoKit's fast-path count cache (`estimatedAssetCount`) instead
            // of running a full `PHAsset.fetchAssets(in:).count` per album. The
            // full fetch is O(assets-in-album) and was the dominant blocker of
            // the main thread — a library with 50 albums × 10k photos spent
            // multiple seconds inside this enumeration on every `loadAlbums()`
            // call, which fires after every assign / remove / library-change.
            //
            // `estimatedAssetCount` returns `NSNotFound` when PhotoKit hasn't
            // populated the cache yet (typically first cold open). Fall back to
            // the precise fetch in that case so the count is never wrong, just
            // potentially slow on the very first read.
            let estimated = collection.estimatedAssetCount
            let count = estimated == NSNotFound
                ? PHAsset.fetchAssets(in: collection, options: nil).count
                : estimated
            collected.append(Album(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                count: count
            ))
        }
        albums = collected.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Returns the `PHAsset.localIdentifier`s of every asset in the album
    /// identified by `albumLocalIdentifier`.
    ///
    /// Uses a direct `PHAssetCollection` fetch by identifier so that no prior
    /// `loadAlbums()` call is required. Returns an empty array if the collection
    /// cannot be found or the app lacks photo-library access.
    func memberAssetIDs(of albumLocalIdentifier: String) -> [String] {
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = result.firstObject else { return [] }
        var ids: [String] = []
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
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
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.addAssets([asset] as NSArray)
            }
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
        let result = PHAssetCollection.fetchAssetCollections(
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
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.addAssets([asset] as NSArray)
            }
            loadAlbums()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// `true` iff `asset` is currently a member of `collection`.
    private func isAsset(_ asset: PHAsset, memberOf collection: PHAssetCollection) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier = %@", asset.localIdentifier)
        options.fetchLimit = 1
        return PHAsset.fetchAssets(in: collection, options: options).count > 0
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
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
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
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = result.firstObject else {
            lastError = "Album not found."
            return false
        }
        return await performRemove(asset, from: collection)
    }

    private func performRemove(_ asset: PHAsset, from collection: PHAssetCollection) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.removeAssets([asset] as NSArray)
            }
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
        // Existing album with this exact title?
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", name)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        if let found = existing.firstObject {
            return found
        }

        // Otherwise create it.
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier else {
            throw AlbumError.creationFailed
        }
        let created = PHAssetCollection.fetchAssetCollections(
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
