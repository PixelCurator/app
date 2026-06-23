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
    ///
    /// **Performance:** uses a bounded min-heap of size `k` to track the
    /// running top-K instead of sorting all N scores. That's `O(N log K)`
    /// instead of `O(N log N)` — on a 10 000-photo library with `k = 30`
    /// the constant-factor win is roughly 10× because most candidates are
    /// rejected with a single comparison against the heap minimum.
    static func cosineTopK(
        query: [Float],
        candidates: [(id: String, vector: [Float])],
        k: Int
    ) -> [(id: String, score: Float)] {
        guard !candidates.isEmpty, k > 0, !query.isEmpty else { return [] }

        let dim = query.count
        var heap = MinHeapTopK(capacity: k)

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
            heap.consider(id: candidate.id, score: dot)
        }

        return heap.sortedDescending()
    }
}

// MARK: - MinHeapTopK

/// A bounded min-heap that retains only the top `capacity` (id, score) pairs
/// seen via `consider(...)`, ranked by `score`. Each `consider` is `O(1)`
/// for rejection (score below current minimum) or `O(log capacity)` for
/// insertion / replacement. `sortedDescending()` returns the kept pairs
/// from highest to lowest score in `O(k log k)`.
///
/// Used by `Similarity.cosineTopK` so the running top-K is maintained in
/// fixed `O(k)` memory and the dominant work per candidate is a single
/// comparison against the heap root.
///
/// Internal because the API surface — `score` as the ordering key, `id`
/// as opaque payload — is specific to the cosine top-K use case.
private struct MinHeapTopK {

    private let capacity: Int

    /// Backing storage. Children of index `i` are at `2i+1` and `2i+2`.
    /// `storage[0]` is the minimum score among the currently held entries.
    private var storage: [(id: String, score: Float)] = []

    init(capacity: Int) {
        precondition(capacity > 0, "MinHeapTopK capacity must be positive")
        self.capacity = capacity
        self.storage.reserveCapacity(capacity)
    }

    /// Considers a candidate for inclusion in the top-K. If the heap is not
    /// full, the candidate is always inserted. Otherwise the candidate
    /// replaces the current minimum iff its score is strictly higher than
    /// the current minimum; ties are rejected. (Same effective tie-handling
    /// as the previous `Array.sort` path, which was unstable.)
    mutating func consider(id: String, score: Float) {
        if storage.count < capacity {
            storage.append((id: id, score: score))
            siftUp(from: storage.count - 1)
        } else if score > storage[0].score {
            storage[0] = (id: id, score: score)
            siftDown(from: 0)
        }
    }

    /// Returns the held entries sorted by descending score.
    func sortedDescending() -> [(id: String, score: Float)] {
        storage.sorted { $0.score > $1.score }
    }

    // MARK: - Heap mechanics

    private mutating func siftUp(from index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i].score < storage[parent].score {
                storage.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var i = index
        let n = storage.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < n, storage[left].score < storage[smallest].score {
                smallest = left
            }
            if right < n, storage[right].score < storage[smallest].score {
                smallest = right
            }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}
