import SwiftUI
import AVFoundation

struct SplashView: View {
    // First-launch flag — when true, the splash plays the startup chime,
    // grows the wordmark in lockstep, and buzzes the device, then calls
    // `onChimeFinished` so the app can route into onboarding. When false,
    // the splash is a static title card that the parent fades out on its
    // own 1.5s timer (legacy behavior).
    var isFirstLaunch: Bool = false
    var onChimeFinished: () -> Void = {}

    @State private var wordmarkScale: CGFloat = 1.0
    @State private var audioPlayer: AVAudioPlayer?
    @State private var hapticTimer: Timer?

    // Scale the wordmark starts at on first launch — tuned so growth is
    // perceptible without feeling like the text was hidden.
    private let initialScale: CGFloat = 0.6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Pre-rendered wordmark image with serifs baked into a
            // padded canvas — no glyph-edge clipping possible.
            TonguesWordmark(size: 32)
                .foregroundStyle(.white)
                .scaleEffect(wordmarkScale)
        }
        // Stay hidden across the launch → splash → chime handoff so the
        // status bar doesn't pop in over the black until the app proper
        // (onboarding or main tabs) renders.
        .statusBarHidden(true)
        .task {
            if isFirstLaunch {
                await playStartupChime()
            }
        }
        .onDisappear {
            hapticTimer?.invalidate()
            hapticTimer = nil
            audioPlayer?.stop()
        }
    }

    // Fallback runtime for the visual/haptic experience when the chime
    // audio can't load — so the first-launch ritual never silently skips
    // to onboarding.
    private let fallbackDuration: TimeInterval = 1.8

    @MainActor
    private func playStartupChime() async {
        // Try to load the chime, but never bail out of the splash sequence
        // if it fails — the wordmark animation + haptics are the heart of
        // the moment. The previous early-return on a nil player is what
        // presented as the chime being "skipped": on cold launch the
        // AVAudioPlayer occasionally fails to init before the audio
        // subsystem is fully warm, and we'd dismiss the splash instantly.
        let url = Bundle.main.url(forResource: "chime", withExtension: "mp3")
        let player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }

        // Re-assert the playback category — it was set in
        // `TONGUESApp.init()` already, but doing it again here is a cheap
        // safety net in case another part of the app has changed it.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        if let player {
            audioPlayer = player
            player.prepareToPlay()
        }

        // Drive the animation off the actual chime length when we have it,
        // otherwise fall back to a fixed duration so the visual swell still
        // lands gracefully.
        let duration = max(player?.duration ?? 0, fallbackDuration)

        // Wordmark starts small and grows to full size over the chime.
        wordmarkScale = initialScale
        withAnimation(.easeOut(duration: duration)) {
            wordmarkScale = 1.0
        }

        // Soft, well-spaced light pulses across the chime — sparse enough
        // to feel like a gentle breath rather than a jittery buzz.
        Haptics.light()
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { _ in
            Haptics.light()
        }

        // Tiny delay before playing helps cold-launch reliability — the
        // audio session is fully active by the time the head of the file
        // is requested.
        try? await Task.sleep(for: .milliseconds(80))
        if let player, !player.play() {
            print("⚠️ Startup chime player.play() returned false")
        }

        try? await Task.sleep(for: .seconds(duration))
        hapticTimer?.invalidate()
        hapticTimer = nil

        onChimeFinished()
    }
}
