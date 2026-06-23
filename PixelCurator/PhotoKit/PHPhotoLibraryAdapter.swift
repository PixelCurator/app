@preconcurrency import Photos

// MARK: - PHPhotoLibraryAdapter (testable seam for AlbumManager)

/// A narrow protocol over the subset of PhotoKit `AlbumManager` calls — the
/// album-mutation `performChanges` entry point plus the three read paths
/// (`PHAssetCollection.fetchAssetCollections(...)` × 2 and
/// `PHAsset.fetchAssets(in:)`).
///
/// Extracting this seam makes `AlbumManager` directly unit-testable: a fake
/// adapter can simulate iCloud / authorization errors from `performChanges`
/// (the only async-throwing surface), and the per-name dedup of
/// `findOrCreateAlbum` can be exercised deterministically without touching the
/// real PhotoKit singleton.
///
/// **Invariant — all album mutation must flow through `performChanges`.**
/// Direct calls to `PHAsset` / `PHAssetCollection` mutation APIs outside of
/// this closure are unsafe (batching, atomicity, error surface). This protocol
/// preserves that invariant by funnelling the only mutation entry point
/// through one method.
///
/// **Why fetches are protocol-level rather than static class calls:**
/// `AlbumManager.findOrCreateAlbum` reads "does this title already exist?"
/// before issuing the creation `performChanges`. Tests that need to exercise
/// the create-path (or the duplicate-name dedup path) require deterministic
/// control over that fetch result. Real `PHFetchResult` cannot be constructed
/// by client code, so the fake produces empty results by calling
/// `PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ["__none__"], …)`
/// — see `FakePHPhotoLibraryAdapter`.
protocol PHPhotoLibraryAdapter: Sendable {
    /// Wraps `PHPhotoLibrary.shared().performChanges(_:)` — the single
    /// throwing entry point for album mutation. The fake injects typed errors
    /// (`PHPhotosError.accessRestricted`, `.networkAccessRequired`, …) here so
    /// `AlbumManager`'s `lastError` and `AssignResult.failed` paths can be
    /// pinned without a real photo library.
    func performChanges(_ changeBlock: @escaping () -> Void) async throws

    /// Wraps the class-level `PHAssetCollection.fetchAssetCollections(with:subtype:options:)`.
    func fetchAssetCollections(
        with type: PHAssetCollectionType,
        subtype: PHAssetCollectionSubtype,
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAssetCollection>

    /// Wraps the class-level `PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:options:)`.
    func fetchAssetCollections(
        withLocalIdentifiers identifiers: [String],
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAssetCollection>

    /// Wraps the class-level `PHAsset.fetchAssets(in:options:)`.
    func fetchAssets(
        in collection: PHAssetCollection,
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAsset>
}

// MARK: - Production conformance

/// Production conformance over the real `PHPhotoLibrary.shared()` singleton
/// and the `PHAssetCollection` / `PHAsset` class-level fetch methods.
///
/// This is the only place inside the album path where `PHPhotoLibrary.shared()`
/// is referenced directly — the rest of `AlbumManager` reads and writes through
/// the protocol.
struct LivePHPhotoLibraryAdapter: PHPhotoLibraryAdapter {
    func performChanges(_ changeBlock: @escaping () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(changeBlock)
    }

    func fetchAssetCollections(
        with type: PHAssetCollectionType,
        subtype: PHAssetCollectionSubtype,
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAssetCollection> {
        PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: options)
    }

    func fetchAssetCollections(
        withLocalIdentifiers identifiers: [String],
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAssetCollection> {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: identifiers, options: options)
    }

    func fetchAssets(
        in collection: PHAssetCollection,
        options: PHFetchOptions?
    ) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(in: collection, options: options)
    }
}
