import XCTest
import Photos
@testable import PixelCurator

/// Performance baselines for `AlbumManager.loadAlbums()`. The previous
/// implementation iterated every album and ran a full `PHAsset.fetchAssets(in:)`
/// per album just to read the member count — O(albums × assets-per-album) on
/// the main actor. The new implementation uses `estimatedAssetCount` which is
/// served from PhotoKit's cache in O(1) per album after the first cold open.
///
/// These tests measure wall-clock time on the simulator's seeded photo library.
/// A failure here means the main thread has regressed back into a slow
/// per-album fetch path, which the user perceives as the app freezing for
/// seconds after every assign / remove / library change.
@MainActor
final class AlbumManagerPerformanceTests: XCTestCase {

    /// Single `loadAlbums()` call must complete inside one autorelease pool's
    /// worth of main-actor time. On the seeded sim this is dominated by
    /// PhotoKit's collection-enumeration cost, NOT by per-album member counts.
    /// Regression target: if we accidentally reintroduce a per-album fetch,
    /// this jumps from low-double-digit ms to hundreds of ms or seconds.
    func testLoadAlbumsFastPath() throws {
        let manager = AlbumManager()
        // Warm any PhotoKit caches so the first measure block isn't an outlier.
        manager.loadAlbums()

        measure(metrics: [XCTClockMetric()]) {
            manager.loadAlbums()
        }
    }

    /// Sequential calls (typical of the post-`performChanges` reload pattern)
    /// must not show linear growth. The library-change observer in B-2 fires
    /// debounced reloads — if each one runs a full member-count fetch, ten
    /// rapid edits stack into a noticeable freeze.
    func testLoadAlbumsRepeatedCalls() throws {
        let manager = AlbumManager()
        manager.loadAlbums()  // warm

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<10 {
                manager.loadAlbums()
            }
        }
    }
}
