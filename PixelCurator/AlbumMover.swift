@preconcurrency import Photos
import Foundation

// MARK: - MoveOutcome

/// Result of a single Move-flow attempt. Carries enough information for the
/// caller to drive its own UI (toast, loadAssets, etc.) without re-deriving
/// state from the operations layer.
enum MoveOutcome: Equatable {
    /// Asset is now in `targetTitle` and was removed from `sourceTitle`. Both
    /// PhotoKit calls succeeded.
    case moved(sourceTitle: String, targetTitle: String)

    /// Adding to the target album failed. Asset is still only in the source
    /// album; no rollback was needed.
    case assignFailed(targetTitle: String, message: String?)

    /// Remove from source failed AFTER assign to target succeeded. The
    /// rollback (remove from target) succeeded, so the library is back to its
    /// pre-move state and the asset is still only in `sourceTitle`.
    case removeFailedRolledBack(sourceTitle: String, targetTitle: String)

    /// Remove from source failed AND the rollback also failed. The asset is
    /// currently in BOTH `sourceTitle` and `targetTitle`. Surface this
    /// explicitly so the user can fix it manually in Photos.app.
    case orphanInBothAlbums(sourceTitle: String, targetTitle: String)
}

// MARK: - AlbumMover

/// Orchestrates the assign-then-remove pair that constitutes "Move asset to
/// another album". Pure with respect to UI: it does NOT know about toasts,
/// view models, or PhotoController. The caller drives the side effects from
/// the returned `MoveOutcome`.
///
/// Single move flow used from `AlbumReviewViews.AlbumDetailView.move(...)`.
/// Tests inject any `AlbumOperations` (typically `MockAlbumOperations`) to
/// exercise the full success / failure / rollback matrix without touching
/// PhotoKit.
enum AlbumMover {

    /// Moves `asset` from `source` to `target` as assign-then-remove.
    ///
    /// Failure handling matrix:
    /// - assign fails           → `.assignFailed`           (no rollback needed)
    /// - assign ok, remove ok   → `.moved`
    /// - assign ok, remove fail, rollback ok    → `.removeFailedRolledBack`
    /// - assign ok, remove fail, rollback fail  → `.orphanInBothAlbums`
    ///
    /// - Parameters:
    ///   - asset: The PHAsset to move.
    ///   - source: A pair of (`localIdentifier`, `title`) for the source album.
    ///     `localIdentifier` is used for the remove so duplicate-named source
    ///     albums can never have their membership mutated by mistake.
    ///   - target: A pair of (`localIdentifier`, `title`) for the target album.
    ///     `localIdentifier` is used for the rollback path so the rollback
    ///     remove cannot misroute either.
    ///   - operations: The `AlbumOperations` backend. In production this is
    ///     the live `AlbumManager`; in tests it is a mock.
    static func move(
        _ asset: PHAsset,
        from source: (id: String, title: String),
        to target: (id: String, title: String),
        via operations: any AlbumOperations
    ) async -> MoveOutcome {
        let added = await operations.assign(asset, toAlbumNamed: target.title)
        guard added else {
            // assign failed — asset is still only in source, nothing to roll back.
            return .assignFailed(targetTitle: target.title, message: nil)
        }

        let removed = await operations.remove(asset, fromAlbumWithID: source.id)
        if removed {
            return .moved(sourceTitle: source.title, targetTitle: target.title)
        }

        // Remove failed after assign succeeded → asset is in both albums.
        // Try to roll back the assign by removing it from target by id.
        let rolledBack = await operations.remove(asset, fromAlbumWithID: target.id)
        if rolledBack {
            return .removeFailedRolledBack(sourceTitle: source.title, targetTitle: target.title)
        }

        // Rollback also failed — surface the double-assign so the user can fix it.
        return .orphanInBothAlbums(sourceTitle: source.title, targetTitle: target.title)
    }
}
