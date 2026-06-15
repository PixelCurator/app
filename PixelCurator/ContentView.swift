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
                PhotoGridView()
                    .task { albums.loadAlbums() }

            case .denied, .restricted:
                AccessDeniedView()
            }
        }
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Photo Access Needed")
                .font(.title2.bold())
            Text("PixelCurator needs access to your photo library to suggest and apply album assignments. Enable it in Settings → Privacy → Photos.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
    }
}
