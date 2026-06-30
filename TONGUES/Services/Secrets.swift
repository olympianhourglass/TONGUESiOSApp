import Foundation

// API keys are read at runtime from a bundled `Secrets.plist` that is NOT
// committed to git (see `.gitignore`). To set up locally, copy
// `Secrets.example.plist` to `Secrets.plist` and fill in your keys.
//
// IMPORTANT: keys shipped inside a client app can be extracted from the
// IPA — they are not truly secret. For production, proxy third-party APIs
// through your own backend so the real keys never leave the server. This
// mechanism only keeps keys out of the public git repository.
enum Secrets {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ),
              let dict = plist as? [String: String]
        else {
            print("⚠️ Secrets.plist missing or unreadable — API keys will be empty.")
            return [:]
        }
        return dict
    }()

    static func value(_ key: String) -> String { values[key] ?? "" }

    static var anthropicAPIKey: String { value("ANTHROPIC_API_KEY") }
    static var elevenLabsAPIKey: String { value("ELEVENLABS_API_KEY") }
    static var forvoAPIKey: String { value("FORVO_API_KEY") }
    static var supadataAPIKey: String { value("SUPADATA_API_KEY") }
}
