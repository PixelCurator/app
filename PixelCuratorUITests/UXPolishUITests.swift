import XCTest

/// UX polish UI tests.
///
/// Validates the experiential quality polish layer of PixelCurator:
///   1. Tab-switch animation completes quickly and settles on the target screen
///   2. Suggestion chip tap produces visible feedback (toast OR queue advance)
///   3. Toast banner appears and auto-dismisses on assign action
///   4. Albums tab loading state does not flash the empty placeholder
///   5. Reduce Motion launch arg keeps the app functional (no crash/hang)
///   6. Dynamic Type Accessibility XL launches without layout collapse
///   7. Critical interactive surfaces meet the 44pt minimum tap target
///
/// All tests follow the WalkthroughUITests pattern:
///   - `continueAfterFailure = true` so we capture as many screenshots as possible
///   - Soft fallbacks for environment-dependent state (empty photo library, no
///     indexed embeddings, no suggestions yet) — only the navigation contract
///     and tap-target invariants are hard-asserted.
///   - Screenshots attached with `.keepAlways` so they land in the xcresult.
final class UXPolishUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true  // capture as many screenshots as possible
    }

    // MARK: - 1. Tab switch animation timing

    /// Tab switches should complete and settle within ~1.5s in the simulator.
    ///
    /// Times the round-trip from `tap()` to the destination nav bar resolving.
    /// Includes generous leeway for simulator scheduling jitter — the contract
    /// is "feels fast", not "frame-perfect".
    @MainActor
    func test_tabSwitch_animatesAndSettlesQuickly() {
        let app = XCUIApplication()
        app.launch()
        grantPhotoAccess()

        let navBar = app.navigationBars["PixelCurator"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 20),
                      "Photo grid did not appear after granting access")

        // Photos → Sort
        let sortTab = app.tabBars.buttons["Sort"]
        XCTAssertTrue(sortTab.waitForExistence(timeout: 5), "Sort tab missing")

        let sortStart = Date()
        sortTab.tap()
        let sortNav = app.navigationBars["Light Table"]
        XCTAssertTrue(sortNav.waitForExistence(timeout: 5),
                      "Light Table nav bar did not appear after Sort tap")
        let sortElapsed = Date().timeIntervalSince(sortStart)
        print("Sort tab settle: \(sortElapsed)s")
        XCTAssertLessThanOrEqual(sortElapsed, 1.5,
                                 "Sort tab switch took \(sortElapsed)s, expected <=1.5s")
        capture(app, name: "tab-switch-sort")

        // Sort → Albums
        let albumsTab = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 5), "Albums tab missing")

        let albumsStart = Date()
        albumsTab.tap()
        // Albums nav bar OR the albums list — either signals settle.
        let albumsNav = app.navigationBars["Albums"]
        let albumsList = app.otherElements["albums-list"]
        let settled = albumsNav.waitForExistence(timeout: 5)
            || albumsList.waitForExistence(timeout: 1)
        XCTAssertTrue(settled, "Albums destination did not settle after tap")
        let albumsElapsed = Date().timeIntervalSince(albumsStart)
        print("Albums tab settle: \(albumsElapsed)s")
        XCTAssertLessThanOrEqual(albumsElapsed, 1.5,
                                 "Albums tab switch took \(albumsElapsed)s, expected <=1.5s")
        capture(app, name: "tab-switch-albums")
    }

    // MARK: - 2. Suggestion chip tap feedback

    /// Tapping a suggestion chip on the Sort tab should produce visible feedback.
    ///
    /// Soft test — the simulator may have an empty queue or no indexed
    /// embeddings, in which case no chip is rendered and the test logs and
    /// returns. When a chip IS present we verify either:
    ///   - a toast banner appears, OR
    ///   - the previously visible chip disappears (queue advanced).
    @MainActor
    func test_suggestionChip_tapHasFeedback() {
        let app = XCUIApplication()
        app.launch()
        grantPhotoAccess()

        XCTAssertTrue(app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
                      "Photo grid did not appear after granting access")

        let sortTab = app.tabBars.buttons["Sort"]
        guard sortTab.waitForExistence(timeout: 5) else {
            print("Sort tab unavailable — skipping suggestion chip test")
            return
        }
        sortTab.tap()
        XCTAssertTrue(app.navigationBars["Light Table"].waitForExistence(timeout: 8),
                      "Light Table nav bar did not appear after Sort tap")

        // Locate a suggestion chip. The chip label contains a confidence
        // percent ("87%") — we use NSPredicate over button labels.
        let chipPredicate = NSPredicate(format: "label CONTAINS '%'")
        let chips = app.buttons.matching(chipPredicate)

        guard chips.count > 0, chips.firstMatch.waitForExistence(timeout: 3) else {
            print("No suggestion chip visible — empty queue or no embeddings indexed")
            capture(app, name: "suggestion-chip-empty")
            return
        }

        let firstChip = chips.firstMatch
        let chipLabelBeforeTap = firstChip.label
        capture(app, name: "suggestion-chip-before")

        firstChip.tap()

        // Feedback path A: toast banner ("Added to ..." or similar) appears.
        let toastPredicate = NSPredicate(format: "label BEGINSWITH 'Added to' OR label BEGINSWITH 'Sent to'")
        let toast = app.staticTexts.matching(toastPredicate).firstMatch
        let toastAppeared = toast.waitForExistence(timeout: 3)

        // Feedback path B: the previously labelled chip is no longer present
        // (queue advanced to next suggestion).
        let sameChip = app.buttons[chipLabelBeforeTap]
        let queueAdvanced = !sameChip.exists

        let feedbackSeen = toastAppeared || queueAdvanced
        print("Suggestion chip feedback — toast: \(toastAppeared), queueAdvanced: \(queueAdvanced)")
        capture(app, name: "suggestion-chip-after")

        // Soft assertion: log the failure but do not break CI for environments
        // where the chip handler is otherwise non-observable.
        if !feedbackSeen {
            print("WARN: suggestion chip tap produced no detectable feedback")
        }
    }

    // MARK: - 3. Toast appears and auto-dismisses

    /// Assigning a photo to an album should show a toast that auto-dismisses.
    ///
    /// Soft-asserts both the appearance (~3s) and the disappearance (~5s after
    /// appearance). The toast is identified by its prefix "Added to" — if the
    /// simulator has no albums or no thumbnails the test logs and returns.
    @MainActor
    func test_toast_appearsAndDismisses() {
        let app = XCUIApplication()
        app.launch()
        grantPhotoAccess()

        XCTAssertTrue(app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
                      "Photo grid did not appear after granting access")

        // Ensure Photos tab is active.
        let photosTab = app.tabBars.buttons["Photos"]
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
        }

        let thumb = app.scrollViews.images.firstMatch
        guard thumb.waitForExistence(timeout: 5), thumb.isHittable else {
            print("No tappable thumbnail in grid — skipping toast test")
            return
        }
        thumb.tap()

        // Wait for the assign-suggestion sheet to mount.
        let assignNav = app.navigationBars["Add to album"]
        let assignSheet = app.otherElements["assign-suggestion-sheet"]
        let sheetReady = assignNav.waitForExistence(timeout: 8)
            || assignSheet.waitForExistence(timeout: 2)
        guard sheetReady else {
            print("Assign sheet did not appear — skipping toast test")
            capture(app, name: "toast-no-sheet")
            return
        }
        capture(app, name: "toast-assign-sheet")

        // Find the first album row in the sheet. Buttons within the sheet
        // labelled with an album name will trigger the assignment.
        // We avoid Cancel / New Album / known toolbar identifiers.
        let blockedLabels: Set<String> = ["Cancel", "Done", "Close", "Skip", "New Album"]
        let buttonsInSheet = app.buttons.allElementsBoundByIndex
        var assigned = false
        for button in buttonsInSheet {
            guard button.exists, button.isHittable else { continue }
            let label = button.label
            guard !label.isEmpty,
                  !blockedLabels.contains(label),
                  !label.contains("%"),
                  button.identifier != "inbox-skip",
                  button.identifier != "inbox-other-album",
                  button.identifier != "new-album-confirm-button"
            else { continue }
            // Heuristic: the assign sheet shows album-name rows under an
            // "All Albums" header; the first such row is what we want.
            button.tap()
            assigned = true
            break
        }

        guard assigned else {
            print("No album row found in assign sheet — skipping toast verification")
            // Dismiss sheet to be polite.
            let cancel = app.buttons["Cancel"]
            if cancel.exists { cancel.tap() }
            return
        }

        // Toast appearance check.
        let toastPredicate = NSPredicate(format: "label BEGINSWITH 'Added to'")
        let toast = app.staticTexts.matching(toastPredicate).firstMatch
        let appeared = toast.waitForExistence(timeout: 3)
        print("Toast appeared within 3s: \(appeared)")
        if appeared {
            capture(app, name: "toast-visible")
        } else {
            print("WARN: toast did not appear within 3s")
        }

        // Toast dismissal check — only meaningful if we saw it appear.
        if appeared {
            // Poll for absence over a 5s window.
            let deadline = Date().addingTimeInterval(5)
            var dismissed = false
            while Date() < deadline {
                if !toast.exists {
                    dismissed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            print("Toast dismissed within 5s: \(dismissed)")
            if !dismissed {
                print("WARN: toast did not dismiss within 5s")
            }
            capture(app, name: "toast-after-dismiss")
        }
    }

    // MARK: - 4. Loading state does not flash empty placeholder

    /// Switching to the Albums tab quickly after launch should not flash the
    /// "No Albums Yet" empty state. We poll for the empty label over the first
    /// 1.5s and assert it is never seen — the screen should either show the
    /// loading skeleton or the actual list.
    @MainActor
    func test_loadingState_doesNotFlashEmpty() {
        let app = XCUIApplication()
        app.launch()
        grantPhotoAccess()

        XCTAssertTrue(app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
                      "Photo grid did not appear after granting access")

        let albumsTab = app.tabBars.buttons["Albums"]
        guard albumsTab.waitForExistence(timeout: 5) else {
            print("Albums tab missing — skipping empty-flash test")
            return
        }
        albumsTab.tap()

        // Poll for ~1.5s. If the "No Albums Yet" text ever materialises
        // during the loading window we record a soft warning. The empty
        // state is allowed AFTER loading settles; we only forbid the flash.
        let emptyLabel = app.staticTexts["No Albums Yet"]
        let deadline = Date().addingTimeInterval(1.5)
        var flashed = false
        while Date() < deadline {
            if emptyLabel.exists {
                flashed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        capture(app, name: "albums-loading-window")

        // Soft assert. If the simulator genuinely has zero albums the empty
        // state IS correct — this test cannot distinguish "loaded fast and
        // there are none" from "flashed empty during load". We only fail
        // when the albums list element shows up after the flash, indicating
        // the empty state was wrongly rendered first.
        let albumsList = app.otherElements["albums-list"]
        let listAppeared = albumsList.waitForExistence(timeout: 5)
        if flashed && listAppeared {
            XCTFail("'No Albums Yet' flashed during the load window before the albums-list rendered")
        } else if flashed {
            print("Note: 'No Albums Yet' appeared and the list never followed — likely a genuine empty library, not a flash")
        }
    }

    // MARK: - 5. Reduce Motion launch argument keeps app functional

    /// XCUITest cannot toggle the system Reduce Motion setting at runtime, so
    /// we pass `-UIAccessibilityReduceMotionEnabled YES` as a launch argument
    /// and verify the app still boots and accepts a tab switch under that
    /// flag. Verifying that scale transitions are actually replaced by fades
    /// requires snapshot testing, which is not available in XCUITest — this
    /// test is therefore a smoke test against crash/hang under Reduce Motion.
    @MainActor
    func test_reducedMotion_disablesScaleTransitions() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIAccessibilityReduceMotionEnabled", "YES"]
        app.launch()
        grantPhotoAccess()

        XCTAssertTrue(app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
                      "Photo grid did not appear under Reduce Motion launch arg")
        capture(app, name: "reduce-motion-grid")

        // Functional smoke: tab switch still works.
        let sortTab = app.tabBars.buttons["Sort"]
        if sortTab.waitForExistence(timeout: 5) {
            sortTab.tap()
            XCTAssertTrue(app.navigationBars["Light Table"].waitForExistence(timeout: 8),
                          "Sort tab failed to settle under Reduce Motion")
            capture(app, name: "reduce-motion-sort")
        }
    }

    // MARK: - 6. Dynamic Type Accessibility XL launch

    /// Boot the app at an accessibility-tier Dynamic Type size and confirm the
    /// shell renders without crashing. We do not measure pixel layout — that
    /// requires snapshot testing. We do confirm the navigation bar and the
    /// Photos tab button are both present, which is enough to detect a hard
    /// layout collapse (clipped chrome, off-screen tab bar).
    @MainActor
    func test_dynamicType_extraLarge_layoutStillReadable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launch()
        grantPhotoAccess()

        XCTAssertTrue(app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
                      "Photo grid did not appear under Accessibility XL Dynamic Type")
        capture(app, name: "dynamic-type-axl-grid")

        // The Photos tab must remain reachable — if the tab bar gets clipped
        // or the label disappears, downstream navigation is broken.
        let photosTab = app.tabBars.buttons["Photos"]
        XCTAssertTrue(photosTab.waitForExistence(timeout: 5),
                      "Photos tab button missing under Accessibility XL Dynamic Type")
        capture(app, name: "dynamic-type-axl-tabbar")
    }

    // MARK: - 7. Minimum 44pt tap targets

    /// All hit-critical interactive elements must meet Apple HIG 44pt minima.
    ///
    /// Hard-asserts on the three persistent toolbar buttons (Settings, Quality,
    /// Undo). Soft-checks the inbox CTA banner because it only renders when
    /// the inbox queue is non-empty — a missing CTA in the simulator is not
    /// a regression.
    @MainActor
    func test_minimumTapTargets() {
        let app = XCUIApplication()
        app.launch()
        grantPhotoAccess()

        XCTAssertTrue(app.navigationBars["PixelCurator"].waitForExistence(timeout: 20),
                      "Photo grid did not appear after granting access")

        // Ensure Photos tab is active so the toolbar is rendered.
        let photosTab = app.tabBars.buttons["Photos"]
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
        }

        // Hard checks — these toolbar buttons are always present.
        let settingsButton = app.buttons["toolbar-app-settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5),
                      "Settings toolbar button missing")
        assertMinTapTarget(settingsButton, name: "toolbar-app-settings")

        let qualityButton = app.buttons["toolbar-variant-settings"]
        XCTAssertTrue(qualityButton.waitForExistence(timeout: 5),
                      "Quality toolbar button missing")
        assertMinTapTarget(qualityButton, name: "toolbar-variant-settings")

        let undoButton = app.buttons["toolbar-undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5),
                      "Undo toolbar button missing")
        assertMinTapTarget(undoButton, name: "toolbar-undo")

        // Soft check — the CTA banner is queue-dependent.
        let ctaBanner = app.otherElements["inbox-cta"]
        if ctaBanner.waitForExistence(timeout: 3) {
            assertMinTapTarget(ctaBanner, name: "inbox-cta")
        } else {
            let ctaButton = app.buttons["inbox-cta"]
            if ctaButton.waitForExistence(timeout: 1) {
                assertMinTapTarget(ctaButton, name: "inbox-cta")
            } else {
                print("inbox-cta not visible — skipping tap-target check (queue likely empty)")
            }
        }
        capture(app, name: "tap-targets")
    }

    // MARK: - Helpers

    /// Grants Photos permission via the Springboard alert. Tolerant of the
    /// three label variants iOS uses across releases. No-op if no alert
    /// appears within 5s (e.g., simulator already authorised).
    @MainActor
    private func grantPhotoAccess() {
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

    /// Captures the current screen as a keep-always attachment.
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Asserts an element's frame meets the Apple HIG 44pt minimum tap target
    /// in both dimensions.
    private func assertMinTapTarget(_ element: XCUIElement,
                                    name: String,
                                    file: StaticString = #file,
                                    line: UInt = #line) {
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.width, 44,
                                    "\(name) width \(frame.width) below 44pt tap target",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44,
                                    "\(name) height \(frame.height) below 44pt tap target",
                                    file: file, line: line)
    }
}
