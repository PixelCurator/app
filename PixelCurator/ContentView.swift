import SwiftUI
import Photos

struct ContentView: View {
    @Environment(PhotoController.self) private var library
    @Environment(AlbumManager.self) private var albums

    var body: some View {
        Group {
            switch library.authState {
            case .unknown:
                ProgressView("Checking photo access…")
                    .task {
                        library.refreshAuthState()
                        if library.authState == .unknown {
                            await library.requestAccess()
                        } else if library.authState == .authorized || library.authState == .limited {
                            library.loadAssets()
                            albums.loadAlbums()
                        }
                    }

            case .authorized, .limited:
                RootTabView()
                    .task { albums.loadAlbums() }

            case .denied, .restricted:
                AccessDeniedView()
            }
        }
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Photo Access Needed")
                .font(.title2.bold())
            Text("PixelCurator needs access to your photo library to suggest and apply album assignments. Enable it in Settings → Privacy → Photos.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            #if os(iOS)
            // Direct deep-link to the app's privacy settings. Falls back
            // silently if the URL can't be opened (e.g. on tests).
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .frame(maxWidth: 240, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("access-denied-open-settings")
            #endif
        }
        .padding()
    }
}
