@preconcurrency import Photos
import Foundation
import SwiftData
import CoreGraphics

/// Iterates over a list of `PHAsset`s, embeds each via `Embedder`, and
/// persists the result to `EmbeddingStore` — skipping assets that are
/// already indexed for the active `CLIPVariant`.
///
/// Progress is published as `indexed` / `total` so SwiftUI views can drive
/// a progress indicator without polling.
@MainActor
@Observable
final class EmbeddingIndexer {

    // MARK: - Published state

    /// Number of assets successfully embedded in the current run.
    var indexed: Int = 0

    /// Number of assets scheduled for embedding in the current run
    /// (after skipping already-indexed ones).
    var total: Int = 0

    /// `true` while an indexing run is in flight.
    var isIndexing: Bool = false

    // MARK: - Private state

    private var _cancelRequested = false

    /// Tracks the in-flight `index(assets:)` work so the orchestrator can await
    /// completion before swapping the underlying `ModelContext`.
    ///
    /// Without this handle, `cancelIndexing()` only requests a stop — the await
    /// on `embedder.embed(_:)` keeps running, and the final `context.save()` +
    /// `isIndexing = false` writes can race a freshly-built replacement indexer
    /// that shares the same `ModelContext`.
    private var currentTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let context: ModelContext
    private let embedder: Embedder
    private let modelStore: ModelStore
    private let variant: CLIPVariant

    // MARK: - Init

    /// - Parameters:
    ///   - context: A `ModelContext` bound to a container that includes `PhotoEmbedding.self`.
    ///   - embedder: Pre-loaded `Embedder` actor for the chosen variant.
    ///   - modelStore: `ModelStore` instance (unused at runtime in Slice B, reserved for future variant switching).
    ///   - variant: The `CLIPVariant` whose `modelID` tags every stored embedding.
    init(
        context: ModelContext,
        embedder: Embedder,
        modelStore: ModelStore,
        variant: CLIPVariant = .bundledDefault
    ) {
        self.context = context
        self.embedder = embedder
        self.modelStore = modelStore
        self.variant = variant
    }

    // MARK: - Indexing

    /// Embeds all `assets` that do not yet have a stored embedding for `variant`.
    ///
    /// Sets `isIndexing = true` for the duration and resets it on completion
    /// or cancellation. Batch-saves every 20 embeddings to bound memory usage.
    ///
    /// The work is wrapped in a stored `Task` so the orchestrator can call
    /// `cancelIndexing()` followed by `waitForCompletion()` (or the combined
    /// `cancelAndWait()`) before constructing a replacement indexer over the
    /// same `ModelContext`.
    func index(assets: [PHAsset]) async {
        // Defensive re-entry guard. PR #26 fixed cross-instance races via
        // `cancelAndWait()`, but the *same* indexer can still be re-entered
        // when `PhotoGridView.task(id: library.assets.count)` refires during
        // a pending variant switch (see also `\.isSwitchingVariant` in
        // `PixelCuratorApp`). If a prior run is still in flight, await it
        // instead of starting a second one in parallel — `currentTask` is
        // serializable but two concurrent runs would race the `indexed` /
        // `total` counters.
        if let inFlight = currentTask, !inFlight.isCancelled, isIndexing {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runIndex(assets: assets)
        }
        currentTask = task
        await task.value
    }

    /// Signals the in-flight `index(assets:)` call to stop after the current asset.
    ///
    /// This only requests a stop — it does NOT block until the loop exits. Use
    /// `cancelAndWait()` (or pair this with `waitForCompletion()`) when the
    /// caller is about to reuse or replace the shared `ModelContext`, otherwise
    /// the prior indexer's trailing `context.save()` and `isIndexing = false`
    /// writes will race the replacement.
    func cancelIndexing() {
        _cancelRequested = true
    }

    /// Awaits the in-flight `index(assets:)` task, if any. Returns immediately
    /// if no indexing is in progress.
    func waitForCompletion() async {
        await currentTask?.value
    }

    /// Convenience: requests cancellation and awaits the in-flight task. Safe to
    /// call when no indexing is in progress.
    func cancelAndWait() async {
        _cancelRequested = true
        await currentTask?.value
    }

    // MARK: - Indexing body

    private func runIndex(assets: [PHAsset]) async {
        isIndexing = true
        _cancelRequested = false

        let store = EmbeddingStore(context: context)
        let alreadyIndexed = store.embeddedAssetIDs(modelID: variant.modelID)
        let pending = assets.filter { !alreadyIndexed.contains($0.localIdentifier) }

        total = pending.count
        indexed = 0

        for asset in pending {
            // Respect both explicit cancellation and Swift structured-concurrency cancellation.
            if _cancelRequested || Task.isCancelled { break }

            guard let cgImage = await fetchCGImage(for: asset) else {
                print("EmbeddingIndexer: could not fetch CGImage for \(asset.localIdentifier), skipping")
                continue
            }

            do {
                let vector = try await embedder.embed(cgImage)
                store.upsert(
                    assetID: asset.localIdentifier,
                    modelID: variant.modelID,
                    vector: vector,
                    assetModificationDate: asset.modificationDate
                )
                indexed += 1

                if indexed % 20 == 0 {
                    try? context.save()
                }
            } catch {
                print("EmbeddingIndexer: embed failed for \(asset.localIdentifier): \(error)")
            }
        }

        try? context.save()
        isIndexing = false
    }

    // MARK: - Private helpers

    /// Fetches a `CGImage` for `asset` at 384×384 using a one-shot high-quality request.
    ///
    /// Network access is disabled — inference runs on locally cached copies only.
    private func fetchCGImage(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 384, height: 384),
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
