import Foundation
import Speech
import AVFoundation

// On-device speech-to-text for the conversation tab's voice input.
// Apple's Speech framework recognizes in the locale you pass in — we
// thread the deck's BCP-47 locale through so French audio is parsed
// with French phonotactics, etc.
//
// Lifecycle:
//   requestAuthorization() → start(locale:) → (recognized text streams
//   into `transcript`) → stop() → caller reads the final value.
//
// We avoid keeping the engine alive between sessions: each .start
// builds a fresh AudioEngine + AudioBufferRecognitionRequest so a
// half-finished previous session can never leak into the next.
@Observable
@MainActor
final class SpeechRecognitionService {
    static let shared = SpeechRecognitionService()

    // Latest transcript so far — partial during a session, final after
    // .stop. SwiftUI observes this directly.
    var transcript: String = ""
    var isRecording = false
    var lastError: String?
    // URL of the captured audio for the most recent session. Lives in
    // the temporary directory; cleared on the next .start. Observed
    // by the drill sheet so it can offer "play back your attempt".
    var lastRecordingURL: URL?

    // Fires exactly once per session when sustained silence is
    // detected after the user has actually spoken. The caller sets
    // this before calling .start; we clear it after firing so the
    // closure doesn't trip again from a stray late buffer.
    var onSilenceDetected: (@MainActor () -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var audioFile: AVAudioFile?

    // Silence-detection state. `hasHeardVoice` flips true the first
    // time we see a buffer above `silenceThresholdDb`; only after that
    // do we start the silence timer so an early auto-stop can never
    // chop the user before they've started speaking.
    private var hasHeardVoice = false
    private var lastVoiceTime: Date?
    private var didFireSilence = false
    private let silenceThresholdDb: Float = -40
    // How long a trailing quiet stretch must last before an utterance is
    // considered finished. Per-session: the conversation auto-mic wants
    // this snappy (1.6s); the pronunciation drill sets it higher so a
    // mid-sentence breath or pause doesn't cut the learner off.
    private var silenceTimeout: TimeInterval = 1.6

    private init() {}

    // MARK: - Authorization

    enum AuthorizationStatus {
        case authorized
        case denied
        case undetermined
        case restricted
    }

    static func currentAuthorization() -> AuthorizationStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .undetermined
        @unknown default:    return .undetermined
        }
    }

    @discardableResult
    static func requestAuthorization() async -> AuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<AuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:    cont.resume(returning: .authorized)
                case .denied:        cont.resume(returning: .denied)
                case .restricted:    cont.resume(returning: .restricted)
                case .notDetermined: cont.resume(returning: .undetermined)
                @unknown default:    cont.resume(returning: .undetermined)
                }
            }
        }
    }

    // MARK: - File transcription (Conversation mode)

    // Transcribes a recorded audio file in one shot via
    // SFSpeechURLRecognitionRequest. File-based recognition is the right
    // tool for a recorded conversation: it handles the full clip at once
    // (no live silence-stop chopping it short) and, with
    // `requiresOnDeviceRecognition = false`, uses Apple's server model
    // for better accuracy on distant / multi-speaker audio.
    //
    // `locale` is a BCP-47 string from `appleSpeechLocale(for:)`. Returns
    // the final transcript; throws on auth failure, unavailable
    // recognizer, or recognition error.
    static func transcribeFile(at url: URL, locale: String) async throws -> String {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            throw NSError(
                domain: "SpeechRecognition", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Enable Speech Recognition for TONGUES in Settings."]
            )
        }
        let resolved = SFSpeechRecognizer(locale: Locale(identifier: locale)) ?? SFSpeechRecognizer()
        guard let recognizer = resolved, recognizer.isAvailable else {
            throw NSError(
                domain: "SpeechRecognition", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available for \(locale) right now."]
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let box = FileTranscriptionBox()
        return try await withCheckedThrowingContinuation { cont in
            box.attach(cont)
            // Retain the task in the box so it isn't deallocated (which
            // would silently cancel recognition) before it completes.
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.fail(error)
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    box.succeed(result.bestTranscription.formattedString)
                }
            }
        }
    }

    // MARK: - Session control

    // Begins listening. `locale` is a BCP-47 string from
    // `appleSpeechLocale(for:)` (e.g. "fr-FR", "ja-JP"). Throws if the
    // recognizer can't initialize for the locale or the audio engine
    // refuses to start.
    func start(locale: String, silenceTimeout: TimeInterval = 1.6) throws {
        stop()
        transcript = ""
        lastError = nil
        hasHeardVoice = false
        lastVoiceTime = nil
        didFireSilence = false
        self.silenceTimeout = silenceTimeout

        let resolved = SFSpeechRecognizer(locale: Locale(identifier: locale))
            ?? SFSpeechRecognizer()
        guard let recognizer = resolved, recognizer.isAvailable else {
            throw NSError(
                domain: "SpeechRecognition",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Speech recognition isn't available for \(locale) right now."
                ]
            )
        }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)

        // Spin up a fresh capture file alongside the recognition
        // request so the drill sheet can play the attempt back to the
        // user. .caf because it can hold the engine's native format
        // without re-encoding.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pronunciation-\(UUID().uuidString).caf")
        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            lastRecordingURL = fileURL
        } catch {
            // Non-fatal: we still get STT, just no replay.
            audioFile = nil
            lastRecordingURL = nil
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { [weak self] buffer, _ in
            // Recognition path.
            request.append(buffer)
            // Capture path.
            try? self?.audioFile?.write(from: buffer)
            // Silence-detection path.
            self?.evaluateLevel(of: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.transcript = text }
            }
            if let error {
                Task { @MainActor in
                    self.lastError = error.localizedDescription
                    self.stop()
                }
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioFile = nil
        isRecording = false
        // Don't deactivate the audio session here. Doing so caused
        // downstream AVAudioPlayer-based sound effects (curating loop,
        // chime, save confirmations) to fall silent or play at very
        // low volume when the user came back from the chat tab — the
        // session was left torn down while the rest of the app still
        // expected `.playback` to be live. Stopping the engine + tap
        // is enough to release the mic; sound-effect callers
        // re-assert `.playback` on their own before playing.
    }

    // MARK: - Silence detection

    // Called from the tap closure on every captured buffer. Computes
    // RMS-derived dB; flips `hasHeardVoice` once the user starts
    // speaking; auto-fires `onSilenceDetected` once `silenceTimeout`
    // worth of quiet trails their utterance.
    nonisolated private func evaluateLevel(of buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 1e-7))

        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            if db > self.silenceThresholdDb {
                self.hasHeardVoice = true
                self.lastVoiceTime = now
                return
            }
            guard self.hasHeardVoice,
                  !self.didFireSilence,
                  let last = self.lastVoiceTime,
                  now.timeIntervalSince(last) > self.silenceTimeout
            else { return }
            self.didFireSilence = true
            let handler = self.onSilenceDetected
            self.onSilenceDetected = nil
            handler?()
        }
    }
}

// Guards a CheckedContinuation so the recognition callback (which can
// fire multiple times) resumes it exactly once, and retains the
// SFSpeechRecognitionTask for its lifetime. `@unchecked Sendable`: all
// mutable state is serialized behind the lock.
private final class FileTranscriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var cont: CheckedContinuation<String, Error>?
    var task: SFSpeechRecognitionTask?

    func attach(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        cont = continuation
    }

    func succeed(_ text: String) {
        finish { $0.resume(returning: text) }
    }

    func fail(_ error: Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ body: (CheckedContinuation<String, Error>) -> Void) {
        lock.lock()
        guard !resumed, let continuation = cont else { lock.unlock(); return }
        resumed = true
        cont = nil
        task = nil
        lock.unlock()
        body(continuation)
    }
}
