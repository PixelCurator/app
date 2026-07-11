import XCTest
import SwiftUI
@testable import PixelCurator

// MARK: - HelpViewTests
//
// N-2. Programmatic verification that every expected `accessibilityIdentifier`
// is present in HelpView's data model. The `Topic.allCases` enumeration that
// drives `ForEach` plus the `.accessibilityIdentifier(topic.rawValue)`
// modifier must include every mandate-specified key — and conversely, every
// Topic must be a mandate key. The internal enum is accessed via Mirror so
// the test does not require the type to leak `internal`.
//
// Two render-tree approaches were tried and rejected for unit-test use:
//   • `String(describing: view.body)` drops `accessibilityIdentifier`
//     modifier arguments from its print format on iOS 17.4.
//   • `UIHostingController` + UIView walk yields an empty identifier set
//     because Form sections are lazily materialised and SwiftUI parks
//     identifiers in `AccessibilityAttachmentModifier` metadata that the
//     public UIView / UIAccessibilityElement APIs don't expose without
//     `UIApplication.shared` orchestration the test bundle can't run.
//
// The Mirror-based Topic walk is the durable shape for a unit test. End-to-end
// `accessibility(identifier:)` reachability is the job of the UI test target
// behind the AllTests plan.

@MainActor
final class HelpViewTests: XCTestCase {

    /// Every section key documented in the N-2 mandate.
    private let expectedSectionKeys: [String] = [
        "help-index-reset",
        "help-indexing-lock",
        "help-clip-variants",
        "help-model-source",
        "help-privacy",
        "help-undo",
        "help-icloud",
        "help-cancel-indexing",
    ]

    // MARK: - Data layer

    /// The HelpView body iterates `Topic.allCases` and tags each section
    /// with `accessibilityIdentifier(topic.rawValue)`. Asserting the set
    /// of raw values directly is precise and stable against SwiftUI
    /// internal changes.
    func testEverySectionKeyIsBackedByATopic() throws {
        let topicRawValues = try discoverTopicRawValues()
        for key in expectedSectionKeys {
            XCTAssertTrue(
                topicRawValues.contains(key),
                "HelpView must define a Topic with rawValue '\(key)' (mandate-specified). Found: \(topicRawValues.sorted())"
            )
        }
    }

    /// Conversely, every Topic in the enum must be a mandate-specified key.
    /// Catches an accidental ninth (or renamed) topic that wasn't reviewed
    /// against the N-2 mandate.
    func testEveryTopicIsAMandateKey() throws {
        let topicRawValues = try discoverTopicRawValues()
        for raw in topicRawValues {
            XCTAssertTrue(
                expectedSectionKeys.contains(raw),
                "HelpView Topic '\(raw)' is not in the mandate-specified key list — either remove it or update the mandate"
            )
        }
        XCTAssertEqual(topicRawValues.count, expectedSectionKeys.count,
                       "Topic count must match the mandate's eight entries exactly")
    }

    func testExpectedSectionCount() {
        XCTAssertEqual(expectedSectionKeys.count, 8,
                       "N-2 specifies exactly eight help topics — keep this in sync")
    }

    // MARK: - Mirror-based enum discovery
    //
    // HelpView.Topic is a private enum (deliberately — it's an internal
    // detail). We discover its case raw values by walking the view's body
    // mirror until we find a `ForEach` whose `data` collection holds the
    // topics, then extract each topic's mirrored `rawValue` child.

    /// Walks the view body via Mirror reflection and returns the set of
    /// every `rawValue: String` discovered on an `Identifiable` element.
    /// This catches the Topic enum without requiring it to be `internal`.
    private func discoverTopicRawValues() throws -> Set<String> {
        let view = HelpView()
        var found: Set<String> = []
        collectRawValues(of: view.body, into: &found, depth: 0)
        guard !found.isEmpty else {
            XCTFail("Could not discover any Topic.rawValue via Mirror reflection — HelpView body shape may have changed")
            return []
        }
        return found
    }

    /// Recursive mirror walk. Bounded depth so a runaway descent into
    /// SwiftUI's metadata graph can't hang the test process.
    private func collectRawValues(of node: Any, into bag: inout Set<String>, depth: Int) {
        guard depth < 80 else { return }
        let mirror = Mirror(reflecting: node)

        // Direct rawValue hit on an enum case (Topic conforms to
        // RawRepresentable with String). Matches every `help-…` key.
        if let raw = (node as? any RawRepresentable)?.rawValue as? String,
           raw.hasPrefix("help-") {
            bag.insert(raw)
        }

        // Descend into every child. SwiftUI's view tree is recursive and
        // closure-captured, so a Mirror walk reaches deeply nested
        // `ForEach.data` payloads after a few hops.
        for child in mirror.children {
            collectRawValues(of: child.value, into: &bag, depth: depth + 1)
        }
    }
}
