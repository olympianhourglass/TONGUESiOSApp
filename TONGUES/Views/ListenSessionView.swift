import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

struct ListenSessionView: View {
    let deck: DeckDocument

    // The app-root host that keeps this view mounted across minimize/expand.
    // Reading it here makes the body react to `isMinimized` and the shared
    // Create New Deck button frame that positions the mini-bar.
    @State private var host = ListenSessionHost.shared

    // Hardware-keyboard transport (iPad/Mac): ← acts as Back, → as Next. A
    // focusable container receives the key presses.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var keyboardNavFocused: Bool

    @State private var currentIndex = 0
    @State private var isPaused = false
    @State private var dragOffset: CGFloat = 0
    // True for the brief window while the sheet is sliding up/down. The
    // breathing radial gradient is paused during it so a static, cheap backdrop
    // translates cleanly with the text instead of re-rendering per-frame mid
    // transition (which caused the lag + the background trailing the text).
    @State private var isAnimatingPresentation = false
    // The window's safe-area insets, measured from a context that respects
    // them. The full player ignores the safe area as ONE layer (so the backdrop
    // and text slide together with no screen-anchored bleed mismatch), then the
    // controls are pushed back inside the safe area using these.
    @State private var safeAreaInsets = EdgeInsets()
    @State private var volume: Double = 0.08
    @State private var autoPlay = false
    @State private var advanceTask: Task<Void, Never>?
    @State private var chainTask: Task<Void, Never>?
    @State private var showOptions = false
    // Bound to the options TabView so each page keeps a stable identity —
    // without an explicit selection + tags, the paged TabView recycles page
    // views mid-swipe and briefly renders one page's content over the next.
    @State private var optionsPage = 0

    // Spotify-style transport state. `playOrder` is a mapping from session
    // position → index in `deck.items`. Shuffle reshuffles it; the un-shuffled
    // state is just 0..<deck.items.count.
    @State private var playOrder: [Int] = []
    @State private var isShuffled = false
    @State private var repeatMode: RepeatMode = .off
    // Audio session bookkeeping for the XP award fired on dismiss. Start
    // time is captured in onAppear; `advancedDeckIndices` records every
    // unique deck item the user landed on so per-minute XP can be capped
    // by real progress (anti background-playback farming).
    @State private var sessionStartedAt: Date = Date()
    @State private var advancedDeckIndices: Set<Int> = []
    @State private var didCompletePlaylist = false
    @State private var didAwardAudioXP = false

    enum RepeatMode {
        case off, all, one
    }

    // Listening session preferences. Persisted via @AppStorage so they carry
    // across sessions; the user surfaces them in the Options panel.
    // Continuous is the persisted state of the in-session Continuous toggle
    // (the icon on the transport bar) — flipping that button saves here, so
    // the choice carries across sessions. Defaults to ON for new users.
    @AppStorage("listenContinuousByDefault") private var continuousEnabled = true
    @AppStorage("listenReadTranslation") private var readTranslation = false
    @AppStorage("listenTranslationOrder") private var translationOrderRaw = "before"
    @AppStorage("listenGapSeconds") private var gapSeconds: Int = 2
    @AppStorage("listenTurtle") private var turtle: Bool = false
    // Selected background tracks (resource filename, "" = none) for the two
    // ambient channels. Persisted so the choice carries across sessions.
    @AppStorage("listenAmbientSound") private var ambientSoundId: String = ""
    @AppStorage("listenAmbientMusic") private var ambientMusicId: String = ""
    // Chosen background gradient for the session backdrop.
    @AppStorage("listenGradientTheme") private var gradientThemeRaw = ListenGradientTheme.aura.rawValue

    private var selectedGradientTheme: ListenGradientTheme {
        ListenGradientTheme(rawValue: gradientThemeRaw) ?? .aura
    }

    // Looping ambient players layered under the study audio. Held as a
    // stable reference for the lifetime of the session view.
    @State private var ambient = AmbientAudioPlayer()

    private var translationBefore: Bool { translationOrderRaw == "before" }
    private var playbackRate: Float { turtle ? 0.5 : 1.0 }

    private var totalCount: Int { deck.items.count }
    private var currentItem: GeneratedItem? {
        // Before onAppear populates `playOrder`, fall back to natural deck order
        // so the first word/translation are on screen from the VERY FIRST frame
        // of the present slide. Otherwise the text has no content at mount and
        // pops in a beat after the sheet has started rising — which reads as the
        // text sliding in slower than the backdrop.
        let order = playOrder.isEmpty ? Array(0..<deck.items.count) : playOrder
        guard currentIndex >= 0, currentIndex < order.count else { return nil }
        let deckIdx = order[currentIndex]
        guard deckIdx < deck.items.count else { return nil }
        return deck.items[deckIdx]
    }
    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(currentIndex + 1) / Double(totalCount)
    }
    // Progress bar fade reflects non-linear playback states so the bar reads
    // as "this isn't strict left-to-right deck order". The numeric counter on
    // the right keeps showing position-in-play-order so the user still has a
    // concrete read on where they are.
    private var progressFillOpacity: Double {
        switch (isShuffled, repeatMode) {
        case (_, .one):    return 0.25  // Most muted — we're stuck on one item
        case (true, .all): return 0.35
        case (true, .off): return 0.5   // Shuffle alone
        case (false, .all): return 0.55 // Repeat alone
        case (false, .off): return 1.0  // Default linear playback
        }
    }
    private var isAtFirst: Bool { currentIndex == 0 }
    private var isAtLast: Bool { currentIndex >= totalCount - 1 }

    var body: some View {
        ZStack {
            if host.isMinimized {
                miniBarLayer
                    .transition(.opacity)
            } else {
                // A pure slide (no opacity fade): the backdrop is opaque from
                // the first frame, so the text rises glued to the background
                // instead of fading in ahead of it.
                fullPlayer
                    .transition(.move(edge: .bottom))
            }
        }
        // Measure the safe-area insets from this (non-ignoring) context so the
        // full player can ignore the safe area as one layer yet still inset its
        // controls correctly.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { safeAreaInsets = geo.safeAreaInsets }
                    .onChange(of: geo.safeAreaInsets) { _, new in safeAreaInsets = new }
            }
        )
        // Session-lifetime hooks live on this always-mounted container so they
        // fire once per session (start / true end) — the mini-bar keeps the
        // view mounted across a minimize, so onDisappear must NOT run then.
        .background(StatusBarRefresher().frame(width: 0, height: 0))
        // Hardware-keyboard transport (iPad/Mac): ← = Back, → = Next. The
        // focusable container receives the key presses; the focus ring is
        // hidden so no outline appears over the player.
        .focusable(supportsArrowKeyNav)
        .focusEffectDisabled()
        .focused($keyboardNavFocused)
        .onKeyPress(.leftArrow) { handleTransportLeftArrow() }
        .onKeyPress(.rightArrow) { handleTransportRightArrow() }
        .onAppear {
            // This view always has a dark radial backdrop, so its status
            // bar must read as white content no matter which surface
            // presented it — including a DeckDetailView reached from a
            // light-content tab like Explore. Force the light override on
            // (it wins over both the tab style and the dark override) and
            // re-run the runtime swap against the freshly-presented
            // hosting controller.
            AppTabRouter.shared.forceLightStatusBar = true
            // Pause the breathing gradient while the present slide plays.
            beginPresentationAnimation()
            DispatchQueue.main.async { StatusBarStyleSwap.installAndRefresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard AppTabRouter.shared.forceLightStatusBar else { return }
                StatusBarStyleSwap.installAndRefresh()
            }
            volume = Double(AVAudioSession.sharedInstance().outputVolume)
            autoPlay = continuousEnabled
            if playOrder.isEmpty {
                playOrder = Array(0..<deck.items.count)
            }
            sessionStartedAt = Date()
            if currentIndex < playOrder.count {
                advancedDeckIndices.insert(playOrder[currentIndex])
            }
            // Kick off speech RIGHT AWAY so the first (uncached) ElevenLabs
            // fetch overlaps the present slide instead of starting 0.4s after
            // it. These calls are light on the main thread — the network fetch
            // runs in an async Task — so the slide stays smooth. Only the
            // ambient beds' on-disk AVAudioPlayer decode actually hitched the
            // transition, so that alone stays deferred until the sheet settles.
            configureRemoteCommands()
            updateNowPlayingInfo()
            playCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                startAmbientBeds()
            }
            // Take focus so the ← / → keys drive transport immediately.
            if supportsArrowKeyNav {
                keyboardNavFocused = true
            }
        }
        .onDisappear {
            // Fires only on a genuine end (deck cleared on the host), not on
            // minimize. Release the white-bar override so the presenter
            // reclaims its own status-bar style, then tear down playback.
            AppTabRouter.shared.forceLightStatusBar = false
            advanceTask?.cancel()
            advanceTask = nil
            chainTask?.cancel()
            chainTask = nil
            SpeechClient.shared.stop()
            ambient.stopAll()
            clearNowPlayingInfo()
            awardAudioSessionXP()
        }
        .onChange(of: currentIndex) { _, newIndex in
            advanceTask?.cancel()
            advanceTask = nil
            chainTask?.cancel()
            chainTask = nil
            // Record which deck items the user has actually advanced to —
            // capping per-minute XP at this count is the anti-passive
            // playback guard. `Set` dedupes loops & shuffles.
            if newIndex < playOrder.count {
                advancedDeckIndices.insert(playOrder[newIndex])
            }
            updateNowPlayingInfo()
            playCurrent()
        }
        .onChange(of: isPaused) { _, paused in
            updateNowPlayingInfo()
            // Keep the ambient bed in lock-step with play/pause.
            if paused { ambient.pause() } else { ambient.resume() }
        }
        .onChange(of: autoPlay) { _, newValue in
            if newValue {
                // Re-trigger playback so the finish handler gets installed
                // even if speech was already running when the toggle flipped.
                if isPaused { isPaused = false }
                playCurrent()
            } else {
                advanceTask?.cancel()
                advanceTask = nil
            }
        }
        // Minimizing hands the status bar back to the tab underneath; expanding
        // re-asserts the white override over the full-screen backdrop.
        .onChange(of: host.isMinimized) { _, minimized in
            if minimized {
                AppTabRouter.shared.forceLightStatusBar = false
                AppTabRouter.shared.applyStatusBarStyle()
            } else {
                AppTabRouter.shared.forceLightStatusBar = true
                StatusBarStyleSwap.installAndRefresh()
            }
        }
    }

    // MARK: Full-screen player

    private var fullPlayer: some View {
        // Backdrop and controls are SIBLINGS in one ZStack that ignores the safe
        // area as a whole, so the move transition slides the entire composited
        // layer up together. (With the controls as an `.overlay` on a separately
        // safe-area-ignoring backdrop, the transition translated the backdrop
        // while the text rendered at rest — reading as "text arrives first".)
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isAnimatingPresentation)) { context in
                GeometryReader { geo in
                // Center at top, oversized endRadius (~2x the larger screen
                // dimension) so the visible part of the gradient is only a small
                // slice of the full radial spread — gives the smooth Figma feel
                // produced by dragging the radial-handle far past the canvas.
                // The radius gently breathes over a ~9-second period; amplitude
                // is small (≤4%) so the motion stays subtle, and slightly
                // boosted while audio is playing for an audio-visualizer feel.
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = sin(t * .pi * 2 / 9.0) * 0.5 + 0.5  // 0…1
                let amplitude: Double = SpeechClient.shared.isSpeaking ? 0.04 : 0.015
                let breath = 1.0 + phase * amplitude
                let stops = selectedGradientTheme.colors
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: stops[0], location: 0.0),
                        .init(color: stops[1], location: 0.167),
                        .init(color: stops[2], location: 0.5)
                    ]),
                    center: .top,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 2 * breath
                )
            }
        }
            .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 8)
                    .padding(.top, 16)

                Spacer(minLength: 0)

                wordSection
                    .padding(.horizontal, 8)

                Spacer(minLength: 0)

                bottomControls
                    .padding(.horizontal, 8)
                    .padding(.bottom, 28)

                bottomMeta
                    .padding(.horizontal, 8)
                    .padding(.bottom, 40)
            }
            // Push the controls back inside the safe area (the whole ZStack
            // ignores it below), so "SKIP TO END" and the transport stay clear
            // of the status bar / home indicator — the original spacing.
            .padding(.top, safeAreaInsets.top)
            .padding(.bottom, safeAreaInsets.bottom)
        }
        // Ignore the safe area on the WHOLE player as a single layer, so the
        // backdrop and controls slide together — no screen-anchored bleed that
        // makes the gradient outrun the text.
        .ignoresSafeArea()
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only follow downward drags so the view doesn't slide
                    // horizontally during left/right swipes.
                    let v = value.translation.height
                    let h = value.translation.width
                    dragOffset = abs(v) > abs(h) ? max(0, v) : 0
                }
                .onEnded { value in
                    let v = value.translation.height
                    let h = value.translation.width
                    let pv = value.predictedEndTranslation.height
                    let ph = value.predictedEndTranslation.width

                    // Horizontal swipe takes precedence when its travel
                    // dominates the vertical component.
                    if abs(h) > abs(v),
                       abs(h) > 60 || abs(ph) > 120 {
                        if h < 0 {
                            goNext()
                        } else {
                            goBack()
                        }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                        return
                    }

                    // Otherwise treat as swipe-down-to-MINIMIZE: the session
                    // collapses into the floating mini-bar above the tab bar
                    // (Apple Music-style) and keeps playing, rather than
                    // disappearing.
                    if v > 120 || pv > 220 {
                        // Don't snap dragOffset back to 0 here — that would jump
                        // the player up for a frame before the move-down removal
                        // transition slides it away (the flash the user saw). It
                        // keeps its dragged offset and slides straight down;
                        // expandSession() zeroes it before the next present.
                        minimizeSession()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .overlay {
            if showOptions {
                optionsPanel
                    .transition(.opacity)
            }
        }
    }

    // MARK: Floating mini-bar

    // Collapsed state: a floating control bar above the tab bar. On the Study
    // tab it stops 8pt short of the Create New Deck button and matches its
    // height; on every other tab it spans the full tab-bar width. Positioned in
    // global space (the GeometryReader ignores the safe area, so local ==
    // global) off the Study button's measured frame — which also supplies the
    // vertical anchor, since the tab bar sits at the same height on every tab.
    private var miniBarLayer: some View {
        // Read the current tab and dismiss/hide flags here in the view body —
        // not inside the GeometryReader closure — so @Observable tracking
        // reliably reflows the width when the tab changes.
        let btn = host.createButtonFrame
        let hasButtonFrame = btn != .zero
        // The bar takes the default full tab-bar width everywhere; it only
        // shortens when the Create New Deck button is actually on screen to its
        // right — the Study home screen with nothing pushed over it. Pushing a
        // detail page hides the button, so the bar reclaims the full width.
        let createButtonOnRight = hasButtonFrame
            && AppTabRouter.shared.current == .study
            && host.createButtonVisible
        // Withhold the bar on full-bleed screens (Statistics) and while it's
        // dissolving away — the session keeps playing regardless.
        let showBar = !host.isDismissing && !host.hideMiniBar

        return GeometryReader { geo in
            // Strip the button's 8pt invisible tap halo to recover the visible
            // capsule metrics the bar mirrors. Fallbacks cover the rare case
            // where Study hasn't laid out yet (session started from Library).
            let barHeight = hasButtonFrame ? btn.height - 16 : 52
            let barBottom = hasButtonFrame ? btn.maxY - 8 : geo.size.height - 91
            let barTop = barBottom - barHeight
            // Inset 16pt on the leading side (mirroring the Create button's own
            // trailing inset). Trailing edge is 8pt from the visible Create
            // button on Study — its 8pt halo makes `btn.minX` exactly that gap
            // — otherwise the matching 16pt inset for the full default width.
            let leftX: CGFloat = 16
            let rightX = createButtonOnRight ? btn.minX : geo.size.width - 16
            let barWidth = max(0, rightX - leftX)

            // Removing the bar within the container makes its Liquid Glass melt
            // out via the materialize transition — the Apple-native dissolve —
            // rather than a hand-rolled fade. `dismissMiniBar()` flips
            // `isDismissing`, which drops it here and, on Study, morphs the
            // Create button back to full size.
            GlassEffectContainer {
                if showBar {
                    miniBar(height: barHeight)
                        .glassEffectTransition(.materialize)
                        .frame(width: barWidth, height: barHeight)
                        .position(x: leftX + barWidth / 2, y: barTop + barHeight / 2)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func miniBar(height: CGFloat) -> some View {
        let theme = selectedGradientTheme
        // Controls stay white on the mini-bar regardless of the chosen theme.
        let fg: Color = .white
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(currentItem?.word ?? deck.title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                if let translation = currentItem?.translation {
                    Text(translation)
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .foregroundStyle(fg.opacity(0.7))
                        .lineLimit(1)
                }
            }
            // The label area is the large hit target: tap to re-expand, or
            // swipe it back down to dismiss the session entirely. Kept off the
            // transport buttons so their taps aren't swallowed. `.lineLimit(1)`
            // tail-truncates each line, so the text quietly gives up width to
            // the transport cluster rather than pushing it off the capsule.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { expandSession() }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        // Swipe LEFT (or down) melts the control away with the
                        // Liquid Glass materialize transition and stops the
                        // playlist.
                        let h = value.translation.width
                        let v = value.translation.height
                        if h < -40 || value.predictedEndTranslation.width < -80 || v > 24 {
                            host.dismissMiniBar()
                        }
                    }
            )

            // Back / play-pause / next, clustered tightly on the trailing side.
            HStack(spacing: 2) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(fg)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isAtFirst)
                .opacity(isAtFirst ? 0.4 : 1)

                Button {
                    togglePause()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(fg)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    goNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(fg)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: height)
        // An animated lava-lamp mesh in the user's chosen session colors churns
        // beneath clear Liquid Glass — the same crashing-colors treatment the
        // Create New Deck button used, now floating over that palette.
        .background {
            LavaLampGradient(colors: theme.lavaPalette)
                .clipShape(Capsule())
        }
        .glassEffect(.clear.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
    }

    // The ambient beds decode their mp3s off disk on the main thread, which
    // hitches the present slide — so they start a beat after onAppear, once the
    // sheet has settled. No-ops if the session was dismissed in that window.
    private func startAmbientBeds() {
        guard host.deck != nil else { return }
        ambient.set(ambientSoundId, for: .sound)
        ambient.set(ambientMusicId, for: .music)
    }

    // MARK: Session transitions

    // Pauses the breathing gradient for the duration of a slide so the sheet
    // animates smoothly, then resumes it once the sheet has settled.
    private func beginPresentationAnimation() {
        isAnimatingPresentation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            isAnimatingPresentation = false
        }
    }

    private func minimizeSession() {
        Haptics.light()
        beginPresentationAnimation()
        host.minimize()
    }

    private func expandSession() {
        Haptics.light()
        // Clear any leftover drag from the minimize gesture so the full player
        // presents cleanly at rest rather than pre-offset downward.
        dragOffset = 0
        beginPresentationAnimation()
        host.expand()
    }

    private func endSession() {
        host.end()
    }

    // MARK: Sections

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    endSession()
                } label: {
                    Text(L("SKIP TO END"))
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .tracking(1)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.18))
                    Rectangle()
                        .fill(Color.white)
                        .opacity(progressFillOpacity)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.25), value: progress)
            .animation(.easeOut(duration: 0.25), value: progressFillOpacity)

            ZStack {
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) { showOptions = true }
                } label: {
                    Text(L("Options"))
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)

                HStack {
                    Spacer()
                    Text("\(min(currentIndex + 1, totalCount))/\(totalCount)")
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var wordSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = currentItem {
                // Light gradients (Arctic, Aura) need dark session text; the
                // rest keep the white treatment.
                let textColor: Color = selectedGradientTheme.usesDarkText
                    ? .black.opacity(0.7)
                    : .white
                Text(item.word)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 56))
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(item.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: 22))
                    .foregroundStyle(selectedGradientTheme.usesDarkText
                        ? .black.opacity(0.7)
                        : .white.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bottomControls: some View {
        HStack {
            Button {
                goBack()
            } label: {
                Text(L("Back"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 60, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isAtFirst)
            .opacity(isAtFirst ? 0.4 : 1)

            Spacer()

            Button {
                togglePause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                goNext()
            } label: {
                Text(L("Next"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 60, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    // Decorative bottom row matching the design — background-music control
    // placeholders. Non-interactive until that feature exists.
    private var bottomMeta: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    Haptics.light()
                    autoPlay.toggle()
                    // Persist the user's explicit choice so it carries across
                    // sessions. The end-of-playlist auto-stop deliberately
                    // does NOT write here, so finishing a playlist never
                    // flips the saved preference off.
                    continuousEnabled = autoPlay
                } label: {
                    Image("Continuous")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.black)
                        .opacity(autoPlay ? 1.0 : 0.3)
                        .rotationEffect(.degrees(autoPlay ? 0 : -90))
                        .animation(.easeInOut(duration: 0.25), value: autoPlay)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                SpeakWaveformButton(
                    action: {
                        guard let item = currentItem else { return }
                        SpeechClient.shared.speak(
                            item.word,
                            language: item.language ?? deck.language,
                            allowForvo: true,
                            pronunciation: item.transliteration
                        )
                    },
                    font: .system(size: 22),
                    foregroundColor: .black.opacity(0.65),
                    frameSize: 22
                )
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.12))
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: geo.size.width * volume)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = value.location.x / geo.size.width
                            volume = min(max(0, ratio), 1)
                        }
                )
            }
            .frame(height: 15)
            .background(
                // Off-screen MPVolumeView bridges our custom slider to the
                // device's master output volume. Setting its embedded UISlider
                // value programmatically remains the supported way to drive
                // system volume from app code on iOS.
                SystemVolumeBridge(volume: volume)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            )

            // Shuffle (left) + Repeat-cycle (right) — Spotify-style transport.
            HStack {
                Button {
                    toggleShuffle()
                } label: {
                    Image("Shuffle")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.black)
                        .opacity(isShuffled ? 1.0 : 0.3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    cycleRepeatMode()
                } label: {
                    Image(repeatMode == .one ? "RepeatOnce" : "Repeat")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.black)
                        .opacity(repeatMode == .off ? 0.3 : 1.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Actions

    private func playCurrent() {
        guard !isPaused, let item = currentItem else { return }
        chainTask?.cancel()
        chainTask = nil
        let language = item.language ?? deck.language
        let translation = item.translation
        let word = item.word

        let rate = playbackRate
        if readTranslation, translationBefore {
            SpeechClient.shared.speakElevenLabs(translation, rate: rate) {
                speakAfterGap {
                    SpeechClient.shared.speak(
                        word,
                        language: language,
                        allowForvo: true,
                        rate: rate,
                        pronunciation: item.transliteration,
                        onFinish: autoPlay ? { scheduleAutoAdvance() } : nil
                    )
                }
            }
        } else if readTranslation {
            SpeechClient.shared.speak(word, language: language, allowForvo: true, rate: rate, pronunciation: item.transliteration) {
                speakAfterGap {
                    SpeechClient.shared.speakElevenLabs(
                        translation,
                        rate: rate,
                        onFinish: autoPlay ? { scheduleAutoAdvance() } : nil
                    )
                }
            }
        } else {
            SpeechClient.shared.speak(
                word,
                language: language,
                allowForvo: true,
                rate: rate,
                pronunciation: item.transliteration,
                onFinish: autoPlay ? { scheduleAutoAdvance() } : nil
            )
        }
    }

    // Silence between the two phrases when both native + translation are
    // spoken. Matches the inter-word gap setting so spacing stays consistent.
    private func speakAfterGap(_ action: @escaping () -> Void) {
        chainTask?.cancel()
        chainTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(gapSeconds)))
            guard !Task.isCancelled, !isPaused else { return }
            action()
        }
    }

    private func scheduleAutoAdvance() {
        advanceTask?.cancel()
        advanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(gapSeconds)))
            guard !Task.isCancelled, autoPlay, !isPaused else { return }

            // Repeat one: replay the same item (foreign + translation as one
            // unit) after the standard inter-word gap.
            if repeatMode == .one {
                playCurrent()
                return
            }

            if isAtLast {
                if repeatMode == .all {
                    // Spotify-style wrap: jump back to the first item and keep
                    // autoplay rolling.
                    currentIndex = 0
                } else {
                    autoPlay = false
                    didCompletePlaylist = true
                    endSession()
                }
            } else {
                currentIndex += 1
            }
        }
    }

    // MARK: Shuffle + repeat

    private func toggleShuffle() {
        Haptics.light()
        guard !playOrder.isEmpty else { return }
        let currentDeckIdx = playOrder[currentIndex]
        isShuffled.toggle()
        if isShuffled {
            // Keep everything up to and including the current item where it is,
            // then shuffle ONLY the not-yet-reached items into the slots after
            // it. This guarantees the current item never lands in the last slot
            // (which would make `isAtLast` true and end the session on the next
            // auto-advance — the "last card shuffled in ends the deck early"
            // bug), while still randomizing the rest of the queue. `currentIndex`
            // stays put, so playback and the progress counter don't jump, and
            // the bar still carries the user through every remaining card to a
            // real finish.
            let prefix = Array(playOrder[0...currentIndex])
            let alreadyPositioned = Set(prefix)
            var remaining = (0..<deck.items.count).filter { !alreadyPositioned.contains($0) }
            remaining.shuffle()
            playOrder = prefix + remaining
            // currentIndex is unchanged — the current item is still at it.
        } else {
            // Restore linear deck order and snap to the current item's natural
            // position so the counter reflects where it truly sits in the deck.
            playOrder = Array(0..<deck.items.count)
            if let newPos = playOrder.firstIndex(of: currentDeckIdx) {
                currentIndex = newPos
            }
        }
    }

    private func cycleRepeatMode() {
        Haptics.light()
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func goNext() {
        Haptics.light()
        advanceTask?.cancel()
        advanceTask = nil
        chainTask?.cancel()
        chainTask = nil
        if isAtLast {
            didCompletePlaylist = true
            endSession()
        } else {
            currentIndex += 1
        }
    }

    private func goBack() {
        Haptics.light()
        advanceTask?.cancel()
        advanceTask = nil
        chainTask?.cancel()
        chainTask = nil
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    // Arrow-key transport only where a hardware keyboard is expected —
    // Mac Catalyst or an iPad in a regular-width layout. iPhone is untouched.
    private var supportsArrowKeyNav: Bool {
        MacLayout.isMac || horizontalSizeClass == .regular
    }

    // ← / → mirror the Back / Next transport buttons, but stop at the ends
    // rather than wrapping or dismissing: left is ignored at the first item
    // (matching the disabled Back button), and right is ignored at the last
    // item so the arrow key never ends the session — unlike the Next button,
    // which intentionally completes and dismisses on the final track.
    private func handleTransportLeftArrow() -> KeyPress.Result {
        guard supportsArrowKeyNav, !isAtFirst else { return .ignored }
        goBack()
        return .handled
    }

    private func handleTransportRightArrow() -> KeyPress.Result {
        guard supportsArrowKeyNav, !isAtLast else { return .ignored }
        goNext()
        return .handled
    }

    private func togglePause() {
        Haptics.light()
        isPaused.toggle()
        if isPaused {
            advanceTask?.cancel()
            advanceTask = nil
            chainTask?.cancel()
            chainTask = nil
            SpeechClient.shared.stop()
        } else {
            playCurrent()
        }
    }

    // MARK: Lock-screen / Control Center takeover

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Wipe targets first so re-entering this view doesn't stack handlers.
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false

        center.playCommand.addTarget { [self] _ in
            if isPaused { togglePause() }
            return .success
        }
        center.pauseCommand.addTarget { [self] _ in
            if !isPaused { togglePause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [self] _ in
            togglePause()
            return .success
        }
        center.nextTrackCommand.addTarget { [self] _ in
            goNext()
            return .success
        }
        center.previousTrackCommand.addTarget { [self] _ in
            goBack()
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let item = currentItem else {
            clearNowPlayingInfo()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.word,
            MPMediaItemPropertyArtist: item.translation,
            MPMediaItemPropertyAlbumTitle: deck.title,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : Double(playbackRate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playbackRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info[MPMediaItemPropertyAlbumTrackNumber] = currentIndex + 1
        info[MPMediaItemPropertyAlbumTrackCount] = totalCount
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }

    // Awards listening XP exactly once on dismiss. Hits a no-op fast path
    // for sessions with no deckId (e.g. preview or unsaved deck) or zero
    // advancement, so quick dismisses don't generate empty toasts.
    private func awardAudioSessionXP() {
        guard !didAwardAudioXP, let deckId = deck.id else { return }
        didAwardAudioXP = true
        let elapsed = max(0, Date().timeIntervalSince(sessionStartedAt))
        let advanced = advancedDeckIndices.count
        let completed = didCompletePlaylist
        // A genuine listen — not an accidental open-and-dismiss — counts toward
        // the daily streak. The streak reads StudySession records, which the XP
        // grants below don't produce, so leave a lightweight session behind.
        let didListen = completed || elapsed >= 15
        Task {
            do {
                let sessionGrants = try await XPService.awardAudioSession(
                    deckId: deckId,
                    language: deck.language,
                    secondsListened: elapsed,
                    cardsAdvanced: advanced,
                    playlistCompleted: completed,
                    ambientActive: !ambientMusicId.isEmpty || !ambientSoundId.isEmpty
                )
                if didListen {
                    _ = try? await FirebaseDeckService.recordStreakActivity(
                        deckId: deckId,
                        deckTitle: deck.title,
                        language: deck.language
                    )
                }
                let dailyGrants = try await XPService.awardDailyBonusIfNeeded()
                await MainActor.run {
                    XPToastCenter.shared.enqueue(sessionGrants + dailyGrants)
                }
            } catch {
                print("XP award (audio) failed: \(error)")
            }
        }
    }

    // MARK: Options panel

    private var optionsPanel: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture { /* swallow taps so they don't pass through */ }

            VStack(spacing: 0) {
                // Swipeable settings: page 1 is the original playback options;
                // page 2 layers ambient background audio; page 3 picks the
                // background color gradient. Page dots hint at the extra pages.
                TabView(selection: $optionsPage) {
                    optionsPageOne.clipped().tag(0)
                    ambientPage.clipped().tag(1)
                    backgroundColorPage.clipped().tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))

                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) { showOptions = false }
                } label: {
                    Text(L("Close"))
                        .font(.custom("NeueHaasDisplay-Light", size: 16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
        }
    }

    // Page 1 — the original playback options.
    private var optionsPageOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("OPTIONS"))
                .font(.custom("NeueHaasDisplay-Black", size: 22))
                .foregroundStyle(.white)
                .padding(.top, 96)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                optionRow(
                    label: L("Native language read out loud:"),
                    isOn: readTranslation,
                    onYes: { readTranslation = true },
                    onNo: { readTranslation = false }
                )

                if readTranslation {
                    optionRow(
                        label: L("Before or after translated text?"),
                        firstTitle: L("BEFORE"),
                        secondTitle: L("AFTER"),
                        firstSelected: translationBefore,
                        onFirst: { translationOrderRaw = "before" },
                        onSecond: { translationOrderRaw = "after" }
                    )
                    .padding(.top, 32)
                }

                optionChoiceRow(
                    label: L("Seconds between audio:"),
                    options: [2, 4, 8],
                    selected: gapSeconds,
                    onSelect: { gapSeconds = $0 }
                )
                .padding(.top, 32)

                optionRow(
                    label: L("Turtle (2× slower):"),
                    isOn: turtle,
                    onYes: { turtle = true },
                    onNo: { turtle = false }
                )
                .padding(.top, 32)
            }
            .offset(y: -32)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Page 2 — ambient background audio. Two independent channels; the
    // user picks None or one track per channel, looped under the session.
    private var ambientPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("BACKGROUND"))
                .font(.custom("NeueHaasDisplay-Black", size: 22))
                .foregroundStyle(.white)
                .padding(.top, 96)

            Text(L("Layer a looping sound or music track under your session."))
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 28) {
                ambientRow(
                    title: L("Ambient Sound"),
                    tracks: AmbientCatalog.sounds,
                    selectedId: ambientSoundId
                ) { id in
                    ambientSoundId = id
                    ambient.set(id, for: .sound)
                }
                ambientRow(
                    title: L("Ambient Music"),
                    tracks: AmbientCatalog.music,
                    selectedId: ambientMusicId
                ) { id in
                    ambientMusicId = id
                    ambient.set(id, for: .music)
                }
            }
            .offset(y: -32)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Page 3 — background color gradient. Each option is a circle previewing
    // its gradient; tapping swaps the session backdrop live.
    private var backgroundColorPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("COLOR"))
                .font(.custom("NeueHaasDisplay-Black", size: 22))
                .foregroundStyle(.white)
                .padding(.top, 96)

            Text(L("Change the background gradient of your session."))
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 20) {
                ForEach(ListenGradientTheme.allCases) { theme in
                    gradientSwatch(theme)
                }
            }
            .frame(maxWidth: .infinity)
            .offset(y: -32)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gradientSwatch(_ theme: ListenGradientTheme) -> some View {
        let selected = selectedGradientTheme == theme
        return Button {
            Haptics.light()
            gradientThemeRaw = theme.rawValue
        } label: {
            VStack(spacing: 10) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: theme.colors,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 60, height: 60)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
                    .overlay(Circle().stroke(.white, lineWidth: selected ? 2.5 : 0))
                Text(L(theme.displayName))
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }

    // One ambient channel: a label above a horizontal strip of pills —
    // "None" plus every track. The selected pill is filled; tapping swaps
    // or clears the channel live.
    private func ambientRow(
        title: String,
        tracks: [AmbientTrack],
        selectedId: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("NeueHaasDisplay-Mediu", size: 17.6))
                .foregroundStyle(.white.opacity(0.85))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ambientChip(label: L("None"), isSelected: selectedId.isEmpty) {
                        onSelect("")
                    }
                    ForEach(tracks) { track in
                        ambientChip(label: track.displayName, isSelected: selectedId == track.id) {
                            onSelect(track.id)
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func ambientChip(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(label)
                .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    private func optionRow(
        label: String,
        isOn: Bool,
        onYes: @escaping () -> Void,
        onNo: @escaping () -> Void
    ) -> some View {
        optionRow(
            label: label,
            firstTitle: L("YES"),
            secondTitle: L("NO"),
            firstSelected: isOn,
            onFirst: onYes,
            onSecond: onNo
        )
    }

    private func optionChoiceRow<T: Hashable>(
        label: String,
        options: [T],
        selected: T,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Mediu", size: 17.6))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 16) {
                ForEach(options, id: \.self) { option in
                    Button {
                        Haptics.light()
                        onSelect(option)
                    } label: {
                        Text("\(String(describing: option))")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                            .foregroundStyle(option == selected ? .white : .white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func optionRow(
        label: String,
        firstTitle: String,
        secondTitle: String,
        firstSelected: Bool,
        onFirst: @escaping () -> Void,
        onSecond: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Mediu", size: 17.6))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 16) {
                Button {
                    Haptics.light()
                    onFirst()
                } label: {
                    Text(firstTitle)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(firstSelected ? .white : .white.opacity(0.35))
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    onSecond()
                } label: {
                    Text(secondTitle)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(firstSelected ? .white.opacity(0.35) : .white)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SystemVolumeBridge: UIViewRepresentable {
    let volume: Double

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        guard let slider = uiView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        let target = Float(volume)
        if abs(slider.value - target) > 0.001 {
            DispatchQueue.main.async {
                slider.value = target
            }
        }
    }
}

// A zero-size hosted controller whose viewDidAppear fires only once the
// enclosing surface (e.g. a full-screen cover) is actually on screen and
// in the window hierarchy — the reliable moment to re-run the status-bar
// style swap so the presented controller is re-classed to white.
private struct StatusBarRefresher: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { RefreshVC() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class RefreshVC: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            StatusBarStyleSwap.installAndRefresh()
        }
    }
}

// MARK: - Background gradient themes

// Selectable backdrops for the listening session. `colors` are the three stops
// top → bottom, mapped onto the radial gradient's 0.0 / 0.167 / 0.5 locations
// (the same layout the original uses).
enum ListenGradientTheme: String, CaseIterable, Identifiable {
    case aura
    case arctic
    case peach
    case myst
    // Formerly "Original". Renamed to "Night" but keeps its "original" raw
    // value so a user who had it selected before the rename still resolves.
    case night = "original"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aura:     return "Aura"
        case .arctic:   return "Arctic"
        case .peach:    return "Peach"
        case .myst:     return "Myst"
        case .night:    return "Night"
        }
    }

    // The three session stops expanded into a 9-color 3×3 mesh for the
    // animated lava-lamp fill on the audio mini-bar. Every row rotates the
    // three stops so all of them collide and churn into one another rather
    // than sitting in flat horizontal bands.
    var lavaPalette: [Color] {
        let c = colors
        return [
            c[0], c[1], c[2],
            c[1], c[2], c[0],
            c[2], c[0], c[1]
        ]
    }

    // A single representative hue for tinting Liquid Glass (the mini-bar),
    // where a full gradient isn't available. Picks whichever stop reads as the
    // theme's signature color rather than its near-white/near-black extreme.
    var tint: Color {
        switch self {
        case .night:  return colors[1]  // slate blue
        case .arctic: return colors[0]  // 54728B (its mid stop is near-white)
        case .peach:  return colors[1]  // E2725B
        case .myst:   return colors[1]  // BFB4DC lavender
        case .aura:   return colors[0]  // 9993A5 mauve
        }
    }

    // The light themes need dark session text; the rest keep white.
    var usesDarkText: Bool {
        switch self {
        case .arctic, .aura: return true
        case .night, .peach, .myst: return false
        }
    }

    var colors: [Color] {
        switch self {
        case .night:
            return [
                Color(red: 10/255, green: 10/255, blue: 10/255),
                Color(red: 83/255, green: 104/255, blue: 120/255),
                Color(red: 229/255, green: 228/255, blue: 226/255)
            ]
        case .arctic:
            // 54728B → EFF3F6 → 8FA1A5
            return [
                Color(red: 0x54/255, green: 0x72/255, blue: 0x8B/255),
                Color(red: 0xEF/255, green: 0xF3/255, blue: 0xF6/255),
                Color(red: 0x8F/255, green: 0xA1/255, blue: 0xA5/255)
            ]
        case .peach:
            // 4E2C23 → E2725B → FFDAB9
            return [
                Color(red: 0x4E/255, green: 0x2C/255, blue: 0x23/255),
                Color(red: 0xE2/255, green: 0x72/255, blue: 0x5B/255),
                Color(red: 0xFF/255, green: 0xDA/255, blue: 0xB9/255)
            ]
        case .myst:
            // AA0003 → BFB4DC → FAFBFD
            return [
                Color(red: 0xAA/255, green: 0x00/255, blue: 0x03/255),
                Color(red: 0xBF/255, green: 0xB4/255, blue: 0xDC/255),
                Color(red: 0xFA/255, green: 0xFB/255, blue: 0xFD/255)
            ]
        case .aura:
            // 9993A5 → CBD0D2 → E5E4E2
            return [
                Color(red: 0x99/255, green: 0x93/255, blue: 0xA5/255),
                Color(red: 0xCB/255, green: 0xD0/255, blue: 0xD2/255),
                Color(red: 0xE5/255, green: 0xE4/255, blue: 0xE2/255)
            ]
        }
    }
}
