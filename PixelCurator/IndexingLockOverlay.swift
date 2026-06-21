import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - IndexingLockOverlay

/// Full-screen overlay that appears while `EmbeddingIndexer.isIndexing == true`.
///
/// Wired from `PixelCuratorApp.body` as a `.fullScreenCover` (iOS) or `.sheet`
/// (macOS) bound to `indexer.isIndexing` — it cannot be dismissed by swiping or
/// tapping outside because the rebuild must finish before the user can interact
/// with the app.
///
/// Design:
///   - Blurred backdrop (`.ultraThinMaterial` + dark overlay) so content peeks
///     through subtly while clearly communicating the lock state. Falls back
///     to a solid color when `accessibilityReduceTransparency` is on.
///   - Centered progress card: icon, title, linear progress bar, ETA caption,
///     accessibility-friendly subtitle.
///   - Pulsing icon animation, fully cancelled when `reduceMotion` is on.
///   - VoiceOver: progress card is a single contained element with a heading
///     trait; an announcement posts when the lock appears, and progress updates
///     are spoken at most every 10 assets.
///
/// All ETA estimation is driven by `.onChange(of: indexer.indexed)` here —
/// `EmbeddingIndexer` itself is not touched.
struct IndexingLockOverlay: View {

    /// The live indexer — non-optional because the overlay is only shown when
    /// an indexer exists and `isIndexing` is true.
    let indexer: EmbeddingIndexer

    // MARK: - State

    @State private var eta = IndexingETAEstimator()
    @State private var lastAnnounced: Int = -1
    @State private var iconScale: Double = 1.0

    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Body

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()
                .accessibilityHidden(true)

            progressCard
                .padding(.horizontal, 32)
                .frame(maxWidth: 360)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("indexing-lock-overlay")
        }
        .onAppear {
            eta.reset()
            lastAnnounced = -1
            if !reduceMotion { startPulse() }
            announceOverlayPresented()
        }
        // Tick the ETA estimator on every successfully indexed asset.
        .onChange(of: indexer.indexed) { _, newValue in
            eta.recordTick()
            announceProgressIfNeeded(indexed: newValue)
        }
        // Start or hard-cancel the pulse when reduceMotion preference changes
        // mid-run. Without the cancel branch the icon would stay frozen at
        // 1.06 (the in-flight `repeatForever` keeps running silently).
        .onChange(of: reduceMotion) { _, nowReduced in
            if nowReduced {
                withAnimation(nil) { iconScale = 1.0 }
            } else {
                startPulse()
            }
        }
        // Appear/disappear transition: scale + opacity, or plain opacity when
        // the user prefers reduced motion.
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 1.02))
        )
    }

    // MARK: - Backdrop

    /// Backdrop: dark-tinted ultra-thin material so the app content is visible
    /// but clearly unreachable. Falls back to an opaque background color when
    /// `accessibilityReduceTransparency` is on — text legibility on glass is
    /// the whole reason that setting exists.
    @ViewBuilder
    private var backdrop: some View {
        if reduceTransparency {
            opaqueBackdropColor
        } else {
            Color.black.opacity(0.75)
                .background(.ultraThinMaterial)
        }
    }

    private var opaqueBackdropColor: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground).opacity(0.96)
        #else
        return Color(NSColor.windowBackgroundColor).opacity(0.96)
        #endif
    }

    // MARK: - Progress card

    private var progressCard: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "wand.and.stars")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .scaleEffect(iconScale)
                .accessibilityHidden(true)

            // Title — heading trait so the rotor lands here first.
            Text("Rebuilding your index")
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            // Progress bar
            let progress = progressFraction
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .accessibilityValue(progressAccessibilityValue)

            // Counter + ETA caption — marked as frequently-updating so VO
            // users swiping through the card know it changes live.
            captionText
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)

            // Subtitle
            Text("Keep PixelCurator open. You can switch apps briefly — we'll keep working in the background for a few minutes.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: shadowColor, radius: 24, x: 0, y: 8)
    }

    /// Card background — opaque under Reduce Transparency, glass otherwise.
    private var cardBackground: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(opaqueCardColor)
        } else {
            return AnyShapeStyle(.regularMaterial)
        }
    }

    private var opaqueCardColor: Color {
        #if canImport(UIKit)
        return Color(UIColor.secondarySystemBackground)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }

    /// Drop-shadow is meaningful only when the card floats on glass; on the
    /// opaque fallback it would just be visual noise.
    private var shadowColor: Color {
        reduceTransparency ? .clear : .black.opacity(0.3)
    }

    // MARK: - Caption

    @ViewBuilder
    private var captionText: some View {
        let indexed = indexer.indexed
        let total = max(1, indexer.total)
        let remaining = max(0, total - indexed)

        if let seconds = eta.estimatedSecondsRemaining(remaining: remaining) {
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            Text("Photo \(indexed) of \(total) · about \(minutes) minute\(minutes == 1 ? "" : "s") left")
        } else {
            Text("Photo \(indexed) of \(total)")
        }
    }

    // MARK: - Progress fraction

    private var progressFraction: Double {
        let total = max(1, indexer.total)
        return Double(indexer.indexed) / Double(total)
    }

    // MARK: - Accessibility

    private var progressAccessibilityValue: String {
        "\(indexer.indexed) of \(indexer.total)"
    }

    /// Posts the modal-lock arrival announcement when the overlay first
    /// appears. Without this, VoiceOver users get no signal that the app
    /// became modal — they just lose responsiveness and don't know why.
    private func announceOverlayPresented() {
        guard voiceOverActive else { return }
        AccessibilityNotification.Announcement(
            "Rebuilding your photo index. This may take several minutes."
        ).post()
    }

    /// Announces progress every 10 assets via VoiceOver on iOS / macOS.
    ///
    /// The cross-platform `AccessibilityNotification.Announcement(_:).post()`
    /// API is available on both iOS 17+ and macOS 14+, so we use it on both
    /// paths instead of the old NSAccessibility / UIAccessibility split — the
    /// previous macOS branch posted on `NSApp.mainWindow as Any`, which
    /// silently no-ops when the lock is presented as a sheet.
    private func announceProgressIfNeeded(indexed: Int) {
        // Announce only every 10 assets to avoid spamming the user.
        let milestone = (indexed / 10) * 10
        guard milestone > 0, milestone != lastAnnounced else { return }
        lastAnnounced = milestone

        guard voiceOverActive else { return }

        let total = max(1, indexer.total)
        let message = "Indexed \(indexed) of \(total) photos."
        AccessibilityNotification.Announcement(message).post()
    }

    /// Cross-platform "is VoiceOver currently listening" check.
    private var voiceOverActive: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning
        #elseif canImport(AppKit)
        return NSWorkspace.shared.isVoiceOverEnabled
        #else
        return false
        #endif
    }

    // MARK: - Icon pulse animation

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: 1.2)
            .repeatForever(autoreverses: true)
        ) {
            iconScale = 1.06
        }
    }
}

// MARK: - Preview stub (preview only, not in production)

private actor PreviewStubEmbedder: ImageEmbedding {
    nonisolated var embeddingDimension: Int { 512 }
    func embed(_ cgImage: CGImage) async throws -> [Float] { [] }
}
