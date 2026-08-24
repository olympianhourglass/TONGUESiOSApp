import SwiftUI
import CoreMotion

/// A swipeable, full-bleed editorial slideshow shown to brand-new users after
/// sign-up, before the paywall. It builds the story from "average apps are
/// finite" through everything TONGUES does, ending on a personalized welcome.
///
/// The deck is data-driven (`slides`): each slide carries its copy, its
/// background (light or dark), where the text sits, which media layer to draw,
/// and whether the pager shows. Adding a slide is just appending to the array
/// — swipe-to-advance, the pager, the status-bar tint and the background all
/// adapt automatically.
struct OnboardingSlideshowView: View {
    /// Called when the user swipes past the final slide — hands off to the next
    /// onboarding step (the paywall, or the welcome finale for paid users).
    let onFinish: () -> Void

    private let slides: [Slide] = [
        // 1 — statement, centered, no media.
        Slide(runs: [
            Slide.Run(L("Your ")),
            Slide.Run(L("average"), emphasized: true),
            Slide.Run(L(" language learning app drip feeds you words based on a ")),
            Slide.Run(L("finite"), emphasized: true),
            Slide.Run(L(" curriculum.")),
        ]),
        // 2 — text top, hand-holding-device photo.
        Slide(
            runs: [
                Slide.Run(L("We give them to you "), opacity: 0.6),
                Slide.Run(L("right away,"), emphasized: true, opacity: 0.6),
                Slide.Run(L(" and"), opacity: 0.6),
                Slide.Run(L(" you can choose your interests ")),
                Slide.Run(L("first."), emphasized: true),
            ],
            textPlacement: .top,
            media: .handDevice
        ),
        // 3 — text top, hand-holding-device photo.
        Slide(
            runs: [
                Slide.Run(L("We have words in every language "), opacity: 0.6),
                Slide.Run(L("and"), emphasized: true, opacity: 0.6),
                Slide.Run(L(" "), opacity: 0.6),
                Slide.Run(L("dialect.")),
            ],
            textPlacement: .top,
            media: .handDevice
        ),
        // 4 — text top, a fanned row of app screenshots.
        Slide(
            runs: [
                Slide.Run(L("With your words, generate "), opacity: 0.4),
                Slide.Run(L("sentences,")),
                Slide.Run(L(" "), opacity: 0.4),
                Slide.Run(L("stories, ")),
                Slide.Run(L("conversations, and audio playlists."), opacity: 0.4),
            ],
            textPlacement: .top,
            media: .phoneRow
        ),
        // 5 — dark: audio-player photo + provider pills.
        Slide(
            runs: [
                Slide.Run(L("Every flashcard deck is "), opacity: 0.4),
                Slide.Run(L("automatically a high quality audio playlist.")),
            ],
            textPlacement: .top,
            media: .audioHand,
            isDark: true
        ),
        // 6 — dark: AR phone + translation-tool pills.
        Slide(
            runs: [
                Slide.Run(L("We give you tools to "), opacity: 0.4),
                Slide.Run(L("explore a new city confidently.")),
            ],
            textPlacement: .top,
            media: .arTools,
            isDark: true
        ),
        // 7 — dark: widgets, with a mock widget card.
        Slide(
            runs: [
                Slide.Run(L("Learn passively with highly configurable and intelligent"), opacity: 0.4),
                Slide.Run(L(" home ")),
                Slide.Run(L("and"), emphasized: true),
                Slide.Run(L(" lock screen widgets.")),
            ],
            textPlacement: .top,
            media: .widgetCard,
            isDark: true
        ),
    ]

    @State private var selection: Int = 0
    // Publishes the device's gentle tilt so the media slides can offset their
    // layers for a subtle parallax (illusion of depth). Only runs while the
    // slideshow is on screen.
    @State private var motion = ParallaxMotion()

    // How far, in points, a layer drifts at full tilt. Background media moves a
    // touch; the chips/text in front of it move further, and the differential
    // reads as depth.
    private let backgroundParallax: CGFloat = 6
    private let foregroundParallax: CGFloat = 16

    private var currentSlide: Slide {
        slides[min(max(selection, 0), slides.count - 1)]
    }

    var body: some View {
        ZStack {
            // Background. A white base with a black layer faded in over it, so
            // the light→dark hand-off (slide 4→5) crossfades cleanly instead of
            // snapping. Both bleed under the safe areas.
            Color.white.ignoresSafeArea()
            Color.black.ignoresSafeArea()
                .opacity(currentSlide.isDark ? 1 : 0)

            // Media. Keyed by the Media case (not the slide index) so slides
            // that share media — the hand-device photo on 2 & 3 — keep the same
            // view mounted: it stays perfectly static while only the text
            // crossfades. Distinct media crossfades in.
            mediaLayer(currentSlide)
                .id(currentSlide.media)
                .transition(.opacity)

            // Copy. Keyed by slide index so it crossfades on every advance.
            slideText(currentSlide)
                .id(selection)
                .transition(.opacity)
        }
        .overlay(alignment: .bottom) {
            if currentSlide.showsPager {
                pager
                    .padding(.bottom, 30)
                    .transition(.opacity)
            }
        }
        // A horizontal swipe advances or retreats. Slides crossfade rather than
        // slide across, so no content bleeds in from the side mid-transition.
        .contentShape(Rectangle())
        .gesture(swipeGesture)
        .onAppear {
            updateStatusBar()
            motion.start()
        }
        .onChange(of: selection) { _, _ in
            updateStatusBar()
        }
        // Release the per-slide override so the next onboarding screen gets the
        // flow-wide status-bar treatment.
        .onDisappear {
            AppTabRouter.shared.forceLightStatusBar = false
            motion.stop()
        }
        .navigationBarBackButtonHidden(true)
    }

    // Swiping left advances (and, past the last slide, hands off to the
    // paywall); swiping right steps back. Each change is wrapped in
    // withAnimation so the layers crossfade.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard abs(value.translation.width) > 50 else { return }
                if value.translation.width < 0 { advance() } else { retreat() }
            }
    }

    private func advance() {
        Haptics.light()
        if selection < slides.count - 1 {
            withAnimation(.easeInOut(duration: 0.3)) { selection += 1 }
        } else {
            AppTabRouter.shared.forceLightStatusBar = false
            onFinish()
        }
    }

    private func retreat() {
        guard selection > 0 else { return }
        Haptics.light()
        withAnimation(.easeInOut(duration: 0.3)) { selection -= 1 }
    }

    // Dark slides need light status-bar content; light slides fall back to the
    // flow-wide dark setting. (forceLight wins over forceDark in AppTabRouter.)
    private func updateStatusBar() {
        AppTabRouter.shared.forceLightStatusBar = currentSlide.isDark
    }

    // MARK: - Slide copy

    // The 304pt-wide copy block at a 16pt leading margin — vertically centered
    // on statement slides, pinned to the top otherwise. Sits inside the safe
    // area (only the background and media bleed to the edges).
    private func slideText(_ slide: Slide) -> some View {
        slide.styledText
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 304, alignment: .leading)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: slide.textPlacement == .top ? .topLeading : .leading
            )
            .padding(.leading, 16)
            .padding(.top, slide.textPlacement == .top ? 8 : 0)
    }

    // MARK: - Media layers
    //
    // Each layer reproduces the Figma's absolute placement (a 393pt-wide
    // artboard) relative to the live screen width so the framing holds across
    // devices. Media never intercepts touches so swipes always pass through.

    @ViewBuilder
    private func mediaLayer(_ slide: Slide) -> some View {
        switch slide.media {
        case .none:
            EmptyView()

        case .handDevice:
            // Oversized hero photo bleeding off the left, right and bottom.
            // Anchored to the bottom edge (so it bleeds off, no gap above the
            // home indicator) and nudged 104pt left of centre — pulled a
            // further 64pt left of the previous framing per design review.
            geometry { scale in
                Image("OnboardingHandDevice")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 793 * scale)
                    .offset(x: -104 * scale, y: 58 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

        case .phoneRow:
            // Three app screenshots fanned in an overlapping row. Figma: each
            // 437.5×328.125, centres 122.5pt apart, vertical centre y≈563.
            geometry { scale in
                let centersX: [CGFloat] = [99.75, 222.25, 344.75]
                let names = ["OnboardingPhone1", "OnboardingPhone2", "OnboardingPhone3"]
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    Image(name)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 437.5 * scale)
                        .position(x: centersX[index] * scale, y: 563 * scale)
                }
            }

        case .audioHand:
            // Hand holding the audio player, bleeding off the left, plus the
            // stacked provider pills to its right. Figma: photo (-232, 332)
            // 709×532; pills at (243, 347), 100pt wide, 16pt gap.
            geometry { scale in
                Image("OnboardingAudioHand")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 709 * scale)
                    .position(x: 122.5 * scale, y: 598 * scale)
                    .offset(parallax(backgroundParallax))
                let audioPills: [(title: String, fills: Bool)] = [
                    (L("ElevenLabs"), true),
                    (L("Forvo"), false),
                    (L("Apple TTS"), true),
                ]
                VStack(alignment: .leading, spacing: 16 * scale) {
                    // Each pill fades up in sequence — the welcome slide's
                    // reveal, dialed back for a gentler stagger.
                    ForEach(Array(audioPills.enumerated()), id: \.offset) { index, item in
                        StaggeredReveal(index: index) {
                            pill(item.title, fontSize: 16, fillsWidth: item.fills, glass: false, scale: scale)
                        }
                    }
                }
                .frame(width: 100 * scale, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 243 * scale)
                .padding(.top, 347 * scale)
                .offset(parallax(foregroundParallax))
            }

        case .arTools:
            // AR translate phone plus a column of glass tool pills. Figma:
            // photo (-42, 181), 653×490; pills at left 16, tops 313/386/459/532.
            geometry { scale in
                Image("OnboardingPhoneAR")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 653 * scale)
                    .position(x: 284.5 * scale, y: 426 * scale)
                    .offset(parallax(backgroundParallax))
                let arPills: [(title: String, top: CGFloat)] = [
                    (L("Translate your environment with AR"), 313),
                    (L("Translate street signs"), 386),
                    (L("Direct translate"), 459),
                    (L("Record conversations and translate"), 532),
                ]
                // The tool chips fade up one after another, then ride the same
                // parallax as a single layer in front of the phone.
                ForEach(Array(arPills.enumerated()), id: \.offset) { index, item in
                    StaggeredReveal(index: index) {
                        arToolPill(item.title, top: item.top, scale: scale)
                    }
                    .offset(parallax(foregroundParallax))
                }
            }

        case .widgetCard:
            // A mock widget card. Figma: (17, 410), 360×169, rounded 25, hairline
            // white border on black.
            geometry { scale in
                widgetCard(scale: scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 17 * scale)
                    .padding(.top, 410 * scale)
            }
        }
    }

    // MARK: - Media helpers

    // Maps the device's current tilt onto a small offset. `depth` is the max
    // drift in points at full tilt; the smoothed roll/pitch (already recentred
    // on wherever the phone is being held) is clamped so the shift stays gentle.
    private func parallax(_ depth: CGFloat) -> CGSize {
        func shift(_ value: Double) -> CGFloat {
            // A gain of 2 lets a natural ±0.5rad hold reach the full range.
            CGFloat(max(-1, min(1, value * 2))) * depth
        }
        return CGSize(width: shift(motion.roll), height: shift(motion.pitch))
    }

    // A full-bleed, non-interactive canvas exposing the width-derived `scale`
    // used to map the Figma's 393pt artboard onto the live screen.
    private func geometry<Content: View>(
        @ViewBuilder _ content: @escaping (_ scale: CGFloat) -> Content
    ) -> some View {
        GeometryReader { geo in
            let scale = geo.size.width / 393
            ZStack {
                Color.clear
                content(scale)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // A capsule label. `glass` uses Liquid Glass (for the AR tool pills, which
    // carry a backdrop blur in the mock); otherwise a flat translucent white.
    private func pill(
        _ title: String,
        fontSize: CGFloat,
        fillsWidth: Bool,
        glass: Bool,
        scale: CGFloat
    ) -> some View {
        let label = Text(title)
            .font(.custom("NeueHaasDisplay-Roman", size: fontSize * scale))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 16 * scale)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        return Group {
            if glass {
                // Darkened glass (~30%) so the chips read as solid dark pills
                // against the photo, while the label stays white.
                label.glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
            } else {
                label.background(Color.white.opacity(0.2), in: Capsule())
            }
        }
    }

    // One left-aligned AR tool pill, positioned by its Figma top edge.
    private func arToolPill(_ title: String, top: CGFloat, scale: CGFloat) -> some View {
        pill(title, fontSize: 12, fillsWidth: false, glass: true, scale: scale)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 16 * scale)
            .padding(.top, top * scale)
    }

    // The mock "widget" card from slide 7 — built natively (no image).
    private func widgetCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text(L("Mandarin"))
                .font(.custom("NeueHaasDisplay-Light", size: 10 * scale))
                .foregroundStyle(.white.opacity(0.6))
            Text(L("Natural Language Processing"))
                .font(.custom("NeueHaasDisplay-Light", size: 10 * scale))
                .foregroundStyle(.white)
            HStack(alignment: .center) {
                Text("深度学习")
                    .font(.custom("NeueHaasDisplay-Bold", size: 20 * scale))
                    .foregroundStyle(.white)
                Spacer(minLength: 8 * scale)
                Image(systemName: "waveform")
                    .font(.system(size: 20 * scale))
                    .foregroundStyle(.white)
            }
            .padding(.top, 4 * scale)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.top, 20 * scale)
        .frame(width: 360 * scale, height: 169 * scale, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 25 * scale)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 25 * scale)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 20 * scale, y: 20 * scale)
        )
    }

    // MARK: - Liquid-glass pager

    // The Figma's bottom "portion": a capsule holding a 32pt active bar plus a
    // dot per remaining slide. The flat translucent fill from the mock is
    // replaced with Liquid Glass; the tick marks flip to white on dark slides
    // so they stay legible against the glass. Hidden on the welcome slide.
    private var pager: some View {
        let tick: Color = currentSlide.isDark ? .white : .black
        // Only real slides get a tick; the welcome finale has no pager anyway.
        let count = slides.filter(\.showsPager).count
        return HStack(spacing: 4) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                let isActive = index == min(selection, count - 1)
                Capsule()
                    .fill(tick.opacity(isActive ? 0.9 : 0.25))
                    .frame(width: isActive ? 32 : 4, height: 4)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selection)
        .padding(8)
        // On dark slides the indicator's glass is darkened ~40% so the capsule
        // reads against the black background instead of glowing bright.
        .glassEffect(
            currentSlide.isDark ? .regular.tint(.black.opacity(0.4)) : .regular,
            in: .capsule
        )
    }
}

/// Fades a chip up into place with a brief blur, delayed by its position in the
/// stack so a group assembles top-to-bottom — the welcome finale's reveal, made
/// deliberately subtler (shorter travel, lighter blur, tighter stagger) for the
/// chip rows. Its `onAppear` trigger means it replays every time its slide's
/// media remounts (i.e. each time the user lands on the slide).
private struct StaggeredReveal<Content: View>: View {
    let index: Int
    @ViewBuilder var content: () -> Content
    @State private var visible = false

    var body: some View {
        content()
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .blur(radius: visible ? 0 : 3)
            .animation(
                .easeOut(duration: 0.5).delay(0.1 + Double(index) * 0.1),
                value: visible
            )
            .onAppear { visible = true }
    }
}

/// Publishes the device's gentle tilt for the slideshow's parallax. It recentres
/// on whatever attitude the phone is first held at, then low-pass filters the
/// delta so the drift stays smooth rather than jittering frame-to-frame.
@MainActor
@Observable
final class ParallaxMotion {
    private(set) var roll: Double = 0
    private(set) var pitch: Double = 0

    private var referenceRoll: Double?
    private var referencePitch: Double?
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        // Delivered on the main queue, so it's safe to touch main-actor state.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated {
                self?.ingest(roll: motion.attitude.roll, pitch: motion.attitude.pitch)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        referenceRoll = nil
        referencePitch = nil
        roll = 0
        pitch = 0
    }

    private func ingest(roll rawRoll: Double, pitch rawPitch: Double) {
        if referenceRoll == nil { referenceRoll = rawRoll }
        if referencePitch == nil { referencePitch = rawPitch }
        let targetRoll = rawRoll - (referenceRoll ?? rawRoll)
        let targetPitch = rawPitch - (referencePitch ?? rawPitch)
        // Ease toward the target so the layers glide rather than snap.
        roll += (targetRoll - roll) * 0.12
        pitch += (targetPitch - pitch) * 0.12
    }
}

extension OnboardingSlideshowView {
    /// A single slideshow page.
    struct Slide {
        var runs: [Run]
        var textPlacement: TextPlacement = .center
        var media: Media = .none
        var isDark: Bool = false
        var showsPager: Bool = true

        var background: Color { isDark ? .black : .white }
        var foreground: Color { isDark ? .white : .black }

        enum TextPlacement { case center, top }
        enum Media: Equatable {
            case none, handDevice, phoneRow, audioHand, arTools, widgetCard
        }

        /// One styled fragment of a slide's copy. `emphasized` runs render in
        /// the italic cut of Neue Haas; `opacity` dims a run below 1 for the
        /// two-tone treatment in the mock.
        struct Run {
            let text: String
            let emphasized: Bool
            let opacity: Double

            init(_ text: String, emphasized: Bool = false, opacity: Double = 1) {
                self.text = text
                self.emphasized = emphasized
                self.opacity = opacity
            }
        }

        // The slide's copy in its own foreground tone.
        var styledText: Text {
            Slide.attributedText(runs, foreground: foreground)
        }

        // Builds runs into a single attributed Text: each fragment in the roman
        // or italic cut of Neue Haas at 40pt, in a (possibly dimmed) color.
        static func attributedText(_ runs: [Run], foreground: Color) -> Text {
            var result = AttributedString()
            for run in runs {
                var piece = AttributedString(run.text)
                piece.font = .custom(
                    run.emphasized ? "NeueHaasDisplay-RomanItalic" : "NeueHaasDisplay-Roman",
                    size: 40
                )
                piece.foregroundColor = foreground.opacity(run.opacity)
                result.append(piece)
            }
            return Text(result)
        }
    }
}

/// The onboarding finale, shown as its own step after the paywall (or straight
/// after the slideshow for users who skip it). A personalized greeting over a
/// black field, with the subtitle revealing line-by-line and the same gentle
/// tilt-parallax the slides use — the treatment it had as the slideshow's last
/// slide, now standalone so it lands as the closing beat.
struct OnboardingWelcomeView: View {
    /// The name captured in question 1; personalizes the greeting.
    var userName: String?
    /// Called when the user swipes on — hands off into the app.
    let onFinish: () -> Void

    @State private var motion = ParallaxMotion()
    // Flipped true on appear so the subtitle staggers in.
    @State private var revealed = false
    // Drives the fake "preparing" loader that fills left→right before the
    // screen auto-advances into the app.
    @State private var loadProgress: CGFloat = 0

    private let backgroundParallax: CGFloat = 6
    private let foregroundParallax: CGFloat = 16

    // The subtitle, split into its display lines so each can fade up in
    // sequence. Runs keep the two-tone treatment (dimmed 40% vs full white).
    private let subtitleLines: [[OnboardingSlideshowView.Slide.Run]] = [
        [.init(L("To the "), opacity: 0.4), .init(L("most"))],
        [.init(L("comprehensive"))],
        [.init(L("language"))],
        [.init(L("application")), .init(L(" on the"), opacity: 0.4)],
        [.init(L("planet."), opacity: 0.4)],
    ]

    private var greeting: String {
        if let name = userName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return L("Welcome %@", name)
        }
        return L("Welcome")
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 393
            ZStack {
                Color.black.ignoresSafeArea()
                // Greeting and subtitle placed by their Figma centre-Y (291 and
                // 470), each drifting a little with device tilt for depth.
                welcomeText(
                    OnboardingSlideshowView.Slide.attributedText(
                        [.init(greeting)],
                        foreground: .white
                    ),
                    centerY: 291,
                    scale: scale
                )
                .offset(parallax(backgroundParallax))
                animatedSubtitle(scale: scale)
                    .offset(parallax(foregroundParallax))
                loadingBar(scale: scale)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // A dark screen: light status-bar content, and start the parallax.
            AppTabRouter.shared.forceLightStatusBar = true
            motion.start()
            revealed = true
        }
        // No swipe required: let the subtitle assemble, run a brief fake
        // "preparing" loader that fills left→right, then drop into the app.
        .task {
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeInOut(duration: 2.0)) { loadProgress = 1 }
            try? await Task.sleep(for: .seconds(2.1))
            onFinish()
        }
        .onDisappear {
            AppTabRouter.shared.forceLightStatusBar = false
            motion.stop()
        }
        .navigationBarBackButtonHidden(true)
    }

    // Maps device tilt onto a small clamped offset. Mirrors the slideshow's
    // parallax so the finale feels of a piece with the slides before it.
    private func parallax(_ depth: CGFloat) -> CGSize {
        func shift(_ value: Double) -> CGFloat {
            CGFloat(max(-1, min(1, value * 2))) * depth
        }
        return CGSize(width: shift(motion.roll), height: shift(motion.pitch))
    }

    // A left-aligned text block placed by its Figma centre-Y.
    private func welcomeText(_ text: Text, centerY: CGFloat, scale: CGFloat) -> some View {
        text
            .font(.custom("NeueHaasDisplay-Roman", size: 40))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 306 * scale, alignment: .leading)
            .position(x: 17 * scale + (306 * scale) / 2, y: centerY * scale)
    }

    // The subtitle, revealed one line at a time: each fades up with a brief
    // blur that clears, staggered so the sentence assembles top to bottom.
    private func animatedSubtitle(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(subtitleLines.enumerated()), id: \.offset) { index, runs in
                OnboardingSlideshowView.Slide.attributedText(runs, foreground: .white)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 12)
                    .blur(radius: revealed ? 0 : 6)
                    .animation(
                        .easeOut(duration: 0.6).delay(0.15 + Double(index) * 0.16),
                        value: revealed
                    )
            }
        }
        .frame(width: 306 * scale, alignment: .leading)
        .position(x: 17 * scale + (306 * scale) / 2, y: 470 * scale)
    }

    // A slim fake-loading bar that fills left→right beneath the subtitle. Purely
    // cosmetic — it paces the automatic hand-off into the app.
    private func loadingBar(scale: CGFloat) -> some View {
        let width = 306 * scale
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: width, height: 3)
            Capsule()
                .fill(Color.white)
                .frame(width: width * loadProgress, height: 3)
        }
        .frame(width: width, alignment: .leading)
        // Fades in just after the subtitle has begun assembling.
        .opacity(revealed ? 1 : 0)
        .animation(.easeOut(duration: 0.6).delay(0.9), value: revealed)
        // Centered horizontally on screen (the fill still grows left→right).
        .position(x: 393 * scale / 2, y: 640 * scale)
    }
}
