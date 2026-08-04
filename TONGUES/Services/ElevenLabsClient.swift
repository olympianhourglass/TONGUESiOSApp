import Foundation

enum ElevenLabsClient {
    private static let apiKey = Secrets.elevenLabsAPIKey

    // "Rachel" — ElevenLabs' default voice, a native US-English speaker. Used
    // as the English voice; other languages resolve a native voice from the
    // shared Voice Library (see `nativeVoiceId(forLanguageCode:)`).
    nonisolated static let defaultVoiceId = "21m00Tcm4TlvDq8ikWAM"

    // Multilingual model. The old `eleven_monolingual_v1` was English-only AND
    // was retired by ElevenLabs on 2026-07-09, so it returns an API error and
    // every generation silently fell back to the system voice. Multilingual v2
    // auto-detects the language from the text — essential for a language-
    // learning app — and is the documented replacement. (Use `eleven_flash_v2_5`
    // instead if lower latency/cost matters more than narration quality.)
    private static let modelId = "eleven_multilingual_v2"

    // ISO-639-1 codes for the 29 languages eleven_multilingual_v2 speaks
    // natively (per ElevenLabs' model language list). A native voice is only
    // discovered for these — every other language the app offers (Cantonese,
    // Thai, Vietnamese, Hebrew, most Indic/African languages, Latin, …) falls
    // back to the device/Forvo path. That avoids a wasted discovery call and,
    // more importantly, prevents grabbing a voice that would read an
    // unsupported language in the wrong accent.
    static let multilingualSupportedISO: Set<String> = [
        "en", "ja", "zh", "de", "hi", "fr", "ko", "pt", "it", "es",
        "id", "nl", "tr", "fil", "pl", "sv", "bg", "ro", "ar", "cs",
        "el", "fi", "hr", "ms", "sk", "da", "ta", "uk", "ru"
    ]

    static var isConfigured: Bool { !apiKey.isEmpty }

    static func textToSpeech(
        _ text: String,
        voiceId: String = defaultVoiceId,
        onCacheMiss: (@Sendable (_ characters: Int) async -> Bool)? = nil
    ) async throws -> Data {
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

    // Forces a fresh generation (bypassing the cache read) and OVERWRITES the
    // cached audio under the same key, so the corrected take replaces the old
    // one for every future play. Used by the audio-source audit sheet when a
    // voice-over came back wrong. Budget-gated like any other generation.
    static func regenerate(
        _ text: String,
        voiceId: String = defaultVoiceId,
        onCacheMiss: (@Sendable (_ characters: Int) async -> Bool)? = nil
    ) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ElevenLabs", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Empty text"])
        }
        guard isConfigured else {
            throw NSError(domain: "ElevenLabs", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API key not set"])
        }
        if let onCacheMiss {
            guard await onCacheMiss(trimmed.count) else {
                throw NSError(domain: "ElevenLabs", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "TTS character budget exhausted"])
            }
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
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabs", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("ElevenLabs regenerate HTTP \(http.statusCode): \(bodyText)")
            throw NSError(domain: "ElevenLabs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: bodyText])
        }

        // Overwrite the cached version (disk + Firebase Storage) under the same
        // key so the improved take is what everyone hears from now on.
        let key = "elevenlabs-\(MediaCache.shaKey("\(voiceId)|\(modelId)|\(trimmed)"))"
        await MediaCache.store(data, key: key)
        return data
    }

    // MARK: - Timestamped speech (karaoke highlight)

    // Character-level alignment for a synthesized clip: each spoken character
    // and the audio time (seconds) it begins at. Drives the read-along word
    // highlight for ElevenLabs playback, matching Apple TTS's word callback.
    struct SpeechAlignment: Codable, Sendable {
        let characters: [String]
        let startTimesSeconds: [Double]
    }

    struct TimestampedSpeech: Sendable {
        let audio: Data
        let alignment: SpeechAlignment?
    }

    // Same as `textToSpeech` but hits the `/with-timestamps` endpoint so the
    // caller gets character timings alongside the audio (for a karaoke
    // highlight). Audio + alignment are cached together under a dedicated
    // key namespace so a plain-audio cache entry can't shadow one without
    // timings. Budget-gated identically — the character cost is the same.
    static func textToSpeechWithTimestamps(
        _ text: String,
        voiceId: String = defaultVoiceId,
        onCacheMiss: (@Sendable (_ characters: Int) async -> Bool)? = nil
    ) async throws -> TimestampedSpeech {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ElevenLabs", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Empty text"])
        }

        let key = "elevenlabs-ts-\(MediaCache.shaKey("\(voiceId)|\(modelId)|\(trimmed)"))"
        if let audio = await MediaCache.fetch(key: key) {
            let alignment = await MediaCache.fetch(key: key, ext: "json")
                .flatMap { try? JSONDecoder().decode(SpeechAlignment.self, from: $0) }
            return TimestampedSpeech(audio: audio, alignment: alignment)
        }

        guard isConfigured else {
            throw NSError(domain: "ElevenLabs", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API key not set"])
        }

        if let onCacheMiss {
            let allowed = await onCacheMiss(trimmed.count)
            guard allowed else {
                throw NSError(domain: "ElevenLabs", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "TTS character budget exhausted"])
            }
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/with-timestamps") else {
            throw NSError(domain: "ElevenLabs", code: -3, userInfo: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let body: [String: Any] = [
            "text": trimmed,
            "model_id": modelId,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabs", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("ElevenLabs with-timestamps HTTP \(http.statusCode): \(bodyText)")
            throw NSError(domain: "ElevenLabs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: bodyText])
        }

        let decoded = try JSONDecoder().decode(WithTimestampsResponse.self, from: data)
        guard let audio = Data(base64Encoded: decoded.audioBase64) else {
            throw NSError(domain: "ElevenLabs", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Malformed audio payload"])
        }
        let alignment = decoded.alignment.map {
            SpeechAlignment(characters: $0.characters, startTimesSeconds: $0.characterStartTimesSeconds)
        }

        // Encode the alignment here (not inside the detached task) so its
        // Codable conformance stays on this actor. Fire-and-forget both writes.
        let alignmentJSON = alignment.flatMap { try? JSONEncoder().encode($0) }
        Task.detached {
            await MediaCache.store(audio, key: key)
            if let alignmentJSON {
                await MediaCache.store(alignmentJSON, key: key, ext: "json")
            }
        }
        return TimestampedSpeech(audio: audio, alignment: alignment)
    }

    private struct WithTimestampsResponse: Decodable {
        let audioBase64: String
        let alignment: Alignment?

        struct Alignment: Decodable {
            let characters: [String]
            let characterStartTimesSeconds: [Double]
            enum CodingKeys: String, CodingKey {
                case characters
                case characterStartTimesSeconds = "character_start_times_seconds"
            }
        }
        enum CodingKeys: String, CodingKey {
            case audioBase64 = "audio_base64"
            case alignment
        }
    }

    // MARK: - Native voice discovery

    // Resolves a native-speaker voice for the given ISO-639-1 language code
    // (e.g. "zh" for Mandarin) from ElevenLabs' shared Voice Library, so the
    // target language is spoken by a native voice rather than an English voice
    // reading foreign text. The chosen voice_id is cached in UserDefaults so
    // the discovery call happens at most once per language per install.
    //
    // Returns nil if the key is missing, the request fails, or the library
    // returns no match — callers fall back to their existing engine.
    static func nativeVoiceId(forLanguageCode iso: String) async -> String? {
        let code = iso.lowercased()
        // Only languages the multilingual model actually speaks natively.
        guard multilingualSupportedISO.contains(code) else { return nil }
        let cacheKey = "elevenlabs-native-voice-\(code)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey), !cached.isEmpty {
            return cached
        }
        guard isConfigured else { return nil }
        guard var components = URLComponents(string: "https://api.elevenlabs.io/v1/shared-voices") else {
            return nil
        }
        // Ask for native voices in this language, most-used first (the API
        // orders shared voices by usage), limited to a small page.
        components.queryItems = [
            URLQueryItem(name: "language", value: code),
            URLQueryItem(name: "page_size", value: "20")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("ElevenLabs shared-voices HTTP \(code) for language \(iso)")
                return nil
            }
            let decoded = try JSONDecoder().decode(SharedVoicesResponse.self, from: data)
            // Prefer a voice explicitly verified for this language; otherwise
            // take the first result the library returned for the filter.
            let match = decoded.voices.first { voice in
                voice.verifiedLanguages?.contains { $0.language?.lowercased() == code } ?? false
            } ?? decoded.voices.first
            guard let voiceId = match?.voiceId, !voiceId.isEmpty else {
                print("ElevenLabs shared-voices: no voice found for language \(iso)")
                return nil
            }
            UserDefaults.standard.set(voiceId, forKey: cacheKey)
            print("ElevenLabs native voice for \(iso): \(voiceId)")
            return voiceId
        } catch {
            print("ElevenLabs shared-voices error for \(iso): \(error)")
            return nil
        }
    }

    private struct SharedVoicesResponse: Decodable {
        let voices: [SharedVoice]
    }

    private struct SharedVoice: Decodable {
        let voiceId: String
        let verifiedLanguages: [VerifiedLanguage]?

        enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
            case verifiedLanguages = "verified_languages"
        }
    }

    private struct VerifiedLanguage: Decodable {
        let language: String?
    }
}
