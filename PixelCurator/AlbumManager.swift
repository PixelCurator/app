@preconcurrency import Photos
import SwiftUI

/// Reads and writes Photos.app albums via PhotoKit — the iOS/macOS replacement
/// for the Python `photoscript` layer. Writing an asset into an album here makes
/// it appear in the real Photos.app, which is the core "commit" operation.
@MainActor
@Observable
final class AlbumManager {

    struct Album: Identifiable, Hashable {
        let id: String          // localIdentifier
        let title: String
        let count: Int
    }

    var albums: [Album] = []
    var lastError: String?

    // MARK: - Read

    func loadAlbums() {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var collected: [Album] = []
        result.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            collected.append(Album(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                count: count
            ))
        }
        albums = collected.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Write

    /// Adds an asset to a named album, creating the album if it does not exist.
    func assign(_ asset: PHAsset, toAlbumNamed name: String) async -> Bool {
        do {
            let collection = try await findOrCreateAlbum(named: name)
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

    private func findOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
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
