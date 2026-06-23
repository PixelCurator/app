import XCTest
@testable import PixelCurator

final class SimilarityTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeUnitVectorIsStable() {
        // A unit vector already has L2 norm == 1; normalising it again should
        // leave values within floating-point rounding error.
        let unit: [Float] = [1, 0, 0]
        let result = Similarity.normalize(unit)
        XCTAssertEqual(result[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(result[1], 0.0, accuracy: 1e-6)
        XCTAssertEqual(result[2], 0.0, accuracy: 1e-6)
    }

    func testNormalizeProducesUnitNorm() {
        let v: [Float] = [3, 4]      // norm == 5
        let n = Similarity.normalize(v)
        let norm = sqrtf(n[0] * n[0] + n[1] * n[1])
        XCTAssertEqual(norm, 1.0, accuracy: 1e-6)
    }

    func testNormalizeZeroVectorDoesNotCrashOrNaN() {
        let zero: [Float] = [0, 0, 0]
        let result = Similarity.normalize(zero)
        // Must not contain NaN; original values returned unchanged.
        for v in result {
            XCTAssertFalse(v.isNaN)
        }
    }

    // MARK: - cosineTopK

    func testIdenticalNormalisedVectorsScoreOne() {
        let v = Similarity.normalize([1, 2, 3, 4])
        let results = Similarity.cosineTopK(
            query: v,
            candidates: [(id: "a", vector: v)],
            k: 1
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].score, 1.0, accuracy: 1e-5)
    }

    func testOrthogonalVectorsScoreZero() {
        let q = Similarity.normalize([1, 0, 0])
        let c = Similarity.normalize([0, 1, 0])
        let results = Similarity.cosineTopK(
            query: q,
            candidates: [(id: "b", vector: c)],
            k: 1
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].score, 0.0, accuracy: 1e-6)
    }

    func testTopKReturnsCorrectDescendingOrder() {
        let q = Similarity.normalize([1, 0, 0])
        let high   = Similarity.normalize([0.9, 0.436, 0])   // closer to q
        let medium = Similarity.normalize([0.5, 0.866, 0])
        let low    = Similarity.normalize([0.1, 0.995, 0])

        let candidates: [(id: String, vector: [Float])] = [
            (id: "low",    vector: low),
            (id: "high",   vector: high),
            (id: "medium", vector: medium)
        ]
        let results = Similarity.cosineTopK(query: q, candidates: candidates, k: 3)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].id, "high")
        XCTAssertEqual(results[1].id, "medium")
        XCTAssertEqual(results[2].id, "low")
        // Descending scores.
        XCTAssertGreaterThan(results[0].score, results[1].score)
        XCTAssertGreaterThan(results[1].score, results[2].score)
    }

    func testTopKRespectsKLimit() {
        let q = Similarity.normalize([1, 0])
        let candidates: [(id: String, vector: [Float])] = [
            (id: "a", vector: Similarity.normalize([1, 0])),
            (id: "b", vector: Similarity.normalize([0, 1])),
            (id: "c", vector: Similarity.normalize([-1, 0]))
        ]
        let results = Similarity.cosineTopK(query: q, candidates: candidates, k: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testTopKWithFewerCandidatesThanK() {
        let q = Similarity.normalize([1, 0])
        let candidates: [(id: String, vector: [Float])] = [
            (id: "only", vector: Similarity.normalize([1, 0]))
        ]
        let results = Similarity.cosineTopK(query: q, candidates: candidates, k: 10)
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Heap correctness vs reference (linear-sort) implementation
    //
    // The migration from `sort + prefix` to a bounded min-heap must produce
    // identical results on non-tie cases. These tests pin that contract on a
    // realistic-sized corpus.

    /// Reference implementation: the pre-heap behaviour, kept verbatim in the
    /// test file so the heap path can be diff'd against it for any corpus.
    private func cosineTopK_referenceLinearSort(
        query: [Float],
        candidates: [(id: String, vector: [Float])],
        k: Int
    ) -> [(id: String, score: Float)] {
        guard !candidates.isEmpty, k > 0, !query.isEmpty else { return [] }
        var scores: [(id: String, score: Float)] = []
        scores.reserveCapacity(candidates.count)
        for c in candidates where c.vector.count == query.count {
            let dot = zip(c.vector, query).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            scores.append((id: c.id, score: dot))
        }
        scores.sort { $0.score > $1.score }
        return Array(scores.prefix(k))
    }

    /// Compares against the reference impl on a 1 000-vector corpus with
    /// distinct scores (no ties — see seed engineering below). The id and
    /// score sequences must match exactly.
    func testHeapMatchesReferenceOn1000DistinctVectors() {
        // Build a unit-norm corpus where each vector points slightly off the
        // y-axis at a unique angle, so dot products with `q = [1,0,…]` are
        // distinct floats. The `i / 1001` offset keeps every score unique.
        let dim = 8
        let count = 1_000
        var rng = SeededRNG_SimTests(seed: 0xC0DE_C0DE)
        var corpus: [(id: String, vector: [Float])] = []
        corpus.reserveCapacity(count)
        for i in 0..<count {
            var v = [Float](repeating: 0, count: dim)
            for j in 0..<dim { v[j] = (Float(rng.next() % 1000) / 1000.0) - 0.5 }
            // Bias each vector toward the query axis by a unique offset
            // so cosine scores are pairwise distinct.
            v[0] += Float(i) / 1001.0
            corpus.append((id: "asset-\(i)", vector: Similarity.normalize(v)))
        }
        let q = Similarity.normalize([Float](repeating: 0, count: dim).enumerated().map { idx, _ in idx == 0 ? 1.0 : 0.0 })

        for k in [1, 5, 15, 30, 100, 500, count] {
            let heap = Similarity.cosineTopK(query: q, candidates: corpus, k: k)
            let ref = cosineTopK_referenceLinearSort(query: q, candidates: corpus, k: k)
            XCTAssertEqual(heap.count, ref.count, "k=\(k): count mismatch")
            XCTAssertEqual(heap.map(\.id), ref.map(\.id),
                           "k=\(k): heap ids differ from reference")
            for (h, r) in zip(heap, ref) {
                XCTAssertEqual(h.score, r.score, accuracy: 1e-5,
                               "k=\(k): score mismatch for id \(h.id)")
            }
        }
    }

    /// `k == 1` is the degenerate case that should hand back exactly the
    /// single best candidate.
    func testTopKWithKOne_returnsExactlyBest() {
        let q = Similarity.normalize([1, 0, 0])
        let candidates: [(id: String, vector: [Float])] = (0..<50).map { i in
            // Each candidate slightly closer to q than the previous → 49 is best.
            let v: [Float] = [Float(i + 1) / 50.0, 0.5, 0]
            return (id: "c-\(i)", vector: Similarity.normalize(v))
        }
        let results = Similarity.cosineTopK(query: q, candidates: candidates, k: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "c-49")
    }

    /// When `k` equals the corpus size every candidate should come back in
    /// descending order — no candidate is dropped.
    func testTopKWithKEqualToCorpusSize() {
        let q = Similarity.normalize([1, 0])
        let candidates: [(id: String, vector: [Float])] = (0..<20).map { i in
            let v: [Float] = [1.0, Float(i) / 20.0]
            return (id: "c-\(i)", vector: Similarity.normalize(v))
        }
        let results = Similarity.cosineTopK(query: q, candidates: candidates, k: 20)
        XCTAssertEqual(results.count, 20)
        // Scores must be monotonically non-increasing.
        for i in 1..<results.count {
            XCTAssertGreaterThanOrEqual(results[i - 1].score, results[i].score,
                                        "Result at \(i) violates descending order")
        }
    }

    /// Mismatched-dimension candidates must be silently skipped — the heap
    /// path must keep this contract from the pre-heap implementation.
    func testTopKSkipsMismatchedDimensionCandidates() {
        let q = Similarity.normalize([1, 0, 0])
        let candidates: [(id: String, vector: [Float])] = [
            (id: "ok",  vector: Similarity.normalize([1, 0, 0])),
            (id: "bad", vector: [1, 0]),                            // wrong dim
            (id: "ok2", vector: Similarity.normalize([0, 1, 0]))
        ]
        let results = Similarity.cosineTopK(query: q, candidates: candidates, k: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.id == "ok" })
        XCTAssertTrue(results.contains { $0.id == "ok2" })
        XCTAssertFalse(results.contains { $0.id == "bad" })
    }
}

// MARK: - SeededRNG for similarity correctness tests

/// Deterministic SplitMix64 PRNG; isolated to this file so the perf-tests
/// file's identical helper stays self-contained.
private struct SeededRNG_SimTests {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
