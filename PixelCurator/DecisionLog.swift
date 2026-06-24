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

    /// Drops every entry from both stacks for which `isAlive` returns `false`.
    ///
    /// Used by the library-change cascade to remove decision entries whose
    /// underlying PhotoKit object (asset or album) has been deleted out of
    /// band — those entries can never replay successfully and would otherwise
    /// keep `canUndo` / `canRedo` reporting `true` while every tap silently
    /// re-fails.
    ///
    /// Returns the total number of entries dropped (undo + redo) for
    /// logging / test assertions.
    @discardableResult
    mutating func prune(isAlive: (Element) -> Bool) -> Int {
        let undoBefore = undoStack.count
        let redoBefore = redoStack.count
        undoStack.removeAll { !isAlive($0) }
        redoStack.removeAll { !isAlive($0) }
        return (undoBefore - undoStack.count) + (redoBefore - redoStack.count)
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

// MARK: - MoveDecision (F-15)

/// Records a single Move (assign-to-target then remove-from-source) for
/// undo/redo as one atomic user action.
///
/// **Why a primitive instead of two `AssignmentDecision` entries?** The
/// straightforward "two entries" lowering was considered and rejected:
/// `AssignmentDecision`'s undo is "remove from the named album", so undoing
/// only the assign-to-target half leaves the asset in neither album (the
/// source-remove half has already happened and there is no entry whose
/// undo means "re-add to the source"). The user's mental model is "I moved
/// it, undo the move" — a single click should restore both halves, not
/// land the asset in limbo. A `MoveDecision` matches that model: undo
/// executes "re-add to source + remove from target" atomically, redo
/// executes the original "assign-to-target + remove-from-source" pair.
///
/// Both album identities are stored as `(id, title)` pairs so undo/redo can
/// route through the duplicate-name-safe `fromAlbumWithID:` / `toAlbumWithID:`
/// `AlbumOperations` surface. Title is carried alongside the id so the
/// toast message ("Moved to <Target>" / "Move undone — restored to <Source>")
/// can be rendered without a second PhotoKit lookup.
struct MoveDecision: Identifiable, Hashable {
    let id: UUID
    let asset: PHAsset
    let sourceAlbumID: String
    let sourceAlbumName: String
    let targetAlbumID: String
    let targetAlbumName: String
    let date: Date

    init(
        asset: PHAsset,
        sourceAlbumID: String,
        sourceAlbumName: String,
        targetAlbumID: String,
        targetAlbumName: String
    ) {
        self.id = UUID()
        self.asset = asset
        self.sourceAlbumID = sourceAlbumID
        self.sourceAlbumName = sourceAlbumName
        self.targetAlbumID = targetAlbumID
        self.targetAlbumName = targetAlbumName
        self.date = Date()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MoveDecision, rhs: MoveDecision) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Decision

/// Tagged union of every undo/redo-able operation. The internal
/// `UndoRedoStack<Decision>` keeps move and assign entries interleaved in
/// recording order so undo/redo always pops the most-recent user action
/// regardless of its kind.
enum Decision: Identifiable, Hashable {
    case assignment(AssignmentDecision)
    case move(MoveDecision)

    var id: UUID {
        switch self {
        case .assignment(let d): return d.id
        case .move(let d): return d.id
        }
    }

    var asset: PHAsset {
        switch self {
        case .assignment(let d): return d.asset
        case .move(let d): return d.asset
        }
    }

    /// Set of album `localIdentifier`s referenced by this decision. Used by
    /// `prune(keepingAssets:livingAlbumIDs:)` to drop entries whose target
    /// album was deleted out of band.
    var referencedAlbumIDs: [String] {
        switch self {
        case .assignment(let d):
            return d.albumLocalIdentifier.map { [$0] } ?? []
        case .move(let d):
            return [d.sourceAlbumID, d.targetAlbumID]
        }
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

    private var stack = UndoRedoStack<Decision>()

    // MARK: - Public accessors

    /// Full undo stack including every `Decision` kind (assignment + move),
    /// in recording order. New in F-15; prefer this over the
    /// assignment-only legacy accessor below for any code that needs to
    /// reason about moves.
    var undoEntries: [Decision] { stack.undoStack }

    /// Full redo stack symmetric to `undoEntries`.
    var redoEntries: [Decision] { stack.redoStack }

    /// Assignment-only view of the undo stack, preserved for the existing
    /// tests and any caller that was written before the `Decision` enum
    /// existed. Filters out `.move` entries — callers that need to see
    /// moves must read `undoEntries` instead.
    var undoStack: [AssignmentDecision] {
        stack.undoStack.compactMap {
            if case .assignment(let d) = $0 { return d } else { return nil }
        }
    }

    /// Assignment-only view of the redo stack — see `undoStack` rationale.
    var redoStack: [AssignmentDecision] {
        stack.redoStack.compactMap {
            if case .assignment(let d) = $0 { return d } else { return nil }
        }
    }

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
        recordDecision(.assignment(decision))
    }

    /// Records a successful Move (F-15). Call this **after**
    /// `AlbumMover.move` returns `.moved` so the undo/redo stack mirrors the
    /// real library state. Failure / rollback outcomes must not record
    /// anything — the library is unchanged in those cases and a recorded
    /// move would mis-report the next undo.
    func recordMove(
        asset: PHAsset,
        sourceAlbumID: String,
        sourceAlbumName: String,
        targetAlbumID: String,
        targetAlbumName: String
    ) {
        let decision = MoveDecision(
            asset: asset,
            sourceAlbumID: sourceAlbumID,
            sourceAlbumName: sourceAlbumName,
            targetAlbumID: targetAlbumID,
            targetAlbumName: targetAlbumName
        )
        recordDecision(.move(decision))
    }

    private func recordDecision(_ decision: Decision) {
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

    /// Undoes the most recent decision (assignment or move).
    /// On success the decision moves to the redo stack.
    ///
    /// On failure the decision is rolled back onto the undo stack and
    /// `lastUndoError` is set. If the *same* decision id fails twice in a row
    /// the entry is dropped from the stack instead — the decision is
    /// presumed permanently broken (e.g. the target album was deleted out of
    /// band) and the toolbar's `canUndo` must reflect reality.
    func undo() async {
        guard let decision = stack.popUndo() else {
            // Nothing to undo at all — distinct from "remove failed".
            // Don't clobber `lastUndoError` here; the caller already gates on
            // `canUndo`.
            return
        }
        // Reset the name first so undoing two operations targeting the *same*
        // album still produces a nil -> value transition that @Observable
        // observers (the toast) can detect; otherwise the second toast is
        // silently dropped. Also clear any prior error so the success path is
        // observable.
        lastUndoneAlbumName = nil
        lastUndoError = nil

        let outcome = await performUndo(of: decision)
        if outcome.ok {
            stack.pushRedo(decision)
            lastUndoneAlbumName = outcome.toastName
            lastFailedUndoID = nil
        } else {
            if lastFailedUndoID == decision.id {
                lastFailedUndoID = nil
                lastUndoError = "Undo not possible — the album may have been deleted."
            } else {
                stack.pushUndo(decision)
                lastFailedUndoID = decision.id
                lastUndoError = outcome.errorMessage
            }
            lastUndoneAlbumName = nil
        }
    }

    /// Performs the side-effect for undoing a single decision and returns
    /// success plus the album name to surface in the toast.
    private func performUndo(of decision: Decision) async -> (ok: Bool, toastName: String?, errorMessage: String?) {
        switch decision {
        case .assignment(let d):
            // Prefer by-id whenever the decision carries the album's
            // localIdentifier — duplicate-named albums must not be silently
            // mutated.
            let ok: Bool
            if let albumID = d.albumLocalIdentifier {
                ok = await operations.remove(d.asset, fromAlbumWithID: albumID)
            } else {
                ok = await operations.remove(d.asset, fromAlbumNamed: d.albumName)
            }
            return (ok, ok ? d.albumName : nil, "Couldn't remove from \(d.albumName).")

        case .move(let d):
            // F-15: undo of a move = re-add to source, then remove from
            // target. Both steps must succeed for the undo to be reported
            // as successful — a partial undo leaves the library in a
            // hybrid state that the user can't easily reason about.
            //
            // Order matters: re-add first so an intermediate observer of
            // the library never sees the asset belonging to neither album.
            // If the second step (remove-from-target) fails, the asset is
            // in BOTH albums — same situation as `AlbumMover`'s orphan
            // case; we report that as failed undo with a descriptive
            // message so the user can fix it in Photos.app.
            let restoredToSource = await operations.assign(d.asset, toAlbumWithID: d.sourceAlbumID)
            guard restoredToSource else {
                return (false, nil, "Couldn't restore to \(d.sourceAlbumName).")
            }
            let removedFromTarget = await operations.remove(d.asset, fromAlbumWithID: d.targetAlbumID)
            guard removedFromTarget else {
                return (false, nil, "Restored to \(d.sourceAlbumName) but still in \(d.targetAlbumName) — please review in Photos.app.")
            }
            return (true, d.sourceAlbumName, nil)
        }
    }

    // MARK: - Redo

    /// Redoes the most recently undone decision (assignment or move).
    /// On success the decision moves back onto the undo stack.
    ///
    /// Symmetric drop-on-persistent-failure to `undo()`: if the same redo
    /// entry fails twice in a row it is dropped so `canRedo` stops lying.
    func redo() async {
        guard let decision = stack.popRedo() else { return }
        lastRedoneAlbumName = nil
        lastRedoError = nil

        let outcome = await performRedo(of: decision)
        if outcome.ok {
            stack.pushUndo(decision)
            lastRedoneAlbumName = outcome.toastName
            lastFailedRedoID = nil
        } else {
            if lastFailedRedoID == decision.id {
                lastFailedRedoID = nil
                lastRedoError = "Redo not possible — the album may have been deleted."
            } else {
                stack.pushRedo(decision)
                lastFailedRedoID = decision.id
                lastRedoError = outcome.errorMessage
            }
            lastRedoneAlbumName = nil
        }
    }

    private func performRedo(of decision: Decision) async -> (ok: Bool, toastName: String?, errorMessage: String?) {
        switch decision {
        case .assignment(let d):
            let ok: Bool
            if let albumID = d.albumLocalIdentifier {
                ok = await operations.assign(d.asset, toAlbumWithID: albumID)
            } else {
                ok = await operations.assign(d.asset, toAlbumNamed: d.albumName)
            }
            return (ok, ok ? d.albumName : nil, "Couldn't re-add to \(d.albumName).")

        case .move(let d):
            // F-15: redo of a move = the original move sequence
            // (assign-to-target then remove-from-source). Same ordering
            // discipline as the original move and the inverse undo.
            let addedToTarget = await operations.assign(d.asset, toAlbumWithID: d.targetAlbumID)
            guard addedToTarget else {
                return (false, nil, "Couldn't re-add to \(d.targetAlbumName).")
            }
            let removedFromSource = await operations.remove(d.asset, fromAlbumWithID: d.sourceAlbumID)
            guard removedFromSource else {
                return (false, nil, "Re-added to \(d.targetAlbumName) but still in \(d.sourceAlbumName) — please review in Photos.app.")
            }
            return (true, d.targetAlbumName, nil)
        }
    }

    // MARK: - Prune

    /// Drops every undo and redo entry whose asset is no longer in
    /// `livingAssetIDs`, or whose referenced album IDs are no longer in
    /// `livingAlbumIDs`.
    ///
    /// **Drop, not requeue.** The existing rollback path on a single failure is
    /// for transient errors; stale entries (Photos.app deleted the asset or
    /// album out of band) are permanently dead and must never come back. After
    /// pruning, the `lastFailedUndoID` / `lastFailedRedoID` trackers are reset
    /// since the entries they referred to may themselves have been dropped.
    ///
    /// Decisions without any tracked album ID (legacy in-memory assignments)
    /// are kept regardless of album survival — they fall back to title-based
    /// resolution at replay time and will surface their own error then. Move
    /// decisions always carry both source and target IDs, so any move whose
    /// source or target was deleted is dropped.
    ///
    /// Returns the number of entries removed across both stacks.
    @discardableResult
    func prune(
        keepingAssets livingAssetIDs: Set<String>,
        livingAlbumIDs: Set<String>
    ) -> Int {
        let dropped = stack.prune { decision in
            guard livingAssetIDs.contains(decision.asset.localIdentifier) else {
                return false
            }
            // Drop iff any referenced album ID is missing.
            for albumID in decision.referencedAlbumIDs where !livingAlbumIDs.contains(albumID) {
                return false
            }
            return true
        }
        if dropped > 0 {
            // The trackers may point at decisions that were just dropped.
            lastFailedUndoID = nil
            lastFailedRedoID = nil
        }
        return dropped
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
