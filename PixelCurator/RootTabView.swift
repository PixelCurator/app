import SwiftUI

/// Root navigation across the app's three peer sections: Photos | Sort | Albums.
///
/// Platform-adaptive, following the Apple HIG: iPhone/iPad use a **tab bar**
/// (the idiom for switching top-level sections), while macOS uses a **sidebar**
/// (`NavigationSplitView`) — a bottom tab bar is not native to the Mac, where
/// source-list sidebars are the standard for primary navigation (cf. Photos,
/// Mail, Music). The unified `.sidebarAdaptable` tab style would do this
/// automatically, but it requires iOS 18 / macOS 15; this app targets 17 / 14.
struct RootTabView: View {
    @Environment(\.sortingCoordinator) private var sortingCoordinator

    enum Section: Hashable, CaseIterable, Identifiable {
        case photos, sort, albums
        var id: Self { self }

        /// `LocalizedStringKey` (not `String`) so SwiftUI localizes these tab /
        /// sidebar labels via the string catalog — a plain `String` variable
        /// would bypass localization.
        var title: LocalizedStringKey {
            switch self {
            case .photos: "Photos"
            case .sort: "Sort"
            case .albums: "Albums"
            }
        }

        var symbol: String {
            switch self {
            case .photos: "photo.on.rectangle"
            case .sort: "tray.full"
            case .albums: "rectangle.stack"
            }
        }
    }

    @State private var selection: Section = .photos

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle("PixelCurator")
        } detail: {
            detail(for: selection)
        }
        #else
        TabView(selection: $selection) {
            ForEach(Section.allCases) { section in
                detail(for: section)
                    .tabItem { Label(section.title, systemImage: section.symbol) }
                    .tag(section)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selection)
        #endif
        #endif
    }

    /// The content for a section. Shared by the iOS tabs and the macOS sidebar
    /// detail so both platforms render identical screens.
    @ViewBuilder
    private func detail(for section: Section) -> some View {
        switch section {
        case .photos:
            PhotoGridView(onShowInbox: { selection = .sort })
        case .sort:
            // `SortingInboxView` reads the coordinator from the environment
            // (not a stored property) so it never captures an orphan reference
            // after a variant switch. The coordinator instance itself is
            // long-lived now (`updateVariant` swaps data sources in place),
            // but the env path is the structural fix.
            if sortingCoordinator != nil {
                SortingInboxView()
            } else {
                ContentUnavailableView(
                    "Preparing…",
                    systemImage: "hourglass",
                    description: Text("The on-device model is still loading.")
                )
            }
        case .albums:
            AlbumsListView()
        }
    }
}
