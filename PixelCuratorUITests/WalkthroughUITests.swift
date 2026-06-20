import XCTest

/// M2/M3 end-to-end walkthrough test.
///
/// Drives the live simulator through the main user flows:
///   1. Photo grid appears (ONLY hard assertion on the tab bar)
///   2. Find Similar sheet (Photos tab)
///   3. Variant Settings sheet (Photos tab)
///   4. Tap thumbnail → "Add to album" sheet (HARD assertion, Photos tab)
///   5. Undo button (Photos tab, best-effort)
///   6. Inbox CTA banner (soft check, Photos tab)
///   7. Albums tab
///   8. Sort tab + batch-select mode
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

        // Grid must render at least one thumbnail — without thumbnails the
        // app never indexes and every downstream step would be a smoke test
        // of an empty surface. Hard-assert so a render regression is loud.
        XCTAssertTrue(
            app.scrollViews.images.firstMatch.waitForExistence(timeout: 10),
            "Photo grid rendered no thumbnails — downstream walkthrough steps would be vacuous"
        )

        capture(screenshot: app.screenshot(), name: "01-grid")

        // MARK: - Step 2: Long-press first thumbnail → Find Similar (Photos tab)

        // Ensure we are on the Photos tab.
        let photosTab = app.tabBars.buttons["Photos"]
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
        }

        let firstImage = app.scrollViews.images.firstMatch
        if firstImage.waitForExistence(timeout: 5) {
            firstImage.press(forDuration: 1.2)

            // Context menu rendered by SwiftUI — look for the "Find Similar" item.
            let findSimilar = app.buttons["Find Similar"]
            if findSimilar.waitForExistence(timeout: 5) {
                findSimilar.tap()

                // Wait for the Similar Photos sheet — hard-assert because
                // this is the only place SimilaritySearch is exercised end-to
                // end via the user-tap path. A silent regression here would
                // leave find-similar feeling like a no-op without anyone
                // noticing in CI.
                let similarNav = app.navigationBars["Similar Photos"]
                XCTAssertTrue(
                    similarNav.waitForExistence(timeout: 10),
                    "Find Similar tapped but Similar Photos sheet never appeared"
                )
            } else {
                // Dump UI tree to attachment for debugging if context menu missing.
                attachUITree(app, label: "debug-no-find-similar-menu")
            }
        } else {
            attachUITree(app, label: "debug-no-thumbnails")
        }

        capture(screenshot: app.screenshot(), name: "02-find-similar")

        // Dismiss any open sheet (find-similar) before proceeding.
        dismissSheet(app)

        // MARK: - Step 3: Variant Settings sheet (Photos tab)

        // Ensure Photos tab is active after sheet dismiss.
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
        }

        // Variant settings: assert the picker opens via either the label or
        // the stable accessibility identifier. A silent regression here masks
        // entitlement / paywall problems that show up only at upgrade time.
        let variantButton = app.buttons["Quality"]
        let variantIDButton = app.buttons["toolbar-variant-settings"]
        if variantButton.waitForExistence(timeout: 5) {
            variantButton.tap()
        } else if variantIDButton.waitForExistence(timeout: 3) {
            variantIDButton.tap()
        } else {
            attachUITree(app, label: "debug-no-variant-settings-button")
            XCTFail("Neither 'Quality' label nor 'toolbar-variant-settings' identifier found")
        }
        XCTAssertTrue(
            app.navigationBars["Model Quality"].waitForExistence(timeout: 8),
            "Model Quality nav bar did not appear after tapping the variant picker"
        )

        capture(screenshot: app.screenshot(), name: "04-variant-settings")

        // Dismiss variant settings sheet.
        dismissSheet(app)

        // MARK: - Step 4: Tap thumbnail → assign suggestion sheet (HARD assertion, Photos tab)

        // Ensure Photos tab is active.
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
        }

        let thumb = app.scrollViews.images.firstMatch
        if thumb.waitForExistence(timeout: 5) && thumb.isHittable {
            thumb.tap()
            // Hard assertion: the new assign-suggestion sheet must appear.
            XCTAssertTrue(app.navigationBars["Add to album"].waitForExistence(timeout: 8),
                          "Assign suggestion sheet did not appear")
            capture(screenshot: app.screenshot(), name: "05-add-to-album")
            // Dismiss via Cancel button if present, else swipe down.
            let cancel = app.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 3) {
                cancel.tap()
            } else {
                dismissSheet(app)
            }
        }

        // MARK: - Step 5: Undo button (Photos tab, best-effort)

        // Ensure Photos tab is active.
        if photosTab.waitForExistence(timeout: 3) {
            photosTab.tap()
        }

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

        // MARK: - Step 6: Soft check — CTA banner (Photos tab, indexing may not be done yet)

        // Ensure Photos tab is active.
        if photosTab.waitForExistence(timeout: 3) {
            photosTab.tap()
        }

        // Wait up to ~15s for the inbox CTA banner to appear. Soft check only.
        let ctaBanner = app.otherElements["inbox-cta"].waitForExistence(timeout: 15)
            ? app.otherElements["inbox-cta"]
            : (app.buttons["inbox-cta"].waitForExistence(timeout: 1) ? app.buttons["inbox-cta"] : nil)
        if ctaBanner != nil {
            capture(screenshot: app.screenshot(), name: "06-inbox-cta")
        }

        // MARK: - Step 7: Albums tab

        let albumsTab = app.tabBars.buttons["Albums"]
        if albumsTab.waitForExistence(timeout: 5) {
            albumsTab.tap()

            // Soft wait for the Albums navigation bar or the list element.
            let albumsNavFound = app.navigationBars["Albums"].waitForExistence(timeout: 8)
            let albumsListFound = albumsNavFound || app.otherElements["albums-list"].waitForExistence(timeout: 1)

            if albumsNavFound || albumsListFound {
                capture(screenshot: app.screenshot(), name: "07-albums")
            }
        }

        // MARK: - Step 8: Sort tab + batch-select mode

        let sortTab = app.tabBars.buttons["Sort"]
        if sortTab.waitForExistence(timeout: 5) {
            sortTab.tap()

            // The Sort tab is one of three peer top-level destinations; if its
            // nav bar fails to render the navigation contract is broken and
            // every downstream sort/select interaction below is meaningless.
            XCTAssertTrue(
                app.navigationBars["Light Table"].waitForExistence(timeout: 8),
                "Light Table nav bar did not appear after tapping Sort tab"
            )

            capture(screenshot: app.screenshot(), name: "03-sorting-inbox")

            // Tap Select if it exists (only shown when queue is non-empty).
            let selectToggle = app.buttons["inbox-select-toggle"]
            if selectToggle.waitForExistence(timeout: 5) {
                selectToggle.tap()

                // Soft-wait for the selection grid.
                let gridFound = app.otherElements["inbox-select-grid"].waitForExistence(timeout: 5)
                    || app.scrollViews.firstMatch.waitForExistence(timeout: 3)

                if gridFound {
                    capture(screenshot: app.screenshot(), name: "08-batch-select")
                }

                // Tap Cancel to exit select mode without mutating the photo library.
                let cancelButton = app.buttons["Cancel"]
                if cancelButton.waitForExistence(timeout: 3) {
                    cancelButton.tap()
                }
            }
        }
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
    /// Only dismisses when one of the known sheet navigation bars is actually present —
    /// tab switching replaces modal dismissal for inbox and albums.
    private func dismissSheet(_ app: XCUIApplication) {
        let sheetNavs = ["Similar Photos", "Model Quality", "Add to album"]
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
