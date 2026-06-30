import Foundation

enum ForvoClient {
    private static let apiKey = Secrets.forvoAPIKey

    // Forvo doesn't always accept the same ISO codes the rest of the app uses.
    // Known mismatches go here, mapping LanguageData's iso → Forvo's expected
    // code. Anything not in this map passes through unchanged.
    private static let forvoCodeOverrides: [String: String] = [
        "fil": "tl"   // Forvo catalogs Filipino under Tagalog
    ]

    // Returns the first available MP3 pronunciation URL for `word` in
    // `languageCode`, or nil if Forvo has no recording. Throws on network /
    // HTTP / decoding errors so the caller can fall back to Apple TTS.
    static func pronunciationURL(word: String, languageCode: String) async throws -> URL? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encodedWord = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
              ) else {
            return nil
        }
        let forvoLang = forvoCodeOverrides[languageCode] ?? languageCode
        let endpoint = "https://apicommercial.forvo.com/key/\(apiKey)/format/json/action/word-pronunciations/word/\(encodedWord)/language/\(forvoLang)/"
        guard let url = URL(string: endpoint) else { return nil }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Forvo", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("Forvo HTTP \(http.statusCode) for word=\"\(trimmed)\" lang=\(forvoLang): \(bodyText)")
            throw NSError(domain: "Forvo", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        let decoded = try JSONDecoder().decode(ForvoResponse.self, from: data)
        guard let items = decoded.items, !items.isEmpty else {
            print("Forvo: no recordings for word=\"\(trimmed)\" lang=\(forvoLang)")
            return nil
        }
        guard let pathmp3 = items.first?.pathmp3,
              !pathmp3.isEmpty,
              let audioURL = URL(string: pathmp3) else {
            return nil
        }
        return audioURL
    }
}

private struct ForvoResponse: Decodable {
    let items: [ForvoItem]?
}

private struct ForvoItem: Decodable {
    let pathmp3: String?
}
