@preconcurrency import Photos
import SwiftUI

/// Owns photo-library authorization and asset/thumbnail access via PhotoKit.
/// This is the iOS/macOS replacement for the Python `osxphotos` + derivative-path layer.
@MainActor
@Observable
final class PhotoController {

    enum AuthState: Equatable {
        case unknown, authorized, limited, denied, restricted
    }

    var authState: AuthState = .unknown
    var assets: [PHAsset] = []

    private let imageManager = PHCachingImageManager()

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
}
