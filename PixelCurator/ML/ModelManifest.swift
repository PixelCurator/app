import Foundation
import CryptoKit

/// Pinned SHA-256 hashes for downloaded Core ML model files (F-05 / R-04).
///
/// Why this exists: `ModelStore` downloads pro-variant `.mlpackage` files from
/// HuggingFace. A compromised HuggingFace account, MITM proxy, or rogue mirror
/// could ship malformed weights. Core ML models are not executable code, but
/// poisoned weights cause silent misclassification (mis-album assignment),
/// and the Core ML compiler itself has had CVEs. We pin both the upstream
/// commit-SHA and a per-file SHA-256 so verification fails closed if any byte
/// is tampered with.
///
/// Per Apple Core ML (iOS 17 SDK), `MLModel.compileModel(at:)` is happy to
/// compile any well-formed `.mlpackage` regardless of provenance — provenance
/// must be enforced at the download layer. This struct is that layer.
///
/// ## Refreshing pinned hashes
///
/// When bumping `commitSHA` to pull updated weights:
///
/// 1. Pick the new HuggingFace commit on https://huggingface.co/apple/coreml-mobileclip/commits/main
/// 2. For each `<filename>` in `files[variant]`, run:
///    ```
///    curl -sSL "https://huggingface.co/apple/coreml-mobileclip/resolve/<commit-sha>/<filename>" \
///      | shasum -a 256
///    ```
/// 3. Paste the resulting 64-char lowercase-hex string as the entry's `sha256`.
/// 4. Update `commitSHA` to the new commit.
/// 5. Run the `ModelStoreTests` suite — checksum tests verify the data flow,
///    but the per-variant hashes themselves are only validated at runtime
///    against a real download.
///
/// ## Sandbox note
///
/// The hashes shipped in this initial commit are TODO placeholders — the agent
/// that wrote this file could not reach `huggingface.co` from inside its
/// sandbox to compute real values. Until they are filled in, runtime
/// verification is gated by `ModelManifest.verifyDownloads`, which defaults to
/// `false` in debug builds. **Set this to `true` (and replace every
/// `TODO_sha256_…` placeholder) before any release build.**
enum ModelManifest {

    // MARK: - Toggle

    /// When `true`, `ModelStore.downloadFile` enforces SHA-256 verification
    /// against the pinned hash; mismatches throw `ModelStoreError.checksumMismatch`
    /// and the cached file is deleted.
    ///
    /// Default `false` so the existing download path keeps working while real
    /// hashes are still TODO placeholders. Flip to `true` once `files` is
    /// fully populated (see "Refreshing pinned hashes" above).
    ///
    /// The unit-test suite calls `verifyChecksum(data:expectedHex:)` directly
    /// and is independent of this flag.
    static let verifyDownloads: Bool = true

    // MARK: - Upstream pin

    /// HuggingFace commit hash pinned for all downloads.
    ///
    /// Using a commit SHA (instead of `main`) is what makes the URL
    /// content-addressable: the same URL returns the same bytes forever,
    /// even if the branch tip moves. Bumping this requires regenerating
    /// every `sha256` below.
    ///
    /// Measured 2026-06-24 against the latest commit on `main` at that
    /// time. Bump alongside refreshing every per-file `sha256` below.
    static let commitSHA: String = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"

    // MARK: - Per-variant file list

    /// File descriptor: the suffix appended after `<commitSHA>/` in the
    /// HuggingFace `resolve` URL, plus the SHA-256 the downloaded bytes
    /// must hash to.
    struct File: Sendable {
        /// Path suffix under the HuggingFace repo root, e.g.
        /// `"mobileclip_s1_image.mlpackage/Manifest.json"`.
        let suffix: String

        /// Lowercase-hex 64-character SHA-256 digest of the file's bytes.
        ///
        /// Placeholders use the format `"TODO_sha256_<variant>_<basename>"` —
        /// they are deliberately the wrong length so a comparison can never
        /// silently succeed even if `verifyDownloads` is flipped on without
        /// real hashes being filled in.
        let sha256: String
    }

    /// Returns the pinned files for `variant`, or `nil` if no manifest entry
    /// exists yet. Callers should treat `nil` as "no enforcement" rather than
    /// fail closed during early-bring-up of a new variant — pair with the
    /// `verifyDownloads` toggle to make the policy explicit.
    static func files(for variant: CLIPVariant) -> [File]? {
        switch variant {
        case .s0:
            // S0 is bundled in the app — never downloaded, no manifest entry.
            return nil
        case .s1:
            return [
                File(
                    suffix: "mobileclip_s1_image.mlpackage/Manifest.json",
                    sha256: "902dc75013a87c745008184e08cec9172b060cbc7940a16ca2274fc11f4b3021"
                ),
                File(
                    suffix: "mobileclip_s1_image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    sha256: "3b1cc781d6d0af08d95d338b083ae6fb97315cc5810037ceb34bc4b19ea41219"
                ),
                File(
                    suffix: "mobileclip_s1_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    sha256: "0d817354a9b98b17f289d1f3e398c1f21d1f7e659ae04d18aa7f94e5a3283da2"
                ),
            ]
        case .s2:
            return [
                File(
                    suffix: "mobileclip_s2_image.mlpackage/Manifest.json",
                    sha256: "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6"
                ),
                File(
                    suffix: "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    sha256: "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b"
                ),
                File(
                    suffix: "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    sha256: "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00"
                ),
            ]
        case .b:
            // The "B" variant ships in HuggingFace as `mobileclip_blt_*` —
            // not `mobileclip_b_*`. CLIPVariant.imageEncoderPackageName
            // returns the correct `mobileclip_blt_image.mlpackage` suffix;
            // these entries must match.
            return [
                File(
                    suffix: "mobileclip_blt_image.mlpackage/Manifest.json",
                    sha256: "112a034d18e8c76b21e491a94ee8236e6989021c13dfe9ea8ecd3ac6dc2bdabe"
                ),
                File(
                    suffix: "mobileclip_blt_image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    sha256: "3acaec5c9eca2f27b7dc6d3bffb19cbb94d34e97cdd8aec70987e4ae7de09fae"
                ),
                File(
                    suffix: "mobileclip_blt_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    sha256: "c12ec418eadf5d536f11e2e575b26c0d0bbc1270a7080d97f218a0a11595c289"
                ),
            ]
        }
    }

    /// Returns the pinned SHA-256 for a specific file suffix, or `nil`
    /// if the suffix is not in the manifest.
    static func expectedSHA256(for suffix: String, variant: CLIPVariant) -> String? {
        files(for: variant)?.first { $0.suffix == suffix }?.sha256
    }

    // MARK: - Hashing

    /// Computes the lowercase-hex SHA-256 of `data`.
    ///
    /// Uses `CryptoKit.SHA256` (iOS 13+, macOS 10.15+). Per Apple
    /// CryptoKit docs, `SHA256.hash(data:)` returns a `Digest` whose
    /// `description` is the readable hex; we iterate the bytes manually to
    /// guarantee the exact format (lowercase, no separators, no prefix).
    static func sha256Hex(of data: Data) -> String {
        SHA256Hasher.hex(data)
    }

    /// Compares the SHA-256 of `data` against `expectedHex` in constant time.
    ///
    /// Constant-time comparison is overkill for a static file hash (the
    /// expected value isn't a secret), but it costs nothing and prevents
    /// any future caller from leaking timing if they ever start treating
    /// the hash as a secret-ish value. Returns `true` on match.
    static func verifyChecksum(data: Data, expectedHex: String) -> Bool {
        let actual = sha256Hex(of: data)
        guard actual.count == expectedHex.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(actual.utf8, expectedHex.utf8) {
            diff |= a ^ b
        }
        return diff == 0
    }
}

// MARK: - SHA-256 helper

/// Thin wrapper around `CryptoKit.SHA256` that returns lowercase-hex.
///
/// Kept private to `ModelManifest`'s file because no other call site needs
/// generic hashing — broadening it would invite ad-hoc use without the
/// "verify against pinned manifest" semantics.
private enum SHA256Hasher {
    static func hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(String(format: "%02x", byte))
        }
        return hex
    }
}
