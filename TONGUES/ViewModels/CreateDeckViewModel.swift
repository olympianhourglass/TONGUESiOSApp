import Foundation
import Observation

@Observable
@MainActor
final class CreateDeckViewModel {
    // Form state. Interests start unselected — the chips are now sourced
    // from the user's onboarding "What are you most interested in?"
    // selections (CreateDeckSheet.applyProfileDefaultsIfNeeded replaces
    // the fallback list at sheet open).
    var selectedInterests: Set<String> = []
    var interestPrompt: String = ""
    var language = "Arabic"
    var dialect = "MSA"
    var contentType = "Words"
    var amount = "10"
    var level = "A1"
    var selectedTones: Set<String> = ["Casual"]

    // Picker / navigation state
    var activeAttribute: DeckAttribute?
    var showResults = false

    // Generation state
    var isGenerating = false
    var generatedDeck: GeneratedDeck?
    var generationError: String?
    // Surfaced separately from `generationError` so the sheet can
    // present an "Upgrade" CTA + paywall instead of a plain OK alert.
    var capError: SubscriptionError?

    // Chips shown in the interests row. Default to the legacy medical
    // sample set as a graceful fallback for users who haven't completed
    // the new Q8 interests onboarding step. CreateDeckSheet overwrites
    // this with a random 9-chip draw from the user's saved onboarding
    // interests when those are present.
    var interestOptions: [String] = [
        "Anatomy", "Diagnostics", "Surgery", "In the Hospital",
        "Physiology", "Customs", "Emergency Medicine", "Pediatrics"
    ]

    func toggleInterest(_ value: String) {
        if selectedInterests.contains(value) {
            selectedInterests.remove(value)
        } else {
            selectedInterests.insert(value)
        }
    }

    func toggleTone(_ value: String) {
        if selectedTones.contains(value) {
            selectedTones.remove(value)
        } else {
            selectedTones.insert(value)
        }
    }

    func options(for attribute: DeckAttribute) -> [String] {
        switch attribute {
        case .dialect: return dialects(for: language)
        case .level:   return levels(for: language)
        default:       return attribute.options
        }
    }

    func handleLanguageChange() {
        let availableDialects = dialects(for: language)
        if !availableDialects.contains(dialect) {
            dialect = availableDialects.first ?? "Standard"
        }
        let availableLevels = levels(for: language)
        if !availableLevels.contains(level) {
            level = availableLevels.first ?? "A1"
        }
    }

    func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let deck = try await DeckGenerator.generate(
                userPrompt: interestPrompt,
                interests: Array(selectedInterests).sorted(),
                language: language,
                dialect: dialect,
                contentType: contentType,
                amount: amount,
                level: level,
                tones: Array(selectedTones).sorted()
            )
            generatedDeck = deck
            showResults = true
        } catch let error as SubscriptionError {
            capError = error
        } catch {
            generationError = error.localizedDescription
        }
    }
}
