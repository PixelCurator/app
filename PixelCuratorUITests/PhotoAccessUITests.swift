import XCTest

/// M1 acceptance test: proves the critical chain end-to-end on a real simulator —
/// launch → grant photo access (system dialog) → photo grid renders.
///
/// The Photos `.readWrite` permission dialog is owned by Springboard, not the app,
/// and cannot be suppressed via `simctl privacy grant` on iOS 26. We dismiss it
/// programmatically here so the run is fully automated and CI-friendly.
final class PhotoAccessUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGrantAccessAndSeeGrid() throws {
        let app = XCUIApplication()
        app.launch()

        // The permission alert is presented by Springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButtons = ["Allow Full Access", "Allow Access to All Photos", "Allow"]
        var granted = false
        for label in allowButtons {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                granted = true
                break
            }
        }
        XCTAssertTrue(granted, "Photo-access permission dialog did not appear or could not be granted")

        // After granting, the grid screen shows the "PixelCurator" navigation title.
        let navBar = app.navigationBars["PixelCurator"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 10),
                      "Photo grid did not appear after granting access")

        // And at least one thumbnail image should be present (simulator ships sample photos).
        let firstImage = app.images.firstMatch
        XCTAssertTrue(firstImage.waitForExistence(timeout: 10),
                      "No thumbnails rendered in the grid")

        // Capture evidence for the run.
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "M1-grid-after-grant"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
