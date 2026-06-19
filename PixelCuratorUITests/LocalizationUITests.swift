import XCTest

/// Proves the localization pipeline end-to-end: launching the app forced to
/// German must render German UI strings. The simulator's system language stays
/// English, so the photo-permission system dialog still uses English buttons —
/// only the app itself is forced to German via `-AppleLanguages`.
final class LocalizationUITests: XCTestCase {

    func testGermanTabLabelsAreLocalized() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()

        // Grant photo access — system dialog buttons follow the simulator's
        // language (English), not the app's forced German.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLabels = ["Allow Full Access", "Allow Access to All Photos", "Allow"]
        for label in allowLabels {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                break
            }
        }

        // The Photos tab must read "Fotos" — proving the German catalog applied.
        let fotosTab = app.tabBars.buttons["Fotos"]
        XCTAssertTrue(
            fotosTab.waitForExistence(timeout: 20),
            "German tab label 'Fotos' did not appear — localization not applied"
        )

        // Hard-assert all three German tab labels exist.
        XCTAssertTrue(
            app.tabBars.buttons["Alben"].exists,
            "German tab label 'Alben' did not appear"
        )
        XCTAssertTrue(
            app.tabBars.buttons["Sortieren"].exists,
            "German tab label 'Sortieren' did not appear"
        )

        // Tap Albums tab and soft-assert a German albums string is visible.
        app.tabBars.buttons["Alben"].tap()
        let albumsNavBar = app.navigationBars["Alben"]
        let noAlbumsText = app.staticTexts["Keine Alben"]
        let albumsStringVisible = albumsNavBar.waitForExistence(timeout: 5) || noAlbumsText.waitForExistence(timeout: 5)
        if !albumsStringVisible {
            XCTFail("No German albums string ('Alben' nav bar or 'Keine Alben') appeared after tapping Alben tab")
        }

        // Tap Sort tab and soft-assert a German inbox string is visible.
        app.tabBars.buttons["Sortieren"].tap()
        let inboxNavBar = app.navigationBars["Leuchttisch"]
        let inboxStringVisible = inboxNavBar.waitForExistence(timeout: 5)
        if !inboxStringVisible {
            XCTFail("No German light-table string ('Leuchttisch' nav bar) appeared after tapping Sortieren tab")
        }
    }
}
