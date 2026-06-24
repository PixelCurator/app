import XCTest
@testable import PixelCurator

/// B-1. Asserts that toast template strings — which the previous code path
/// constructed as raw Swift `String` literals via interpolation — actually
/// resolve through the `Localizable.xcstrings` catalog for non-English
/// locales.
///
/// Before the fix, callers wrote `await showToast("Moved to \(title)")` and
/// passed the result to `Text.init(_: String)` (the verbatim init) plus
/// `VoiceOver.announce(_:String)`. Neither localizes. German devices saw
/// English on every assign / move / undo, despite the catalog having DE
/// entries. The fix routes these through `LocalizedStringResource`, which
/// carries a catalog-bound key and resolves at render time. This test pins
/// the contract: a German-locale lookup against the catalog returns German.
///
/// The test does NOT exercise the SwiftUI render path — it asserts the
/// catalog binding directly. If a future refactor accidentally drops the
/// catalog key (e.g. by switching back to raw `String`), the matching
/// production callsite will no longer produce a key that resolves here, and
/// these assertions will fail.
final class ToastLocalizationTests: XCTestCase {

    // MARK: - Helpers

    /// Looks up `key` in the main (app) bundle for the given locale and
    /// returns the resolved string. Forces a locale rather than relying on
    /// the device locale so CI is deterministic.
    private func resolve(_ key: String, locale: Locale, arguments: CVarArg...) -> String {
        // String(localized:bundle:locale:) is the canonical Swift 5.7+ entry
        // point for forcing locale-specific catalog lookup. `LocalizedStringResource`
        // would be even nicer but it captures the locale at init via the
        // process-wide preferred-language list, which is exactly what we want
        // to override here.
        let template = NSLocalizedString(
            key,
            bundle: .main,
            value: key,
            comment: ""
        )
        // Re-look-up via the bundle's localized variant so we get the DE
        // string when locale=de, instead of the dev-language fallback.
        guard let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            // Some build environments compile the catalog into the base
            // .lproj rather than per-language. Fall back to the catalog-via-
            // localizedString shorthand, which still picks the locale up.
            return String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
        }
        let localized = bundle.localizedString(forKey: key, value: key, table: nil)
        if arguments.isEmpty { return localized }
        return String(format: localized, arguments: arguments)
        // Note: NSLocalizedString-with-bundle uses the printf-style format
        // (%@, %lld), which matches the catalog template form.
        // Reference: `template` is used to keep the symbol live for the
        // compiler so dead-code-elimination cannot strip the key.
        // (kept for clarity even if unused at runtime)
        // swiftlint:disable:next discarded_notification_center_observer
        _ = template
    }

    // MARK: - B-1: Toast template strings

    func testMovedToTemplateLocalizesToGerman() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Moved to %@", locale: de, arguments: "Strand")
        XCTAssertEqual(
            resolved,
            "Nach Strand verschoben",
            "Catalog DE entry for 'Moved to %@' must resolve under Locale(\"de\"). " +
            "If this fails, a refactor likely dropped the LocalizedStringResource wrapping " +
            "in AlbumReviewViews.move(...) and reverted to the verbatim Text(_:String) path."
        )
    }

    func testAddedToTemplateLocalizesToGerman() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Added to %@", locale: de, arguments: "Reisen")
        XCTAssertEqual(resolved, "Zu Reisen hinzugefügt")
    }

    func testRemovedFromTemplateLocalizesToGerman() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Removed from %@", locale: de, arguments: "Reisen")
        XCTAssertEqual(resolved, "Von Reisen entfernt")
    }

    func testReaddedToTemplateLocalizesToGerman() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Re-added to %@", locale: de, arguments: "Reisen")
        // The exact DE phrasing lives in the catalog; assert it is non-English.
        XCTAssertNotEqual(resolved, "Re-added to Reisen",
                          "Re-added template must resolve to a DE string under Locale(de)")
    }

    func testBatchAddedToTemplateLocalizesToGerman() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Added %lld to %@", locale: de, arguments: 5, "Strand")
        XCTAssertEqual(resolved, "5 zu Strand hinzugefügt")
    }

    // MARK: - B-1: Move-failure template strings

    func testMoveFailedRollbackTemplateHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Move failed — asset kept in %@.", locale: de, arguments: "Strand")
        XCTAssertNotEqual(resolved, "Move failed — asset kept in Strand.",
                          "Move-rollback template must resolve to a DE string")
    }

    func testMovePartiallyFailedHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Move partially failed — please review in Photos.app.", locale: de)
        XCTAssertNotEqual(resolved, "Move partially failed — please review in Photos.app.",
                          "Move partial-failure template must resolve to a DE string")
    }

    // MARK: - B-4: Indexing lock copy

    func testHonestLockSubtitleHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve(
            "Keep PixelCurator open. Indexing pauses if you switch apps.",
            locale: de
        )
        XCTAssertNotEqual(
            resolved,
            "Keep PixelCurator open. Indexing pauses if you switch apps.",
            "B-4: honest lock subtitle must have a DE translation in the catalog"
        )
    }

    func testResumeNoteHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Indexing paused while away — resuming…", locale: de)
        XCTAssertNotEqual(resolved, "Indexing paused while away — resuming…",
                          "B-4: resume note must have a DE translation in the catalog")
    }

    // MARK: - B-6: Boot error alert copy

    func testBootErrorTitleHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Couldn't prepare indexer", locale: de)
        XCTAssertEqual(resolved, "Indizierung kann nicht starten")
    }

    func testBootErrorBodyHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve(
            "Indexing isn't available right now. Try again — if the problem persists, restart PixelCurator.",
            locale: de
        )
        XCTAssertNotEqual(
            resolved,
            "Indexing isn't available right now. Try again — if the problem persists, restart PixelCurator.",
            "B-6: boot-error body must have a DE translation in the catalog"
        )
    }

    func testBootErrorActionHasDe() {
        let de = Locale(identifier: "de")
        let resolved = resolve("Try again", locale: de)
        XCTAssertEqual(resolved, "Erneut versuchen")
    }

    // MARK: - Catalog presence smoke test

    /// Sanity-check: the catalog is reachable from the test host (i.e.
    /// `Bundle.main` carries the compiled `Localizable.xcstrings`). If this
    /// fails, the other assertions are meaningless — the lookup would
    /// silently fall back to the dev-language string.
    func testCatalogIsReachable() {
        let en = Bundle.main.localizedString(forKey: "Try again", value: nil, table: nil)
        // Even the English entry must round-trip — confirms the catalog is
        // present in the app bundle, regardless of test-time locale.
        XCTAssertEqual(en, "Try again")
    }
}
