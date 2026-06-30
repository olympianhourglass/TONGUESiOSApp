import Foundation
import FirebaseFirestore

// Saved long-form generation (Story, Conversation, News Article, Song,
// Poem, Joke) the user chose to keep from the GenerateContentSheet. Lives
// under the deck it was generated from so each deck carries its own
// keepsake collection — the user opens a deck and finds the things they
// liked enough to bookmark, right next to the words/phrases the deck is
// teaching.
//
// `pairs` mirrors the foreign↔english alignment Claude emits so the
// reader can offer both a continuous-prose view and a line-by-line view,
// matching the live result-screen layout.
struct Artifact: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    // Denormalized so a future collection-group query (e.g. "all my
    // artifacts across decks") doesn't have to walk the parent path.
    let deckId: String
    // Raw string instead of the enum directly so an unfamiliar value
    // from a future client (new kind added) decodes without throwing —
    // `resolvedKind` falls back to `.story` for unknowns.
    let kind: String
    let title: String
    let prose: String
    let pairs: [SentencePair]
    // The "additional details" the user typed in before generating. Kept
    // so the artifact reader can show "you asked for: …" context.
    let userPrompt: String?
    let createdAt: Date

    var resolvedKind: ContentGenerationKind {
        ContentGenerationKind(rawValue: kind) ?? .story
    }

    // Pulls a clean headline out of the generated prose. Prefers the
    // English half (after the "English:" marker the DeckGenerator prompt
    // appends) since the user will recognize it faster than non-Latin
    // script at a glance, and falls back to the foreign side when
    // there's no English block. Trims at a word boundary so the result
    // doesn't end on a half-word.
    static func deriveTitle(fromProse prose: String) -> String {
        let englishMarker = "English:"
        let source: String
        if let range = prose.range(of: englishMarker) {
            source = String(prose[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            source = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstLine = source
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let firstSentence = firstLine
            .split(whereSeparator: { ".!?".contains($0) })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? firstLine
        return truncate(firstSentence, maxLength: 70)
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let prefix = text.prefix(maxLength)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return prefix[..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return prefix.trimmingCharacters(in: .whitespaces) + "…"
    }
}
