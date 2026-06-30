import SwiftUI

// MARK: - Anchor plumbing

enum CoachTarget: Hashable {
    case language, dialect, content, amount, level, generate

    // The matching attribute pill id, for horizontal scroll-to-reveal.
    var deckAttribute: DeckAttribute? {
        switch self {
        case .language: return .language
        case .dialect:  return .dialect
        case .content:  return .content
        case .amount:   return .amount
        case .level:    return .level
        case .generate: return nil
        }
    }
}

// Named coordinate space anchored to the attribute strip's scrollable
// CONTENT (the AttributesRow). A pill's frame in this space is its STATIC
// position within the content — it does NOT change as the strip scrolls,
// so it can be captured once and reliably, without depending on geometry
// callbacks firing mid-scroll (which they don't, for horizontal scroll).
enum CoachContentSpace {
    static let name = "coachAttributesContent"
}

// Collects everything needed to compute each tour target's on-screen
// frame. Horizontal pills are derived deterministically from their static
// content position + the live scroll offset + the strip's viewport frame,
// so we never rely on per-pill geometry updates during a horizontal scroll
// (the unreliable piece that left the off-screen pills un-spotlighted).
@MainActor
@Observable
final class CoachFrameStore {
    // Global frames for targets measured directly (the Generate button,
    // which only the OUTER vertical scroll moves — that IS tracked).
    var frames: [CoachTarget: CGRect] = [:]
    // Static per-pill frames in the attributes-content coordinate space.
    var contentFrames: [CoachTarget: CGRect] = [:]
    // The attribute strip's viewport (global). Stable; moves only with the
    // outer vertical scroll, which geometry tracking handles fine.
    var hViewport: CGRect = .zero
    // Live horizontal content offset of the attribute strip.
    var hOffsetX: CGFloat = 0

    // On-screen global frame for a target. Pills are computed; everything
    // else uses its directly-measured global frame.
    func globalFrame(for target: CoachTarget) -> CGRect {
        if target.deckAttribute != nil, let cf = contentFrames[target] {
            guard hViewport != .zero else { return .zero }
            return CGRect(
                x: hViewport.minX + cf.minX - hOffsetX,
                y: hViewport.minY + cf.minY,
                width: cf.width,
                height: cf.height
            )
        }
        return frames[target] ?? .zero
    }
}

extension View {
    // Reports this view's GLOBAL frame into the store (for the Generate
    // button — vertical scroll moves it, which geometry tracking handles).
    func coachAnchor(_ target: CoachTarget, store: CoachFrameStore?) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { store?.frames[target] = geo.frame(in: .global) }
            }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newValue in
            store?.frames[target] = newValue
        }
    }

    // Reports an attribute pill's STATIC frame in the content space. Stable
    // across scrolling, so a one-time onAppear capture is enough (plus an
    // onGeometryChange to catch a value-driven width change of the pill).
    func coachContentAnchor(_ target: CoachTarget, store: CoachFrameStore?) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { store?.contentFrames[target] = geo.frame(in: .named(CoachContentSpace.name)) }
            }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CoachContentSpace.name)) } action: { newValue in
            store?.contentFrames[target] = newValue
        }
    }

    // Optional variant: content-space capture for an attribute pill.
    @ViewBuilder
    func coachAnchorIf(_ target: CoachTarget?, store: CoachFrameStore?) -> some View {
        if let target {
            coachContentAnchor(target, store: store)
        } else {
            self
        }
    }
}

// MARK: - Tour

struct CreateDeckTourStep: Identifiable {
    let target: CoachTarget
    let caption: String
    var id: CoachTarget { target }
}

// Game-style guided walkthrough of the Create New Deck form. Dims the
// screen, spotlights one control at a time, floats a hand in to tap it
// (with ripples), and advances automatically. `onFocus` lets the host
// scroll the target into view before the hand points at it; `onFinish`
// tears the tour down.
struct CreateDeckCoachTour: View {
    // Presentational only — the driver (step advance, taps, ripples) lives
    // in CreateDeckSheet, a STABLE view whose `.task` survives the frequent
    // re-renders caused by the control frames updating mid-tour. (When the
    // driver lived here, the churn kept resetting this view's @State and
    // restarting its task, so the tour never got past the first step — or
    // showed nothing at all.) This view just renders the current step.
    let step: CreateDeckTourStep?
    let targetRect: CGRect
    let containerSize: CGSize
    let handDip: Bool
    let ripples: [UUID]
    // While true, the spotlight/hand/caption fade out and the scrim shows
    // a plain dim (no cutout). Used during a scroll so nothing chases the
    // moving content; the host re-reveals once the target frame is stable.
    var hideContent: Bool = false
    let onSkip: () -> Void

    @State private var ringPulse = false
    @State private var visible = false

    private var current: CreateDeckTourStep? { step }
    private var targetCenter: CGPoint {
        CGPoint(x: targetRect.midX, y: targetRect.midY)
    }
    private var hasTarget: Bool { targetRect != .zero }
    private var showContent: Bool { !hideContent && hasTarget }

    // Place the hand below the target when there's room, otherwise above
    // it (rotated to point down) so it never runs off the bottom edge.
    private var handBelow: Bool {
        targetRect.maxY + 120 < containerSize.height
    }
    private var handPosition: CGPoint {
        let gap: CGFloat = handDip ? 14 : 26
        let x = targetCenter.x + 12
        if handBelow {
            return CGPoint(x: x, y: targetRect.maxY + gap)
        } else {
            return CGPoint(x: x, y: targetRect.minY - gap)
        }
    }
    private var captionY: CGFloat {
        if handBelow {
            return max(70, targetRect.minY - 52)
        } else {
            return min(containerSize.height - 70, targetRect.maxY + 64)
        }
    }

    var body: some View {
        ZStack {
            scrim
            Group {
                spotlight
                ripplesLayer
                caption
                hand
            }
            .opacity(showContent ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(visible ? 1 : 0)
        // Glide the hand/spotlight between targets only while content is
        // shown; when hidden (mid-scroll) snap so it re-appears at the new
        // target without a stray glide across the screen.
        .animation(showContent ? .easeInOut(duration: 0.4) : nil, value: targetRect)
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { visible = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                ringPulse = true
            }
        }
    }

    // MARK: Layers

    private var scrim: some View {
        Rectangle()
            .fill(Color.black.opacity(0.5))
            .mask {
                ZStack {
                    Rectangle()
                    if showContent {
                        RoundedRectangle(cornerRadius: 10)
                            .frame(width: targetRect.width + 14, height: targetRect.height + 14)
                            .position(targetCenter)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            }
            .contentShape(Rectangle())
            .onTapGesture { onSkip() }   // tap anywhere to skip
    }

    private var spotlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.9), lineWidth: 2)
            .frame(width: targetRect.width + 16, height: targetRect.height + 16)
            .scaleEffect(ringPulse ? 1.04 : 0.98)
            .opacity(ringPulse ? 0.4 : 0.9)
            .position(targetCenter)
            .allowsHitTesting(false)
    }

    private var ripplesLayer: some View {
        ForEach(ripples, id: \.self) { id in
            TourRipple()
                .id(id)
        }
        .position(targetCenter)
        .allowsHitTesting(false)
    }

    private var caption: some View {
        Group {
            if let current {
                Text(current.caption)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .fixedSize()
                    .position(x: containerSize.width / 2, y: captionY)
            }
        }
        .allowsHitTesting(false)
    }

    private var hand: some View {
        Image("Tap")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 58, height: 58)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
            .rotationEffect(.degrees(handBelow ? 0 : 180))
            .scaleEffect(handDip ? 0.82 : 1, anchor: handBelow ? .top : .bottom)
            .position(handPosition)
            .allowsHitTesting(false)
    }

}

// A single expanding, fading ring centered on its container.
private struct TourRipple: View {
    @State private var scale: CGFloat = 0.25
    @State private var opacity: Double = 0.55

    var body: some View {
        Circle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: 96, height: 96)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) {
                    scale = 1.7
                    opacity = 0
                }
            }
    }
}
