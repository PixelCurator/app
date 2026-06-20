@preconcurrency import Photos
import SwiftUI

/// Owns photo-library authorization and asset/thumbnail access via PhotoKit.
/// This is the iOS/macOS replacement for the Python `osxphotos` + derivative-path layer.
///
/// Also registers as a `PHPhotoLibraryChangeObserver` so external mutations
/// (Photos.app deletions, iCloud Shared Library sync, the user revoking
/// limited-access permissions) reload the asset list and fire a debounced
/// `onLibraryDidChange` callback that the app uses to cascade-prune stale
/// derived data (embeddings, corrections, decision history).
@MainActor
@Observable
final class PhotoController: NSObject, PHPhotoLibraryChangeObserver {

    enum AuthState: Equatable {
        case unknown, authorized, limited, denied, restricted
    }

    var authState: AuthState = .unknown
    var assets: [PHAsset] = []

    /// Invoked on the main actor after a `PHPhotoLibrary` change has been
    /// applied to `assets`. The app wires this to a cascade prune over
    /// `EmbeddingStore`, `CorrectionStore`, and `DecisionLog` so stale derived
    /// data cannot outlive the underlying `PHAsset` / `PHAssetCollection`.
    ///
    /// Set this from `PixelCuratorApp` after the stores are constructed.
    /// Optional so unit tests and previews don't need to wire it.
    var onLibraryDidChange: (@MainActor () async -> Void)?

    private let imageManager = PHCachingImageManager()

    /// Debounce token for `photoLibraryDidChange(_:)`. Photos can deliver many
    /// change callbacks in a tight burst (e.g. iCloud Shared Library re-sync,
    /// album reorder); coalesce them into one reload + prune.
    private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(200)

    // MARK: - Init / deinit

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        // `unregisterChangeObserver` is safe to call from any thread.
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - Authorization

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        apply(status)
        if authState == .authorized || authState == .limited {
            loadAssets()
        }
    }

    func refreshAuthState() {
        apply(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private func apply(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: authState = .authorized
        case .limited:    authState = .limited
        case .denied:     authState = .denied
        case .restricted: authState = .restricted
        default:          authState = .unknown
        }
    }

    // MARK: - Assets

    /// Loads image assets newest-first. `limit == 0` (the default) loads the
    /// entire library — required so that every existing-album photo is embedded
    /// and available as a labeled point for `AlbumSuggester`, and so the sorting
    /// inbox sees all unsorted photos rather than only the 500 most recent.
    func loadAssets(limit: Int = 0) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if limit > 0 {
            options.fetchLimit = limit
        }
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var collected: [PHAsset] = []
        collected.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        assets = collected
    }

    // MARK: - Thumbnails

    /// Loads a single thumbnail. Uses .highQualityFormat so the completion
    /// handler fires exactly once (opportunistic mode fires multiple times,
    /// which is incompatible with a single continuation resume).
    func thumbnail(for asset: PHAsset, size: CGSize) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - CGImage (for ML inference)

    /// Returns a CGImage for `asset` at the given `targetSize`, or `nil` on failure.
    ///
    /// Uses `.highQualityFormat` so the completion fires exactly once.
    /// Network access is disabled — inference works on locally available copies.
    func requestCGImage(for asset: PHAsset, targetSize: CGSize) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
#if canImport(UIKit)
                continuation.resume(returning: image?.cgImage)
#else
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
#endif
            }
        }
    }

    // MARK: - PHPhotoLibraryChangeObserver

    /// Apple delivers this on an unspecified background queue. We hop to the
    /// main actor and debounce — multiple changes arriving in a tight burst
    /// (a typical iCloud Shared Library sync coalesces dozens) collapse into
    /// one reload + cascade prune.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.scheduleLibraryReload()
        }
    }

    /// Coalesces a burst of `photoLibraryDidChange` notifications into one
    /// reload at the trailing edge of `debounceInterval`. Cancels the
    /// in-flight debounce task each time so only the last call wins.
    private func scheduleLibraryReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            await self.handleLibraryChange()
        }
    }

    /// The debounced response to a library change:
    ///   1. Re-derive `authState` — the user may have changed limited-library
    ///      selections or revoked access entirely.
    ///   2. Reload assets (newest-first, no limit) and have `AlbumManager`
    ///      reload albums — both are read off `PHFetchResult` snapshots that
    ///      are now stale.
    ///   3. Invoke `onLibraryDidChange` so the app can cascade-prune derived
    ///      data against the freshly-loaded asset / album sets.
    private func handleLibraryChange() async {
        refreshAuthState()
        guard authState == .authorized || authState == .limited else {
            // Access revoked. Clear the local cache so views don't show ghost
            // thumbnails for assets we can no longer fetch.
            assets = []
            await onLibraryDidChange?()
            return
        }
        loadAssets()
        await onLibraryDidChange?()
    }
}
