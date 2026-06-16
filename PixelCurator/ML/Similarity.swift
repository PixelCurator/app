import Accelerate

/// Namespace for on-device vector similarity utilities.
///
/// All functions assume **L2-normalised** input vectors unless otherwise noted.
/// Normalise with `Similarity.normalize(_:)` before calling `cosineTopK`.
enum Similarity {

    // MARK: - Normalisation

    /// Returns the L2-normalised form of `v`.
    ///
    /// If `v` is a zero vector (norm ≈ 0), the original vector is returned
    /// unchanged to avoid NaN propagation.
    static func normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrtf(norm)
        guard norm > 1e-8 else { return v }
        var result = [Float](repeating: 0, count: v.count)
        var scalar = 1.0 / norm
        vDSP_vsmul(v, 1, &scalar, &result, 1, vDSP_Length(v.count))
        return result
    }

    // MARK: - Top-K cosine search

    /// Returns the `k` closest candidates to `query` by cosine similarity.
    ///
    /// **Precondition:** both `query` and every `vector` in `candidates` must
    /// already be L2-normalised. Under this condition cosine similarity equals
    /// the dot product, computed here via `vDSP_dotpr` for speed.
    ///
    /// Results are sorted by descending score. Fewer than `k` results are
    /// returned when `candidates.count < k`. The caller is responsible for
    /// filtering the query's own id from candidates if required.
    static func cosineTopK(
        query: [Float],
        candidates: [(id: String, vector: [Float])],
        k: Int
    ) -> [(id: String, score: Float)] {
        guard !candidates.isEmpty, k > 0, !query.isEmpty else { return [] }

        let dim = query.count
        var scores = [(id: String, score: Float)]()
        scores.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard candidate.vector.count == dim else { continue }
            var dot: Float = 0
            candidate.vector.withUnsafeBufferPointer { candidateBuf in
                query.withUnsafeBufferPointer { queryBuf in
                    vDSP_dotpr(
                        queryBuf.baseAddress!, 1,
                        candidateBuf.baseAddress!, 1,
                        &dot,
                        vDSP_Length(dim)
                    )
                }
            }
            scores.append((id: candidate.id, score: dot))
        }

        scores.sort { $0.score > $1.score }
        return Array(scores.prefix(k))
    }
}
