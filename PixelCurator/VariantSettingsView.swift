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
            List(CLIPVariant.allCases) { variant in
                variantRow(variant)
            }
            .navigationTitle("Model Quality")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                Text(variant.displayName)
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
            } else if unlocked {
                Button("Select") {
                    onVariantChange(variant)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Button("Unlock") {
                        Task { await purchase(variant) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
