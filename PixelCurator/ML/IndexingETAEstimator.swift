import Foundation

/// Rolling-window ETA for the embedding indexer.
///
/// Append a tick on every `indexer.indexed` increment. The estimator keeps the
/// last `windowSize` ticks (default 30) and returns `seconds` based on a moving
/// average of inter-tick intervals. Returns `nil` until at least `minSamples`
/// (default 20) ticks have been observed — below that the moving average is too
/// noisy to display reliably.
///
/// Drive from `IndexingLockOverlay`'s `.onChange(of: indexer.indexed)` rather
/// than from `EmbeddingIndexer` itself, which keeps the indexer's core path
/// untouched (no ML-layer changes needed for this feature).
///
/// All methods are `@MainActor` so they can be called safely from SwiftUI body
/// and `.onChange` closures without cross-actor hops.
@MainActor
final class IndexingETAEstimator {
    private var ticks: [Date] = []
    private let windowSize: Int
    private let minSamples: Int

    /// - Parameters:
    ///   - windowSize: Maximum number of tick timestamps to keep. Older ticks
    ///     are discarded on a FIFO basis. Default: 30.
    ///   - minSamples: Minimum number of ticks before an estimate is returned.
    ///     Below this the moving average is too noisy. Default: 20.
    init(windowSize: Int = 30, minSamples: Int = 20) {
        self.windowSize = windowSize
        self.minSamples = minSamples
    }

    /// Discards all recorded ticks, e.g. when a new indexing run starts.
    func reset() {
        ticks.removeAll(keepingCapacity: true)
    }

    /// Records a new tick at `now` (defaults to `Date()`).
    ///
    /// Call once per successfully embedded asset (i.e. on each
    /// `.onChange(of: indexer.indexed)` increment). The window is trimmed
    /// to `windowSize` immediately after insertion.
    func recordTick(at now: Date = Date()) {
        ticks.append(now)
        if ticks.count > windowSize {
            ticks.removeFirst(ticks.count - windowSize)
        }
    }

    /// Returns the estimated number of seconds until `remaining` more assets
    /// have been indexed, or `nil` if there are fewer than `minSamples` ticks.
    ///
    /// The estimate is `averageInterTickInterval × remaining`. The interval is
    /// the total elapsed time across all ticks divided by `(ticks.count - 1)`.
    ///
    /// - Parameter remaining: Number of assets still to index (`total - indexed`).
    func estimatedSecondsRemaining(remaining: Int) -> TimeInterval? {
        guard ticks.count >= minSamples, remaining > 0 else { return nil }
        guard let first = ticks.first, let last = ticks.last, last > first else { return nil }
        let perAsset = last.timeIntervalSince(first) / Double(ticks.count - 1)
        return perAsset * Double(remaining)
    }
}
