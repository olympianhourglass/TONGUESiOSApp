import Foundation
import AVFoundation

@Observable
@MainActor
final class SpeechClient {
    static let shared = SpeechClient()

    private var player: AVAudioPlayer?
    private var activeTask: Task<Void, Never>?
    private var clearStatusTask: Task<Void, Never>?
    private let appleSynth = AVSpeechSynthesizer()
    private var appleDelegate: AppleSpeechDelegate?
    private var audioPlayerDelegate: AudioPlayerFinishDelegate?

    // Fired exactly once when the current utterance finishes playing on its own.
    // Cleared (without firing) when playback is superseded by a new speak() call
    // or stopped via stop(), so caller-driven cancellation doesn't trigger it.
    private var pendingCompletion: (() -> Void)?

    // Observed by views to draw a read-along highlight over the currently
    // spoken word. The range is into the exact text passed to `speak`.
    // nil means nothing is currently being read aloud via Apple TTS.
    var currentSpokenWordRange: NSRange?

    // Short transient label describing which engine just produced audio
    // (e.g. "iOS system voice", "Forvo native recording"). Consumed only by
    // views that opt in via `.speechStatusToast()`; auto-clears after a few
    // seconds.
    var statusMessage: String?

    private init() {
        let delegate = AppleSpeechDelegate(
            onWillSpeak: { [weak self] range in self?.currentSpokenWordRange = range },
            onCancel: { [weak self] in self?.currentSpokenWordRange = nil },
            onFinish: { [weak self] in
                self?.currentSpokenWordRange = nil
                self?.firePendingCompletion()
            }
        )
        appleDelegate = delegate
        appleSynth.delegate = delegate

        audioPlayerDelegate = AudioPlayerFinishDelegate { [weak self] in
            self?.firePendingCompletion()
        }
    }

    private func firePendingCompletion() {
        let handler = pendingCompletion
        pendingCompletion = nil
        handler?()
    }

    // `allowForvo` should only be passed for single-word lookups (deck rows,
    // flashcards). Forvo's library is per-word — passages and stories can't
    // be retrieved from it, so the multi-sentence "Read aloud" button leaves
    // this false.
    func speak(_ text: String, language: String? = nil, allowForvo: Bool = false, rate: Float = 1.0, onFinish: (() -> Void)? = nil) {
        // Strip emoji so they're never read aloud (or mispronounced as
        // their Unicode names) by any of the playback engines.
        let trimmed = text.strippingEmoji()
        guard !trimmed.isEmpty else {
            onFinish?()
            return
        }

        // Drop the previous handler before tearing down — it represents a
        // playback that's about to be superseded, not one that finished.
        pendingCompletion = nil
        activeTask?.cancel()
        player?.stop()
        appleSynth.stopSpeaking(at: .immediate)
        currentSpokenWordRange = nil
        pendingCompletion = onFinish

        // Tier 1: Apple TTS when iOS has an installed voice for the locale.
        if let language, Self.appleHasInstalledVoice(for: language) {
            emitStatus("iOS system voice (\(language))")
            speakWithApple(trimmed, language: language, rate: rate)
            return
        }

        // Tier 2: Forvo native-speaker recording for single-word lookups when
        // Apple has no installed voice for the language.
        if allowForvo,
           let language,
           let isoCode = languageISOCode(for: language) {
            let forvoKey = "forvo-\(MediaCache.shaKey("\(isoCode)|\(trimmed)"))"
            activeTask = Task { [weak self] in
                guard let self else { return }
                // Cache check first — skips both Forvo's API and the audio
                // download. Disk hits are instant; Firebase Storage hits
                // populate the disk cache on the way through.
                if let cached = await MediaCache.fetch(key: forvoKey) {
                    if Task.isCancelled { return }
                    self.emitStatus("Forvo cached (\(language))")
                    try? self.play(data: cached, rate: rate)
                    return
                }
                do {
                    guard let audioURL = try await ForvoClient.pronunciationURL(
                        word: trimmed,
                        languageCode: isoCode
                    ) else {
                        if Task.isCancelled { return }
                        self.emitStatus("No \(language) recording — system fallback")
                        self.speakWithApple(trimmed, language: language, rate: rate)
                        return
                    }
                    let (data, _) = try await URLSession.shared.data(from: audioURL)
                    if Task.isCancelled { return }
                    self.emitStatus("Forvo native recording (\(language))")
                    try self.play(data: data, rate: rate)
                    Task.detached { await MediaCache.store(data, key: forvoKey) }
                } catch {
                    if Self.isCancellationError(error) || Task.isCancelled { return }
                    print("Forvo error: \(error). Falling back to Apple TTS.")
                    self.emitStatus("Couldn't reach Forvo — system fallback")
                    self.speakWithApple(trimmed, language: language, rate: rate)
                }
            }
            return
        }

        // Final fallback: Apple TTS with whatever the system can muster.
        if let language {
            emitStatus("No \(language) voice on this device")
        } else {
            emitStatus("iOS system voice")
        }
        speakWithApple(trimmed, language: language, rate: rate)
    }

    // Public stop — used by ListenSessionView's pause control.
    func stop() {
        pendingCompletion = nil
        activeTask?.cancel()
        player?.stop()
        appleSynth.stopSpeaking(at: .immediate)
        currentSpokenWordRange = nil
    }

    // True while audio is actively being produced (Apple TTS, Forvo recording,
    // or ElevenLabs). Used by the listening session's breathing gradient.
    var isSpeaking: Bool {
        appleSynth.isSpeaking || (player?.isPlaying ?? false)
    }

    // Dedicated path for English translation playback. Tries ElevenLabs first
    // for a natural voice, then falls back to Apple TTS so onFinish still fires
    // even when the API key isn't set or the request fails.
    func speakElevenLabs(_ text: String, rate: Float = 1.0, onFinish: (() -> Void)? = nil) {
        let trimmed = text.strippingEmoji()
        guard !trimmed.isEmpty else {
            onFinish?()
            return
        }

        pendingCompletion = nil
        activeTask?.cancel()
        player?.stop()
        appleSynth.stopSpeaking(at: .immediate)
        currentSpokenWordRange = nil
        pendingCompletion = onFinish

        guard ElevenLabsClient.isConfigured else {
            emitStatus("ElevenLabs key missing — system English fallback")
            speakWithApple(trimmed, language: "English", rate: rate)
            return
        }

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await ElevenLabsClient.textToSpeech(trimmed)
                if Task.isCancelled { return }
                self.emitStatus("ElevenLabs voice")
                try self.play(data: data, rate: rate)
            } catch {
                // Cancellation race: a newer speak() superseded this one and
                // its .cancel() made URLSession throw. The new call already
                // owns playback — falling back to Apple here would double
                // up with the ElevenLabs audio the new task is about to play.
                if Self.isCancellationError(error) || Task.isCancelled { return }
                print("ElevenLabs error: \(error). Falling back to Apple TTS.")
                self.emitStatus("ElevenLabs unavailable — system fallback")
                self.speakWithApple(trimmed, language: "English", rate: rate)
            }
        }
    }

    // URLSession surfaces task cancellation as a URLError with code .cancelled,
    // not Swift's `CancellationError`. Treat both as cancellation so the
    // fallback path doesn't run when the caller already moved on.
    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        return false
    }

    private func emitStatus(_ message: String) {
        statusMessage = message
        clearStatusTask?.cancel()
        clearStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    private func play(data: Data, rate: Float = 1.0) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])

        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = audioPlayerDelegate
        if rate != 1.0 {
            newPlayer.enableRate = true
            newPlayer.rate = rate
        }
        newPlayer.prepareToPlay()
        newPlayer.play()
        player = newPlayer
    }

    private func speakWithApple(_ text: String, language: String?, rate: Float = 1.0) {
        let utterance = AVSpeechUtterance(string: text)
        if let language, let locale = appleSpeechLocale(for: language),
           let voice = AVSpeechSynthesisVoice(language: locale) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        appleSynth.speak(utterance)
    }

    // True when iOS has a synthesizer voice whose primary language code matches
    // the requested locale. Uses split-on-"-" to handle 2-letter (en-US) and
    // 3-letter (yue-HK, fil-PH, ceb-PH) language codes consistently.
    static func appleHasInstalledVoice(for language: String) -> Bool {
        guard let locale = appleSpeechLocale(for: language) else { return false }
        let primary = locale.split(separator: "-").first.map(String.init) ?? locale
        return AVSpeechSynthesisVoice.speechVoices().contains { voice in
            let voicePrimary = voice.language.split(separator: "-").first.map(String.init)
            return voicePrimary == primary
        }
    }
}

private final class AppleSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onWillSpeak: @MainActor (NSRange) -> Void
    let onCancel: @MainActor () -> Void
    let onFinish: @MainActor () -> Void

    init(
        onWillSpeak: @escaping @MainActor (NSRange) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.onWillSpeak = onWillSpeak
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onWillSpeak(characterRange) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onFinish() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onCancel() }
    }
}

private final class AudioPlayerFinishDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}
