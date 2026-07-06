import Foundation

// A grammatical or cultural insight the learner chose to keep. Persisted
// per-user at users/{uid}/savedInsights/{id}. Carries enough context to
// re-render the insight in full later: grammatical insights embed the
// whole GrammarBreakdown; cultural insights keep their place + fact text.
struct SavedInsight: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case grammatical
        case cultural
    }

    let id: String
    let kind: Kind
    // Row title: the sentence (grammatical) or the place (cultural).
    let title: String
    // Secondary line: the translation (grammatical); nil for cultural.
    let subtitle: String?
    // Readable body used for the preview and the cultural detail screen.
    let body: String
    // Display language / dialect when known (grammatical insights).
    let language: String?
    let dialect: String?
    // Full structured grammar context, present for grammatical insights so
    // the detail can re-render the same breakdown without another API call.
    let grammar: GrammarBreakdown?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        body: String,
        language: String? = nil,
        dialect: String? = nil,
        grammar: GrammarBreakdown? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.language = language
        self.dialect = dialect
        self.grammar = grammar
        self.createdAt = createdAt
    }
}
