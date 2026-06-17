import XCTest

/// M2/M3 end-to-end walkthrough test.
///
/// Drives the live simulator through the main user flows:
///   1. Photo grid appears (ONLY hard assertion)
///   2. Find Similar sheet
///   3. Sorting Inbox sheet
///   4. Variant Settings sheet
///   5. Undo button (best-effort)
///
/// Screenshots are captured as XCTAttachment (keepAlways) at each step so they
/// end up in the xcresult bundle regardless of pass/fail.
///
/// All interactions beyond step 1 are wrapped in `waitForExistence` guards —
/// a missing element logs a note and moves on rather than failing the test.
final class WalkthroughUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true  // capture as many screenshots as possible
    }

    @MainActor
    func testM2M3Walkthrough() throws {
        let app = XCUIApplication()
        app.launch()

        // MARK: - Step 1: Grant Photos permission and wait for grid

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLabels = ["Allow Full Access", "Allow Access to All Photos", "Allow"]
        for label in allowLabels {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                break
            }
        }

        // Wait for the navigation bar — this is the only hard assertion.
        let navBar = app.navigationBars["PixelCurator"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 20),
                      "Photo grid did not appear after granting access")

        // Give thumbnails a moment to render.
        _ = app.images.firstMatch.waitForExistence(timeout: 10)

        capture(screenshot: app.screenshot(), name: "01-grid")

        // MARK: - Step 2: Long-press first thumbnail → Find Similar

        let firstImage = app.images.firstMatch
        if firstImage.waitForExistence(timeout: 5) {
            firstImage.press(forDuration: 1.2)

            // Context menu rendered by SwiftUI — look for the "Find Similar" item.
            let findSimilar = app.buttons["Find Similar"]
            if findSimilar.waitForExistence(timeout: 5) {
                findSimilar.tap()

                // Wait for the Similar Photos sheet.
                let similarNav = app.navigationBars["Similar Photos"]
                _ = similarNav.waitForExistence(timeout: 10)
            } else {
                // Dump UI tree to attachment for debugging if context menu missing.
                attachUITree(app, label: "debug-no-find-similar-menu")
            }
        } else {
            attachUITree(app, label: "debug-no-thumbnails")
        }

        capture(screenshot: app.screenshot(), name: "02-find-similar")

        // MARK: - Step 3: Dismiss sheet, open Sorting Inbox

        // Dismiss any open sheet by swiping down.
        dismissSheet(app)

        // Tap the Sorting Inbox toolbar button.
        let sortingInboxButton = app.buttons["Sort Inbox"]
        if sortingInboxButton.waitForExistence(timeout: 5) {
            sortingInboxButton.tap()
            let inboxNav = app.navigationBars["Sorting Inbox"]
            _ = inboxNav.waitForExistence(timeout: 8)
        } else {
            // Fallback: try by accessibility identifier.
            let byID = app.buttons["toolbar-sorting-inbox"]
            if byID.waitForExistence(timeout: 3) {
                byID.tap()
                _ = app.navigationBars["Sorting Inbox"].waitForExistence(timeout: 8)
            } else {
                attachUITree(app, label: "debug-no-sorting-inbox-button")
            }
        }

        capture(screenshot: app.screenshot(), name: "03-sorting-inbox")

        // MARK: - Step 4: Dismiss sheet, open Variant Settings

        dismissSheet(app)

        let variantButton = app.buttons["Quality"]
        if variantButton.waitForExistence(timeout: 5) {
            variantButton.tap()
            let variantNav = app.navigationBars["Model Quality"]
            _ = variantNav.waitForExistence(timeout: 8)
        } else {
            let byID = app.buttons["toolbar-variant-settings"]
            if byID.waitForExistence(timeout: 3) {
                byID.tap()
                _ = app.navigationBars["Model Quality"].waitForExistence(timeout: 8)
            } else {
                attachUITree(app, label: "debug-no-variant-settings-button")
            }
        }

        capture(screenshot: app.screenshot(), name: "04-variant-settings")

        // MARK: - Step 5: Dismiss, tap thumbnail, navigate back, tap Undo

        dismissSheet(app)

        // Open a thumbnail detail by tapping it (shows confirmationDialog).
        let thumb = app.images.firstMatch
        if thumb.waitForExistence(timeout: 5) && thumb.isHittable {
            thumb.tap()
            // Dismiss the confirmation dialog if it appeared.
            let cancel = app.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 3) {
                cancel.tap()
            }
        }

        // Tap the Undo toolbar button (may be disabled — tap anyway for coverage).
        let undoButton = app.buttons["Undo"]
        if undoButton.waitForExistence(timeout: 5) {
            if undoButton.isEnabled {
                undoButton.tap()
            }
        } else {
            let byID = app.buttons["toolbar-undo"]
            if byID.waitForExistence(timeout: 3) && byID.isEnabled {
                byID.tap()
            }
        }

        capture(screenshot: app.screenshot(), name: "05-undo")
    }

    // MARK: - Helpers

    private func capture(screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Swipe down to dismiss a modal sheet, then wait for the main grid to be visible.
    ///
    /// On iOS the main "PixelCurator" navigation bar can still report `exists`
    /// while a sheet is presented on top of it, so we cannot key the swipe off
    /// the main bar's absence. Instead we swipe whenever one of the known sheet
    /// navigation bars is present, which reliably clears the sheet before the
    /// next step interacts with the grid underneath.
    private func dismissSheet(_ app: XCUIApplication) {
        let sheetNavs = ["Similar Photos", "Sorting Inbox", "Model Quality"]
        if sheetNavs.contains(where: { app.navigationBars[$0].exists }) {
            app.swipeDown(velocity: .fast)
        }
        _ = app.navigationBars["PixelCurator"].waitForExistence(timeout: 5)
    }

    /// Captures the XCUIApplication element tree as a plain-text attachment.
    private func attachUITree(_ app: XCUIApplication, label: String) {
        guard let data = app.debugDescription.data(using: .utf8) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
