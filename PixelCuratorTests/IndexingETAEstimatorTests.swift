import XCTest
@testable import PixelCurator

/// Unit tests for `IndexingETAEstimator`.
///
/// All tests run on `@MainActor` because `IndexingETAEstimator` is `@MainActor`-isolated.
@MainActor
final class IndexingETAEstimatorTests: XCTestCase {

    // MARK: - Below minSamples

    func test_estimateIsNilBeforeMinSamples() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 20)
        // Feed 19 ticks — one below the minimum.
        feedTicks(sut, count: 19, interval: 1.0)
        XCTAssertNil(sut.estimatedSecondsRemaining(remaining: 10),
                     "Expected nil before reaching minSamples")
    }

    func test_estimateIsNilWithZeroTicks() {
        let sut = IndexingETAEstimator()
        XCTAssertNil(sut.estimatedSecondsRemaining(remaining: 5),
                     "Fresh estimator must return nil")
    }

    func test_estimateIsNilWhenRemainingIsZero() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 5)
        feedTicks(sut, count: 10, interval: 1.0)
        XCTAssertNil(sut.estimatedSecondsRemaining(remaining: 0),
                     "Zero remaining must return nil")
    }

    // MARK: - At or above minSamples

    func test_estimateAppearsAtExactlyMinSamples() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 20)
        feedTicks(sut, count: 20, interval: 1.0)
        XCTAssertNotNil(sut.estimatedSecondsRemaining(remaining: 10),
                        "Estimate must appear at exactly minSamples ticks")
    }

    /// With a uniform 1-second tick interval and 10 remaining assets, the
    /// expected estimate is 10 s. Allow ±25 % (7.5 s – 12.5 s).
    func test_estimateAccuracy_uniformInterval_within25Percent() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 20)
        let intervalSeconds: TimeInterval = 1.0
        let remaining = 10
        let expected = intervalSeconds * Double(remaining) // 10 s

        feedTicks(sut, count: 25, interval: intervalSeconds)

        let estimate = sut.estimatedSecondsRemaining(remaining: remaining)
        XCTAssertNotNil(estimate)
        if let estimate {
            let tolerance = expected * 0.25
            XCTAssertEqual(estimate, expected, accuracy: tolerance,
                           "Estimate \(estimate) s deviates >25% from expected \(expected) s")
        }
    }

    /// 2 s/photo uniform, 5 remaining → expect 10 s ± 2.5 s.
    func test_estimateAccuracy_slowerInterval_within25Percent() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 20)
        let intervalSeconds: TimeInterval = 2.0
        let remaining = 5
        let expected = intervalSeconds * Double(remaining) // 10 s

        feedTicks(sut, count: 20, interval: intervalSeconds)

        let estimate = sut.estimatedSecondsRemaining(remaining: remaining)
        XCTAssertNotNil(estimate)
        if let estimate {
            let tolerance = expected * 0.25
            XCTAssertEqual(estimate, expected, accuracy: tolerance,
                           "Estimate \(estimate) s deviates >25% from expected \(expected) s")
        }
    }

    // MARK: - Window trimming

    /// After exceeding `windowSize`, only the most recent `windowSize` ticks
    /// should count. Feed 40 ticks at 0.5 s, then 10 ticks at 2 s into a
    /// window of 30. The window should contain only the 2 s ticks + the last
    /// few 0.5 s ticks, making the estimate dominated by the slower rate.
    func test_windowTrimsOldTicks() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 20)

        // First 40 ticks at 0.5 s (fast) — all pushed out of the window
        feedTicks(sut, count: 40, interval: 0.5)

        // Next 30 ticks at 3 s (slow) — should fill the entire window
        feedTicks(sut, count: 30, interval: 3.0, startOffset: 40 * 0.5)

        let estimate = sut.estimatedSecondsRemaining(remaining: 10)
        XCTAssertNotNil(estimate)
        // With all 30 window slots at 3 s/tick, estimate ≈ 30 s (10 × 3 s).
        // Allow ±25 % → 22.5 s – 37.5 s.
        if let estimate {
            XCTAssertGreaterThan(estimate, 22.5, "Estimate too low — old fast ticks leaked into window")
            XCTAssertLessThan(estimate, 37.5, "Estimate too high — unexpected skew")
        }
    }

    // MARK: - Reset

    func test_resetClearsTicks() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 5)
        feedTicks(sut, count: 10, interval: 1.0)
        sut.reset()
        XCTAssertNil(sut.estimatedSecondsRemaining(remaining: 5),
                     "After reset the estimator must return nil until minSamples are re-fed")
    }

    func test_estimateResumesAfterResetAndRefeed() {
        let sut = IndexingETAEstimator(windowSize: 30, minSamples: 5)
        feedTicks(sut, count: 10, interval: 1.0)
        sut.reset()
        feedTicks(sut, count: 5, interval: 2.0)
        // 5 ticks at 2 s/tick, remaining = 3 → expect ≈ 6 s
        let estimate = sut.estimatedSecondsRemaining(remaining: 3)
        XCTAssertNotNil(estimate)
        if let estimate {
            XCTAssertEqual(estimate, 6.0, accuracy: 6.0 * 0.25)
        }
    }

    // MARK: - Helpers

    /// Feeds `count` synthetic ticks at `interval`-second spacing, starting
    /// at `Date(timeIntervalSinceReferenceDate: startOffset)`.
    private func feedTicks(
        _ estimator: IndexingETAEstimator,
        count: Int,
        interval: TimeInterval,
        startOffset: TimeInterval = 0
    ) {
        for i in 0 ..< count {
            let t = Date(timeIntervalSinceReferenceDate: startOffset + Double(i) * interval)
            estimator.recordTick(at: t)
        }
    }
}
