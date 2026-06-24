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
    static let verifyDownloads: Bool = false

    // MARK: - Upstream pin

    /// HuggingFace commit hash pinned for all downloads.
    ///
    /// Using a commit SHA (instead of `main`) is what makes the URL
    /// content-addressable: the same URL returns the same bytes forever,
    /// even if the branch tip moves. Bumping this requires regenerating
    /// every `sha256` below.
    ///
    /// TODO_commit_sha: replace with the actual commit you measured the
    /// hashes against. The placeholder is intentionally invalid so a build
    /// that flips `verifyDownloads = true` without updating the manifest
    /// fails loudly instead of silently downloading from `main`.
    static let commitSHA: String = "TODO_commit_sha_replace_before_release"

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
                    sha256: "TODO_sha256_s1_manifest_json"
                ),
                File(
                    suffix: "mobileclip_s1_image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    sha256: "TODO_sha256_s1_model_mlmodel"
                ),
                File(
                    suffix: "mobileclip_s1_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    sha256: "TODO_sha256_s1_weight_bin"
                ),
            ]
        case .s2:
            return [
                File(
                    suffix: "mobileclip_s2_image.mlpackage/Manifest.json",
                    sha256: "TODO_sha256_s2_manifest_json"
                ),
                File(
                    suffix: "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    sha256: "TODO_sha256_s2_model_mlmodel"
                ),
                File(
                    suffix: "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    sha256: "TODO_sha256_s2_weight_bin"
                ),
            ]
        case .b:
            return [
                File(
                    suffix: "mobileclip_b_image.mlpackage/Manifest.json",
                    sha256: "TODO_sha256_b_manifest_json"
                ),
                File(
                    suffix: "mobileclip_b_image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    sha256: "TODO_sha256_b_model_mlmodel"
                ),
                File(
                    suffix: "mobileclip_b_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    sha256: "TODO_sha256_b_weight_bin"
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
