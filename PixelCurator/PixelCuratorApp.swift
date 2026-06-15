import SwiftUI

@main
struct PixelCuratorApp: App {
    @State private var library = PhotoController()
    @State private var albums = AlbumManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(albums)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
