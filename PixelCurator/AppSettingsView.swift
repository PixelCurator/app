import SwiftUI
import SwiftData

/// App-level settings.
///
/// Presented in two shapes:
///   - macOS: as the contents of the native `Settings` scene declared in
///     `PixelCuratorApp`. Cmd-, opens it automatically.
///   - iOS: as a `.sheet` from `PhotoGridView`'s toolbar gear button (wrapped
///     in a `NavigationStack` by the caller so it gets a title bar + Done).
///
/// Persisted state is stored via `@AppStorage`, which writes through to
/// `UserDefaults.standard`. The same `@AppStorage` key is read by
/// `PhotoGridView`, which mirrors the value into `PhotoController.hideICloudPhotos`
/// so the grid's `visibleAssets` filter reacts on the next render.
struct AppSettingsView: View {
    @AppStorage("hideICloudPhotos") private var hideICloudPhotos: Bool = false

    // MARK: - Injected services

    @Environment(\.embeddingIndexer) private var indexer
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoController.self) private var library
    @Environment(\.activeVariant) private var activeVariant
    // F-13. Read the in-flight variant-switch flag so the Delete Index
    // affordance is gated until the switch finishes. Without this gate, the
    // user could tap Delete Index between selecting a new variant and
    // `bootIndexer(variant:)` reassigning `activeVariant`; the wipe would
    // then target the OLD variant's `modelID`, not the one the user
    // believes they reset.
    @Environment(\.isSwitchingVariant) private var isSwitchingVariant

    // MARK: - Local state

    @State private var showDeleteConfirmation = false

    // MARK: - Body

    var body: some View {
        Form {
            // MARK: Photos section
            Section {
                // Inverted polarity reads better: the user is choosing what to
                // SHOW, not what to hide. We negate on read/write so the
                // persisted boolean ("hide") matches its semantic name.
                Toggle("Show iCloud photos", isOn: Binding(
                    get: { !hideICloudPhotos },
                    set: { hideICloudPhotos = !$0 }
                ))
                .accessibilityIdentifier("settings-show-icloud-photos")
            } footer: {
                Text("iCloud-only photos appear with the iCloud badge but cannot be analyzed for album suggestions until downloaded in Photos.app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: Index section
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    // `role: .destructive` already paints the label red on iOS
                    // and matches the system destructive tint on macOS
                    // (including under Increase Contrast). An explicit
                    // `.foregroundStyle(.red)` overrides the system-adaptive
                    // tint inconsistently, especially on macOS, so we don't
                    // set one.
                    Label("Delete Index", systemImage: "trash")
                }
                .accessibilityIdentifier("settings-delete-index")
                // F-13. Disable while a variant switch is in flight. See the
                // `isSwitchingVariant` property declaration above for the
                // race motivation.
                .disabled(isSwitchingVariant)
                .confirmationDialog(
                    "Delete and rebuild the index?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete and Rebuild Index", role: .destructive) {
                        Task { await resetIndex() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("PixelCurator will reanalyze every photo. This can take several minutes.")
                }
            } header: {
                Text("Index")
            } footer: {
                // F-13. Swap the footer to an explanation of the gate while a
                // variant switch is in flight, so the disabled button doesn't
                // look like a bug.
                if isSwitchingVariant {
                    Text("Wait for the quality switch to finish before resetting the index.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reset the index if album suggestions feel wrong. The app stays locked while rebuilding.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        // HIG: macOS Settings panes use `.formStyle(.grouped)` to render
        // sectioned, padded forms that match System Settings styling. Without
        // it the form looks like an iOS sheet shoved into a window.
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 200)
        #endif
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("app-settings-view")
    }

    // MARK: - Index reset

    /// Deletes all embeddings for the active variant, saves, and re-triggers the indexer.
    ///
    /// The full-screen lock overlay in `PixelCuratorApp` is bound to
    /// `indexer.isIndexing`, so it appears automatically once `index(assets:)`
    /// begins and disappears when it finishes — no extra wiring needed here.
    @MainActor
    private func resetIndex() async {
        guard let indexer else { return }
        // F-13 defense in depth. The Delete Index button is already disabled
        // while `isSwitchingVariant == true`, but the confirmation dialog
        // could in principle latch a tap that arrived while the gate was
        // open. Re-check here and bail if a variant switch is now in flight —
        // wiping with a stale `activeVariant.modelID` would target the wrong
        // variant's embeddings.
        guard !isSwitchingVariant else { return }
        let modelID = activeVariant.modelID

        // 1. Stop any in-flight indexing first. Without cancelAndWait the parallel
        //    `runIndex` loop keeps writing rows AFTER deleteAll, producing a
        //    non-deterministic mix of pre-reset and post-reset embeddings
        //    (backlog F-01).
        await indexer.cancelAndWait()

        // 2. Wipe stored embeddings AND user corrections for the current variant.
        //    Settings copy promises this fixes "suggestions feel wrong" — the
        //    suggestions are shaped by both stores, so wiping only embeddings
        //    leaves the user's complaint un-addressed (backlog F-19).
        EmbeddingStore(context: modelContext).deleteAll(modelID: modelID)
        CorrectionStore(context: modelContext).deleteAll(modelID: modelID)
        try? modelContext.save()

        // 3. Re-index everything. `indexer.index(assets:)` sets `isIndexing = true`
        //    which the top-level lock overlay observes and presents itself.
        //    Background-task wrapping lives in PixelCuratorApp, not here.
        await indexer.index(assets: library.assets)
    }
}

#Preview {
    AppSettingsView()
}
