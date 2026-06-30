import Foundation
import AVFoundation

// Far-field conversation recorder for the Direct page's Conversation
// mode. Unlike the live close-mic dictation (SpeechRecognitionService,
// which streams short utterances and stops on silence), this records a
// full clip to a file first, then hands it off for file-based
// transcription. Recording-then-transcribing is what makes a phone-on-
// the-table, up-to-a-minute, two-person conversation actually work:
//
//   • `.record` category + `.default` mode keeps the system's automatic
//     gain control ON (the live dictation path uses `.measurement`,
//     which disables AGC and is why distant speech barely registers).
//   • Input gain is pushed to max when settable.
//   • A hard `maxDuration` cap auto-stops the clip.
//
// The captured `.m4a` then goes to SpeechRecognitionService.transcribeFile.
@Observable
@MainActor
final class ConversationRecorder: NSObject, AVAudioRecorderDelegate {

    var isRecording = false
    // Seconds elapsed in the current clip.
    var elapsed: TimeInterval = 0
    // Normalized 0…1 mic level for the meter UI.
    var level: Double = 0
    // Set when a clip finishes (manual stop OR auto-stop at maxDuration).
    // The view observes this to kick off transcription. Cleared on the
    // next start.
    var finishedURL: URL?

    let maxDuration: TimeInterval = 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    // MARK: - Control

    func start() throws {
        cleanupTimer()
        finishedURL = nil
        elapsed = 0
        level = 0

        let session = AVAudioSession.sharedInstance()
        // `.default` mode (not `.measurement`) keeps AGC + system audio
        // processing on, which dramatically helps distant/quiet speech.
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if session.isInputGainSettable {
            try? session.setInputGain(1.0)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true
        // Auto-stops at the cap; the delegate fires when it does.
        guard rec.record(forDuration: maxDuration) else {
            throw NSError(
                domain: "ConversationRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."]
            )
        }

        recorder = rec
        fileURL = url
        isRecording = true
        startTimer()
    }

    // Manual stop. The actual `finishedURL` is published from the
    // delegate callback so manual + auto stop share one code path.
    func stop() {
        recorder?.stop()
        cleanupTimer()
    }

    // Abort + delete the partial file (e.g. the user backed out).
    func cancel() {
        recorder?.delegate = nil
        recorder?.stop()
        cleanupTimer()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        fileURL = nil
        isRecording = false
        finishedURL = nil
        restorePlaybackSession()
    }

    // MARK: - Metering timer

    private func startTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        elapsed = rec.currentTime
        level = normalizedLevel(rec.averagePower(forChannel: 0))
    }

    // Maps an AVAudioRecorder dB power (-160…0) to a 0…1 bar. Floor at
    // -50 dB so room tone doesn't peg the meter, with a gentle curve.
    private func normalizedLevel(_ db: Float) -> Double {
        let floorDb: Float = -50
        guard db > floorDb else { return 0 }
        let normalized = (db - floorDb) / (0 - floorDb)  // 0…1 linear in dB
        return Double(min(1, max(0, pow(normalized, 1.5))))
    }

    private func cleanupTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            self.cleanupTimer()
            self.level = 0
            if flag {
                self.finishedURL = self.fileURL
            }
            self.restorePlaybackSession()
        }
    }

    // Restore the app's default playback session so save chimes / the
    // curating loop aren't left muted after a recording.
    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }
}
