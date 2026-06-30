import SwiftUI
import AVFoundation

// Full-screen "loading" state shown between the Generate tap and the
// results push. Plays loading.mp3 on loop + a steady haptic pulse,
// and renders the word "Curating" under the liquid-glass wiper shader.
//
// Tapping anywhere on the screen toggles a Liquid Glass back button
// so the user can cancel and return to the generate form. Cancellation
// just navigates back — the in-flight generation task is guarded on
// the receiving side (CreateDeckSheet) and silently drops its result.
struct CuratingView: View {
    let onCancel: () -> Void
    // Flipped to `true` by the parent when generation finishes; the
    // view then fades its visuals + audio volume to zero over
    // `fadeDuration` so the hand-off to the results screen feels softer
    // than a hard cut.
    @Binding var isFinishing: Bool

    @State private var loadingPlayer: AVAudioPlayer?
    @State private var fxTimer: Timer?
    @State private var lastHapticCycle: Int = -1
    @State private var showCancel = false
    @State private var contentOpacity: Double = 1
    @State private var audioFadeStart: Date?

    // Matches `sin(t * π/2)` in Shaders.metal: a full back-and-forth
    // wipe cycle is 4 seconds, with the brightness peak landing right
    // around phase = 1.0s (bar at the right edge, fully bright).
    private let cycleDuration: Double = 4.0
    private let peakPhase: Double = 1.0
    // Long enough for the audio to taper smoothly past hearing instead
    // of clipping at zero. `CreateDeckSheet`'s post-generation
    // `Task.sleep` must match this so the view stays mounted for the
    // full fade window.
    private let fadeDuration: Double = 0.5

    var body: some View {
        ZStack {
            Color.black
            Text("Curating")
                .font(.custom("PlayfairDisplay-Regular", size: 16))
                .tracking(-0.5)
                .foregroundStyle(.white)
        }
        .liquidGlassWiper()
        .opacity(contentOpacity)
        .overlay(alignment: .topLeading) {
            if showCancel {
                cancelButton
                    .padding(.leading, 16)
                    .padding(.top, 60)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                showCancel.toggle()
            }
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { startFX() }
        .onDisappear { stopFX() }
        .onChange(of: isFinishing) { _, finishing in
            if finishing { beginFadeOut() }
        }
    }

    private var cancelButton: some View {
        Button {
            Haptics.light()
            onCancel()
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    // Idempotent — stops any in-flight playback first so a re-entry
    // doesn't double up audio or haptic timers.
    private func startFX() {
        stopFX()

        // Re-assert the playback session before constructing the player.
        // The chat tab's auto-mic flips the session into `.playAndRecord`
        // / `.measurement` while it's active, and a previous `setActive`
        // may have left ducking flags in place — without this reset the
        // curating loop sometimes plays at very low volume (or not at
        // all) after the user has visited Conversations.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        if let url = Bundle.main.url(forResource: "loading", withExtension: "mp3"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            // Volume is driven by `fxTimer` to track the wiper's
            // brightness; start at the silent floor so the first audible
            // moment is the swell into the first peak rather than a
            // mid-volume blip.
            player.volume = 0
            player.prepareToPlay()
            player.play()
            loadingPlayer = player
        }

        // Initial light tap to mark the Generate press — independent of
        // the per-cycle peak haptic below.
        Haptics.light()

        // 30 Hz drives the volume envelope + the per-cycle peak haptic.
        // We key off absolute time (timeIntervalSinceReferenceDate) so
        // the phase here matches the shader's `time` parameter exactly,
        // keeping audio + haptics locked to the visual.
        fxTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0,
            repeats: true
        ) { _ in
            let absTime = Date().timeIntervalSinceReferenceDate
            let cycle = Int(floor(absTime / cycleDuration))
            let phase = absTime - Double(cycle) * cycleDuration

            let baseVolume = brightness(at: phase)
            // Quadratic ease-out: the fade starts at slope -2/fadeDuration
            // and decays to slope 0 at the end — perceived as a sharp
            // initial drop with a gentle tail, rather than a linear ramp
            // that flattens just before hitting zero.
            let fadeFactor: Double = {
                guard let start = audioFadeStart else { return 1.0 }
                let elapsed = Date().timeIntervalSince(start)
                let remaining = max(0, 1 - elapsed / fadeDuration)
                return remaining * remaining
            }()
            loadingPlayer?.volume = Float(baseVolume * fadeFactor)

            // One medium haptic per cycle, fired the first tick after
            // the right-bound brightness peak. The `< cycleDuration / 2`
            // bound keeps it inside the right-bound half so we never
            // accidentally double-pulse late in the cycle. Suppressed
            // during the exit fade so we don't ship a pulse the user
            // never sees a peak for.
            if phase >= peakPhase
                && phase < cycleDuration / 2
                && cycle != lastHapticCycle
                && audioFadeStart == nil {
                Haptics.medium()
                lastHapticCycle = cycle
            }
        }
    }

    // Kicks off the soft hand-off when the parent flips `isFinishing`.
    // Visuals fade with the SwiftUI animation; audio fades via the
    // `audioFadeStart` factor multiplied into the ongoing volume loop.
    private func beginFadeOut() {
        withAnimation(.easeOut(duration: fadeDuration)) {
            contentOpacity = 0
        }
        audioFadeStart = Date()
    }

    private func stopFX() {
        loadingPlayer?.stop()
        loadingPlayer = nil
        fxTimer?.invalidate()
        fxTimer = nil
        lastHapticCycle = -1
        audioFadeStart = nil
    }

    // Mirrors the shader's `lightI` envelope, normalized to [0, 1] so
    // it can be handed straight to AVAudioPlayer.volume. Peak (≈ 1.0)
    // happens when the wiper bar is at the right edge moving right;
    // trough (≈ 0.1) happens on the left-bound return.
    private func brightness(at phase: Double) -> Double {
        let wipePhase = phase * .pi / 2
        let velocity = cos(wipePhase)
        let blendToLeft = smoothstep(edge0: -0.20, edge1: 0.20, x: -velocity)
        let wipePos = sin(wipePhase) * 0.85 + 0.5
        let onScreen = min(1.0, max(0.0, wipePos))
        let brightRight = sqrt(onScreen)
        let brightLeft = onScreen * onScreen * 0.125
        let brightShape = brightRight * (1 - blendToLeft) + brightLeft * blendToLeft
        let returnSubtlety = 0.7 + (1 - blendToLeft) * 0.3
        let lightI = (0.40 + brightShape * 2.35) * returnSubtlety
        return min(1.0, max(0, lightI / 2.75))
    }

    private func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
