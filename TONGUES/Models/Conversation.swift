import Foundation
import FirebaseFirestore

// MARK: - Conversation

// One chat thread. Users can have many conversations per language —
// the chat-history sheet lists them and lets the user pick one or
// start a fresh one.
//
// Stored at `users/{uid}/conversations/{Conversation.id}` where `id`
// is a stable UUID string. The `languageID` field carries the
// canonical language tag so the history sheet can filter by it with a
// single indexed query.
struct Conversation: Codable, Identifiable, Hashable {
    let id: String                // UUID string — also the Firestore doc id
    let languageID: String        // Canonical, alphanumeric-only language tag
    let language: String          // Display name, e.g. "Chinese (Mandarin)"
    let dialect: String
    let level: String
    var messages: [ConversationMessage]
    // Special-purpose threads. Nil for ordinary chats; "placement" marks
    // a conversational level check so the view model knows to grade the
    // transcript after enough turns. Optional → legacy docs decode fine.
    var purpose: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        languageID: String,
        language: String,
        dialect: String,
        level: String,
        messages: [ConversationMessage] = [],
        purpose: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.languageID = languageID
        self.language = language
        self.dialect = dialect
        self.level = level
        self.messages = messages
        self.purpose = purpose
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Canonicalize a language name into a stable filter tag. We
    // collapse everything to alphanumerics so dialect parens / spaces /
    // dashes never trip Firestore's index rules.
    static func languageID(for language: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return language.unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
    }

    // Display title for the chat-history row. Derived from the first
    // user message (or assistant if the user hasn't spoken yet),
    // falling back to "New chat" for empty threads. Computed so we
    // never have to write it back to Firestore.
    var title: String {
        if let firstUser = messages.first(where: { $0.role == .user })?.text,
           !firstUser.isEmpty {
            return Self.snippet(firstUser, limit: 40)
        }
        if let firstAssistant = messages.first(where: { $0.role == .assistant })?.text,
           !firstAssistant.isEmpty {
            return Self.snippet(firstAssistant, limit: 40)
        }
        return "New chat"
    }

    // Short preview line shown under the title in the history list.
    var preview: String {
        guard let last = messages.last else { return "Tap to start." }
        let prefix = last.role == .assistant ? "" : "You: "
        return prefix + Self.snippet(last.text, limit: 80)
    }

    private static func snippet(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - Message

// One turn in a conversation. Carries the rendered text + optional
// transliteration + an optional list of inline corrections (the AI's
// feedback on the *user's* most recent turn — attached to the user
// message so the bubble can decorate the wrong tokens).
struct ConversationMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    let role: ConversationRole
    let text: String
    // Latin-script romanization for non-Latin target languages so the
    // user can read along. Nil for Latin-script languages and for
    // user-authored turns (we don't transliterate the user's own input).
    var transliteration: String?
    // Inline corrections the AI returned for THIS message (only
    // populated on `.user` turns when the AI flagged mistakes).
    var corrections: [ConversationCorrection]?
    // Once any token in this message has been saved to a deck, we
    // remember which item ids were added so the bubble can stamp them
    // and the save UI doesn't double-add the same phrase.
    var savedDeckItemIDs: [UUID]?
    // Structured card rendered under the bubble (deck proposal, plan
    // proposal, progress snapshot, …). Only the tutor agent sets this.
    // Optional → every pre-existing message decodes unchanged, and the
    // attachment enum itself degrades unknown future types gracefully.
    var attachment: MessageAttachment?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ConversationRole,
        text: String,
        transliteration: String? = nil,
        corrections: [ConversationCorrection]? = nil,
        savedDeckItemIDs: [UUID]? = nil,
        attachment: MessageAttachment? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.transliteration = transliteration
        self.corrections = corrections
        self.savedDeckItemIDs = savedDeckItemIDs
        self.attachment = attachment
        self.createdAt = createdAt
    }
}

enum ConversationRole: String, Codable, Hashable {
    case user
    case assistant
}

// MARK: - Corrections

// One stretch of the user's message the AI flagged for correction.
// `original` is the exact substring as the user wrote it; `corrected`
// is what they should have written; `explanation` is a short
// language-aware reason (in English) the user can tap to expand.
struct ConversationCorrection: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let original: String
    let corrected: String
    let explanation: String

    init(
        id: UUID = UUID(),
        original: String,
        corrected: String,
        explanation: String
    ) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.explanation = explanation
    }
}

// MARK: - Recap

// What the recap pipeline returns at the end of a conversation: a
// curated set of `RecapPhrase` ready to be turned into `GeneratedItem`
// and handed to the existing deck-add UI.
struct ConversationRecap: Hashable {
    let phrases: [RecapPhrase]
    let summary: String  // Brief 1-2 sentence wrap of the conversation.
}

struct RecapPhrase: Hashable, Identifiable {
    var id = UUID()
    let foreign: String
    let translation: String
    let transliteration: String?
    let partsOfSpeech: [String]
    // Whether the user has staged this phrase for save. Drives the
    // checkbox in the recap UI before the bulk "Add to deck" call.
    var isSelected: Bool = true

    func asGeneratedItem(language: String) -> GeneratedItem {
        GeneratedItem(
            word: foreign,
            translation: translation,
            transliteration: transliteration,
            language: language,
            kind: nil,
            partsOfSpeech: partsOfSpeech,
            addedAt: Date()
        )
    }
}

// MARK: - Pronunciation attempt history

// One saved attempt at a pronunciation drill. Persisted to
// `users/{uid}/pronunciationAttempts/{id}` so the drill sheet can
// surface long-term improvement on a given sentence across sessions
// and the Statistics surface can later chart progress per-language.
struct PronunciationAttempt: Codable, Identifiable, Hashable {
    let id: String                // UUID string — also the Firestore doc id.
    let language: String          // Canonical display name.
    let languageID: String        // Alphanumeric tag for indexing.
    let dialect: String
    let target: String            // The exact sentence the user was drilling.
    let transcript: String        // STT output of the attempt.
    let grade: ConversationClient.PronunciationGrade
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        language: String,
        languageID: String,
        dialect: String,
        target: String,
        transcript: String,
        grade: ConversationClient.PronunciationGrade,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.language = language
        self.languageID = languageID
        self.dialect = dialect
        self.target = target
        self.transcript = transcript
        self.grade = grade
        self.createdAt = createdAt
    }
}

// MARK: - Scenario starters

// A single quick-start prompt the user can tap from an empty
// conversation. Drives an opening AI message in-language. Some are
// curated; others are derived dynamically from the user's onboarding
// interests so the menu always carries something topically relevant.
struct ConversationScenario: Identifiable, Hashable {
    let id: String
    let title: String       // Short noun-phrase chip label, e.g. "At a café"
    let prompt: String      // What the AI is told to do when this is tapped.
    let systemImage: String

    static let curated: [ConversationScenario] = [
        ConversationScenario(
            id: "cafe",
            title: "Order at a café",
            prompt: "Start a short roleplay where you (the assistant) play a friendly barista at a small local café and the user is a customer ordering something. Open with a greeting and ask what they'd like.",
            systemImage: "cup.and.saucer"
        ),
        ConversationScenario(
            id: "directions",
            title: "Ask for directions",
            prompt: "Start a short roleplay where the user is a tourist asking you (a friendly local) for directions to a nearby landmark or train station. Open by warmly offering to help.",
            systemImage: "map"
        ),
        ConversationScenario(
            id: "smalltalk",
            title: "Small talk",
            prompt: "Strike up natural, low-stakes small talk. Open with one short, friendly question about their day or weekend. Keep your turns short.",
            systemImage: "bubble.left.and.bubble.right"
        ),
        ConversationScenario(
            id: "interview",
            title: "Job interview",
            prompt: "Start a brief, relaxed roleplay where you're a friendly interviewer asking the user about their background. Begin with a warm opening and one easy starter question.",
            systemImage: "person.badge.clock"
        ),
        ConversationScenario(
            id: "story",
            title: "Tell me a short story",
            prompt: "Tell a short, age-appropriate story (4–6 sentences) calibrated to the user's level. End by asking the user a single open-ended question about it.",
            systemImage: "book"
        ),
        ConversationScenario(
            id: "describe",
            title: "Describe a photo",
            prompt: "Invite the user to describe a place they've been to recently. Ask them one specific question that will get them talking (the weather, what they ate, who they were with).",
            systemImage: "photo"
        )
    ]

    // Builds an "About X" scenario for each of the user's onboarding
    // interests so the chip strip personalizes itself. Capped to a
    // handful so the layout doesn't sprawl.
    static func fromInterests(_ interests: [String]) -> [ConversationScenario] {
        interests.prefix(4).map { interest in
            ConversationScenario(
                id: "interest.\(interest)",
                title: "About \(interest.lowercased())",
                prompt: "Strike up a conversation about \(interest). Ask the user one specific question that gets them talking — their experience, an opinion, a recent example. Keep it warm and natural.",
                systemImage: "sparkles"
            )
        }
    }
}
