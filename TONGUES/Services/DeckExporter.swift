import Foundation
import AVFoundation

// Exports a deck to shareable files:
//  • Audio: synthesizes every item (foreign word, optionally the native
//    translation) into a single .m4a using Apple's on-device TTS, honoring
//    the same Listen-style options (read native, order, gap, slower).
//  • CSV: a basic two-column file (native, foreign).
//
// Audio is rendered fully offline via AVSpeechSynthesizer.write(...) into a
// PCM .caf, then encoded to .m4a with AVAssetExportSession.
enum DeckExporter {

    struct AudioSettings {
        var readNative: Bool = false
        var nativeBefore: Bool = false
        var gapSeconds: Int = 2
        var slower: Bool = false   // turtle: half speed
    }

    enum ExportError: LocalizedError {
        case empty
        case synthesisFailed
        case encodeFailed
        var errorDescription: String? {
            switch self {
            case .empty:           return "This deck has no words to export."
            case .synthesisFailed: return "Couldn't synthesize the audio."
            case .encodeFailed:    return "Couldn't encode the audio file."
            }
        }
    }

    // MARK: - CSV

    // Writes a basic CSV (native, foreign) to a temp file, returns its URL.
    static func makeCSV(for deck: DeckDocument) throws -> URL {
        var csv = "Native,Foreign\n"
        for item in deck.items {
            csv += "\(escapeCSV(item.translation)),\(escapeCSV(item.word))\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFileName(deck.title)).csv")
        try? FileManager.default.removeItem(at: url)
        try csv.data(using: .utf8)?.write(to: url)
        return url
    }

    private static func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: - Audio

    private struct Segment {
        let text: String
        let localeID: String?
    }

    // Renders the deck to an .m4a file and returns its URL. `onProgress`
    // reports 0…1 on the main actor as items are synthesized.
    static func makeAudio(
        for deck: DeckDocument,
        settings: AudioSettings,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        let foreignLocale = appleSpeechLocale(for: deck.language)
        let nativeLocale = "en-US"

        // Build the ordered list of spoken segments. Emoji are stripped so
        // they aren't read aloud.
        var segments: [Segment] = []
        for item in deck.items {
            let word = item.word.strippingEmoji()
            let native = item.translation.strippingEmoji()
            if settings.readNative, settings.nativeBefore, !native.isEmpty {
                segments.append(Segment(text: native, localeID: nativeLocale))
            }
            if !word.isEmpty {
                segments.append(Segment(text: word, localeID: foreignLocale))
            }
            if settings.readNative, !settings.nativeBefore, !native.isEmpty {
                segments.append(Segment(text: native, localeID: nativeLocale))
            }
        }
        guard !segments.isEmpty else { throw ExportError.empty }

        // Canonical PCM format we accumulate into.
        guard let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 22_050,
            channels: 1,
            interleaved: false
        ) else { throw ExportError.synthesisFailed }

        let cafURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-audio-\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: cafURL)
        let pcmFile = try AVAudioFile(
            forWriting: cafURL,
            settings: canonical.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let rate = AVSpeechUtteranceDefaultSpeechRate * (settings.slower ? 0.5 : 1.0)
        let synth = AVSpeechSynthesizer()
        let total = Double(segments.count)
        let silence = makeSilence(seconds: Double(settings.gapSeconds), format: canonical)

        for (index, seg) in segments.enumerated() {
            let buffers = try await render(seg, rate: rate, synth: synth)
            for buffer in buffers {
                let converted = try convert(buffer, to: canonical)
                try pcmFile.write(from: converted)
            }
            if let silence { try pcmFile.write(from: silence) }
            let progress = Double(index + 1) / total
            await MainActor.run { onProgress(progress) }
        }

        // Encode the PCM .caf → .m4a.
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFileName(deck.title)).m4a")
        try? FileManager.default.removeItem(at: m4aURL)
        try await encodeToM4A(from: cafURL, to: m4aURL)
        try? FileManager.default.removeItem(at: cafURL)
        return m4aURL
    }

    // Synthesizes one segment to PCM buffers via offline TTS rendering.
    private static func render(
        _ segment: Segment,
        rate: Float,
        synth: AVSpeechSynthesizer
    ) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: segment.text)
        if let id = segment.localeID, let voice = AVSpeechSynthesisVoice(language: id) {
            utterance.voice = voice
        }
        utterance.rate = rate

        return await withCheckedContinuation { (cont: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            var collected: [AVAudioPCMBuffer] = []
            var finished = false
            synth.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finished = true
                    cont.resume(returning: collected)
                } else if let copy = pcm.deepCopy() {
                    collected.append(copy)
                }
            }
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * (format.sampleRate / buffer.format.sampleRate)
                ) + 1024
              )
        else { throw ExportError.synthesisFailed }

        var error: NSError?
        var supplied = false
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }

    private static func makeSilence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(0, seconds) * format.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                memset(data[ch], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        return buffer
    }

    private static func encodeToM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ExportError.encodeFailed }
        session.outputURL = destination
        session.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? ExportError.encodeFailed
        }
    }

    // MARK: - Helpers

    private static func safeFileName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Deck" : cleaned
    }
}

private extension AVAudioPCMBuffer {
    // Deep-copies the buffer — the TTS callback reuses its buffer, so we
    // must copy frames out before the next callback overwrites them.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size) }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size) }
        }
        return copy
    }
}
