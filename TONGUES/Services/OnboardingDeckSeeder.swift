import Foundation
import Observation

// Auto-generates a new user's starter decks right after they finish
// onboarding, so the Study tab is never empty on first launch. Each
// suggested deck (the titles shown on the final onboarding page) becomes
// a 10-word A1 deck in the user's top language. This is FREE — it bypasses
// the subscription cap entirely (skipCapCheck) and never spends the
// free-deck grace. Paid credits only apply after onboarding.
@MainActor
@Observable
final class OnboardingDeckSeeder {
    static let shared = OnboardingDeckSeeder()

    // True while starter decks are being generated. StudyView shows a
    // "setting up your decks" state instead of the empty state.
    private(set) var isSeeding = false
    // Bumped each time a starter deck is saved, so the Study tab can
    // refresh and reveal them as they land.
    private(set) var seededCount = 0

    private init() {}

    // Kicks off generation in the background (non-blocking) so the app can
    // transition into the main UI immediately. Idempotent — a second call
    // while seeding is in flight is ignored.
    func seed(answers: OnboardingAnswers, titles: [String]) {
        guard !isSeeding else { return }
        let titles = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return }

        isSeeding = true
        seededCount = 0
        AnalyticsService.log(.starterDecksSeedStarted, [
            .planned: min(titles.count, 4)
        ])

        Task {
            defer { isSeeding = false }

            // Resolve the user's top language; snap dialect to a valid one.
            let pref = answers.languagePreferences?.first
            let rawLanguage = pref?.language ?? answers.languageOfInterest ?? "Spanish"
            let language = canonicalLanguageName(rawLanguage)
            let validDialects = dialects(for: language)
            let dialect = validDialects.contains(pref?.dialect ?? "")
                ? (pref?.dialect ?? "")
                : (validDialects.first ?? "")
            let interests = answers.interests ?? []

            // Cap at 4 to match the onboarding "Your first decks" list.
            let plannedTitles = Array(titles.prefix(4))
            let planned = plannedTitles.count
            for title in plannedTitles {
                do {
                    let deck = try await DeckGenerator.generate(
                        userPrompt: title,
                        interests: interests,
                        language: language,
                        dialect: dialect,
                        contentType: "Words",
                        amount: "10",
                        level: "A1",
                        tones: [],
                        skipCapCheck: true   // onboarding is free — no paywall
                    )
                    _ = try await FirebaseDeckService.saveDeck(
                        deck,
                        title: title,
                        source: "onboarding"
                    )
                    seededCount += 1
                } catch {
                    print("⚠️ OnboardingDeckSeeder failed for \"\(title)\": \(error)")
                }
            }
            // Success RATIO matters here: a new user landing in an empty
            // Study tab because seeding silently failed is a first-run
            // experience we'd otherwise never hear about.
            AnalyticsService.log(.starterDecksSeedFinished, [
                .succeeded: seededCount,
                .planned: planned,
                .language: language
            ])
        }
    }
}
