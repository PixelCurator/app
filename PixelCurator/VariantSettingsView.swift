import StoreKit
import SwiftUI

/// Lets the user pick a CLIP quality variant and purchase pro variants.
///
/// Presented as a sheet from `PhotoGridView`. Selecting a different variant
/// triggers `onVariantChange(_:)`, which causes the app to download (if needed)
/// and re-index using the new model — the old embeddings are preserved
/// (per-modelID in SwiftData) and can be restored by switching back.
struct VariantSettingsView: View {

    // MARK: - Dependencies

    let currentVariant: CLIPVariant
    let entitlements: any EntitlementProvider
    let onVariantChange: (CLIPVariant) -> Void

    // MARK: - Local state

    @State private var purchasing: CLIPVariant?
    @State private var purchaseError: String?
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CLIPVariant.allCases) { variant in
                        variantRow(variant)
                    }
                } footer: {
                    // Honest disclosure: pro variants are downloaded from a
                    // third-party host (huggingface.co) which sees the user's
                    // IP. This breaks the "fully on-device" claim if read
                    // strictly; the disclosure keeps the privacy story honest.
                    // Switching to bundled / self-hosted variants in the
                    // future would let us drop this footer.
                    Text("Quality variants are downloaded from huggingface.co. Your IP address is visible to HuggingFace when downloading.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #if os(macOS)
            // HIG: macOS settings-style lists read better as a grouped form.
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 320)
            #endif
            .navigationTitle("Model Quality")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityIdentifier("variant-settings-view")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Purchase failed", isPresented: .constant(purchaseError != nil), actions: {
                Button("OK") { purchaseError = nil }
            }, message: {
                Text(purchaseError ?? "")
            })
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func variantRow(_ variant: CLIPVariant) -> some View {
        let unlocked = entitlements.isUnlocked(variant)
        let isCurrent = variant == currentVariant

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(variant.displayName))
                    .font(.body)
                if variant.tier == .free {
                    Text("Free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pro")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text("Currently selected"))
            } else if unlocked {
                Button("Select") {
                    onVariantChange(variant)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(Text("Select \(LocalizedStringKey(variant.displayName))"))
            } else if purchasing == variant {
                // Surface in-flight purchase — without this, the row looks
                // frozen while StoreKit is awaiting the user's confirmation.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Purchasing…"))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button("Unlock") {
                        Task { await purchase(variant) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Unlock \(LocalizedStringKey(variant.displayName))"))
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Purchase

    private func purchase(_ variant: CLIPVariant) async {
        guard let skProvider = entitlements as? StoreKitEntitlementProvider else {
            // DebugEntitlementProvider: no-op (all already unlocked in debug).
            return
        }
        purchasing = variant
        defer { purchasing = nil }
        do {
            try await skProvider.purchase(variant)
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}

// MARK: - Note on switching

extension VariantSettingsView {
    /// Switching variants triggers a full re-index of the photo library using the
    /// new model. Old embeddings are kept in the SwiftData store (tagged by modelID)
    /// and become active again if the user switches back. The re-index may take
    /// several minutes on large libraries.
    static let switchingNote = "Switching quality re-indexes your library using the selected model. Old indexes are preserved and reactivated when you switch back."
}
