import WidgetKit
import Foundation

// One entry in the widget's timeline. Carries one card + the metadata
// the entry view renders (header label, per-instance background color).
struct WordCycleEntry: TimelineEntry {
    let date: Date
    let card: WidgetCard?
    // What to render in the language label slot. For FSRS or language
    // mode we show the card's language; for deck mode we show the
    // deck title since the language is implicit.
    let headerLabel: String
    // Per-instance background hex, sourced from the widget's
    // configuration intent so each widget on the home screen keeps its
    // own color.
    let backgroundHex: String
    // The configured source's stable identifier — "fsrs",
    // "lang:Spanish", or "deck:<id>". Threaded into the shuffle button's
    // AppIntent so each source bucket keeps its own shuffle offset.
    let sourceID: String
}

// AppIntentTimelineProvider yields entries by reading the snapshot,
// resolving the configured source, building a pool, and stepping
// through it one card per timeline step (default: 15 minutes).
struct WordCycleProvider: AppIntentTimelineProvider {

    private static let stepInterval: TimeInterval = 60 * 60
    private static let entriesPerTimeline = 16 // ≈ 16 hours of variation

    // MARK: - Placeholders

    func placeholder(in context: Context) -> WordCycleEntry {
        WordCycleEntry(
            date: Date(),
            card: WidgetCard(
                cardID: "placeholder",
                deckID: "placeholder",
                deckTitle: "Sample Deck",
                language: "Mandarin",
                dialect: "Standard",
                foreign: "你好",
                english: "Hello",
                transliteration: "nǐ hǎo",
                forgettingRisk: 0,
                contentType: "Words"
            ),
            headerLabel: "Mandarin",
            backgroundHex: WidgetBackgroundColorOption.slate.hex,
            sourceID: WidgetSourceEntity.fsrs.id
        )
    }

    func snapshot(
        for configuration: WordCycleConfigurationIntent,
        in context: Context
    ) async -> WordCycleEntry {
        let source = configuration.source ?? .fsrs
        let pool = pool(for: source, family: context.family)
        let card = pool.first
        return WordCycleEntry(
            date: Date(),
            card: card,
            headerLabel: headerLabel(for: card, source: source),
            backgroundHex: configuration.backgroundColor.hex,
            sourceID: source.id
        )
    }

    func timeline(
        for configuration: WordCycleConfigurationIntent,
        in context: Context
    ) async -> Timeline<WordCycleEntry> {
        let source = configuration.source ?? .fsrs
        let pool = pool(for: source, family: context.family)
        let now = Date()

        guard !pool.isEmpty else {
            // Empty pool (signed out, no decks, source resolves to
            // nothing, etc.) → render an empty entry and try again
            // in an hour.
            let entry = WordCycleEntry(
                date: now,
                card: nil,
                headerLabel: "",
                backgroundHex: configuration.backgroundColor.hex,
                sourceID: source.id
            )
            return Timeline(
                entries: [entry],
                policy: .after(now.addingTimeInterval(60 * 60))
            )
        }

        // Slot-align to absolute hour boundaries so two timeline builds
        // inside the same hour produce identical entry 0 → no perceived
        // mid-hour jump when something calls reloadAllTimelines().
        let firstSlot = Int(now.timeIntervalSince1970 / Self.stepInterval)
        let firstSlotStart = Date(
            timeIntervalSince1970: Double(firstSlot) * Self.stepInterval
        )
        let offset = WidgetShuffleOffsetStore.read(.home(sourceID: source.id))

        var entries: [WordCycleEntry] = []
        entries.reserveCapacity(Self.entriesPerTimeline)
        for step in 0..<Self.entriesPerTimeline {
            let date = firstSlotStart.addingTimeInterval(
                Double(step) * Self.stepInterval
            )
            let slot = firstSlot + step
            // Wrap the combined index into the pool's bounds. The extra
            // `+ pool.count) %` guards against negative offsets if the
            // store ever wraps past Int.max.
            let index = ((slot + offset) % pool.count + pool.count) % pool.count
            let card = pool[index]
            entries.append(
                WordCycleEntry(
                    date: date,
                    card: card,
                    headerLabel: headerLabel(for: card, source: source),
                    backgroundHex: configuration.backgroundColor.hex,
                    sourceID: source.id
                )
            )
        }
        let nextRefresh = entries.last?.date.addingTimeInterval(Self.stepInterval)
            ?? now.addingTimeInterval(Self.stepInterval)
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    // MARK: - Pool construction

    // Resolves the chosen source into a card pool according to the
    // three product configurations:
    //
    //   .fsrs     → every card across every deck, ordered by descending
    //               forgetting risk. The snapshot is pre-sorted, so we
    //               just hand it back as-is. Phrases and sentences are
    //               intentionally included because FSRS works on all
    //               card types the user studies.
    //
    //   .language → every WORD card in that language, in snapshot
    //               order (descending forgetting risk). Phrases and
    //               sentences are excluded explicitly per spec.
    //
    //   .deck     → every WORD card in that deck, in deck order.
    //               Phrases/sentences excluded the same way.
    private func pool(
        for source: WidgetSourceEntity,
        family: WidgetFamily
    ) -> [WidgetCard] {
        guard let snapshot = WidgetSnapshotIO.read() else { return [] }
        // Sentences only show up on the larger widget (.systemMedium) —
        // a "Sentences" card never fits legibly in the small tile, so
        // we exclude them up front for systemSmall. Phrases stay on
        // both sizes; only the long-form Sentences bucket is gated.
        let allowSentences = family != .systemSmall
        let base: [WidgetCard]
        switch source.kind {
        case .fsrs:
            base = snapshot.cards
        case .language:
            guard let target = source.value else { return [] }
            base = snapshot.cards
                .filter { $0.language == target && $0.contentType == "Words" }
        case .deck:
            guard let target = source.value else { return [] }
            base = snapshot.cards.filter {
                $0.deckID == target && $0.contentType == "Words"
            }
        }
        if allowSentences {
            return base
        }
        return base.filter { $0.contentType != "Sentences" }
    }

    private func headerLabel(
        for card: WidgetCard?,
        source: WidgetSourceEntity
    ) -> String {
        guard let card else { return "" }
        switch source.kind {
        case .fsrs, .language:
            return shortLanguageLabel(card.language)
        case .deck:
            return card.deckTitle
        }
    }

    // "Chinese (Mandarin)" → "Mandarin" — same compaction the in-app
    // cards use so the widget label reads naturally at small sizes.
    private func shortLanguageLabel(_ language: String) -> String {
        if let open = language.firstIndex(of: "("),
           let close = language.firstIndex(of: ")"),
           open < close {
            return String(language[language.index(after: open)..<close])
        }
        return language
    }
}
