import XCTest

/// UI tests for the Index Reset feature.
///
/// Tests run on the iPhone 17 Pro simulator (UDID A6D0A445-9A44-4977-BA58-5B3D75AC85C7).
/// The simulator must have at least one photo in its library — the existing
/// `WalkthroughUITests` set uses the same constraint.
///
/// Test order is NOT guaranteed. Each test launches fresh and navigates to the
/// Settings sheet independently.
final class IndexResetUITests: XCTestCase {

    // Each test must grant photo access independently because `continueAfterFailure`
    // is false by default here — a hard failure aborts the test immediately.
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 1. Delete Index button is visible in Settings

    /// Opens the Settings sheet from the Photos tab toolbar and asserts that
    /// the destructive "Delete Index" row exists with its accessibility identifier.
    @MainActor
    func test_deleteIndexButton_isVisibleInSettings() throws {
        let app = XCUIApplication()
        app.launch()

        grantPhotoAccess(app)
        navigateToSettings(app)

        let deleteButton = app.buttons["settings-delete-index"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 10),
            "Delete Index button (accessibilityIdentifier: settings-delete-index) not found in Settings"
        )
        capture(screenshot: app.screenshot(), name: "settings-delete-index-visible")
    }

    // MARK: - 2. Tapping Delete Index shows the confirmation dialog

    @MainActor
    func test_tappingDeleteIndex_showsConfirmation() throws {
        let app = XCUIApplication()
        app.launch()

        grantPhotoAccess(app)
        navigateToSettings(app)

        let deleteButton = app.buttons["settings-delete-index"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
        deleteButton.tap()

        // The confirmation dialog contains the destructive "Delete and Rebuild Index"
        // button and a "Cancel" button.
        XCTAssertTrue(
            app.buttons["Delete and Rebuild Index"].waitForExistence(timeout: 5),
            "Destructive 'Delete and Rebuild' button not found after tapping Delete Index"
        )
        XCTAssertTrue(
            app.buttons["Cancel"].waitForExistence(timeout: 3),
            "Cancel button not found in confirmation dialog"
        )
        capture(screenshot: app.screenshot(), name: "delete-confirmation-dialog")
    }

    // MARK: - 3. Confirming Delete shows the indexing lock overlay

    @MainActor
    func test_confirmingDelete_showsLockOverlay() throws {
        let app = XCUIApplication()
        app.launch()

        grantPhotoAccess(app)
        navigateToSettings(app)

        let deleteButton = app.buttons["settings-delete-index"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
        deleteButton.tap()

        let confirmButton = app.buttons["Delete and Rebuild Index"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        // The full-screen lock overlay is identified by "indexing-lock-overlay".
        // It appears as soon as EmbeddingIndexer.isIndexing flips true.
        let overlay = app.otherElements["indexing-lock-overlay"]
        XCTAssertTrue(
            overlay.waitForExistence(timeout: 15),
            "Indexing lock overlay (accessibilityIdentifier: indexing-lock-overlay) did not appear after confirming delete"
        )
        capture(screenshot: app.screenshot(), name: "indexing-lock-overlay-visible")
    }

    // MARK: - 4. Lock overlay blocks tab switching

    @MainActor
    func test_lockOverlay_blocksTabSwitching() throws {
        let app = XCUIApplication()
        app.launch()

        grantPhotoAccess(app)
        navigateToSettings(app)

        let deleteButton = app.buttons["settings-delete-index"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
        deleteButton.tap()

        let confirmButton = app.buttons["Delete and Rebuild Index"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        // Wait for the lock overlay to appear.
        let overlay = app.otherElements["indexing-lock-overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 15),
                      "Lock overlay did not appear")

        capture(screenshot: app.screenshot(), name: "lock-overlay-blocking")

        // The tab bar buttons should either not exist (fullScreenCover covers
        // them) or be non-hittable while the overlay is present.
        let albumsTab = app.tabBars.buttons["Albums"]
        if albumsTab.exists {
            XCTAssertFalse(
                albumsTab.isHittable,
                "Albums tab should not be hittable while the lock overlay is visible"
            )
        }
        // If the tab bar doesn't exist at all, that also proves it's blocked.
        // Both outcomes satisfy the requirement.
    }

    // MARK: - 5. Lock overlay disappears when indexing completes

    /// This test uses a sim with seeded photos (≤ ~20). On a fast simulator the
    /// indexer finishes in well under 30 s. Increase the timeout if you observe
    /// flakiness on slower machines.
    @MainActor
    func test_lockOverlay_dismissesWhenIndexingCompletes() throws {
        let app = XCUIApplication()
        app.launch()

        grantPhotoAccess(app)
        navigateToSettings(app)

        let deleteButton = app.buttons["settings-delete-index"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
        deleteButton.tap()

        let confirmButton = app.buttons["Delete and Rebuild Index"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        let overlay = app.otherElements["indexing-lock-overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 15),
                      "Lock overlay did not appear after confirming reset")

        capture(screenshot: app.screenshot(), name: "lock-overlay-indexing")

        // Wait for the overlay to disappear — this signals indexing completion.
        // The simulator has a small number of seeded photos so this should
        // finish in < 60 s. Adjust the timeout for your specific sim setup.
        let disappeared = overlay.waitForNonExistence(timeout: 120)
        XCTAssertTrue(
            disappeared,
            "Indexing lock overlay did not dismiss within 120 s — indexing may be stuck"
        )

        capture(screenshot: app.screenshot(), name: "lock-overlay-dismissed")

        // After dismissal the photo grid should be accessible again.
        XCTAssertTrue(
            app.navigationBars["PixelCurator"].waitForExistence(timeout: 5),
            "Photo grid did not reappear after lock overlay dismissed"
        )
    }

    // MARK: - Helpers

    /// Grants full photo access if the system permission dialog appears.
    private func grantPhotoAccess(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLabels = ["Allow Full Access", "Allow Access to All Photos", "Allow"]
        for label in allowLabels {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                break
            }
        }
        // Wait for the grid to settle before proceeding.
        _ = app.navigationBars["PixelCurator"].waitForExistence(timeout: 20)
    }

    /// Opens the Settings sheet from the Photos tab toolbar.
    ///
    /// The gear button uses `accessibilityIdentifier("toolbar-app-settings")`
    /// as defined in `PhotoGridView`. Falls back to searching by label "Settings"
    /// for resilience against minor UI restructures.
    private func navigateToSettings(_ app: XCUIApplication) {
        // Ensure we are on the Photos tab.
        let photosTab = app.tabBars.buttons["Photos"]
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
        }

        // Wait for the grid to be ready.
        _ = app.navigationBars["PixelCurator"].waitForExistence(timeout: 10)

        // Primary: find by accessibilityIdentifier set in PhotoGridView.
        let gearButton = app.buttons["toolbar-app-settings"]
        if gearButton.waitForExistence(timeout: 8) {
            gearButton.tap()
        }

        // Wait for the Settings form to appear.
        _ = app.otherElements["app-settings-view"].waitForExistence(timeout: 8)
    }

    private func capture(screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
