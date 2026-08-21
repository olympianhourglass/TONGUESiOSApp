import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

struct ListenSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument

    // Hardware-keyboard transport (iPad/Mac): ← acts as Back, → as Next. A
    // focusable container receives the key presses.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var keyboardNavFocused: Bool

    @State private var currentIndex = 0
    @State private var isPaused = false
    @State private var dragOffset: CGFloat = 0
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
        guard currentIndex >= 0, currentIndex < playOrder.count else { return nil }
        let deckIdx = playOrder[currentIndex]
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
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
        .ignoresSafeArea()
        .overlay {
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
        }
        .presentationBackground(.clear)
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

                    // Otherwise treat as swipe-down-to-dismiss.
                    if v > 120 || pv > 220 {
                        Haptics.light()
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        // Re-classes the status bar to white once the full-screen cover's
        // hosting controller is actually on screen — reliable where the
        // onAppear timing passes below can miss the freshly-presented
        // controller (e.g. when opened from a pushed DeckDetailView).
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
            // fullScreenCover hosting controller.
            AppTabRouter.shared.forceLightStatusBar = true
            // The flag's didSet installs the swap immediately, but the
            // fullScreenCover's hosting controller often isn't in the
            // window hierarchy yet at onAppear, so that first pass can
            // miss it and the bar stays dark. Re-assert on the next
            // runloop and again once the present animation has settled so
            // the presented controller is reliably re-classed to white.
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
            configureRemoteCommands()
            updateNowPlayingInfo()
            playCurrent()
            // Resume any previously-chosen ambient tracks, layered under
            // the study audio.
            ambient.set(ambientSoundId, for: .sound)
            ambient.set(ambientMusicId, for: .music)
            // Take focus so the ← / → keys drive transport immediately.
            if supportsArrowKeyNav {
                keyboardNavFocused = true
            }
        }
        .onDisappear {
            // Release the white-bar override so the presenter (a tab or
            // DeckDetailView) reclaims its own status-bar style. That view's
            // own onChange/onDisappear then restores the correct bar.
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
        .overlay {
            if showOptions {
                optionsPanel
                    .transition(.opacity)
            }
        }
    }

    // MARK: Sections

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    dismiss()
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
                    dismiss()
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
            dismiss()
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
