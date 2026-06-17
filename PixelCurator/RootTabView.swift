import SwiftUI

/// Root three-tab navigation: Photos | Sort | Albums. The sorting inbox and the
/// album browser are now top-level tabs rather than modal sheets.
struct RootTabView: View {
    @Environment(\.sortingCoordinator) private var sortingCoordinator
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            PhotoGridView(onShowInbox: { selection = 1 })
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                .tag(0)

            Group {
                if let coordinator = sortingCoordinator {
                    SortingInboxView(coordinator: coordinator)
                } else {
                    ContentUnavailableView(
                        "Preparing…",
                        systemImage: "hourglass",
                        description: Text("The on-device model is still loading.")
                    )
                }
            }
            .tabItem { Label("Sort", systemImage: "tray.full") }
            .tag(1)

            AlbumsListView()
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                .tag(2)
        }
    }
}
