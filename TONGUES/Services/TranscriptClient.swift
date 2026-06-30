import Foundation

// Transcript fetcher backed by Supadata (https://supadata.ai).
//
// Supadata takes a media URL (YouTube, TikTok, Instagram, X, or a direct
// file URL) and returns its transcript — pulling existing captions when
// available and falling back to its own speech-to-text when they aren't.
// That ASR fallback is why this covers far more than caption scraping:
// even a music video with captions disabled can come back with real
// lyrics.
//
// HOW IT'S WIRED: `DeckGenerator.extractFromMediaLink` calls this FIRST.
// A real transcript → Claude translates + ranks those verbatim words.
// nil (unsupported link, no transcript, provider error) → the caller
// silently falls back to the model-knowledge recall path. So this stays
// optional infrastructure: the feature degrades, never breaks.
enum TranscriptClient {

    // MARK: - Configuration

    private static let apiKey = Secrets.supadataAPIKey
    private static let baseURL = "https://api.supadata.ai/v1/transcript"
    private static let apiKeyHeader = "x-api-key"

    static var isConfigured: Bool { !apiKey.isEmpty }

    // Polling budget for Supadata's async path (used for long media that
    // needs server-side transcription). Short songs/videos return
    // synchronously and never hit this.
    private static let maxPollAttempts = 20
    private static let pollIntervalNanos: UInt64 = 1_500_000_000  // 1.5s

    // MARK: - Result + errors

    struct TranscriptResult {
        let text: String
        let detectedLanguage: String?  // BCP-47 code from Supadata, e.g. "es"
        let title: String?             // Supadata's transcript endpoint omits this → nil
    }

    enum TranscriptError: LocalizedError {
        case notConfigured
        case http(Int)
        case provider(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConfigured:   return "Transcript provider isn't configured."
            case .http(let code):  return "Transcript provider returned HTTP \(code)."
            case .provider(let m): return m
            case .timedOut:        return "Transcript took too long to generate."
            }
        }
    }

    // MARK: - Public API

    // Returns a transcript for the given media URL, or nil when the
    // caller should fall back to model recall (unconfigured, non-URL
    // input, unsupported link, or no transcript). Throws only on hard
    // failures the caller may want to log; `extractFromMediaLink` wraps
    // this in `try?` so a throw also degrades to the fallback.
    static func fetchTranscript(forURL urlString: String) async throws -> TranscriptResult? {
        guard isConfigured else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http") else { return nil }

        guard var components = URLComponents(string: baseURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: trimmed),
            // Plain text rather than timestamped cue chunks.
            URLQueryItem(name: "text", value: "true")
        ]
        guard let url = components.url else { return nil }

        let payload = try await get(url)

        // Sync path: transcript came back immediately.
        if let text = payload.transcriptText, !text.isEmpty {
            return TranscriptResult(text: text, detectedLanguage: payload.lang, title: nil)
        }

        // Async path: Supadata queued a job (long media needing ASR).
        if let jobId = payload.jobId, !jobId.isEmpty {
            return try await pollJob(jobId)
        }

        // Recognized response but nothing usable → fall back.
        return nil
    }

    // MARK: - Async job polling

    private static func pollJob(_ jobId: String) async throws -> TranscriptResult? {
        guard let url = URL(string: "\(baseURL)/\(jobId)") else { return nil }
        for _ in 0..<maxPollAttempts {
            try await Task.sleep(nanoseconds: pollIntervalNanos)
            let payload = try await get(url)
            switch payload.status?.lowercased() {
            case "completed", "complete", "done", .none:
                if let text = payload.transcriptText, !text.isEmpty {
                    return TranscriptResult(text: text, detectedLanguage: payload.lang, title: nil)
                }
                // Completed but empty → no transcript; fall back.
                if payload.status != nil { return nil }
            case "failed", "error":
                return nil
            default:
                continue  // queued / active → keep polling
            }
        }
        throw TranscriptError.timedOut
    }

    // MARK: - HTTP

    private static func get(_ url: URL) async throws -> SupadataPayload {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: apiKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptError.provider("No HTTP response from transcript provider.")
        }

        // Decode first — Supadata returns useful JSON on both success and
        // many error statuses.
        let payload = (try? JSONDecoder().decode(SupadataPayload.self, from: data)) ?? SupadataPayload()

        switch http.statusCode {
        case 200...299:
            return payload
        case 202:
            // Accepted → async job. The payload carries the jobId.
            return payload
        case 404, 206, 416:
            // "No transcript / unsupported / out of range" — graceful
            // fallback, not a hard error.
            return SupadataPayload()
        default:
            // Surface real errors (bad key, rate limit, etc.) so they get
            // logged; the caller's `try?` still degrades to model recall.
            if let message = payload.error ?? payload.message {
                throw TranscriptError.provider(message)
            }
            throw TranscriptError.http(http.statusCode)
        }
    }
}

// Flexible decode of Supadata's responses across its sync, async, and
// error shapes. `content` may be a plain string (text=true) OR an array
// of cue chunks — both are normalized into `transcriptText`.
private struct SupadataPayload: Decodable {
    let contentString: String?
    let contentChunks: [Chunk]?
    let lang: String?
    let jobId: String?
    let status: String?
    let error: String?
    let message: String?

    struct Chunk: Decodable {
        let text: String?
        let lang: String?
    }

    enum CodingKeys: String, CodingKey {
        case content, lang, language, jobId, id, status, error, message
    }

    init() {
        contentString = nil; contentChunks = nil; lang = nil
        jobId = nil; status = nil; error = nil; message = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // content: string (text=true) or [Chunk] (timestamped).
        if let s = try? c.decode(String.self, forKey: .content) {
            contentString = s
            contentChunks = nil
        } else {
            contentString = nil
            contentChunks = try? c.decode([Chunk].self, forKey: .content)
        }
        lang = (try? c.decode(String.self, forKey: .lang))
            ?? (try? c.decode(String.self, forKey: .language))
        jobId = (try? c.decode(String.self, forKey: .jobId))
            ?? (try? c.decode(String.self, forKey: .id))
        status = try? c.decode(String.self, forKey: .status)
        error = try? c.decode(String.self, forKey: .error)
        message = try? c.decode(String.self, forKey: .message)
    }

    // Single transcript block regardless of which content shape arrived.
    var transcriptText: String? {
        if let contentString, !contentString.isEmpty { return contentString }
        if let contentChunks, !contentChunks.isEmpty {
            let joined = contentChunks.compactMap { $0.text }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
