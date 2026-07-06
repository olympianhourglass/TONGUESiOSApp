import Foundation
import WidgetKit

// Builds the WidgetSnapshot from already-loaded deck/schedule data and
// drops it into the shared App Group container. The widget extension's
// TimelineProvider reads from there.
//
// Called from LibraryViewModel.loadDecks (after the main fetch finishes)
// and from FlashcardView.onSessionComplete (so freshly-reviewed cards
// reflect their new FSRS state immediately on the widget).
//
// Failures are intentionally swallowed — a widget snapshot is a nice-
// to-have; never block the main app on it.
@MainActor
enum WidgetSnapshotWriter {

    // Fire-and-forget refresh: pulls fresh decks + schedules from
    // Firestore and writes a new snapshot. Used from contexts that
    // don't already have those collections in memory — e.g., the
    // flashcard finish screen wants the widget to reflect the just-
    // updated FSRS state without waiting for the user to navigate back
    // to the Library tab.
    static func refreshFromBackend() {
        Task { @MainActor in
            do {
                async let decksTask = FirebaseDeckService.fetchDecks()
                async let schedulesTask = FirebaseDeckService.fetchAllSchedules()
                let decks = try await decksTask
                let schedules = try await schedulesTask
                writeSnapshot(decks: decks, schedules: schedules)
            } catch {
                print("WidgetSnapshotWriter refreshFromBackend failed: \(error)")
            }
        }
    }

    static func writeSnapshot(
        decks: [DeckDocument],
        schedules: [String: CardSchedule],
        now: Date = Date()
    ) {
        let cards = buildCards(decks: decks, schedules: schedules, now: now)
        let deckRefs = buildDeckRefs(decks: decks)
        let languages = buildLanguages(decks: decks)

        let snapshot = WidgetSnapshot(
            generatedAt: now,
            cards: cards,
            decks: deckRefs,
            languages: languages
        )

        if WidgetSnapshotIO.write(snapshot) {
            // Best-effort widget reload. WidgetKit budgets ~40-70 of
            // these per day; we call it on every major data change
            // (loadDecks, session complete) which stays well under.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Builders

    // One WidgetCard per (deck × item). Pre-sorted by descending
    // forgettingRisk so the widget's "At Risk" mode can just read the
    // top of the array without re-ranking, and the other modes filter
    // a still-ranked subset.
    private static func buildCards(
        decks: [DeckDocument],
        schedules: [String: CardSchedule],
        now: Date
    ) -> [WidgetCard] {
        var cards: [WidgetCard] = []
        cards.reserveCapacity(decks.reduce(0) { $0 + $1.items.count })

        for deck in decks {
            guard let deckID = deck.id else { continue }
            for item in deck.items {
                let cardID = item.id.uuidString
                let schedule = schedules[cardID]
                let risk = FSRSScheduler.forgettingRisk(for: schedule, at: now)

                // Skip items that are missing a usable foreign / english
                // pair — the widget can't render them and including them
                // would just waste pool slots.
                let foreign = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
                let english = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !foreign.isEmpty, !english.isEmpty else { continue }

                let transliteration = item.transliteration?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cards.append(
                    WidgetCard(
                        cardID: cardID,
                        deckID: deckID,
                        deckTitle: deck.title,
                        language: deck.language,
                        dialect: deck.dialect,
                        foreign: foreign,
                        english: english,
                        transliteration: transliteration?.isEmpty == false ? transliteration : nil,
                        forgettingRisk: risk,
                        // Fold "Phrases" → "Sentences" so the widget's
                        // sentence gating (small-widget exclusion, single-
                        // word source filter) applies to legacy phrase decks.
                        contentType: canonicalContentType(deck.contentType)
                    )
                )
            }
        }
        // Descending risk → first element of `cards` is the most-likely-
        // to-be-forgotten card across the user's whole library.
        cards.sort { $0.forgettingRisk > $1.forgettingRisk }
        return cards
    }

    private static func buildDeckRefs(decks: [DeckDocument]) -> [WidgetDeckRef] {
        decks.compactMap { deck in
            guard let id = deck.id else { return nil }
            return WidgetDeckRef(
                deckID: id,
                title: deck.title,
                language: deck.language
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func buildLanguages(decks: [DeckDocument]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for deck in decks where !seen.contains(deck.language) {
            seen.insert(deck.language)
            ordered.append(deck.language)
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
