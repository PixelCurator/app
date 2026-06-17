import XCTest
import SwiftData
@testable import PixelCurator

@MainActor
final class EmbeddingStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Builds an in-memory SwiftData container holding only `PhotoEmbedding`.
    private func makeInMemoryStore() throws -> (ModelContainer, EmbeddingStore) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = EmbeddingStore(context: container.mainContext)
        return (container, store)
    }

    // MARK: - Codec

    func testFloatDataRoundTripIsBitExact() {
        let original: [Float] = [0.1, 0.2, Float.pi, -42.5, 0.0, Float.leastNormalMagnitude]
        let data = PhotoEmbedding.encode(original)
        let decoded = PhotoEmbedding.decode(data)
        XCTAssertEqual(original.count, decoded.count)
        for (a, b) in zip(original, decoded) {
            XCTAssertEqual(a.bitPattern, b.bitPattern,
                           "Bit pattern mismatch for value \(a)")
        }
    }

    // MARK: - Upsert & fetch

    func testUpsertThenFetchReturnsSameVector() throws {
        let (container, store) = try makeInMemoryStore()
        let vector: [Float] = [0.1, 0.2, 0.3]
        store.upsert(assetID: "asset1", modelID: "mobileclip_s0", vector: vector, assetModificationDate: nil)

        let fetched = try XCTUnwrap(store.embedding(assetID: "asset1", modelID: "mobileclip_s0"))
        XCTAssertEqual(fetched.floats.count, vector.count)
        for (a, b) in zip(vector, fetched.floats) {
            XCTAssertEqual(a.bitPattern, b.bitPattern)
        }
        _ = container // keep the in-memory container alive for the duration of the test
    }

    func testSecondUpsertOverwritesAndKeepsCountOne() throws {
        let (container, store) = try makeInMemoryStore()
        store.upsert(assetID: "asset1", modelID: "mobileclip_s0", vector: [1, 2, 3], assetModificationDate: nil)
        store.upsert(assetID: "asset1", modelID: "mobileclip_s0", vector: [7, 8, 9], assetModificationDate: nil)

        let all = store.allEmbeddings(modelID: "mobileclip_s0")
        XCTAssertEqual(all.count, 1, "Second upsert should overwrite, not insert a duplicate")

        let fetched = try XCTUnwrap(store.embedding(assetID: "asset1", modelID: "mobileclip_s0"))
        XCTAssertEqual(fetched.floats, [7, 8, 9])
        _ = container // keep container alive
    }

    func testSameAssetUnderTwoModelIDsCoexist() throws {
        let (container, store) = try makeInMemoryStore()
        store.upsert(assetID: "asset1", modelID: "mobileclip_s0", vector: [1, 0], assetModificationDate: nil)
        store.upsert(assetID: "asset1", modelID: "mobileclip_b",  vector: [0, 1], assetModificationDate: nil)

        let s0Rows = store.allEmbeddings(modelID: "mobileclip_s0")
        let bRows  = store.allEmbeddings(modelID: "mobileclip_b")
        XCTAssertEqual(s0Rows.count, 1)
        XCTAssertEqual(bRows.count,  1)
        _ = container
    }

    // MARK: - embeddedAssetIDs

    func testEmbeddedAssetIDsReturnsOnlyMatchingModelID() throws {
        let (container, store) = try makeInMemoryStore()
        store.upsert(assetID: "photo-A", modelID: "mobileclip_s0", vector: [1], assetModificationDate: nil)
        store.upsert(assetID: "photo-B", modelID: "mobileclip_s0", vector: [2], assetModificationDate: nil)
        store.upsert(assetID: "photo-C", modelID: "mobileclip_b",  vector: [3], assetModificationDate: nil)

        let s0IDs = store.embeddedAssetIDs(modelID: "mobileclip_s0")
        XCTAssertEqual(s0IDs, Set(["photo-A", "photo-B"]))
        XCTAssertFalse(s0IDs.contains("photo-C"))

        let bIDs = store.embeddedAssetIDs(modelID: "mobileclip_b")
        XCTAssertEqual(bIDs, Set(["photo-C"]))
        _ = container
    }
}
