import CoreML
import Foundation

/// Resolves compiled Core ML model URLs for each `CLIPVariant`.
///
/// For the bundled S0 variant, `compiledModelURL(for:)` checks the app bundle
/// for a pre-compiled `.mlmodelc`, then falls back to compiling the bundled
/// `.mlpackage` and caching the result in Application Support.
///
/// Pro variants (S1, S2, B) are download-on-demand and not exercised in Slice B.
final class ModelStore {

    // MARK: - Init

    init() {}

    // MARK: - Compiled model resolution

    /// Returns the URL of a compiled `.mlmodelc` for `variant`, compiling and
    /// caching if needed.
    ///
    /// - Parameter variant: The `CLIPVariant` to resolve.
    /// - Returns: A file URL pointing to a `.mlmodelc` directory ready for `MLModel`.
    /// - Throws: `ModelStoreError` if the resource is missing or compilation fails.
    static func compiledModelURL(for variant: CLIPVariant) async throws -> URL {
        switch variant {
        case .s0:
            return try await resolveS0()
        case .s1, .s2, .b:
            throw ModelStoreError.notDownloadedYet(variant)
        }
    }

    // MARK: - Private helpers

    private static func resolveS0() async throws -> URL {
        let baseName = "mobileclip_s0_image"

        // 1. Pre-compiled .mlmodelc already in the bundle (Xcode auto-compiles on build).
        if let bundledCompiled = Bundle.main.url(forResource: baseName, withExtension: "mlmodelc") {
            return bundledCompiled
        }

        // 2. Cached compiled model in Application Support.
        let cacheURL = try cachedModelURL(baseName: baseName)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        // 3. Fall back to compiling the bundled .mlpackage.
        guard let packageURL = Bundle.main.url(forResource: baseName, withExtension: "mlpackage") else {
            throw ModelStoreError.bundleResourceMissing("\(baseName).mlpackage")
        }

        let compiledTemp: URL
        do {
            compiledTemp = try await MLModel.compileModel(at: packageURL)
        } catch {
            throw ModelStoreError.compilationFailed(error)
        }

        // Move the compiled output to the stable cache location.
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Replace any stale partial output.
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
        try FileManager.default.moveItem(at: compiledTemp, to: cacheURL)

        return cacheURL
    }

    private static func cachedModelURL(baseName: String) throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("PixelCurator/CompiledModels", isDirectory: true)
            .appendingPathComponent("\(baseName).mlmodelc")
    }
}

// MARK: - Errors

enum ModelStoreError: LocalizedError {
    case notDownloadedYet(CLIPVariant)
    case bundleResourceMissing(String)
    case compilationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notDownloadedYet(let variant):
            return "Model '\(variant.displayName)' has not been downloaded yet."
        case .bundleResourceMissing(let name):
            return "Bundle resource '\(name)' not found."
        case .compilationFailed(let underlying):
            return "Model compilation failed: \(underlying.localizedDescription)"
        }
    }
}
