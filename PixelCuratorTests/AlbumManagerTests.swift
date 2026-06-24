import XCTest
@preconcurrency import Photos
@testable import PixelCurator

// MARK: - AlbumManagerTests (T-4)
//
// Direct unit coverage of `AlbumManager` via the `PHPhotoLibraryAdapter` seam
// extracted in T-4. Tests pin Sad-Path behaviour that UI tests can't reach
// reliably: typed PhotoKit errors surfacing through `lastError`, the
// `pendingCreations` dedup of concurrent creates, and graceful handling when
// the underlying `performChanges` fails between an asset's resolution and the
// album write.
//
// Coverage limitation: `PHFetchResult` has no public initialiser, so the fake
// can only fabricate *empty* fetch results (via a guaranteed-nonexistent
// identifier). This means:
//   • The "album already exists" branch of `findOrCreateAlbum` cannot be
//     exercised under the fake — every assign falls through to the create
//     path. Happy-path "album already exists" coverage stays in
//     `AlbumManagerPerformanceTests` (which uses the seeded simulator library).
//   • `assignAndResolve`'s happy-path success cannot be observed end-to-end
//     because the production closure relies on
//     `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`
//     populating a `placeholderForCreatedAssetCollection`, which requires a
//     real photo library context. The fake therefore does not execute the
//     change closure — every fresh-album create resolves to `.failed` with
//     `AlbumError.creationFailed`. The tests below assert this is consistent.
//
// What we *can* and do pin:
//   1. `PHPhotosError.accessRestricted` from `performChanges` → `.failed` + typed message
//   2. `PHPhotosError.networkAccessRequired` from `performChanges` → `.failed` + typed message
//   3. Concurrent `assignAndResolve` to the same fresh name → exactly one
//      `performChanges` invocation thanks to the `pendingCreations` task cache
//   4. Asset-deleted-between-fetch-and-write simulated via a typed error from
//      `performChanges` mid-flight → `.failed`, no crash, `lastError` set
//   5. `remove(_:fromAlbumNamed:)` returns false when fetch finds no album,
//      sets a descriptive `lastError`
//   6. `remove(_:fromAlbumWithID:)` returns false when fetch finds no
//      album-by-id, sets a descriptive `lastError`

@MainActor
final class AlbumManagerTests: XCTestCase {

    // MARK: - Sad-path: PHPhotosError.accessRestricted

    /// Scenario: the user revoked Photos access between authorization and
    /// `assign`. `performChanges` surfaces a `PHPhotosError.accessRestricted`.
    /// AlbumManager must catch the throw, return `.failed`, and expose the
    /// system-localised error string via `lastError`.
    func testAssignAndResolve_accessRestricted_returnsFailedAndSetsLastError() async {
        let fake = FakePHPhotoLibraryAdapter()
        fake.performChangesResult = .failure(
            NSError(
                domain: PHPhotosErrorDomain,
                code: PHPhotosError.accessRestricted.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Access to Photos is restricted."]
            )
        )
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        let result = await manager.assignAndResolve(asset, toAlbumNamed: "Vacation")

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(manager.lastError, "Access to Photos is restricted.")
        XCTAssertEqual(fake.performChangesCallCount, 1,
                       "Exactly one performChanges call — the create attempt that threw")
    }

    // MARK: - Sad-path: PHPhotosError.networkAccessRequired (iCloud)

    /// Scenario: the target asset is iCloud-backed and the album write
    /// requires a network fetch. `performChanges` throws
    /// `PHPhotosError.networkAccessRequired`. AlbumManager must surface the
    /// typed error, not crash.
    func testAssignAndResolve_networkAccessRequired_returnsFailedAndSetsLastError() async {
        let fake = FakePHPhotoLibraryAdapter()
        fake.performChangesResult = .failure(
            NSError(
                domain: PHPhotosErrorDomain,
                code: PHPhotosError.networkAccessRequired.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Network access required for iCloud asset."]
            )
        )
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-icloud-1")

        let result = await manager.assignAndResolve(asset, toAlbumNamed: "Trips")

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(manager.lastError, "Network access required for iCloud asset.")
    }

    // MARK: - Concurrent create-album dedup (pendingCreations cache)

    /// Two concurrent `assignAndResolve` calls to the same fresh album name
    /// must share one in-flight `findOrCreateAlbum` task — otherwise both
    /// callers would issue a creation `performChanges` and Photos.app would
    /// end up with two duplicate-titled albums (which permanently breaks
    /// title-based remove / DecisionLog by-name fallback).
    ///
    /// The fake widens the race window with a small delay so both callers are
    /// reliably overlapping inside `actuallyFindOrCreateAlbum` when the second
    /// arrives at `pendingCreations[name]`.
    ///
    /// Because `PHFetchResult` cannot be stubbed to "found", both calls
    /// terminate in `.failed` (placeholder never populated → `AlbumError.creationFailed`).
    /// The point being asserted here is **call-count dedup**, not the outcome.
    func testAssignAndResolve_concurrentSameName_dedupsCreationCall() async {
        let fake = FakePHPhotoLibraryAdapter()
        fake.performChangesDelay = 0.05  // wide enough for both callers to enqueue
        let manager = AlbumManager(adapter: fake)
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")

        async let r1 = manager.assignAndResolve(asset1, toAlbumNamed: "ConcurrentAlbum")
        async let r2 = manager.assignAndResolve(asset2, toAlbumNamed: "ConcurrentAlbum")

        let (result1, result2) = await (r1, r2)

        // Both fail because the fake cannot fabricate a "found" PHFetchResult
        // and the placeholder is never populated. The contract being pinned is
        // that the **shared in-flight task** was used: exactly one
        // performChanges invocation for the (shared) creation attempt.
        XCTAssertEqual(result1, .failed)
        XCTAssertEqual(result2, .failed)
        XCTAssertEqual(fake.performChangesCallCount, 1,
                       "Both concurrent assigns to the same fresh name must share one in-flight creation Task")
    }

    // MARK: - Asset-deleted-between-fetch-and-write

    /// Scenario: by the time `performChanges` runs, the underlying asset has
    /// been deleted (e.g. user emptied Recently Deleted in another window).
    /// Photos raises a non-domain-specific NSError. AlbumManager must catch
    /// and surface it without crashing — never propagate an uncaught throw
    /// into `@Observable` mutation.
    func testAssignAndResolve_assetDeletedDuringPerformChanges_handlesGracefully() async {
        let fake = FakePHPhotoLibraryAdapter()
        fake.performChangesResult = .failure(
            NSError(
                domain: PHPhotosErrorDomain,
                code: PHPhotosError.invalidResource.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "The requested resource is no longer available."]
            )
        )
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-just-deleted")

        let result = await manager.assignAndResolve(asset, toAlbumNamed: "DoesNotMatter")

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(manager.lastError, "The requested resource is no longer available.")
    }

    // MARK: - remove by-name when album fetch finds nothing

    /// `remove(_:fromAlbumNamed:)` must return `false` and populate
    /// `lastError` with a user-presentable string when the title resolves to
    /// no collection. Distinct from the throw paths above — this is the
    /// pre-`performChanges` early-out.
    func testRemoveByName_albumNotFound_returnsFalseAndSetsLastError() async {
        let fake = FakePHPhotoLibraryAdapter()
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        let ok = await manager.remove(asset, fromAlbumNamed: "NonexistentAlbum")

        XCTAssertFalse(ok)
        XCTAssertEqual(manager.lastError, "Album \"NonexistentAlbum\" not found.")
        XCTAssertEqual(fake.performChangesCallCount, 0,
                       "No performChanges issued when the album can't be resolved")
    }

    // MARK: - remove by-id when album fetch finds nothing

    func testRemoveByID_albumNotFound_returnsFalseAndSetsLastError() async {
        let fake = FakePHPhotoLibraryAdapter()
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        let ok = await manager.remove(asset, fromAlbumWithID: "stale-local-identifier")

        XCTAssertFalse(ok)
        XCTAssertEqual(manager.lastError, "Album not found.")
        XCTAssertEqual(fake.performChangesCallCount, 0)
    }

    // MARK: - assign(by-id) when album fetch finds nothing

    /// Used by `DecisionLog.redo()` — if the target album has been deleted
    /// between the original assign and the redo, the by-id fetch returns
    /// empty and `assign` must surface that, not crash.
    func testAssignByID_albumNotFound_returnsFalseAndSetsLastError() async {
        let fake = FakePHPhotoLibraryAdapter()
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        let ok = await manager.assign(asset, toAlbumWithID: "stale-local-identifier")

        XCTAssertFalse(ok)
        XCTAssertEqual(manager.lastError, "Album not found.")
        XCTAssertEqual(fake.performChangesCallCount, 0)
    }

    // MARK: - F-03: remove pre-checks membership

    /// **F-03**: PhotoKit's `PHAssetCollectionChangeRequest.removeAssets(_:)`
    /// is idempotent — passing an asset that is not a member of the collection
    /// resolves successfully. Without a pre-check `AlbumManager` would return
    /// `true` for a no-op remove and the undo path would render a phantom
    /// "Removed from <Album>" toast.
    ///
    /// The fake adapter cannot fabricate a populated `PHFetchResult<PHAssetCollection>`
    /// (PHFetchResult has no public init), so we exercise `performRemove`
    /// directly via the `@testable` internal entry point. The fake's
    /// `fetchAssets(in:options:)` already returns empty by construction —
    /// which is exactly the "asset is not a member" state the guard is meant
    /// to short-circuit on. The contract being pinned: `performRemove` must
    /// return `false`, set `lastError`, and **not** issue a `performChanges`
    /// write.
    func testPerformRemove_assetNotMemberOfAlbum_returnsFalseAndSkipsPerformChanges() async {
        let fake = FakePHPhotoLibraryAdapter()
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-not-in-album")
        let collection = StubPHAssetCollection()

        let ok = await manager.performRemove(asset, from: collection)

        XCTAssertFalse(ok, "Remove must report failure when the asset isn't actually a member")
        XCTAssertEqual(manager.lastError, "Asset is no longer in the album.")
        XCTAssertEqual(fake.performChangesCallCount, 0,
                       "F-03: no PhotoKit write may be issued for a no-op remove")
    }

    // MARK: - F-04: findOrCreateAlbum disambiguation

    /// **F-04**: when Photos.app contains duplicate-titled albums,
    /// `findOrCreateAlbum` must pick deterministically rather than letting
    /// PhotoKit pick whichever it enumerates first. The fix asks PhotoKit to
    /// sort by `creationDate` descending so `firstObject` resolves to the
    /// most-recently-created album of that title.
    ///
    /// This test pins the **contract at the seam**: the `PHFetchOptions`
    /// passed to `fetchAssetCollections(with:subtype:options:)` carries a
    /// `creationDate` descending sort descriptor and a title predicate. We
    /// cannot fabricate a populated `PHFetchResult` to exercise the picker
    /// over real collections (PHFetchResult has no public init), but pinning
    /// the seam contract is sufficient — PhotoKit's documented behaviour is
    /// to honour the sort order.
    func testFindOrCreateAlbum_passesCreationDateDescendingSortToFetch() async {
        let fake = FakePHPhotoLibraryAdapter()
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        // Trigger the find path (will create because every fake fetch is
        // empty). The interesting assertion is on the options captured by the
        // fake's title-predicate fetch, not on the eventual result.
        _ = await manager.assignAndResolve(asset, toAlbumNamed: "Sunset")

        guard let captured = fake.lastTitlePredicateOptions else {
            XCTFail("Expected `findOrCreateAlbum` to issue a title-predicate fetch with options")
            return
        }
        let descriptors = captured.sortDescriptors ?? []
        XCTAssertEqual(descriptors.count, 1, "Exactly one sort descriptor expected")
        XCTAssertEqual(descriptors.first?.key, "creationDate")
        XCTAssertEqual(descriptors.first?.ascending, false,
                       "F-04: must sort descending so firstObject = most recently created")
        XCTAssertEqual(captured.predicate?.predicateFormat, "localizedTitle == \"Sunset\"")
    }

    // MARK: - assign(toAlbumNamed:) thin wrapper preserves failure

    /// The Bool-returning `assign(_:toAlbumNamed:)` is kept for
    /// `AlbumOperations` parity and must report `false` whenever the
    /// underlying `assignAndResolve` returns `.failed`.
    func testAssignByName_propagatesFailureFromAssignAndResolve() async {
        let fake = FakePHPhotoLibraryAdapter()
        fake.performChangesResult = .failure(
            NSError(
                domain: PHPhotosErrorDomain,
                code: PHPhotosError.accessRestricted.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Access restricted."]
            )
        )
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        let ok = await manager.assign(asset, toAlbumNamed: "Vacation")

        XCTAssertFalse(ok)
        XCTAssertEqual(manager.lastError, "Access restricted.")
    }

    // MARK: - F-04: existing path still allows test of empty-result fast path

    /// When no album of the requested name exists, the count is 0 — the
    /// disambiguation logger must not fire (it only fires for `> 1` matches).
    /// This pins the no-noise behaviour: a normal user with no duplicates
    /// must not see the "disambiguated N albums" notice in Console.
    ///
    /// We can't directly assert on the Logger output in a unit test, but we
    /// can pin the fast-path return: assignAndResolve still proceeds into the
    /// create branch (which `.failed`s in the fake) and the captured options
    /// still carry the F-04 sort descriptor.
    func testFindOrCreateAlbum_noMatches_stillSetsSortDescriptorAndProceedsToCreate() async {
        let fake = FakePHPhotoLibraryAdapter()
        let manager = AlbumManager(adapter: fake)
        let asset = StubPHAsset(localIdentifier: "asset-1")

        let result = await manager.assignAndResolve(asset, toAlbumNamed: "Sunset")

        XCTAssertEqual(result, .failed,
                       "Fake can't fabricate created collections → create attempt resolves to .failed")
        XCTAssertEqual(fake.lastTitlePredicateOptions?.sortDescriptors?.first?.key, "creationDate")
        XCTAssertEqual(fake.lastTitlePredicateOptions?.sortDescriptors?.first?.ascending, false)
    }

    // MARK: - Default-init back-compat (production code constructs AlbumManager() without args)

    /// AlbumManager's default initialiser must remain callable without
    /// arguments so existing call sites (`@State private var albums = AlbumManager()`
    /// in PixelCuratorApp and the perf tests) keep compiling. This test pins
    /// the back-compat init at the surface level — it does not exercise the
    /// real PHPhotoLibrary singleton.
    func testDefaultInit_compilesAndProducesUsableInstance() {
        let manager = AlbumManager()
        XCTAssertTrue(manager.albums.isEmpty)
        XCTAssertNil(manager.lastError)
    }
}

// MARK: - StubPHAssetCollection
//
// Sibling to `StubPHAsset`. PHAssetCollection is NSObject-backed so it can be
// subclassed for tests. We don't override any properties — the F-03 tests only
// pass the instance through to `AlbumManager.performRemove`, which routes
// membership inspection back into the fake adapter.
final class StubPHAssetCollection: PHAssetCollection, @unchecked Sendable {
    override init() { super.init() }
}
