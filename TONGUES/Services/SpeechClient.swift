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
    // Drives the read-along word highlight during ElevenLabs playback (Apple
    // TTS uses its own willSpeakRange delegate instead). Cancelled whenever
    // playback is stopped or superseded.
    private var highlightTask: Task<Void, Never>?

    // Fired exactly once when the current utterance finishes playing on its own.
    // Cleared (without firing) when playback is superseded by a new speak() call
    // or stopped via stop(), so caller-driven cancellation doesn't trigger it.
    private var pendingCompletion: (() -> Void)?

    // Observed by views to draw a read-along highlight over the currently
    // spoken word. The range is into the exact text passed to `speak`. Set by
    // Apple TTS's willSpeakRange delegate, or — for ElevenLabs playback with
    // `highlightPassage` — driven from the clip's character timestamps. nil
    // means nothing is currently being read aloud.
    var currentSpokenWordRange: NSRange?

    // Short transient label describing which engine just produced audio
    // (e.g. "iOS system voice", "Forvo native recording"). Consumed only by
    // views that opt in via `.speechStatusToast()`; auto-clears after a few
    // seconds.
    var statusMessage: String?

    // Details of the most recent playback, surfaced by the audio-source chip's
    // audit sheet: it shows the engine/voice and, for ElevenLabs, offers a
    // regenerate. Set at every play point.
    struct SpokenAudioInfo: Equatable {
        enum Engine: String { case elevenLabs, forvo, apple }
        let text: String
        let language: String?
        let engine: Engine
        let voiceID: String?   // ElevenLabs voice id; nil for Forvo / Apple
    }
    var lastSpoken: SpokenAudioInfo?

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
    // `highlightPassage` requests a read-along word highlight for long-form
    // playback ("Read aloud"): Apple TTS drives it via its willSpeakRange
    // delegate, ElevenLabs via the clip's character timestamps. Single-word
    // playback leaves it false (no highlight needed, and it avoids paying for
    // timestamps on cheap short clips).
    // `pronunciation` is a Latin-script romanization of `text`, used as a
    // last-resort spoken form when NO engine can pronounce the target language
    // (e.g. Mongolian: no ElevenLabs voice, no Forvo recording, no installed
    // Apple voice). Reading the romanization with the default voice at least
    // approximates the sound instead of falling silent.
    func speak(_ text: String, language: String? = nil, allowForvo: Bool = false, rate: Float = 1.0, highlightPassage: Bool = false, pronunciation: String? = nil, onFinish: (() -> Void)? = nil) {
        // Strip emoji so they're never read aloud (or mispronounced as
        // their Unicode names) by any of the playback engines.
        let trimmed = text.strippingEmoji()
        let pron = pronunciation?.strippingEmoji()
        guard !trimmed.isEmpty else {
            onFinish?()
            return
        }

        // Drop the previous handler before tearing down — it represents a
        // playback that's about to be superseded, not one that finished.
        pendingCompletion = nil
        activeTask?.cancel()
        highlightTask?.cancel()
        player?.stop()
        appleSynth.stopSpeaking(at: .immediate)
        currentSpokenWordRange = nil
        pendingCompletion = onFinish

        // Preferred tier: ElevenLabs speaking the TARGET language in a native
        // voice. English uses Rachel; other languages resolve a native voice
        // from the shared Voice Library. Any failure (no key, no native voice
        // found, API/playback error) falls through to the Apple/Forvo tiers,
        // so this only ever upgrades quality — it never removes a fallback.
        if let language, ElevenLabsClient.isConfigured {
            activeTask = Task { [weak self] in
                guard let self else { return }
                if highlightPassage {
                    // Read-aloud: fetch audio + character timestamps so the
                    // native voice gets the same karaoke highlight Apple TTS
                    // produces on the fallback path.
                    if let result = await self.nativeElevenLabsTimestamped(for: trimmed, language: language) {
                        if Task.isCancelled { return }
                        let audio = await Self.loudnessNormalizedAudio(result.audio)
                        if Task.isCancelled { return }
                        self.emitStatus("ElevenLabs native voice (\(language))")
                        do {
                            try self.playWithAlignment(audio: audio, alignment: result.alignment, text: trimmed, rate: rate)
                            return
                        } catch {
                            // Playback failed — drop to the classic tiers below.
                        }
                    }
                } else if let data = await self.nativeElevenLabsData(for: trimmed, language: language) {
                    if Task.isCancelled { return }
                    let audio = await Self.loudnessNormalizedAudio(data)
                    if Task.isCancelled { return }
                    self.emitStatus("ElevenLabs native voice (\(language))")
                    do {
                        try self.play(data: audio, rate: rate)
                        return
                    } catch {
                        // Playback failed — drop to the classic tiers below.
                    }
                }
                if Task.isCancelled { return }
                self.fallbackSpeak(trimmed, language: language, allowForvo: allowForvo, rate: rate, pronunciation: pron)
            }
            return
        }

        fallbackSpeak(trimmed, language: language, allowForvo: allowForvo, rate: rate, pronunciation: pron)
    }

    // The original Apple-TTS / Forvo tier ladder, used when ElevenLabs isn't
    // configured or its native-voice attempt fails. Assumes `speak` has
    // already torn down any in-flight playback and set `pendingCompletion`.
    private func fallbackSpeak(_ trimmed: String, language: String?, allowForvo: Bool, rate: Float, pronunciation: String? = nil) {
        // Preferred fallback: Forvo native-speaker recording (single-word
        // lookups only) — a real human voice, so it's chosen over Apple TTS.
        // On a miss or error the Forvo task itself drops to Apple TTS. This is
        // the ElevenLabs → Forvo → Apple ladder (ElevenLabs was already tried
        // in `speak`; passages skip Forvo since it's word-only).
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
                    self.lastSpoken = SpokenAudioInfo(text: trimmed, language: language, engine: .forvo, voiceID: nil)
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
                        self.speakWithApple(trimmed, language: language, rate: rate, pronunciation: pronunciation)
                        return
                    }
                    let (data, _) = try await URLSession.shared.data(from: audioURL)
                    if Task.isCancelled { return }
                    self.emitStatus("Forvo native recording (\(language))")
                    self.lastSpoken = SpokenAudioInfo(text: trimmed, language: language, engine: .forvo, voiceID: nil)
                    try self.play(data: data, rate: rate)
                    Task.detached { await MediaCache.store(data, key: forvoKey) }
                } catch {
                    if Self.isCancellationError(error) || Task.isCancelled { return }
                    print("Forvo error: \(error). Falling back to Apple TTS.")
                    self.emitStatus("Couldn't reach Forvo — system fallback")
                    self.speakWithApple(trimmed, language: language, rate: rate, pronunciation: pronunciation)
                }
            }
            return
        }

        // Apple TTS — reached for passages (no Forvo), an unresolved language
        // code, or a language for which Forvo had no recording (that miss is
        // handled inside the Forvo task above).
        if let language, Self.appleHasInstalledVoice(for: language) {
            emitStatus("iOS system voice (\(language))")
        } else if let language {
            emitStatus("No \(language) voice on this device")
        } else {
            emitStatus("iOS system voice")
        }
        speakWithApple(trimmed, language: language, rate: rate, pronunciation: pronunciation)
    }

    // Resolves and fetches ElevenLabs audio for the target language in a
    // native voice. English maps to Rachel; other languages look up a native
    // voice from the shared library (cached after first use). Returns nil when
    // no native voice can be resolved — deliberately, so foreign text is never
    // read in an English voice; the caller then falls back to Apple/Forvo.
    private func nativeElevenLabsData(for text: String, language: String) async -> Data? {
        guard let iso = languageISOCode(for: language) else { return nil }
        let voiceId: String?
        if iso.lowercased() == "en" {
            voiceId = ElevenLabsClient.defaultVoiceId
        } else {
            voiceId = await ElevenLabsClient.nativeVoiceId(forLanguageCode: iso)
        }
        guard let voiceId else { return nil }
        guard let data = try? await ElevenLabsClient.textToSpeech(
            text,
            voiceId: voiceId,
            onCacheMiss: Self.ttsBudgetGate
        ) else { return nil }
        lastSpoken = SpokenAudioInfo(text: text, language: language, engine: .elevenLabs, voiceID: voiceId)
        return data
    }

    // Same resolution as `nativeElevenLabsData`, but fetches the audio WITH
    // character timestamps so the caller can render a karaoke highlight.
    private func nativeElevenLabsTimestamped(for text: String, language: String) async -> ElevenLabsClient.TimestampedSpeech? {
        guard let iso = languageISOCode(for: language) else { return nil }
        let voiceId: String?
        if iso.lowercased() == "en" {
            voiceId = ElevenLabsClient.defaultVoiceId
        } else {
            voiceId = await ElevenLabsClient.nativeVoiceId(forLanguageCode: iso)
        }
        guard let voiceId else { return nil }
        guard let result = try? await ElevenLabsClient.textToSpeechWithTimestamps(
            text,
            voiceId: voiceId,
            onCacheMiss: Self.ttsBudgetGate
        ) else { return nil }
        lastSpoken = SpokenAudioInfo(text: text, language: language, engine: .elevenLabs, voiceID: voiceId)
        return result
    }

    // Regenerates a fresh ElevenLabs take of the last-spoken audio and
    // overwrites the cached version (so future plays use the corrected one),
    // then plays it. No-op unless the last playback was ElevenLabs.
    func regenerateLastElevenLabs() async {
        guard let info = lastSpoken, info.engine == .elevenLabs, let voiceId = info.voiceID else { return }
        do {
            let data = try await ElevenLabsClient.regenerate(
                info.text,
                voiceId: voiceId,
                onCacheMiss: Self.ttsBudgetGate
            )
            let audio = await Self.loudnessNormalizedAudio(data)
            try play(data: audio, rate: 1.0)
            emitStatus("ElevenLabs voice — regenerated")
        } catch {
            print("ElevenLabs regenerate failed: \(error)")
            emitStatus("Couldn't regenerate voice")
        }
    }

    // Budget gate handed to ElevenLabs on a cache miss: reserves the
    // characters against the user's monthly TTS budget and returns whether
    // the generation is allowed. Out-of-budget → false → the caller falls
    // back to Apple's on-device voice. Cache hits never invoke this.
    private static let ttsBudgetGate: @Sendable (Int) async -> Bool = { chars in
        await SubscriptionService.shared.reserveTTSCharactersIfAffordable(chars)
    }

    // Public stop — used by ListenSessionView's pause control.
    func stop() {
        pendingCompletion = nil
        activeTask?.cancel()
        highlightTask?.cancel()
        player?.stop()
        appleSynth.stopSpeaking(at: .immediate)
        currentSpokenWordRange = nil
    }

    // True while audio is actively being produced (Apple TTS, Forvo recording,
    // or ElevenLabs). Used by the listening session's breathing gradient.
    var isSpeaking: Bool {
        appleSynth.isSpeaking || (player?.isPlaying ?? false)
    }

    // Dedicated path for native-language translation playback. For English
    // it uses ElevenLabs (a natural voice) with an Apple-TTS fallback. For any
    // other native language, ElevenLabs here is the English-only monolingual
    // model — which would mispronounce — so we route straight to Apple TTS in
    // the native language for correct pronunciation.
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

        let native = AppLanguage.currentNative
        guard native == .en else {
            // Native-language audio via Apple TTS in that language.
            emitStatus("\(native.speechLanguageName) voice")
            speakWithApple(trimmed, language: native.speechLanguageName, rate: rate)
            return
        }

        guard ElevenLabsClient.isConfigured else {
            emitStatus("ElevenLabs key missing — system English fallback")
            speakWithApple(trimmed, language: "English", rate: rate)
            return
        }

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await ElevenLabsClient.textToSpeech(
                    trimmed,
                    onCacheMiss: Self.ttsBudgetGate
                )
                if Task.isCancelled { return }
                let audio = await Self.loudnessNormalizedAudio(data)
                if Task.isCancelled { return }
                self.emitStatus("ElevenLabs voice")
                try self.play(data: audio, rate: rate)
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

    // MARK: - ElevenLabs loudness normalization
    //
    // ElevenLabs clips come back at inconsistent (and often low) levels, so a
    // native voice can get buried under an ambient soundscape. We normalize
    // every ElevenLabs clip to a FIXED target loudness the moment it arrives:
    // this makes all native-voice playback the same level app-wide AND loud
    // enough to sit over the soundscapes. Forvo/Apple paths never call this.

    // Linear-amplitude (0...1) targets. `nonisolated` so the off-main-actor
    // normalizer can read them.
    nonisolated private static let targetPeak: Float = 0.97   // ceiling - keep just under clipping
    nonisolated private static let targetRMS: Float = 0.16    // ~-16 dBFS, a healthy speech level
    nonisolated private static let maxBoost: Float = 8.0       // don't amplify a near-silent clip into hiss

    // Async wrapper that runs the (CPU-bound) normalize off the main actor and
    // always yields playable audio — the original clip if anything goes wrong.
    nonisolated static func loudnessNormalizedAudio(_ data: Data) async -> Data {
        await Task.detached(priority: .userInitiated) {
            loudnessNormalized(data) ?? data
        }.value
    }

    // Peak+RMS normalize one ElevenLabs MP3. Decodes to PCM, computes a gain to
    // reach `targetRMS` (capped by `targetPeak` so it never clips and by
    // `maxBoost` so silence isn't over-amplified), applies it, and re-encodes to
    // 16-bit PCM (CAF) that AVAudioPlayer plays directly — duration and sample
    // rate are preserved, so the read-along timestamp highlight stays in sync.
    // Returns nil (→ caller plays the original) if decoding fails or the clip is
    // already at target.
    nonisolated private static func loudnessNormalized(_ mp3: Data) -> Data? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let inURL = dir.appendingPathComponent("ll-\(UUID().uuidString).mp3")
        let outURL = dir.appendingPathComponent("ll-\(UUID().uuidString).caf")
        defer {
            try? fm.removeItem(at: inURL)
            try? fm.removeItem(at: outURL)
        }

        do {
            try mp3.write(to: inURL)
            let inFile = try AVAudioFile(forReading: inURL)
            let format = inFile.processingFormat   // float32, deinterleaved
            let frameCount = AVAudioFrameCount(inFile.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }
            try inFile.read(into: buffer)
            guard let channels = buffer.floatChannelData else { return nil }
            let channelCount = Int(format.channelCount)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return nil }

            // Peak amplitude and RMS across every channel.
            var peak: Float = 0
            var sumSquares: Double = 0
            for c in 0..<channelCount {
                let samples = channels[c]
                for i in 0..<frames {
                    let v = samples[i]
                    let a = abs(v)
                    if a > peak { peak = a }
                    sumSquares += Double(v) * Double(v)
                }
            }
            guard peak > 0 else { return nil }
            let rms = Float(sqrt(sumSquares / Double(frames * channelCount)))
            guard rms > 0 else { return nil }

            // Aim for target RMS, but never push the loudest peak past the
            // ceiling and never boost more than maxBoost.
            let gain = min(targetRMS / rms, targetPeak / peak, maxBoost)
            // Already essentially at target — skip the re-encode round trip.
            guard abs(gain - 1) >= 0.05 else { return nil }

            for c in 0..<channelCount {
                let samples = channels[c]
                for i in 0..<frames {
                    // Peak-limited gain, plus a hard clamp against float slop.
                    samples[i] = max(-1, min(1, samples[i] * gain))
                }
            }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            var outFile: AVAudioFile? = try AVAudioFile(forWriting: outURL, settings: settings)
            try outFile?.write(from: buffer)
            outFile = nil   // dealloc flushes/closes the file before we read it back

            return try Data(contentsOf: outURL)
        } catch {
            print("ElevenLabs loudness normalize failed: \(error)")
            return nil
        }
    }

    private func play(data: Data, rate: Float = 1.0) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        } catch {
            // The speech recognizer leaves the session active in
            // `.playAndRecord`/`.measurement` (its stop() doesn't deactivate
            // it), which can reject the switch to `.playback` — the failure
            // that was dropping ElevenLabs playback to Apple TTS. Deactivate
            // and retry so the native voice actually plays.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        }

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

    // Plays ElevenLabs audio and drives `currentSpokenWordRange` from the
    // clip's character timestamps, so the read-along highlight tracks the
    // native voice the same way it tracks Apple TTS. `text` is the exact
    // (emoji-stripped) string passed to `speak`, so the ranges line up with
    // what the view renders.
    private func playWithAlignment(
        audio: Data,
        alignment: ElevenLabsClient.SpeechAlignment?,
        text: String,
        rate: Float
    ) throws {
        try play(data: audio, rate: rate)   // sets `player`, starts playback

        highlightTask?.cancel()
        guard let alignment, !alignment.characters.isEmpty else {
            currentSpokenWordRange = nil
            return
        }

        // Word ranges into `text` (locale-aware, so spaced languages break on
        // words and CJK on characters). The alignment's characters concatenate
        // to the whitespace-trimmed text ElevenLabs spoke, so shift character
        // offsets past any leading whitespace to land back in `text`.
        let words = Self.wordRanges(in: text)
        let leadingWS = text.prefix { $0.isWhitespace || $0.isNewline }.utf16.count
        var charOffsets: [Int] = []
        charOffsets.reserveCapacity(alignment.characters.count)
        var acc = leadingWS
        for ch in alignment.characters {
            charOffsets.append(acc)
            acc += ch.utf16.count
        }
        let startTimes = alignment.startTimesSeconds

        highlightTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, player.isPlaying else { break }
                let t = player.currentTime
                if let idx = Self.lastIndex(of: startTimes, notAfter: t), idx < charOffsets.count {
                    let range = Self.word(in: words, containingUTF16: charOffsets[idx])
                    if self.currentSpokenWordRange != range {
                        self.currentSpokenWordRange = range
                    }
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            if !Task.isCancelled { self?.currentSpokenWordRange = nil }
        }
    }

    // Locale-aware word ranges (UTF-16) for the read-along highlight.
    private static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .localized]) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        if ranges.isEmpty {
            let length = (text as NSString).length
            if length > 0 { ranges.append(NSRange(location: 0, length: length)) }
        }
        return ranges
    }

    // The word range containing `offset`, or the next word after it (so a
    // space/punctuation gap snaps the highlight forward), or the last word.
    private static func word(in words: [NSRange], containingUTF16 offset: Int) -> NSRange? {
        for r in words {
            if offset >= r.location && offset < r.location + r.length { return r }
            if offset < r.location { return r }
        }
        return words.last
    }

    // Rightmost index into the nondecreasing `times` whose value is <= `t`.
    private static func lastIndex(of times: [Double], notAfter t: Double) -> Int? {
        var lo = 0, hi = times.count - 1, ans: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    private func speakWithApple(_ text: String, language: String?, rate: Float = 1.0, pronunciation: String? = nil) {
        let voice: AVSpeechSynthesisVoice? = {
            guard let language, let locale = appleSpeechLocale(for: language) else { return nil }
            return AVSpeechSynthesisVoice(language: locale)
        }()

        // With no installed voice for the language (e.g. Mongolian), the
        // default voice can't pronounce the native script — it just falls
        // silent. If we have a Latin-script romanization, speak THAT instead so
        // there's still an audible approximation of the pronunciation.
        let spoken: String
        if voice == nil, let pronunciation, !pronunciation.isEmpty {
            spoken = pronunciation
        } else {
            spoken = text
        }

        let utterance = AVSpeechUtterance(string: spoken)
        if let voice {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        lastSpoken = SpokenAudioInfo(text: text, language: language, engine: .apple, voiceID: nil)
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
