import SwiftUI
import SwiftData

@main
struct PixelCuratorApp: App {
    @State private var library = PhotoController()
    @State private var albums = AlbumManager()
    @State private var indexer: EmbeddingIndexer?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(albums)
                .environment(indexer)
                .task { await bootIndexer() }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
        .modelContainer(for: PhotoEmbedding.self)
    }

    @MainActor
    private func bootIndexer() async {
        guard indexer == nil else { return }
        do {
            let modelURL = try await ModelStore.compiledModelURL(for: .bundledDefault)
            let embedder = try await Embedder(modelURL: modelURL)
            // Access the modelContainer's mainContext via the environment is
            // not available here at app-init time; we create a separate
            // container instance for the indexer so it shares the same
            // persistent store schema.
            let container = try ModelContainer(for: PhotoEmbedding.self)
            let newIndexer = EmbeddingIndexer(
                context: container.mainContext,
                embedder: embedder,
                modelStore: ModelStore()
            )
            self.indexer = newIndexer
        } catch {
            print("PixelCuratorApp: failed to boot indexer: \(error)")
        }
    }
}
