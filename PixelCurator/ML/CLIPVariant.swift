/// Identifies which MobileCLIP model variant is in use.
///
/// Each variant defines an independent embedding space. Vectors produced by
/// different `modelID`s are **not** comparable and must never be mixed in
/// similarity search.
enum CLIPVariant: String, CaseIterable, Sendable, Identifiable {
    case s0, s1, s2, b

    // MARK: - Identity

    /// Stable string that tags every stored embedding.
    /// Slice B uses this as the `modelID` column in `PhotoEmbedding`.
    var id: String { rawValue }

    var modelID: String {
        switch self {
        case .s0: return "mobileclip_s0"
        case .s1: return "mobileclip_s1"
        case .s2: return "mobileclip_s2"
        case .b:  return "mobileclip_b"
        }
    }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .s0: return "MobileCLIP S0 (Fast)"
        case .s1: return "MobileCLIP S1"
        case .s2: return "MobileCLIP S2"
        case .b:  return "MobileCLIP B (Best)"
        }
    }

    // MARK: - Core ML package

    /// File name of the Core ML image-encoder package bundled in the app
    /// or downloaded on demand. Consumed by Slice B's inference pipeline.
    var imageEncoderPackageName: String {
        switch self {
        case .s0: return "mobileclip_s0_image.mlpackage"
        case .s1: return "mobileclip_s1_image.mlpackage"
        case .s2: return "mobileclip_s2_image.mlpackage"
        case .b:  return "mobileclip_blt_image.mlpackage"
        }
    }

    // MARK: - Tier

    enum Tier {
        case free, pro
    }

    /// `.s0` ships bundled in the free tier; all other variants require Pro.
    var tier: Tier {
        switch self {
        case .s0: return .free
        case .s1, .s2, .b: return .pro
        }
    }

    // MARK: - Dimension hint

    /// Expected embedding vector length.
    ///
    /// This is a UI/preallocation hint only. The authoritative dimension is
    /// read from the compiled Core ML model at runtime in Slice B; treat
    /// this value as advisory, not contractual.
    var expectedEmbeddingDimension: Int { 512 }

    // MARK: - Defaults

    /// The variant shipped inside the app bundle for free-tier users.
    static var bundledDefault: CLIPVariant { .s0 }
}
