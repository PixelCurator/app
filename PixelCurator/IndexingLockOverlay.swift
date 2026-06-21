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
/// Wired from `PixelCuratorApp.body` as a `.fullScreenCover` bound to
/// `indexer.isIndexing` — it cannot be dismissed by swiping or tapping outside
/// because the rebuild must finish before the user can interact with the app.
///
/// Design:
///   - Blurred backdrop (`.ultraThinMaterial` + dark overlay) so content peeks
///     through subtly while clearly communicating the lock state.
///   - Centered progress card: icon, title, linear progress bar, ETA caption,
///     accessibility-friendly subtitle.
///   - Pulsing icon animation (suppressed when reduceMotion is on).
///   - VoiceOver progress announcements every 10 assets.
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

    // MARK: - Body

    var body: some View {
        ZStack {
            // Backdrop: dark-tinted ultra-thin material so the app content
            // is visible but clearly unreachable.
            Color.black.opacity(0.75)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            progressCard
                .padding(.horizontal, 32)
                .frame(maxWidth: 360)
        }
        .accessibilityIdentifier("indexing-lock-overlay")
        .onAppear {
            eta.reset()
            lastAnnounced = -1
            if !reduceMotion { startPulse() }
        }
        // Tick the ETA estimator on every successfully indexed asset.
        .onChange(of: indexer.indexed) { _, newValue in
            eta.recordTick()
            announceProgressIfNeeded(indexed: newValue)
        }
        // Restart pulse when reduceMotion preference changes mid-run.
        .onChange(of: reduceMotion) { _, nowReduced in
            if !nowReduced { startPulse() }
        }
        // Appear/disappear transition: scale + opacity, or plain opacity when
        // the user prefers reduced motion.
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 1.02))
        )
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

            // Title
            Text("Rebuilding your index")
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            // Progress bar
            let progress = progressFraction
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .accessibilityValue(progressAccessibilityValue)

            // Counter + ETA caption
            captionText
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Subtitle
            Text("Keep PixelCurator open. You can switch apps briefly — we'll keep working in the background for a few minutes.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 8)
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

    /// Announces progress every 10 assets via VoiceOver on iOS / macOS.
    private func announceProgressIfNeeded(indexed: Int) {
        // Announce only every 10 assets to avoid spamming the user.
        let milestone = (indexed / 10) * 10
        guard milestone > 0, milestone != lastAnnounced else { return }
        lastAnnounced = milestone

        let total = max(1, indexer.total)
        let message = "Indexed \(indexed) of \(total) photos."

        #if canImport(UIKit)
        if UIAccessibility.isVoiceOverRunning {
            AccessibilityNotification.Announcement(message).post()
        }
        #elseif canImport(AppKit)
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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
