import Foundation

enum DeckAttribute: String, Identifiable, CaseIterable {
    case language, dialect, content, amount, level

    var id: String { rawValue }

    var title: String {
        switch self {
        case .language: return "Language"
        case .dialect:  return "Dialect"
        case .content:  return "Content"
        case .amount:   return "Amount"
        case .level:    return "Level"
        }
    }

    var options: [String] {
        switch self {
        case .language: return [
            "Afrikaans", "Albanian", "Amharic", "Arabic", "Armenian", "Assamese", "Azerbaijani",
            "Basque", "Belarusian", "Bengali", "Bosnian", "Bulgarian", "Burmese",
            "Catalan", "Cebuano", "Chichewa", "Chinese (Cantonese)", "Chinese (Mandarin)",
            "Corsican", "Croatian", "Czech",
            "Danish", "Dutch",
            "English", "Esperanto", "Estonian",
            "Filipino", "Finnish", "French", "Frisian",
            "Galician", "Georgian", "German", "Greek", "Gujarati",
            "Haitian Creole", "Hausa", "Hawaiian", "Hebrew", "Hindi", "Hmong", "Hungarian",
            "Icelandic", "Igbo", "Indonesian", "Irish", "Italian",
            "Japanese", "Javanese",
            "Kannada", "Kazakh", "Khmer", "Kinyarwanda", "Korean", "Kurdish", "Kyrgyz",
            "Lao", "Latin", "Latvian", "Lithuanian", "Luxembourgish",
            "Macedonian", "Malagasy", "Malay", "Malayalam", "Maltese", "Maori", "Marathi", "Mongolian",
            "Nepali", "Norwegian",
            "Odia",
            "Pashto", "Persian", "Polish", "Portuguese", "Punjabi",
            "Quechua",
            "Romanian", "Russian",
            "Samoan", "Sanskrit", "Scots Gaelic", "Serbian", "Sesotho", "Shona", "Sindhi",
            "Sinhala", "Slovak", "Slovenian", "Somali", "Spanish", "Sundanese", "Swahili", "Swedish",
            "Taiwanese", "Tajik", "Tamil", "Tatar", "Telugu", "Thai", "Tibetan", "Tigrinya", "Turkish", "Turkmen",
            "Ukrainian", "Urdu", "Uyghur", "Uzbek",
            "Vietnamese",
            "Welsh",
            "Xhosa",
            "Yiddish", "Yoruba",
            "Zulu"
        ]
        case .dialect:  return ["Standard"]
        // "Phrases" was retired — it now funnels into "Sentences" (see
        // canonicalContentType). Only Words and Sentences remain.
        case .content:  return ["Words", "Sentences"]
        case .amount:   return ["5", "10", "20", "50"]
        case .level:    return ["A1", "A2", "B1", "B2", "C1", "C2"]
        }
    }
}

// The app now has exactly two content categories: Words and Sentences.
// "Phrases" is a legacy value that we fold into "Sentences" so existing
// decks and any stray inputs behave as sentences everywhere — routing to
// Sentence Studio, exclusion from word widgets, and the shared cap bucket.
func canonicalContentType(_ raw: String) -> String {
    raw == "Phrases" ? "Sentences" : raw
}

struct Dialect: Hashable {
    let name: String
    let speakers: Int
}

struct WordInfo: Codable, Hashable {
    let meaning: String
    let partsOfSpeech: [String]
    let pronunciation: String
    let language: String
    let wordFrequency: String
    let pronunciationDifficulty: String
}

// Structured etymology data, fetched on demand and rendered inside the
// word-info modal's pushed detail page. The schema mirrors the spec — every
// human-readable field (meanings, glosses, periods, highlight) is written
// in the learner's explanation language so they can actually read it,
// while surface forms (form/surface/word) stay in the source script.
struct Etymology: Codable, Hashable {
    struct Summary: Codable, Hashable {
        let originLanguage: String
        let rootForm: String
        let originalMeaning: String
        let highlight: String
    }
    struct Morpheme: Codable, Hashable, Identifiable {
        let surface: String
        let type: String  // prefix | root | suffix | combining
        let gloss: String
        let originLanguage: String
        let rootId: String
        var id: String { rootId + "·" + surface }
    }
    struct LineageStep: Codable, Hashable, Identifiable {
        let form: String
        let language: String
        let period: String
        let periodSort: Int
        let meaning: String
        let current: Bool?
        var id: String { form + "·" + language + "·" + period }
    }
    struct Related: Codable, Hashable, Identifiable {
        let word: String
        let gloss: String
        let rootId: String
        var id: String { word + "·" + rootId }
    }
    let word: String
    let pronunciation: String
    let partOfSpeech: String
    let summary: Summary
    let morphemes: [Morpheme]?
    let lineage: [LineageStep]
    let related: [Related]?
}

// Structured, chunked grammatical analysis of a single sentence. Powers
// the "Grammar" action on conversation bubbles — the AI splits the
// sentence into readable segments and surfaces the key grammar concepts
// behind it.
struct GrammarBreakdown: Codable, Hashable {
    // A contiguous, reading-order segment of the sentence with its role
    // and a friendly explanation of why it takes the form it does.
    struct Chunk: Codable, Hashable, Identifiable {
        let text: String
        let transliteration: String?
        let literal: String
        let role: String
        let explanation: String
        var id: String { text + "·" + role }
    }
    // A standalone grammar concept the learner should take away from the
    // sentence (case, agreement, word order, aspect, …).
    struct GrammarPoint: Codable, Hashable, Identifiable {
        let title: String
        let explanation: String
        let example: String?
        var id: String { title }
    }

    let sentence: String
    let translation: String
    let summary: String
    let sentenceType: String
    let register: String
    let chunks: [Chunk]
    let grammarPoints: [GrammarPoint]
    let wordOrderNote: String?
}

enum ContentGenerationKind: String, CaseIterable, Identifiable {
    case story = "Story"
    case conversation = "Conversation"
    case newsArticle = "News Article"
    case songs = "Songs"
    case poems = "Poems"
    case jokes = "Jokes"

    var id: String { rawValue }

    var promptDescription: String {
        switch self {
        case .story:        return "a short, vivid story"
        case .conversation: return "a natural dialogue between two speakers"
        case .newsArticle:  return "a short news article in a journalistic register"
        case .songs:        return "a short song with one or two verses and a chorus, with line breaks preserved"
        case .poems:        return "a short poem of roughly 8–16 lines, with line breaks preserved"
        case .jokes:        return "two or three short jokes or witty exchanges"
        }
    }

    var placeholder: String {
        switch self {
        case .story:        return "e.g. a doctor's first day in a busy ER"
        case .conversation: return "e.g. two friends discussing a recent surgery"
        case .newsArticle:  return "e.g. breakthrough in regenerative medicine"
        case .songs:        return "e.g. a long road trip with friends"
        case .poems:        return "e.g. autumn light in the mountains"
        case .jokes:        return "e.g. medical school humor"
        }
    }
}

enum RelationKind: String, CaseIterable, Identifiable {
    case synonyms, antonyms, phrases, plurals, conjugations

    var id: String { rawValue }

    var pillLabel: String {
        switch self {
        case .synonyms:     return "Add Synonyms"
        case .antonyms:     return "Add Antonyms"
        case .phrases:      return "Add Phrases"
        case .plurals:      return "Add Plurals"
        case .conjugations: return "Add Conjugations"
        }
    }

    var promptDescription: String {
        switch self {
        case .synonyms:     return "synonyms (different words with similar meaning)"
        case .antonyms:     return "antonyms (words with opposite meaning)"
        case .phrases:      return "natural phrases or short sentences that use the source word in context"
        case .plurals:      return "plural and other number inflections (e.g. singular ↔ plural; dual where the language has it)"
        case .conjugations: return "the most pedagogically useful conjugated forms of the source verb — pick the main tenses (present, past, future and any other commonly taught at this level) and the most representative person/number for each (often 1st-person singular). Where the language has aspect (Slavic), include the aspectual pair. Where the language has separable prefixes or auxiliary-based constructions (German, French passé composé, etc.), include them. Each item should be a single conjugated form, not a paragraph."
        }
    }
}

struct GeneratedItem: Codable, Identifiable, Hashable {
    var id = UUID()
    let word: String
    let translation: String
    let transliteration: String?
    var language: String?
    // Optional tag set when this item was generated as a relation (e.g.
    // "synonym", "antonym", "phrase", "plural"). Nil for items from the
    // initial deck generation. Used to decide which inline controls apply
    // (relation pills only make sense on word-shaped items).
    var kind: String?
    // Grammatical categories returned with the initial generation (e.g.
    // ["Noun"], ["Verb", "Phrase"]). Optional for backward compatibility
    // with items saved before this field existed; populated lookups can
    // also fall through to the heavier per-word WordInfo call.
    var partsOfSpeech: [String]?
    // When this item entered the user's library. FirebaseDeckService
    // stamps it at save time. Nil for legacy items written before this
    // field existed — readers fall back to the parent deck's `createdAt`.
    var addedAt: Date?

    enum CodingKeys: String, CodingKey {
        case word, translation, transliteration, language, kind, partsOfSpeech, addedAt
    }

    init(
        word: String,
        translation: String,
        transliteration: String?,
        language: String? = nil,
        kind: String? = nil,
        partsOfSpeech: [String]? = nil,
        addedAt: Date? = nil
    ) {
        self.word = word
        self.translation = translation
        self.transliteration = transliteration
        self.language = language
        self.kind = kind
        self.partsOfSpeech = partsOfSpeech
        self.addedAt = addedAt
    }

    func withLanguage(_ language: String) -> GeneratedItem {
        var copy = self
        copy.language = language
        return copy
    }

    func withKind(_ kind: String) -> GeneratedItem {
        var copy = self
        copy.kind = kind
        return copy
    }

    func withAddedAt(_ date: Date) -> GeneratedItem {
        var copy = self
        copy.addedAt = date
        return copy
    }
}

struct GenerationResult: Codable {
    let title: String
    let items: [GeneratedItem]
}

// FSRS grades — replaces the prior binary correct/incorrect. Old Firestore
// records (sessions + schedules) used "correct"/"incorrect"; those values are
// still accepted on decode and mapped to .good / .again respectively so legacy
// data keeps loading.
enum ReviewResult: String, Codable, Hashable {
    case again
    case hard
    case good
    case easy

    var displayName: String {
        switch self {
        case .again: return "Again"
        case .hard:  return "Hard"
        case .good:  return "Good"
        case .easy:  return "Easy"
        }
    }

    /// FSRS rating index (1...4). Used by the scheduler's update formulas.
    var fsrsIndex: Int {
        switch self {
        case .again: return 1
        case .hard:  return 2
        case .good:  return 3
        case .easy:  return 4
        }
    }

    /// True for the only grade that counts as a memory failure / lapse.
    var isLapse: Bool { self == .again }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "again", "incorrect": self = .again
        case "hard":               self = .hard
        case "good", "correct":    self = .good
        case "easy":               self = .easy
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown ReviewResult: \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CardReview: Codable, Hashable {
    let cardId: String
    let word: String
    let language: String
    let result: ReviewResult
    let reviewedAt: Date
    // Seconds the learner spent looking at this card before submitting a
    // grade. Nil for legacy reviews written before this field existed —
    // readers should treat that as "unknown" rather than zero. Memberwise
    // init keeps the default so existing call sites continue to compile.
    var timeSpent: TimeInterval? = nil
}

struct GeneratedDeck: Hashable, Identifiable {
    let id: UUID
    let title: String
    let items: [GeneratedItem]
    let language: String
    let dialect: String
    let level: String
    let contentType: String
    let amount: String
    let tones: [String]
    let interests: [String]
    let userPrompt: String
    let promptSent: String
    let rawJSON: String

    init(
        id: UUID = UUID(),
        title: String,
        items: [GeneratedItem],
        language: String,
        dialect: String,
        level: String,
        contentType: String,
        amount: String,
        tones: [String],
        interests: [String],
        userPrompt: String,
        promptSent: String,
        rawJSON: String
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.language = language
        self.dialect = dialect
        self.level = level
        self.contentType = contentType
        self.amount = amount
        self.tones = tones
        self.interests = interests
        self.userPrompt = userPrompt
        self.promptSent = promptSent
        self.rawJSON = rawJSON
    }

    static func == (lhs: GeneratedDeck, rhs: GeneratedDeck) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
