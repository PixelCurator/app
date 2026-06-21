//  AnimationStyles.swift
//  PixelCurator
//
//  Centralised animation / transition presets and reusable view modifiers for
//  the UX-polish pass. Consuming views import nothing extra — they just reference
//  `PCAnimation.*`, `PCTransition.*`, `.polishedButton`, and `.shimmer(…)`.

import SwiftUI
import Photos

// MARK: - PCAnimation

/// Namespace for named `Animation` presets used throughout the app.
///
/// Keeping durations in one place makes it trivial to tune the feel globally
/// and ensures that sibling views that animate together actually share timing.
enum PCAnimation {
    /// General content transitions (list rows, image loads, view swaps).
    /// Smooth spring with a whisper of extra bounce.
    static let contentSmooth: Animation = .smooth(duration: 0.35, extraBounce: 0.05)

    /// Interactive tap responses (buttons, toggles).
    /// Snappy spring so feedback feels instant.
    static let tapSnappy: Animation = .snappy(duration: 0.25, extraBounce: 0.1)

    /// Larger entry / exit animations (sheets, cards sliding in).
    /// More pronounced bounce for a playful, energetic feel.
    static let springBouncy: Animation = .spring(response: 0.45, dampingFraction: 0.7)

    /// Toast / banner appearance.
    /// Slightly tighter than `springBouncy` — assertive without being distracting.
    static let toastSpring: Animation = .spring(response: 0.4, dampingFraction: 0.75)
}

// MARK: - PCTransition

/// Namespace for named `AnyTransition` presets used throughout the app.
///
/// Each transition has a paired `PCAnimation` preset in its call site; the
/// two are designed to complement each other (matching durations).
enum PCTransition {
    /// Scale-with-opacity — used when content appears in place (grid cells,
    /// detail overlays). Subtle shrink on entry gives a sense of materialising.
    static let scaleOpacity: AnyTransition =
        .opacity.combined(with: .scale(scale: 0.96))

    /// Slide-up-with-opacity — used for toast banners entering from the bottom.
    static let slideBottomOpacity: AnyTransition =
        .move(edge: .bottom).combined(with: .opacity)

    /// Pure opacity — used when `accessibilityReduceMotion` is `true`.
    /// No movement, just a clean fade so content still feels deliberate.
    static let opacityOnly: AnyTransition = .opacity
}

// MARK: - PolishedButtonStyle

/// A `ButtonStyle` that scales the label down on press and respects
/// `accessibilityReduceMotion`.
///
/// Usage:
/// ```swift
/// Button("Tap me") { … }
///     .buttonStyle(PolishedButtonStyle())
/// ```
///
/// - When `reduceMotion` is **off**: label shrinks to 96 % on press, springs back
///   on release using a snappy animation.
/// - When `reduceMotion` is **on**: scale stays at 1.0; opacity drops to 0.75 as
///   the only visible feedback, which is still clear without inducing discomfort.
struct PolishedButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scaleFor(configuration.isPressed))
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1.0)
            .animation(
                reduceMotion ? .none : .snappy(duration: 0.2, extraBounce: 0),
                value: configuration.isPressed
            )
    }

    private func scaleFor(_ isPressed: Bool) -> CGFloat {
        guard !reduceMotion, isPressed else { return 1.0 }
        return 0.96
    }
}

extension ButtonStyle where Self == PolishedButtonStyle {
    /// Convenience accessor: `.buttonStyle(.polished)`.
    static var polished: PolishedButtonStyle { PolishedButtonStyle() }
}

// MARK: - ShimmerModifier

/// A `ViewModifier` that overlays a sweeping gradient shimmer to signal a
/// loading state.
///
/// Usage:
/// ```swift
/// RoundedRectangle(cornerRadius: 8)
///     .fill(Color.secondary.opacity(0.15))
///     .shimmer(isAnimating: isLoading)
/// ```
///
/// The shimmer is iOS-only: on macOS, loading states are fast enough (local
/// disk / in-process Core ML) that a shimmer would flicker and disappear before
/// the user notices it.
///
/// Animation lifecycle:
/// - `onAppear` with `isAnimating == true` starts the repeating loop.
/// - `onChange(of: isAnimating)` handles toggling mid-lifecycle (e.g. image
///   loaded while the view is still on screen).
/// - Setting `phase = -1` before re-triggering resets the gradient to the
///   leading edge, avoiding a jarring jump from wherever it stopped.
struct ShimmerModifier: ViewModifier {
    /// When `false` the overlay is hidden and no animation runs.
    let isAnimating: Bool

    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay { platformOverlay }
            .onAppear {
                guard isAnimating, !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onChange(of: isAnimating) { _, newValue in
                guard !reduceMotion else { phase = -1; return }
                if newValue {
                    phase = -1
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                } else {
                    phase = -1
                }
            }
            // Cancel the in-flight sweep if the user enables Reduce Motion
            // mid-load; otherwise the gradient keeps marching forever even
            // though the user has opted out of motion.
            .onChange(of: reduceMotion) { _, nowReduced in
                if nowReduced {
                    withAnimation(nil) { phase = -1 }
                } else if isAnimating {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
            }
    }

    /// Platform-dispatched overlay. iOS gets the sweeping shimmer (unless
    /// Reduce Motion is on — then it's suppressed); macOS stays inert
    /// because loading states are fast enough that a shimmer would flicker
    /// out before the user notices it.
    @ViewBuilder
    private var platformOverlay: some View {
        #if os(iOS)
        if reduceMotion {
            EmptyView()
        } else {
            shimmerOverlay
        }
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// The actual gradient panel, 2.5× the view width so it sweeps fully
    /// across from left to right without a visible seam at the edges.
    private var shimmerOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.55), location: 0.5),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: w * 2.5)
            .offset(x: phase * w * 2.5 - w)
        }
        .clipped()
        .allowsHitTesting(false)
    }
    #endif
}

// MARK: - View + shimmer

extension View {
    /// Overlays a sweeping shimmer gradient to indicate a loading state.
    ///
    /// - Parameter isAnimating: Pass `true` while content is loading, `false`
    ///   once data has arrived. The modifier handles start / stop transitions.
    func shimmer(isAnimating: Bool = true) -> some View {
        modifier(ShimmerModifier(isAnimating: isAnimating))
    }
}

// MARK: - Photo accessibility label

/// Builds the VoiceOver label for a `PHAsset` thumbnail cell.
///
/// Without a distinguishing detail every cell announces as "Photo" — a grid
/// of "Photo, Photo, Photo, …" is unusable for VO orientation. When the
/// asset has a `creationDate` we include a short localized date so users can
/// place each photo in time. Without one we fall back to the plain key
/// `"Photo"`, which the catalog already covers in DE as `"Foto"`.
@MainActor
func photoAccessibilityLabel(for asset: PHAsset) -> Text {
    if let date = asset.creationDate {
        return Text("Photo from \(date, format: .dateTime.month().day().year())")
    } else {
        return Text("Photo")
    }
}

// MARK: - VoiceOver helpers

/// Cross-platform helpers for posting VoiceOver announcements.
///
/// Toast banners that show up and disappear cannot rely on
/// `accessibilityAddTraits(.updatesFrequently)` — that trait announces a value
/// the user has navigated to, but toasts are transient by design. Posting an
/// announcement at the moment the toast appears is the only reliable way for
/// VoiceOver users to hear it.
enum VoiceOver {
    /// `true` when VoiceOver is actively listening.
    static var isRunning: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning
        #elseif canImport(AppKit)
        return NSWorkspace.shared.isVoiceOverEnabled
        #else
        return false
        #endif
    }

    /// Posts `message` to VoiceOver if (and only if) the user is listening.
    /// Uses the modern cross-platform `AccessibilityNotification.Announcement`
    /// API available on iOS 17 / macOS 14.
    static func announce(_ message: String) {
        guard isRunning else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - SensoryFeedbackHelper (documentation)

/// Sensory feedback is applied inline via the `.sensoryFeedback(_:trigger:)`
/// view modifier introduced in iOS 17 / macOS 14.
///
/// There is no wrapper type — applying the modifier directly on the relevant
/// view keeps the haptic intent co-located with the UI element that triggers
/// it, which makes it easy to audit and adjust per-interaction.
///
/// Common patterns used in PixelCurator:
/// ```swift
/// // Confirm a photo assignment decision.
/// Button { viewModel.confirm() } label: { … }
///     .sensoryFeedback(.success, trigger: viewModel.lastConfirmed)
///
/// // Signal an undo action.
/// Button { viewModel.undo() } label: { … }
///     .sensoryFeedback(.warning, trigger: viewModel.lastUndo)
/// ```
///
/// This enum is intentionally empty — it exists solely as a documentation
/// anchor for the sensory-feedback convention.
enum SensoryFeedbackHelper {}
