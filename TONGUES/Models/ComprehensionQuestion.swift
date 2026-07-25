import Foundation

// A single reading-comprehension question generated for a story, news
// article, or conversation. The question stem is phrased in the learner's
// native language; the four answer `choices` are in the target language.
// `correctIndex` is the 0-based index of the right choice.
//
// Decoded straight from Claude's structured tool output, so `id` is
// excluded from the coding keys (the model never supplies it) and defaults
// to a fresh UUID — the same pattern GeneratedItem uses.
struct ComprehensionQuestion: Codable, Hashable, Identifiable {
    var id = UUID()
    let question: String
    let choices: [String]
    let correctIndex: Int
    // Native-language translation of each choice, in the same order as
    // `choices`. Revealed behind the eye toggle so the learner can check
    // what each target-language option means.
    let choiceTranslations: [String]
    // Latin-script pronunciation of each choice, in the same order as
    // `choices`. Only populated for non-Latin target scripts that the app
    // surfaces a reading for (Chinese, Japanese, Korean, Arabic); `nil`
    // for every other language.
    let choicePronunciations: [String]?

    enum CodingKeys: String, CodingKey {
        case question, choices, correctIndex, choiceTranslations, choicePronunciations
    }

    // A question is only usable if it has exactly four choices, the answer
    // key points at one of them, and every choice has a matching
    // translation. Malformed questions from the model are filtered out
    // before they ever reach the UI.
    var isWellFormed: Bool {
        choices.count == 4
            && correctIndex >= 0 && correctIndex < choices.count
            && choiceTranslations.count == choices.count
            && (choicePronunciations == nil || choicePronunciations?.count == choices.count)
    }

    // The pronunciation for a given choice, if one was generated for this
    // language. Guards the index so a short/absent array never traps.
    func pronunciation(at index: Int) -> String? {
        guard let pronunciations = choicePronunciations,
              index >= 0, index < pronunciations.count else { return nil }
        let value = pronunciations[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // The translation for a given choice. Guards the index so a
    // short/absent array never traps.
    func translation(at index: Int) -> String? {
        guard index >= 0, index < choiceTranslations.count else { return nil }
        let value = choiceTranslations[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
