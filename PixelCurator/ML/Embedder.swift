import CoreML
import Vision
import CoreGraphics

/// Loads a compiled Core ML image-encoder and runs CLIP embedding inference.
///
/// `Embedder` is an actor so its mutable model handle is protected from
/// concurrent access. Callers `await embed(_:)` naturally hop off the calling
/// actor — `@MainActor` UI code stays responsive while inference runs.
actor Embedder {

    // MARK: - Private state

    private let model: MLModel

    // MARK: - Public state

    /// Dimensionality of the embedding vectors this model produces.
    ///
    /// Read from the compiled model's output description at init time.
    /// For MobileCLIP S0 this is 512.
    ///
    /// Declared `nonisolated` because it is immutable after `init` and safe
    /// to read from any concurrency context without hopping onto the actor.
    nonisolated let embeddingDimension: Int

    // MARK: - Init

    /// Loads the compiled Core ML model at `modelURL` and reads its output dimension.
    ///
    /// - Parameter modelURL: URL of a compiled `.mlmodelc` directory.
    /// - Throws: If the model cannot be loaded or no multi-array output is found.
    init(modelURL: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loaded = try await MLModel.load(contentsOf: modelURL, configuration: config)

        // Derive embedding dimension from the model's output description.
        // The output is a multi-array of shape [1, 512] for S0 — take the last element.
        var dimension = 0
        for desc in loaded.modelDescription.outputDescriptionsByName.values
        where desc.type == .multiArray {
            if let constraint = desc.multiArrayConstraint {
                let shape = constraint.shape
                if let last = shape.last {
                    dimension = last.intValue
                }
            }
            break
        }

        self.model = loaded
        self.embeddingDimension = dimension
    }

    // MARK: - Inference

    /// Embeds `cgImage` using the loaded CLIP image encoder.
    ///
    /// The returned vector is L2-normalised via `Similarity.normalize(_:)`.
    ///
    /// - Parameter cgImage: Source image. CLIP preprocessing is baked into the
    ///   Core ML model — pass the raw CGImage without manual normalisation.
    /// - Returns: An L2-normalised `[Float]` of length `embeddingDimension`.
    /// - Throws: If the Vision request fails or produces no result.
    func embed(_ cgImage: CGImage) async throws -> [Float] {
        let visionModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: visionModel)
        // Center-crop matches CLIP's expected square input crop.
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard
            let results = request.results as? [VNCoreMLFeatureValueObservation],
            let first = results.first,
            let mlArray = first.featureValue.multiArrayValue
        else {
            throw EmbedderError.noOutputProduced
        }

        let count = mlArray.count
        var floats = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            floats[i] = mlArray[i].floatValue
        }

        return Similarity.normalize(floats)
    }
}

// MARK: - Errors

enum EmbedderError: Error, LocalizedError {
    case noOutputProduced

    var errorDescription: String? {
        switch self {
        case .noOutputProduced:
            return "The Core ML model produced no feature value observation."
        }
    }
}
