import Foundation

enum ElevenLabsClient {
    private static let apiKey = Secrets.elevenLabsAPIKey

    // "Rachel" — ElevenLabs' default voice. Swap the ID to use a different
    // voice from your library.
    private static let defaultVoiceId = "21m00Tcm4TlvDq8ikWAM"

    // Multilingual model. The old `eleven_monolingual_v1` was English-only AND
    // was retired by ElevenLabs on 2026-07-09, so it returns an API error and
    // every generation silently fell back to the system voice. Multilingual v2
    // auto-detects the language from the text — essential for a language-
    // learning app — and is the documented replacement. (Use `eleven_flash_v2_5`
    // instead if lower latency/cost matters more than narration quality.)
    private static let modelId = "eleven_multilingual_v2"

    static var isConfigured: Bool { !apiKey.isEmpty }

    static func textToSpeech(_ text: String, voiceId: String = defaultVoiceId) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "ElevenLabs",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Empty text"]
            )
        }

        // Cache hit (disk or Firebase Storage) — no API call, no characters
        // consumed. Always check before API key — even if the key is removed
        // later, previously-cached phrases still play. The model id is part of
        // the key so switching models (e.g. off the retired English-only one)
        // regenerates fresh audio instead of serving stale blobs.
        let key = "elevenlabs-\(MediaCache.shaKey("\(voiceId)|\(modelId)|\(trimmed)"))"
        if let cached = await MediaCache.fetch(key: key) {
            print("ElevenLabs cache hit (\(cached.count) bytes)")
            return cached
        }

        guard isConfigured else {
            throw NSError(
                domain: "ElevenLabs",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API key not set"]
            )
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            throw NSError(domain: "ElevenLabs", code: -3, userInfo: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": trimmed,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabs", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("ElevenLabs HTTP \(http.statusCode): \(bodyText)")
            throw NSError(domain: "ElevenLabs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: bodyText])
        }

        // Fire-and-forget cache write — don't block playback on the upload.
        Task.detached { await MediaCache.store(data, key: key) }
        return data
    }
}
