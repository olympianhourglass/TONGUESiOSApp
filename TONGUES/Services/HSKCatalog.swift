import Foundation

// Bundled, pre-authored HSK deck catalog (Mandarin only). Sourced once from
// the open complete-hsk-vocabulary dataset (HSK 3.0), transformed into compact
// per-deck lists and shipped in the app (Resources/HSK/hsk-catalog.json) so
// every Mandarin learner gets the identical decks with no generation step —
// tapping a card on Explore adds the whole list straight to their library.
//
// The official HSK 3.0 standard publishes levels 7–9 as a single advanced
// band; that ~5k-word list is pre-split into parts so each deck stays within
// Firestore's per-document size limit when it lands in a user's library.
struct HSKCatalog {
    struct Deck: Decodable, Identifiable, Hashable {
        let id: String        // e.g. "hsk-1-characters", "hsk-7-9-words-3"
        let level: String     // "HSK 1"…"HSK 6", "HSK 7–9"
        let kind: String      // "characters" | "words"
        let title: String     // "Characters" | "Words" | "Words · Part 3"
        let items: [Item]

        var isCharacters: Bool { kind == "characters" }
    }

    struct Item: Decodable, Hashable {
        let w: String   // simplified hanzi
        let p: String   // pinyin (with tone marks)
        let t: String   // English gloss
    }

    let decks: [Deck]

    static let shared = HSKCatalog()

    private init() {
        self.decks = Self.load()
    }

    private struct File: Decodable {
        let version: Int
        let decks: [Deck]
    }

    private static func load() -> [Deck] {
        guard let url = Bundle.main.url(forResource: "hsk-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("⚠️ HSKCatalog: hsk-catalog.json missing or unreadable")
            return []
        }
        return file.decks
    }
}

extension HSKCatalog.Deck {
    // The canonical Mandarin language label these decks are tagged with, so
    // they slot into the library, handwriting, and stats like any other deck.
    static let language = "Chinese (Mandarin)"

    // Builds the app's savable deck model from this catalog entry. Reuses the
    // normal save path (FirebaseDeckService.saveDeck) so the deck behaves
    // exactly like a generated one once it's in the user's library.
    func makeGeneratedDeck() -> GeneratedDeck {
        let generatedItems = items.map { item in
            GeneratedItem(
                word: item.w,
                translation: item.t,
                transliteration: item.p.isEmpty ? nil : item.p,
                language: Self.language
            )
        }
        return GeneratedDeck(
            title: "\(level) \(title)",
            items: generatedItems,
            language: Self.language,
            dialect: "Standard (Putonghua)",
            level: level,
            contentType: "Words",
            amount: String(generatedItems.count),
            tones: [],
            interests: [],
            userPrompt: "\(level) \(title)",
            promptSent: "",
            rawJSON: ""
        )
    }
}
