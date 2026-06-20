import SwiftUI

/// App-level settings.
///
/// Presented in two shapes:
///   - macOS: as the contents of the native `Settings` scene declared in
///     `PixelCuratorApp`. Cmd-, opens it automatically.
///   - iOS: as a `.sheet` from `PhotoGridView`'s toolbar gear button (wrapped
///     in a `NavigationStack` by the caller so it gets a title bar + Done).
///
/// Persisted state is stored via `@AppStorage`, which writes through to
/// `UserDefaults.standard`. The same `@AppStorage` key is read by
/// `PhotoGridView`, which mirrors the value into `PhotoController.hideICloudPhotos`
/// so the grid's `visibleAssets` filter reacts on the next render.
struct AppSettingsView: View {
    @AppStorage("hideICloudPhotos") private var hideICloudPhotos: Bool = false

    var body: some View {
        Form {
            Section {
                // Inverted polarity reads better: the user is choosing what to
                // SHOW, not what to hide. We negate on read/write so the
                // persisted boolean ("hide") matches its semantic name.
                Toggle("Show iCloud photos", isOn: Binding(
                    get: { !hideICloudPhotos },
                    set: { hideICloudPhotos = !$0 }
                ))
                .accessibilityIdentifier("settings-show-icloud-photos")
            } footer: {
                Text("iCloud-only photos appear with the iCloud badge but cannot be analyzed for album suggestions until downloaded in Photos.app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        // Native Settings windows are sized by their content; give the form a
        // sensible minimum so the toggle + footer aren't cramped.
        .frame(minWidth: 420, minHeight: 200)
        .padding()
        #endif
        .accessibilityIdentifier("app-settings-view")
    }
}

#Preview {
    AppSettingsView()
}
