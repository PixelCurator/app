import XCTest
@testable import PixelCurator

/// Performance baselines for `AlbumSuggester.rank(query:labeledPoints:k:)`.
///
/// The pure ranking function is exercised on every photo tap (via
/// `SortingCoordinator.recomputeSuggestions` → `AlbumSuggester.suggestions(...)`
/// → `rank(...)`). A regression here translates 1:1 into a multi-millisecond
/// freeze on the main actor whenever the user moves to the next photo in the
/// inbox.
///
/// These tests measure wall-clock cost of `rank` against synthetic vectors so
/// no PhotoKit / SwiftData I/O contaminates the measurement. Companion to
/// `AlbumManagerPerformanceTests` (which measures the PhotoKit-bound
/// `loadAlbums` hot path).
///
/// **Regression target:** if the cosine-topK or the per-album aggregation gets
/// rewritten into something accidentally quadratic, these baselines jump
/// from low-millisecond into 100ms+ on the sim.
final class AlbumSuggesterPerformanceTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds `count` synthetic labeled points across `albumCount` albums.
    /// Vectors are unit-normalised in a 64-dim space; album labels are
    /// distributed uniformly. The seed is fixed so successive measure runs
    /// see the same corpus (XCTest re-runs the block ~10 times for stats).
    private func makeCorpus(count: Int, albumCount: Int, seed: UInt64) -> [(album: String, vector: [Float])] {
        var rng = SeededRNG(seed: seed)
        var corpus: [(album: String, vector: [Float])] = []
        corpus.reserveCapacity(count)
        for i in 0..<count {
            let vec = makeUnitVector(dim: 64, rng: &rng)
            let album = "Album-\(i % albumCount)"
            corpus.append((album: album, vector: vec))
        }
        return corpus
    }

    private func makeUnitVector(dim: Int, rng: inout SeededRNG) -> [Float] {
        var raw = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            // Map UInt64 -> Float in [-1, 1] via two halves.
            let bits = rng.next()
            let hi = Float(bits >> 32) / Float(UInt32.max) * 2 - 1
            raw[i] = hi
        }
        return Similarity.normalize(raw)
    }

    // MARK: - Baseline: 1000 points, 20 albums, k=15

    /// Mirrors a mid-sized library: 1 000 already-indexed photos spread across
    /// 20 albums, default `k = 15`. This is the realistic "tap a photo →
    /// suggestions appear" load. Expected wall-clock on the iPhone 17 Pro sim
    /// is well under 10 ms; a quadratic regression pushes it past 200 ms.
    func testRank_1000Points_20Albums_k15() throws {
        let corpus = makeCorpus(count: 1_000, albumCount: 20, seed: 0xC0FFEE)
        var queryRng = SeededRNG(seed: 0xDEAD_BEEF)
        let query = makeUnitVector(dim: 64, rng: &queryRng)

        // Warm-up so the first measure block isn't an outlier (Swift runtime
        // ARC + dictionary growth on first hit).
        _ = AlbumSuggester.rank(query: query, labeledPoints: corpus, k: 15)

        measure(metrics: [XCTClockMetric()]) {
            _ = AlbumSuggester.rank(query: query, labeledPoints: corpus, k: 15)
        }
    }

    // MARK: - Larger neighborhood: k=50 over 5000 points

    /// Stress the per-neighbor aggregation step. `k = 50` widens the
    /// neighborhood; the top-K extraction is O(N log K) so this should grow
    /// gently with N. A regression in the album-score dictionary growth (e.g.
    /// reallocating on every insert) shows up here first.
    func testRank_5000Points_50Albums_k50() throws {
        let corpus = makeCorpus(count: 5_000, albumCount: 50, seed: 0xCAFE_BABE)
        var queryRng = SeededRNG(seed: 0xBADC_AB1E)
        let query = makeUnitVector(dim: 64, rng: &queryRng)

        _ = AlbumSuggester.rank(query: query, labeledPoints: corpus, k: 50)

        measure(metrics: [XCTClockMetric()]) {
            _ = AlbumSuggester.rank(query: query, labeledPoints: corpus, k: 50)
        }
    }

    // MARK: - Repeated calls: simulate sorting-inbox tap-tap-tap

    /// `SortingInboxView` calls `recomputeSuggestions` on every advance to the
    /// next photo. A user blasting through 20 photos in a session triggers 20
    /// `rank` calls within seconds. This measures that aggregate cost so a
    /// per-call slow-down can't hide behind "one call is still fast".
    func testRank_20RepeatedCalls_1000Points() throws {
        let corpus = makeCorpus(count: 1_000, albumCount: 20, seed: 0xFEED_FACE)
        var queryRng = SeededRNG(seed: 0xF00D_F00D)
        let queries = (0..<20).map { _ in makeUnitVector(dim: 64, rng: &queryRng) }

        _ = AlbumSuggester.rank(query: queries[0], labeledPoints: corpus, k: 15)

        measure(metrics: [XCTClockMetric()]) {
            for q in queries {
                _ = AlbumSuggester.rank(query: q, labeledPoints: corpus, k: 15)
            }
        }
    }
}

// MARK: - SeededRNG

/// Deterministic SplitMix64-style PRNG so successive measure runs see the
/// same corpus across all XCTest invocations. Keeping the seed fixed bounds
/// the inter-run variance to scheduler / cache effects rather than fixture
/// randomness.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
