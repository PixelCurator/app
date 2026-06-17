import XCTest
@testable import PixelCurator

/// Unit tests for `AlbumSuggester.rank(query:labeledPoints:k:)`.
///
/// The pure `rank` function has no PhotoKit or SwiftData dependencies, so all
/// test vectors are constructed inline using `Similarity.normalize`.
final class AlbumSuggesterTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a unit vector pointing in the direction `[mainValue, 0, …]`
    /// with minor orthogonal jitter so repeated album exemplars differ slightly.
    private func nearVector(primary: Float, jitter: Float = 0) -> [Float] {
        Similarity.normalize([primary, jitter, 0])
    }

    // MARK: - Basic ranking

    /// A query close to "Beach" exemplars and far from "City" → "Beach" ranks first.
    func testBeachRanksAboveCity() {
        // Beach exemplars: all point roughly toward [1, 0, 0].
        let beachPoints: [(album: String, vector: [Float])] = [
            (album: "Beach", vector: Similarity.normalize([1.0,  0.10, 0])),
            (album: "Beach", vector: Similarity.normalize([1.0,  0.05, 0])),
            (album: "Beach", vector: Similarity.normalize([0.98, 0.20, 0])),
        ]
        // City exemplars: point toward [0, 1, 0] (orthogonal to Beach).
        let cityPoints: [(album: String, vector: [Float])] = [
            (album: "City", vector: Similarity.normalize([0.05, 1.0, 0])),
            (album: "City", vector: Similarity.normalize([0.10, 1.0, 0])),
            (album: "City", vector: Similarity.normalize([0.02, 0.95, 0])),
        ]

        // Query pointing squarely toward the Beach cluster.
        let query = Similarity.normalize([1.0, 0.0, 0.0])
        let suggestions = AlbumSuggester.rank(
            query: query,
            labeledPoints: beachPoints + cityPoints,
            k: 6
        )

        XCTAssertFalse(suggestions.isEmpty, "Should return at least one suggestion")
        XCTAssertEqual(suggestions.first?.albumTitle, "Beach", "Beach should rank first")
        let beachScore = suggestions.first(where: { $0.albumTitle == "Beach" })?.score ?? 0
        let cityScore  = suggestions.first(where: { $0.albumTitle == "City"  })?.score ?? 0
        XCTAssertGreaterThan(beachScore, cityScore, "Beach score must exceed City score")
    }

    /// `supportingCount` for each suggestion equals the number of top-k neighbors
    /// from that album.
    func testSupportingCountIsCorrect() {
        // 3 Beach points, 1 City point; query near Beach.
        let labeled: [(album: String, vector: [Float])] = [
            (album: "Beach", vector: Similarity.normalize([1.0, 0.0, 0])),
            (album: "Beach", vector: Similarity.normalize([0.99, 0.14, 0])),
            (album: "Beach", vector: Similarity.normalize([0.98, 0.20, 0])),
            (album: "City",  vector: Similarity.normalize([0.0, 1.0, 0])),
        ]
        let query = Similarity.normalize([1.0, 0.0, 0.0])
        let suggestions = AlbumSuggester.rank(query: query, labeledPoints: labeled, k: 4)

        let beach = suggestions.first(where: { $0.albumTitle == "Beach" })
        XCTAssertNotNil(beach)
        XCTAssertEqual(beach?.supportingCount, 3, "All 3 Beach neighbors should be counted")

        let city = suggestions.first(where: { $0.albumTitle == "City" })
        XCTAssertNotNil(city)
        XCTAssertEqual(city?.supportingCount, 1, "Exactly 1 City neighbor")
    }

    // MARK: - Edge cases

    /// Empty `labeledPoints` → returns [].
    func testEmptyLabeledPointsReturnsEmpty() {
        let query = Similarity.normalize([1, 0, 0])
        let result = AlbumSuggester.rank(query: query, labeledPoints: [], k: 5)
        XCTAssertTrue(result.isEmpty)
    }

    /// Empty query vector → returns [].
    func testEmptyQueryReturnsEmpty() {
        let labeled: [(album: String, vector: [Float])] = [
            (album: "Beach", vector: Similarity.normalize([1, 0, 0]))
        ]
        let result = AlbumSuggester.rank(query: [], labeledPoints: labeled, k: 5)
        XCTAssertTrue(result.isEmpty)
    }

    /// k larger than labeledPoints.count → uses all points, no crash.
    func testKLargerThanLabeledPointsUsesAllPoints() {
        let labeled: [(album: String, vector: [Float])] = [
            (album: "Beach", vector: Similarity.normalize([1.0, 0, 0])),
            (album: "Beach", vector: Similarity.normalize([0.9, 0.1, 0])),
        ]
        let query = Similarity.normalize([1.0, 0, 0])
        let result = AlbumSuggester.rank(query: query, labeledPoints: labeled, k: 100)
        XCTAssertFalse(result.isEmpty, "Should return at least one suggestion")
        XCTAssertEqual(result.first?.albumTitle, "Beach")
        XCTAssertEqual(result.first?.supportingCount, 2,
                       "Both points used when k > count")
    }

    // MARK: - Score invariants

    /// All scores must lie in [0, 1].
    func testScoresAreInUnitInterval() {
        let labeled: [(album: String, vector: [Float])] = [
            (album: "Beach", vector: Similarity.normalize([1.0, 0.1, 0])),
            (album: "City",  vector: Similarity.normalize([0.0, 1.0, 0])),
            (album: "Forest",vector: Similarity.normalize([-1.0, 0.1, 0])),
        ]
        let query = Similarity.normalize([0.7, 0.7, 0])
        let result = AlbumSuggester.rank(query: query, labeledPoints: labeled, k: 3)
        for suggestion in result {
            XCTAssertGreaterThanOrEqual(suggestion.score, 0,
                "Score must be ≥ 0, got \(suggestion.score) for \(suggestion.albumTitle)")
            XCTAssertLessThanOrEqual(suggestion.score, 1,
                "Score must be ≤ 1, got \(suggestion.score) for \(suggestion.albumTitle)")
        }
    }

    /// Suggestions must be sorted in descending score order.
    func testScoresAreSortedDescending() {
        let labeled: [(album: String, vector: [Float])] = [
            (album: "Beach",  vector: Similarity.normalize([1.0, 0.0, 0])),
            (album: "Beach",  vector: Similarity.normalize([0.95, 0.31, 0])),
            (album: "City",   vector: Similarity.normalize([0.5, 0.87, 0])),
            (album: "Forest", vector: Similarity.normalize([0.0, 1.0, 0])),
        ]
        let query = Similarity.normalize([1.0, 0.0, 0.0])
        let result = AlbumSuggester.rank(query: query, labeledPoints: labeled, k: 4)
        for i in 1..<result.count {
            XCTAssertGreaterThanOrEqual(result[i - 1].score, result[i].score,
                "Scores should be non-increasing; violation at index \(i)")
        }
    }

    // MARK: - AlbumSuggestion identity

    /// `id` is the album title; Hashable conformance allows use in Sets/ForEach.
    func testAlbumSuggestionIdentity() {
        let s = AlbumSuggestion(albumTitle: "Beach", score: 0.9, supportingCount: 3)
        XCTAssertEqual(s.id, "Beach")

        let set: Set<AlbumSuggestion> = [s, s]
        XCTAssertEqual(set.count, 1, "Duplicate AlbumSuggestion should collapse in a Set")
    }
}
