import Foundation
import Photos
import SwiftUI

// MARK: - AlbumOperations (testable seam)

/// A protocol that abstracts the PhotoKit assign/remove side effects so
/// DecisionLog can be driven from tests with a mock instead of a real
/// AlbumManager and a real PHPhotoLibrary.
///
/// Two parallel surfaces exist intentionally:
/// - **By-name** (`toAlbumNamed:` / `fromAlbumNamed:`) — title-based PHFetch.
///   Used as a fallback when no `PHAssetCollection.localIdentifier` is known,
///   and by paths that have not (yet) been migrated to by-id.
/// - **By-id** (`toAlbumWithID:` / `fromAlbumWithID:`) — `localIdentifier`-based
///   PHFetch. Photos.app permits duplicate-named albums, so a title lookup
///   may resolve to a different collection than the one the user actually
///   targeted. Anywhere we already have the collection's `localIdentifier`
///   (e.g. immediately after `assign` resolves), prefer the by-id surface.
protocol AlbumOperations: AnyObject {
    func assign(_ asset: PHAsset, toAlbumNamed name: String) async -> Bool
    func assign(_ asset: PHAsset, toAlbumWithID albumLocalIdentifier: String) async -> Bool
    func remove(_ asset: PHAsset, fromAlbumNamed name: String) async -> Bool
    func remove(_ asset: PHAsset, fromAlbumWithID albumLocalIdentifier: String) async -> Bool
}

// MARK: - UndoRedoStack (pure, generic, no PHAsset dependency)

/// A pure value-type stack pair that manages undo/redo bookkeeping.
/// Completely decoupled from PhotoKit so unit tests can exercise the
/// push/pop/clear-redo/canUndo/canRedo mechanics with any element type.
struct UndoRedoStack<Element> {
    private(set) var undoStack: [Element] = []
    private(set) var redoStack: [Element] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records a new element. Clears the redo stack because a new action
    /// invalidates the previously undone history.
    mutating func record(_ element: Element) {
        undoStack.append(element)
        redoStack.removeAll()
    }

    /// Pops the top undo entry, returning it. On success the caller must push
    /// the entry onto redo (via `pushRedo`) after performing the side effect.
    mutating func popUndo() -> Element? {
        undoStack.popLast()
    }

    /// Pushes a previously undone entry back onto the redo stack.
    mutating func pushRedo(_ element: Element) {
        redoStack.append(element)
    }

    /// Pops the top redo entry, returning it. On success the caller must push
    /// the entry back onto undo (via `pushUndo`) after performing the side effect.
    mutating func popRedo() -> Element? {
        redoStack.popLast()
    }

    /// Pushes a re-applied entry back onto the undo stack.
    mutating func pushUndo(_ element: Element) {
        undoStack.append(element)
    }
}

// MARK: - AssignmentDecision

struct AssignmentDecision: Identifiable, Hashable {
    let id: UUID
    let asset: PHAsset
    let albumName: String
    /// `PHAssetCollection.localIdentifier` of the album the asset was assigned to.
    ///
    /// When present, undo/redo route through the by-id `AlbumOperations` surface so
    /// duplicate-named albums (which Photos.app permits) can never silently mutate
    /// the wrong collection. Optional only to allow in-memory decisions recorded
    /// before the by-id migration to fall back to the title-based path.
    let albumLocalIdentifier: String?
    let date: Date

    init(asset: PHAsset, albumName: String, albumLocalIdentifier: String? = nil) {
        self.id = UUID()
        self.asset = asset
        self.albumName = albumName
        self.albumLocalIdentifier = albumLocalIdentifier
        self.date = Date()
    }

    // PHAsset is not Hashable by its class definition, so we hash by localIdentifier.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AssignmentDecision, rhs: AssignmentDecision) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - DecisionLog

/// Manages undo/redo of album assignments made during sorting.
///
/// The actual PhotoKit side effects (assign/remove) are injected via the
/// `AlbumOperations` protocol, keeping the stack mechanics testable without
/// a real PHPhotoLibrary.
@MainActor
@Observable
final class DecisionLog {

    // MARK: - Dependencies

    private let operations: any AlbumOperations

    // MARK: - State (via UndoRedoStack)

    private var stack = UndoRedoStack<AssignmentDecision>()

    // MARK: - Public accessors

    var undoStack: [AssignmentDecision] { stack.undoStack }
    var redoStack: [AssignmentDecision] { stack.redoStack }
    var canUndo: Bool { stack.canUndo }
    var canRedo: Bool { stack.canRedo }

    /// The album name of the last undone action, set after `undo()` succeeds.
    /// Views can observe this to display a toast ("Removed from <album>").
    private(set) var lastUndoneAlbumName: String?

    /// The album name of the last redone action, set after `redo()` succeeds.
    private(set) var lastRedoneAlbumName: String?

    /// Error from the most recent `undo()` call, or `nil` on success. Views can
    /// observe this to surface a toast and explain why nothing visibly happened
    /// (otherwise repeat-Undo failures look like silent no-ops and the toolbar
    /// button stays enabled).
    ///
    /// Kept distinct from `AlbumManager.lastError` so callers can tell apart
    /// "undo failed because remove failed" (here) vs "undo failed because
    /// nothing to undo" (would set `canUndo == false` only).
    private(set) var lastUndoError: String?

    /// Error from the most recent `redo()` call, or `nil` on success. Symmetric
    /// to `lastUndoError`.
    private(set) var lastRedoError: String?

    // MARK: - Drop-on-persistent-failure tracking

    /// Tracks the id of the decision that failed on the most recent undo/redo
    /// attempt. When the *same* decision fails twice in a row, it is dropped
    /// from its stack so the toolbar's `canUndo` / `canRedo` flag reflects
    /// reality — otherwise the button stays enabled on a permanently broken
    /// entry (e.g. the album was deleted out of band) and every tap silently
    /// re-fails.
    private var lastFailedUndoID: UUID?
    private var lastFailedRedoID: UUID?

    // MARK: - Init

    init(operations: any AlbumOperations) {
        self.operations = operations
    }

    // MARK: - Record

    /// Records a new assignment decision. Clears redo history.
    ///
    /// Pass `albumLocalIdentifier` whenever it is known (i.e. resolved by
    /// `AlbumManager.assignAndResolve`) so that undo/redo can route through the
    /// duplicate-name-safe by-id `AlbumOperations` surface.
    func record(asset: PHAsset, albumName: String, albumLocalIdentifier: String? = nil) {
        let decision = AssignmentDecision(
            asset: asset,
            albumName: albumName,
            albumLocalIdentifier: albumLocalIdentifier
        )
        stack.record(decision)
        lastUndoneAlbumName = nil
        lastRedoneAlbumName = nil
        // A new user action invalidates any prior failure context.
        lastUndoError = nil
        lastRedoError = nil
        lastFailedUndoID = nil
        lastFailedRedoID = nil
    }

    // MARK: - Undo

    /// Undoes the most recent assignment by removing the asset from its album.
    /// On success the decision moves to the redo stack.
    ///
    /// On failure the decision is rolled back onto the undo stack and
    /// `lastUndoError` is set. If the *same* decision id fails twice in a row
    /// the entry is dropped from the stack instead — the assignment is
    /// presumed permanently broken (e.g. the target album was deleted out of
    /// band) and the toolbar's `canUndo` must reflect reality.
    func undo() async {
        guard let decision = stack.popUndo() else {
            // Nothing to undo at all — distinct from "remove failed".
            // Don't clobber `lastUndoError` here; the caller already gates on
            // `canUndo`.
            return
        }
        // Reset the name first so undoing two assignments to the *same* album
        // still produces a nil -> value transition that @Observable observers
        // (the toast) can detect; otherwise the second toast is silently
        // dropped. Also clear any prior error so the success path is observable.
        lastUndoneAlbumName = nil
        lastUndoError = nil
        // Prefer by-id whenever the decision carries the album's localIdentifier
        // — Photos.app permits duplicate-named albums, so title-based remove
        // could mutate a sibling collection.
        let ok: Bool
        if let albumID = decision.albumLocalIdentifier {
            ok = await operations.remove(decision.asset, fromAlbumWithID: albumID)
        } else {
            ok = await operations.remove(decision.asset, fromAlbumNamed: decision.albumName)
        }
        if ok {
            stack.pushRedo(decision)
            lastUndoneAlbumName = decision.albumName
            lastFailedUndoID = nil
        } else {
            // Persistent failure — same decision failed on the previous attempt
            // too. Drop the entry so the toolbar's `canUndo` no longer lies.
            if lastFailedUndoID == decision.id {
                lastFailedUndoID = nil
                lastUndoError = "Undo not possible — the album may have been deleted."
            } else {
                // First failure: roll back so the user can retry.
                stack.pushUndo(decision)
                lastFailedUndoID = decision.id
                lastUndoError = "Couldn't remove from \(decision.albumName)."
            }
            lastUndoneAlbumName = nil
        }
    }

    // MARK: - Redo

    /// Redoes the most recently undone assignment by re-adding the asset to its album.
    /// On success the decision moves back onto the undo stack.
    ///
    /// Symmetric drop-on-persistent-failure to `undo()`: if the same redo
    /// entry fails twice in a row it is dropped so `canRedo` stops lying.
    func redo() async {
        guard let decision = stack.popRedo() else { return }
        // Reset first (see undo) so a repeat redo to the same album still
        // produces an observable nil -> value transition for the toast.
        lastRedoneAlbumName = nil
        lastRedoError = nil
        // Same by-id discipline as undo: a duplicate-named album in the
        // library must not be able to capture the redo by accident.
        let ok: Bool
        if let albumID = decision.albumLocalIdentifier {
            ok = await operations.assign(decision.asset, toAlbumWithID: albumID)
        } else {
            ok = await operations.assign(decision.asset, toAlbumNamed: decision.albumName)
        }
        if ok {
            stack.pushUndo(decision)
            lastRedoneAlbumName = decision.albumName
            lastFailedRedoID = nil
        } else {
            if lastFailedRedoID == decision.id {
                lastFailedRedoID = nil
                lastRedoError = "Redo not possible — the album may have been deleted."
            } else {
                stack.pushRedo(decision)
                lastFailedRedoID = decision.id
                lastRedoError = "Couldn't re-add to \(decision.albumName)."
            }
            lastRedoneAlbumName = nil
        }
    }
}

// MARK: - Environment key

/// Shared `DecisionLog` injected from the root scene so that `PhotoGridView`
/// and any other non-coordinator view can record assignments for undo.
///
/// Usage: inject via `.environment(\.decisionLog, myLog)` and consume via
/// `@Environment(\.decisionLog)`.
private struct DecisionLogKey: EnvironmentKey {
    static let defaultValue: DecisionLog? = nil
}

extension EnvironmentValues {
    var decisionLog: DecisionLog? {
        get { self[DecisionLogKey.self] }
        set { self[DecisionLogKey.self] = newValue }
    }
}
