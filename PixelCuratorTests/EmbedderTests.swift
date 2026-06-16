import XCTest
import CoreGraphics
import SwiftData
@testable import PixelCurator

/// Tests for the Embedder actor and ModelStore using the bundled S0 model.
///
/// These tests require the real mobileclip_s0_image model to be present in
/// Bundle.main (the test host). They are model-dependent and not stubbable.
final class EmbedderTests: XCTestCase {

    // MARK: - Helpers

    /// Loads the bundled S0 compiled model URL via ModelStore.
    private func modelURL() async throws -> URL {
        try await ModelStore.compiledModelURL(for: .bundledDefault)
    }

    /// Creates a solid-color CGImage of the given size.
    private func makeSolidCGImage(width: Int = 64, height: Int = 64, gray: CGFloat = 0.5) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Test A: dimension

    func testEmbeddingDimensionIsPositiveAndMatchesModel() async throws {
        let url = try await modelURL()
        let embedder = try await Embedder(modelURL: url)
        let dim = embedder.embeddingDimension
        XCTAssertGreaterThan(dim, 0, "embeddingDimension must be positive")
        // S0 is expected to report 512; assert it matches what the model advertises
        XCTAssertEqual(dim, 512, "S0 model should report 512-dimensional embeddings")
    }

    // MARK: - Test B: unit norm

    func testEmbedSolidColorImageReturnsUnitNormVector() async throws {
        let url = try await modelURL()
        let embedder = try await Embedder(modelURL: url)
        let dim = embedder.embeddingDimension

        let cgImage = makeSolidCGImage()
        let vector = try await embedder.embed(cgImage)

        XCTAssertEqual(vector.count, dim, "Vector length must equal embeddingDimension")

        // All values must be finite
        for (i, v) in vector.enumerated() {
            XCTAssert(v.isFinite, "Non-finite value at index \(i): \(v)")
        }

        // L2 norm must be ≈ 1.0 (since Embedder applies Similarity.normalize)
        var sumSq: Float = 0
        for v in vector { sumSq += v * v }
        let norm = sqrtf(sumSq)
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3, "Embedded vector must have unit L2 norm")
    }

    // MARK: - Test C: determinism

    func testEmbedSameImageTwiceGivesCosineSimilarityOne() async throws {
        let url = try await modelURL()
        let embedder = try await Embedder(modelURL: url)

        let cgImage = makeSolidCGImage(gray: 0.3)
        let v1 = try await embedder.embed(cgImage)
        let v2 = try await embedder.embed(cgImage)

        XCTAssertEqual(v1.count, v2.count)

        // Dot product of two L2-normalised vectors == cosine similarity
        var dot: Float = 0
        for (a, b) in zip(v1, v2) { dot += a * b }
        XCTAssertEqual(dot, 1.0, accuracy: 1e-3, "Same image embedded twice must yield cosine similarity ≈ 1.0")
    }
}
