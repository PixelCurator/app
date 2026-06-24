import CoreML
import Foundation

/// Resolves compiled Core ML model URLs for each `CLIPVariant`.
///
/// For the bundled S0 variant, `compiledModelURL(for:)` checks the app bundle
/// for a pre-compiled `.mlmodelc`, then falls back to compiling the bundled
/// `.mlpackage` and caching the result in Application Support.
///
/// Pro variants (S1, S2, B) are downloaded on demand from HuggingFace into
/// Application Support, compiled via `MLModel.compileModel(at:)`, and cached.
/// The cache is checked first — re-download is skipped if the `.mlmodelc` exists.
final class ModelStore {

    // MARK: - Init

    init() {}

    // MARK: - Compiled model resolution

    /// Returns the URL of a compiled `.mlmodelc` for `variant`.
    ///
    /// - For `.s0`: resolves from bundle or compiles the bundled package.
    /// - For pro variants: checks the compiled-model cache; if absent,
    ///   downloads the `.mlpackage` from HuggingFace, compiles, and caches.
    ///
    /// - Parameter variant: The `CLIPVariant` to resolve.
    /// - Returns: A file URL pointing to a ready-to-load `.mlmodelc` directory.
    /// - Throws: `ModelStoreError` on any failure.
    static func compiledModelURL(for variant: CLIPVariant) async throws -> URL {
        switch variant {
        case .s0:
            return try await resolveS0()
        case .s1, .s2, .b:
            return try await resolveProVariant(variant)
        }
    }

    // MARK: - S0 (bundled, unchanged)

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

        try moveToCache(from: compiledTemp, to: cacheURL)
        return cacheURL
    }

    // MARK: - Pro variants (download on demand)

    /// HuggingFace base URL for the apple/coreml-mobileclip repository.
    ///
    /// Uses the **content-addressable** `resolve/<commit-sha>` form (not `main`)
    /// so the same URL returns the same bytes forever; combined with the
    /// per-file SHA-256 in `ModelManifest`, this gives us a verifiable
    /// supply-chain pin for the model weights (F-05 / R-04). Bumping
    /// `ModelManifest.commitSHA` requires re-pinning every file hash.
    private static var hfBaseURL: String {
        "https://huggingface.co/apple/coreml-mobileclip/resolve/\(ModelManifest.commitSHA)"
    }

    /// Resolves a pro variant by checking cache first, then downloading from HuggingFace.
    ///
    /// Download structure (three files per package):
    ///   <hfBaseURL>/<imageEncoderPackageName>/Manifest.json
    ///   <hfBaseURL>/<imageEncoderPackageName>/Data/com.apple.CoreML/model.mlmodel
    ///   <hfBaseURL>/<imageEncoderPackageName>/Data/com.apple.CoreML/weights/weight.bin
    private static func resolveProVariant(_ variant: CLIPVariant) async throws -> URL {
        let baseName = String(variant.imageEncoderPackageName.dropLast(".mlpackage".count))
        let cacheURL = try cachedModelURL(baseName: baseName)

        // Cache-first: if compiled model already exists, return immediately.
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        // Download the .mlpackage into a temp directory, compile, cache, return.
        let packageURL = try await downloadMLPackage(for: variant)
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let compiledTemp: URL
        do {
            compiledTemp = try await MLModel.compileModel(at: packageURL)
        } catch {
            throw ModelStoreError.compilationFailed(error)
        }

        try moveToCache(from: compiledTemp, to: cacheURL)
        return cacheURL
    }

    /// Downloads all three files that make up a `.mlpackage` directory into a
    /// temporary location, then returns the URL of the reconstructed package directory.
    ///
    /// Package layout on disk after download:
    ///   <tmpDir>/<imageEncoderPackageName>/Manifest.json
    ///   <tmpDir>/<imageEncoderPackageName>/Data/com.apple.CoreML/model.mlmodel
    ///   <tmpDir>/<imageEncoderPackageName>/Data/com.apple.CoreML/weights/weight.bin
    private static func downloadMLPackage(for variant: CLIPVariant) async throws -> URL {
        let packageName = variant.imageEncoderPackageName  // e.g. "mobileclip_s1_image.mlpackage"
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelCurator-\(variant.modelID)-\(UUID().uuidString)", isDirectory: true)
        let packageDir = tmpDir.appendingPathComponent(packageName, isDirectory: true)

        // Create the expected directory tree.
        let coreMLDir = packageDir
            .appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        let weightsDir = coreMLDir.appendingPathComponent("weights", isDirectory: true)

        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)

        // File descriptors: (relative URL suffix, local destination)
        let files: [(String, URL)] = [
            ("\(packageName)/Manifest.json",
             packageDir.appendingPathComponent("Manifest.json")),
            ("\(packageName)/Data/com.apple.CoreML/model.mlmodel",
             coreMLDir.appendingPathComponent("model.mlmodel")),
            ("\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
             weightsDir.appendingPathComponent("weight.bin")),
        ]

        for (suffix, destination) in files {
            guard let remoteURL = URL(string: "\(hfBaseURL)/\(suffix)") else {
                throw ModelStoreError.invalidDownloadURL(suffix)
            }
            let expectedHash = ModelManifest.expectedSHA256(for: suffix, variant: variant)
            try await downloadFile(
                from: remoteURL,
                to: destination,
                expectedSHA256: expectedHash
            )
        }

        return packageDir
    }

    /// Downloads a single file from `remoteURL` and writes it to `localURL`,
    /// using `URLSession` with default configuration. Overwrites any existing file.
    ///
    /// When `expectedSHA256` is non-nil **and** `ModelManifest.verifyDownloads`
    /// is `true`, the bytes are SHA-256 hashed and compared to the pin before
    /// being moved into place. On mismatch we delete both the temp download
    /// and any pre-existing destination, then throw
    /// `ModelStoreError.checksumMismatch` — fail closed (F-05 / R-04).
    static func downloadFile(
        from remoteURL: URL,
        to localURL: URL,
        expectedSHA256: String?
    ) async throws {
        let (tmpURL, response) = try await URLSession.shared.download(from: remoteURL)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ModelStoreError.downloadFailed(remoteURL, statusCode: httpResponse.statusCode)
        }

        // Verify checksum before publishing the file. We read the temp file
        // (already on disk, written by URLSession) rather than the destination
        // so a mismatch never leaves a poisoned file in the cache.
        if ModelManifest.verifyDownloads, let expectedSHA256 {
            let data: Data
            do {
                data = try Data(contentsOf: tmpURL)
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
                throw ModelStoreError.checksumReadFailed(remoteURL, underlying: error)
            }
            let actualHex = ModelManifest.sha256Hex(of: data)
            guard ModelManifest.verifyChecksum(data: data, expectedHex: expectedSHA256) else {
                try? FileManager.default.removeItem(at: tmpURL)
                // Defensive cleanup: if a prior partial download left a file at
                // `localURL`, drop it so the next attempt re-downloads cleanly.
                try? FileManager.default.removeItem(at: localURL)
                throw ModelStoreError.checksumMismatch(
                    url: remoteURL,
                    expected: expectedSHA256,
                    actual: actualHex
                )
            }
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: localURL)
    }

    // MARK: - Shared cache helpers

    private static func cachedModelURL(baseName: String) throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("PixelCurator/CompiledModels", isDirectory: true)
            .appendingPathComponent("\(baseName).mlmodelc")
    }

    private static func moveToCache(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

// MARK: - Errors

enum ModelStoreError: LocalizedError {
    case notDownloadedYet(CLIPVariant)        // kept for legacy callers; no longer thrown internally
    case bundleResourceMissing(String)
    case compilationFailed(Error)
    case invalidDownloadURL(String)
    case downloadFailed(URL, statusCode: Int)
    /// The downloaded bytes did not hash to the pinned SHA-256 in
    /// `ModelManifest`. The downloaded temp file is deleted before the throw —
    /// the cache stays uncorrupted. Callers should not retry without
    /// investigating: a mismatch means either the manifest is stale (new
    /// upstream commit) or the download path is compromised (MITM / poisoned
    /// mirror). F-05 / R-04.
    case checksumMismatch(url: URL, expected: String, actual: String)
    /// The downloaded temp file could not be read back for checksum
    /// verification. Treated as a hard failure rather than degrading to
    /// "ship without verification" — if the disk is too sick to read what we
    /// just wrote, the resulting `.mlpackage` is not trustworthy either.
    case checksumReadFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notDownloadedYet(let variant):
            return "Model '\(variant.displayName)' has not been downloaded yet."
        case .bundleResourceMissing(let name):
            return "Bundle resource '\(name)' not found."
        case .compilationFailed(let underlying):
            return "Model compilation failed: \(underlying.localizedDescription)"
        case .invalidDownloadURL(let suffix):
            return "Could not construct download URL for '\(suffix)'."
        case .downloadFailed(let url, let statusCode):
            return "Download failed for \(url.lastPathComponent) (HTTP \(statusCode))."
        case .checksumMismatch(let url, let expected, let actual):
            // Defensive phrasing — no exploit walkthrough, no hint about
            // bypass. Surface enough to debug a legitimate upstream-commit
            // bump (the hash diff identifies the offending file).
            return "Downloaded file failed integrity check: \(url.lastPathComponent). " +
                "Expected SHA-256 \(expected), got \(actual)."
        case .checksumReadFailed(let url, let underlying):
            return "Could not verify integrity of downloaded file \(url.lastPathComponent): " +
                "\(underlying.localizedDescription)"
        }
    }
}
