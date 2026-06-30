import SwiftUI

/// Drives the first-run "tap Create New Deck" coach mark from the root
/// view (ContentView) so the floating hand draws *over* the tab bar
/// instead of being clipped beneath it inside the Study tab. StudyView
/// measures the button frame and publishes the present/dismiss request +
/// callbacks here; ContentView renders the overlay above the TabView.
@MainActor
@Observable
final class FirstRunCoachController {
    static let shared = FirstRunCoachController()

    var isPresented = false
    var buttonFrame: CGRect = .zero
    var onProceed: () -> Void = {}
    var onSkip: () -> Void = {}
    // Reliable, reference-typed signal that the Create New Deck sheet
    // should run its in-sheet tour. Set when the user taps the spotlight;
    // consumed (reset) by the sheet. Backstops the @State `startTutorial`
    // flag against any propagation timing issues.
    var runSheetTour = false

    private init() {}
}

/// First-run coach mark — a game-style tutorial layer that dims the
/// screen, spotlights a target control, and floats a "hand" (the Tap
/// asset) in to repeatedly tap it. Each tap emits an expanding ripple
/// from the target's center. Tapping the spotlight proceeds into the
/// real flow; tapping the dimmed area skips the tutorial.
///
/// Coordinates are supplied in this view's own (full-screen) space — the
/// host converts the target's global frame before handing it over.
struct CreateDeckCoachmark: View {
    /// Target control frame, in this view's local coordinate space.
    let target: CGRect
    /// Full container size, used to center the caption without overflow.
    let containerSize: CGSize
    /// Caption shown above the spotlight.
    var message: String = "Tap here to create your first deck"
    /// User tapped the highlighted control — proceed into the real flow.
    let onProceed: () -> Void
    /// User tapped the dimmed area — skip the tutorial.
    let onSkip: () -> Void

    @State private var handOffset: CGSize = enterOffset
    @State private var handScale: CGFloat = 1
    @State private var handOpacity: Double = 0
    @State private var ringPulse = false
    @State private var ripples: [UUID] = []

    // Hand travel: enters from off to the lower-right, rests just below
    // the target, then dips toward it on each tap.
    private static let enterOffset = CGSize(width: 130, height: 170)
    private static let restOffset = CGSize(width: 24, height: 38)
    private static let tapOffset = CGSize(width: 13, height: 22)

    private var targetCenter: CGPoint {
        CGPoint(x: target.midX, y: target.midY)
    }

    var body: some View {
        ZStack {
            scrim
            spotlight
            ripplesLayer
            caption
            hand
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await runDemo() }
    }

    // MARK: Layers

    // Dim everything except a capsule cutout around the target. Tapping
    // the dimmed region skips the tutorial.
    private var scrim: some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .mask {
                ZStack {
                    Rectangle()
                    Capsule()
                        .frame(width: target.width + 12, height: target.height + 12)
                        .position(targetCenter)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .contentShape(Rectangle())
            .onTapGesture { onSkip() }
    }

    // Pulsing ring + an invisible tap target sitting over the spotlight.
    private var spotlight: some View {
        ZStack {
            Capsule()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: target.width + 14, height: target.height + 14)
                .scaleEffect(ringPulse ? 1.06 : 0.97)
                .opacity(ringPulse ? 0.35 : 0.9)
            Capsule()
                .fill(Color.white.opacity(0.001))
                .frame(width: target.width + 22, height: target.height + 22)
                .contentShape(Capsule())
                .onTapGesture { onProceed() }
        }
        .position(targetCenter)
    }

    private var ripplesLayer: some View {
        ForEach(ripples, id: \.self) { id in
            RippleRing(center: targetCenter)
                .id(id)
        }
        .allowsHitTesting(false)
    }

    private var caption: some View {
        Text(message)
            .font(.custom("NeueHaasDisplay-Mediu", size: 15))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .fixedSize()
            .position(x: containerSize.width / 2, y: max(60, target.minY - 56))
            .allowsHitTesting(false)
    }

    private var hand: some View {
        Image("Tap")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 62, height: 62)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
            .scaleEffect(handScale, anchor: .top)
            .opacity(handOpacity)
            .position(targetCenter)
            .offset(handOffset)
            .allowsHitTesting(false)
    }

    // MARK: Animation loop

    private func runDemo() async {
        handOpacity = 0
        handOffset = Self.enterOffset
        handScale = 1

        // Glide in and rest below the target.
        withAnimation(.easeOut(duration: 0.55)) {
            handOpacity = 1
            handOffset = Self.restOffset
        }
        // Steady ring pulse for the whole tutorial.
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            ringPulse = true
        }

        guard await sleep(700) else { return }

        // Repeating tap: dip toward the target, ripple out, lift back.
        while true {
            spawnRipple()
            Haptics.light()
            withAnimation(.easeIn(duration: 0.16)) {
                handOffset = Self.tapOffset
                handScale = 0.8
            }
            guard await sleep(200) else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                handOffset = Self.restOffset
                handScale = 1
            }
            guard await sleep(1100) else { return }
        }
    }

    // Sleeps; returns false if the surrounding task was cancelled (view
    // gone) so the caller can bail instead of spinning.
    private func sleep(_ ms: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(ms))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func spawnRipple() {
        let id = UUID()
        ripples.append(id)
        Task {
            try? await Task.sleep(for: .milliseconds(950))
            ripples.removeAll { $0 == id }
        }
    }
}

// A single expanding, fading ring. Animates itself on appear so each
// tap can spawn a fresh, independent ripple.
private struct RippleRing: View {
    let center: CGPoint
    @State private var scale: CGFloat = 0.25
    @State private var opacity: Double = 0.55

    var body: some View {
        Circle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: 92, height: 92)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(center)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) {
                    scale = 1.7
                    opacity = 0
                }
            }
    }
}
