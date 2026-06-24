import SwiftUI

// MARK: - HelpView
//
// N-2. Static in-app Help & Tips view that answers the eight questions
// surfaced by loop-qa as "zero in-app answers". Pure SwiftUI `Form` with
// per-section `accessibilityIdentifier`s so UI tests can verify each entry
// is present in the rendered hierarchy.
//
// No remote fetch, no markdown engine — every body string is a
// `LocalizedStringResource` in `Localizable.xcstrings`. Tone is
// photographer-voice, du-form on the German side; Apple Photos-style.
// Honest about limitations (no "minutes" promises, no "cancel any time"
// when the cancel button doesn't exist yet).

struct HelpView: View {

    // MARK: - Section identity
    //
    // The `key` doubles as the `accessibilityIdentifier` on the Section row
    // so `HelpViewTests` can assert that every expected entry is present.
    // Keep these in sync with the keys called out in the mandate.
    private enum Topic: String, CaseIterable, Identifiable {
        case indexReset      = "help-index-reset"
        case indexingLock    = "help-indexing-lock"
        case clipVariants    = "help-clip-variants"
        case modelSource     = "help-model-source"
        case privacy         = "help-privacy"
        case undo            = "help-undo"
        case icloud          = "help-icloud"
        case cancelIndexing  = "help-cancel-indexing"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .indexReset:     return "arrow.triangle.2.circlepath"
            case .indexingLock:   return "lock.circle"
            case .clipVariants:   return "cpu"
            case .modelSource:    return "icloud.and.arrow.down"
            case .privacy:        return "hand.raised"
            case .undo:           return "arrow.uturn.backward.circle"
            case .icloud:         return "icloud"
            case .cancelIndexing: return "xmark.circle"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .indexReset:     return "What does Index Reset do?"
            case .indexingLock:   return "Why is the app locked while indexing?"
            case .clipVariants:   return "What's a CLIP variant?"
            case .modelSource:    return "Where do quality models come from?"
            case .privacy:        return "Are my photos private?"
            case .undo:           return "Is Undo permanent?"
            case .icloud:         return "Why aren't my iCloud photos in suggestions?"
            case .cancelIndexing: return "How do I cancel indexing?"
            }
        }
    }

    var body: some View {
        Form {
            ForEach(Topic.allCases) { topic in
                Section {
                    sectionBody(for: topic)
                } header: {
                    Label {
                        Text(topic.title)
                    } icon: {
                        Image(systemName: topic.icon)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier(topic.rawValue)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .navigationTitle("Help & Tips")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("help-view")
    }

    // MARK: - Section bodies
    //
    // Each topic's body is a small VStack of `Text`s rendered inside the
    // section. We intentionally avoid markdown — the catalog already pins
    // every string by its source-language key, and inline markdown would
    // add another fragile resolution step. Plain text with `.body` font
    // honours Dynamic Type out of the box.

    @ViewBuilder
    private func sectionBody(for topic: Topic) -> some View {
        switch topic {
        case .indexReset:
            VStack(alignment: .leading, spacing: 8) {
                Text("Index Reset wipes the embeddings and corrections for the variant you're using right now.")
                Text("Embeddings for other variants are preserved — if you've ever switched to a Pro variant and back, that earlier index stays put.")
                Text("After the reset, indexing runs from scratch.")
                Text("Your Photos library and album assignments are never touched.")
                Text("Use it if suggestions feel wrong.")
            }
            .font(.body)

        case .indexingLock:
            VStack(alignment: .leading, spacing: 8) {
                Text("The rebuild has to finish before suggestions can be accurate.")
                Text("Indexing pauses if you switch to another app — iOS limits how much work can run in the background, so we don't promise a fixed time.")
                Text("On a fresh library or after Index Reset, this can take several minutes.")
                Text("You can leave the device on the lock screen if you don't want to watch the progress bar.")
            }
            .font(.body)

        case .clipVariants:
            VStack(alignment: .leading, spacing: 10) {
                Text("CLIP variants are the on-device vision models that read your photos and decide which albums they belong in.")

                VStack(spacing: 6) {
                    variantRow(name: "S0", quality: "Fast", availability: "Bundled, free", size: "~50 MB")
                    variantRow(name: "S1", quality: "Better quality", availability: "Pro", size: "~50 MB")
                    variantRow(name: "S2", quality: "Higher quality", availability: "Pro", size: "~75 MB")
                    variantRow(name: "B",  quality: "Best quality", availability: "Pro", size: "~175 MB")
                }
                .padding(.vertical, 4)

                Text("Tradeoff: a bigger model gives more accurate suggestions but takes longer to index.")
                Text("You can switch any time — every variant keeps its own index, so switching back later doesn't waste work.")
            }
            .font(.body)

        case .modelSource:
            VStack(alignment: .leading, spacing: 8) {
                Text("S0 ships inside the app.")
                Text("Pro variants download from HuggingFace (apple/coreml-mobileclip).")
                Text("Downloads are content-addressable and verified by SHA-256 checksum — a corrupted download won't be installed.")
                Text("Cached models live in Application Support. Deleting them from Settings is safe; the next switch re-downloads.")
            }
            .font(.body)

        case .privacy:
            VStack(alignment: .leading, spacing: 8) {
                Text("Your photos never leave the device for inference or any other reason.")
                Text("Suggestions, similarity ranking and album assignments all run on-device.")
                Text("No analytics, no tracking, no third-party SDKs.")
                Text("When you download a Pro model, HuggingFace logs your IP address (same as any web request) — that's the only network traffic this app starts on its own.")
                Text("Album assignments are written to Photos.app via PhotoKit, the same way you'd add a photo to an album manually.")
            }
            .font(.body)

        case .undo:
            VStack(alignment: .leading, spacing: 8) {
                Text("Undo history is session-only — closing the app clears it.")
                Text("Once you close the app, album assignments are permanent. You can still remove photos from an album in Photos.app.")
                Text("Photos.app itself doesn't undo album moves across launches either, so this matches the system behaviour.")
            }
            .font(.body)

        case .icloud:
            VStack(alignment: .leading, spacing: 8) {
                Text("iCloud-only photos can't be analyzed without downloading them first.")
                Text("PixelCurator skips them to avoid slow background downloads on cellular or limited Wi-Fi.")
                Text("To include one: open Photos.app, view the photo so iCloud downloads it, then come back here.")
                Text("The Settings toggle \"Show iCloud photos\" controls whether they appear in lists at all.")
            }
            .font(.body)

        case .cancelIndexing:
            VStack(alignment: .leading, spacing: 8) {
                Text("There's currently no Cancel button for an in-flight indexing run.")
                Text("Switching CLIP variants cancels the run and rebuilds for the new variant.")
                Text("Index Reset also cancels and restarts.")
                Text("A proper Cancel button is on the roadmap for a future release.")
            }
            .font(.body)
        }
    }

    // MARK: - Variant table row

    /// A single row of the CLIP-variants table.
    ///
    /// We render with `Text` interpolation rather than a `Grid` so VoiceOver
    /// reads "S0 — Fast — Bundled, free — about 50 megabytes" in one phrase
    /// instead of cell-by-cell, which would force the user to swipe four
    /// times per row.
    @ViewBuilder
    private func variantRow(
        name: LocalizedStringResource,
        quality: LocalizedStringResource,
        availability: LocalizedStringResource,
        size: LocalizedStringResource
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.body.weight(.semibold).monospaced())
                .frame(minWidth: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(quality)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(availability)
                    Text("·")
                        .accessibilityHidden(true)
                    Text(size)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
