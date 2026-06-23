import XCTest

/// Additive hard-assertion coverage layered on top of `WalkthroughUITests`.
///
/// `WalkthroughUITests` is intentionally soft (`if elem.waitForExistence { … }`,
/// `continueAfterFailure = true`) so a transient sim hiccup never kills the
/// whole walkthrough. That permissiveness has a cost: silent regressions in
/// the top-level navigation contract (tab presence, primary nav bars) sneak
/// past CI because every soft check just logs and walks on.
///
/// This separate class pins the invariants that *must* hold or the app is
/// broken in a user-visible way:
///   • All three top-level tabs exist and switch
///   • Every primary destination renders its own navigation bar
///   • Every sheet exposes a discoverable dismiss affordance
///
/// Kept as its own class so a sim flake here can be quarantined via
/// `-skip-testing` without disabling the broader `WalkthroughUITests` capture
/// pass.
final class WalkthroughHardAssertionsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Hard assertions: stop at the first failure so the surfaced error
        // points at the actual regression, not a downstream cascade.
        continueAfterFailure = false
    }

    @MainActor
    func testTabBarExposesAllThreeTopLevelDestinations() throws {
        let app = XCUIApplication()
        app.launch()
        grantPhotosPermissionIfNeeded()

        XCTAssertTrue(
            app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
            "Photo grid never rendered — cannot evaluate tab-bar invariant"
        )

        let tabs = ["Photos", "Albums", "Sort"]
        for tab in tabs {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(
                button.waitForExistence(timeout: 5),
                "Tab '\(tab)' missing from tab bar — top-level navigation contract broken"
            )
        }
    }

    @MainActor
    func testEachTabRendersItsOwnNavigationBar() throws {
        let app = XCUIApplication()
        app.launch()
        grantPhotosPermissionIfNeeded()

        XCTAssertTrue(
            app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
            "Photos tab nav bar 'PixelCurator' did not appear on launch"
        )

        // Albums tab → 'Albums' nav bar
        let albumsTab = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 5), "Albums tab missing")
        albumsTab.tap()
        XCTAssertTrue(
            app.navigationBars["Albums"].waitForExistence(timeout: 10),
            "Albums nav bar did not appear after switching to Albums tab"
        )

        // Sort tab → 'Light Table' nav bar
        let sortTab = app.tabBars.buttons["Sort"]
        XCTAssertTrue(sortTab.waitForExistence(timeout: 5), "Sort tab missing")
        sortTab.tap()
        XCTAssertTrue(
            app.navigationBars["Light Table"].waitForExistence(timeout: 10),
            "Light Table nav bar did not appear after switching to Sort tab"
        )

        // Back to Photos → 'PixelCurator' nav bar again
        let photosTab = app.tabBars.buttons["Photos"]
        XCTAssertTrue(photosTab.waitForExistence(timeout: 5), "Photos tab missing")
        photosTab.tap()
        XCTAssertTrue(
            app.navigationBars["PixelCurator"].waitForExistence(timeout: 10),
            "PixelCurator nav bar did not reappear after switching back to Photos tab"
        )
    }

    @MainActor
    func testAddToAlbumSheetExposesADismissAffordance() throws {
        let app = XCUIApplication()
        app.launch()
        grantPhotosPermissionIfNeeded()

        XCTAssertTrue(
            app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
            "Photo grid never rendered"
        )

        let thumb = app.scrollViews.images.firstMatch
        XCTAssertTrue(
            thumb.waitForExistence(timeout: 10),
            "No thumbnail rendered — cannot drive the assign-suggestion sheet"
        )
        XCTAssertTrue(thumb.isHittable, "First thumbnail is not hittable")
        thumb.tap()

        XCTAssertTrue(
            app.navigationBars["Add to album"].waitForExistence(timeout: 10),
            "Tapping a thumbnail did not present the 'Add to album' sheet"
        )

        // The sheet MUST surface a Cancel button — without it the user has no
        // a11y-discoverable way to back out (swipe-down is gestural and is not
        // surfaced to VoiceOver as a labelled action).
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(
            cancel.waitForExistence(timeout: 5),
            "'Add to album' sheet exposes no Cancel button — a11y back-out broken"
        )
        cancel.tap()

        XCTAssertTrue(
            app.navigationBars["PixelCurator"].waitForExistence(timeout: 5),
            "Sheet did not dismiss after tapping Cancel"
        )
    }

    // MARK: - Helpers

    /// Tap whichever Photos-permission button the Springboard alert presents.
    /// Best-effort — when the sim already has the permission cached this is a
    /// no-op. The downstream nav-bar assertions catch the case where the
    /// permission was never granted (grid never appears).
    private func grantPhotosPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLabels = ["Allow Full Access", "Allow Access to All Photos", "Allow"]
        for label in allowLabels {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                return
            }
        }
    }
}
