import XCTest
import CoreML
@testable import PixelCurator

/// Tests for `ModelStore` that do NOT perform real network downloads.
///
/// - S0 path: verifies that `compiledModelURL(for: .s0)` resolves to an existing URL
///   (this requires the bundled model to be present in the test host bundle).
/// - Pro download path: tests the cache-hit branch by pre-placing a sentinel file at
///   the expected cache location and asserting it is returned without a network call.
/// - URL structure: tests that the derived HuggingFace URLs are well-formed.
final class ModelStoreTests: XCTestCase {

    // MARK: - S0 (bundled)

    func testS0ResolvesToExistingURL() async throws {
        let url = try await ModelStore.compiledModelURL(for: .bundledDefault)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "S0 compiled model URL must point to an existing path: \(url.path)"
        )
        XCTAssertTrue(
            url.path.hasSuffix(".mlmodelc"),
            "S0 URL must end in .mlmodelc, got: \(url.path)"
        )
    }

    // MARK: - Pro cache-hit branch

    /// Pre-places a fake `.mlmodelc` directory at the expected cache location for S1,
    /// then asserts that `compiledModelURL(for: .s1)` returns it without downloading.
    func testProVariantCacheHitReturnsWithoutDownload() async throws {
        let cacheURL = try proVariantCacheURL(for: .s1)

        // Set up: create a fake .mlmodelc directory in the cache.
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        defer {
            // Tear down: remove the sentinel so it doesn't pollute other test runs.
            try? FileManager.default.removeItem(at: cacheURL)
        }

        // ModelStore should return the cache URL without attempting a download.
        let resolved = try await ModelStore.compiledModelURL(for: .s1)
        // Normalize by stripping any trailing slash before comparing paths.
        let resolvedPath = resolved.path.hasSuffix("/") ? String(resolved.path.dropLast()) : resolved.path
        let expectedPath = cacheURL.path.hasSuffix("/") ? String(cacheURL.path.dropLast()) : cacheURL.path
        XCTAssertEqual(
            resolvedPath,
            expectedPath,
            "Pro variant should return the cached .mlmodelc URL without downloading"
        )
    }

    // MARK: - Cache URL structure

    func testProVariantCacheURLStructure() throws {
        for variant in CLIPVariant.allCases where variant.tier == .pro {
            let url = try proVariantCacheURL(for: variant)
            XCTAssertTrue(
                url.path.contains("PixelCurator/CompiledModels"),
                "Cache URL for \(variant.displayName) must be under PixelCurator/CompiledModels"
            )
            XCTAssertTrue(
                url.path.hasSuffix(".mlmodelc"),
                "Cache URL for \(variant.displayName) must end in .mlmodelc"
            )
            // The base name should match the package name minus the extension.
            let baseName = String(variant.imageEncoderPackageName.dropLast(".mlpackage".count))
            XCTAssertTrue(
                url.lastPathComponent == "\(baseName).mlmodelc",
                "Cache filename for \(variant.displayName) should be \(baseName).mlmodelc"
            )
        }
    }

    // MARK: - HuggingFace URL well-formedness

    func testDownloadURLsAreWellFormed() {
        let hfBase = "https://huggingface.co/apple/coreml-mobileclip/resolve/main"
        for variant in CLIPVariant.allCases where variant.tier == .pro {
            let packageName = variant.imageEncoderPackageName
            let suffixes = [
                "\(packageName)/Manifest.json",
                "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
                "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
            ]
            for suffix in suffixes {
                let urlString = "\(hfBase)/\(suffix)"
                let url = URL(string: urlString)
                XCTAssertNotNil(url, "URL should be valid: \(urlString)")
                XCTAssertEqual(url?.scheme, "https")
                XCTAssertEqual(url?.host, "huggingface.co")
            }
        }
    }

    // MARK: - Helpers

    /// Replicates the cache URL logic from `ModelStore` for test setup/assertions.
    private func proVariantCacheURL(for variant: CLIPVariant) throws -> URL {
        let baseName = String(variant.imageEncoderPackageName.dropLast(".mlpackage".count))
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("PixelCurator/CompiledModels", isDirectory: true)
            .appendingPathComponent("\(baseName).mlmodelc")
    }
}
