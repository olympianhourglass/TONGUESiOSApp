import SwiftUI
import MediaPlayer
import AVFoundation

struct ListenSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument

    @State private var currentIndex = 0
    @State private var isPaused = false
    @State private var dragOffset: CGFloat = 0
    @State private var volume: Double = 0.08
    @State private var autoPlay = false
    @State private var advanceTask: Task<Void, Never>?
    @State private var chainTask: Task<Void, Never>?
    @State private var showOptions = false

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
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 10/255, green: 10/255, blue: 10/255), location: 0.0),
                        .init(color: Color(red: 83/255, green: 104/255, blue: 120/255), location: 0.167),
                        .init(color: Color(red: 229/255, green: 228/255, blue: 226/255), location: 0.5)
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
        .onAppear {
            // This view always has a dark radial backdrop, so its status
            // bar must read as white content no matter which surface
            // presented it — including a DeckDetailView reached from a
            // light-content tab like Explore. Force the light override on
            // (it wins over both the tab style and the dark override) and
            // re-run the runtime swap against the freshly-presented
            // fullScreenCover hosting controller.
            AppTabRouter.shared.forceLightStatusBar = true
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
        .onChange(of: isPaused) { _, _ in
            updateNowPlayingInfo()
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
                    Text("SKIP TO END")
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
                    Text("Options")
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
                Text(item.word)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 56))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(item.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: 22))
                    .foregroundStyle(.white.opacity(0.75))
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
                Text("Back")
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
                Text("Next")
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
                            allowForvo: true
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
                        onFinish: autoPlay ? { scheduleAutoAdvance() } : nil
                    )
                }
            }
        } else if readTranslation {
            SpeechClient.shared.speak(word, language: language, allowForvo: true, rate: rate) {
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
            var indices = Array(0..<deck.items.count)
            indices.shuffle()
            playOrder = indices
        } else {
            playOrder = Array(0..<deck.items.count)
        }
        // Preserve the currently-playing item by snapping currentIndex to its
        // new position in the reordered playOrder.
        if let newPos = playOrder.firstIndex(of: currentDeckIdx) {
            currentIndex = newPos
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
        Task {
            do {
                let sessionGrants = try await XPService.awardAudioSession(
                    deckId: deckId,
                    secondsListened: elapsed,
                    cardsAdvanced: advanced,
                    playlistCompleted: completed
                )
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

            VStack(alignment: .leading, spacing: 0) {
                Text("OPTIONS")
                    .font(.custom("NeueHaasDisplay-Black", size: 22))
                    .foregroundStyle(.white)
                    .padding(.top, 96)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    optionRow(
                        label: "Native language read out loud:",
                        isOn: readTranslation,
                        onYes: { readTranslation = true },
                        onNo: { readTranslation = false }
                    )

                    if readTranslation {
                        optionRow(
                            label: "Before or after translated text?",
                            firstTitle: "BEFORE",
                            secondTitle: "AFTER",
                            firstSelected: translationBefore,
                            onFirst: { translationOrderRaw = "before" },
                            onSecond: { translationOrderRaw = "after" }
                        )
                        .padding(.top, 32)
                    }

                    optionChoiceRow(
                        label: "Seconds between audio:",
                        options: [2, 4, 8],
                        selected: gapSeconds,
                        onSelect: { gapSeconds = $0 }
                    )
                    .padding(.top, 32)

                    optionRow(
                        label: "Turtle (2× slower):",
                        isOn: turtle,
                        onYes: { turtle = true },
                        onNo: { turtle = false }
                    )
                    .padding(.top, 32)
                }
                .offset(y: -32)

                Spacer(minLength: 0)

                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) { showOptions = false }
                } label: {
                    Text("Close")
                        .font(.custom("NeueHaasDisplay-Light", size: 16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    private func optionRow(
        label: String,
        isOn: Bool,
        onYes: @escaping () -> Void,
        onNo: @escaping () -> Void
    ) -> some View {
        optionRow(
            label: label,
            firstTitle: "YES",
            secondTitle: "NO",
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
