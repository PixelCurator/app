@preconcurrency import Photos
@testable import PixelCurator

// MARK: - FakePHPhotoLibraryAdapter

/// Test fake that lets `AlbumManagerTests` inject deterministic Sad-Path
/// behaviour into the only async-throwing surface of the PhotoKit seam,
/// `performChanges`.
///
/// Why the fake is a class (not a struct) even though the protocol refines
/// `Sendable`: tests need to mutate `performChangesCallCount` and read it back
/// from the test body, and they need to swap `performChangesResult` between
/// records. The class is marked `@unchecked Sendable` because access is gated
/// by the test runner on a single actor (typically `@MainActor`) — there is
/// no cross-actor concurrent mutation in practice.
///
/// The fetch methods produce empty `PHFetchResult`s by calling the real
/// `PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:options:)`
/// with a guaranteed-nonexistent identifier. `PHFetchResult` has no public
/// initialiser, so this is the only legal way to fabricate an empty result.
/// Because of that constraint, every fake fetch returns "no albums found" —
/// tests that exercise `findOrCreateAlbum`'s create-path benefit, since the
/// existence check always misses and the code falls through to the
/// `performChanges` creation request, which the fake controls.
final class FakePHPhotoLibraryAdapter: PHPhotoLibraryAdapter, @unchecked Sendable {

    // MARK: - performChanges scripting

    /// What the next `performChanges(_:)` call should do. Default: succeed
    /// (execute the closure and return).
    var performChangesResult: Result<Void, Error> = .success(())

    /// Number of `performChanges(_:)` invocations seen, lifetime of the fake.
    /// Used by the concurrent-create test to assert the dedup behaviour:
    /// two concurrent `assignAndResolve` calls to the same fresh album name
    /// should issue exactly one creation `performChanges`, not two.
    private(set) var performChangesCallCount = 0

    /// Optional artificial delay (seconds) before `performChanges` returns —
    /// used by the concurrent test to widen the race window so two callers
    /// reliably overlap inside `findOrCreateAlbum`.
    var performChangesDelay: TimeInterval = 0

    /// Whether to invoke the change block on success. Defaults to `false`
    /// because `PHAssetCollectionChangeRequest.creationRequestForAssetCollection`
    /// crashes when called outside a real PhotoKit `performChanges` context —
    /// the closure's side effects are not testable without a real photo
    /// library anyway. Tests that need to observe the closure being entered
    /// (none currently) can flip this to `true`.
    var invokesChangeBlock: Bool = false

    // MARK: - Fetch scripting (F-04)

    /// Captures the `PHFetchOptions` from the most recent title-predicate
    /// `fetchAssetCollections(with:subtype:options:)` call. F-04 tests assert
    /// on the sort descriptor / predicate combination passed to the seam to
    /// pin the deterministic-disambiguation contract.
    private(set) var lastTitlePredicateOptions: PHFetchOptions?

    // MARK: - PHPhotoLibraryAdapter

    func performChanges(_ changeBlock: @escaping () -> Void) async throws {
        performChangesCallCount += 1
        if performChangesDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(performChangesDelay * 1_000_000_000))
        }
        switch performChangesResult {
        case .success:
            if invokesChangeBlock {
                changeBlock()
            }
        case .failure(let error):
            throw error
        }
    }

    func fetchAssetCollections(
        with type: PHAssetCollectionType,
        subtype: PHAssetCollectionSubtype,
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAssetCollection> {
        // Capture options whenever the call carries a predicate — that is the
        // "find album by title" code path that F-04 inspects. The top-level
        // album-list refresh issues this method with `options == nil` and
        // must not clobber the F-04 capture.
        if options?.predicate != nil {
            lastTitlePredicateOptions = options
        }
        return Self.emptyAssetCollections()
    }

    func fetchAssetCollections(
        withLocalIdentifiers identifiers: [String],
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAssetCollection> {
        Self.emptyAssetCollections()
    }

    func fetchAssets(
        in collection: PHAssetCollection,
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAsset> {
        // Always empty: the F-03 guard treats an empty membership result as
        // "asset is not in this album", which is exactly the no-op-remove
        // scenario the tests pin.
        Self.emptyAssets()
    }

    // MARK: - Empty PHFetchResult fabrication

    /// `PHFetchResult` is opaque (no public init), so the only way to
    /// produce an empty one is to fetch by an identifier no album can have.
    private static func emptyAssetCollections() -> PHFetchResult<PHAssetCollection> {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: ["__pixelcurator_test_nonexistent_album_id__"],
            options: nil
        )
    }

    private static func emptyAssets() -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(
            withLocalIdentifiers: ["__pixelcurator_test_nonexistent_asset_id__"],
            options: nil
        )
    }
}
