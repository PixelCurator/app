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
}
