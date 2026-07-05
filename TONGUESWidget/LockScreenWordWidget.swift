import WidgetKit
import SwiftUI
import AppIntents

// Lock screen widget. Two accessory families are supported:
//   - .accessoryRectangular (the "large" lock screen tile)
//   - .accessoryCircular    (the "small" lock screen tile)
//
// Configuration model is intentionally simpler than the home screen
// widget: no FSRS, no deck picker, no per-instance Edit Widget options.
// The user picks ONE language in the Profile page; that value lives in
// `WidgetLockScreenLanguageStore` (App Group UserDefaults), and every
// lock screen widget instance reads from there. When nothing has been
// set we fall back to the first language in the snapshot — a sensible
// default since the snapshot's language list is sorted by user activity.

struct LockScreenWordEntry: TimelineEntry {
    let date: Date
    let card: WidgetCard?
}

// StaticConfiguration provider — no AppIntent because lock screen
// instances don't expose a configuration dropdown. Picks a random
// `contentType == "Words"` card in the chosen language each timeline
// step so phrases / sentences never crowd out a single small tile.
struct LockScreenWordProvider: TimelineProvider {

    private static let stepInterval: TimeInterval = 60 * 60
    private static let entriesPerTimeline = 16

    func placeholder(in context: Context) -> LockScreenWordEntry {
        LockScreenWordEntry(
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
            )
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (LockScreenWordEntry) -> Void
    ) {
        completion(LockScreenWordEntry(date: Date(), card: pickCard()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<LockScreenWordEntry>) -> Void
    ) {
        let now = Date()
        let pool = pool()

        guard !pool.isEmpty else {
            let entry = LockScreenWordEntry(date: now, card: nil)
            completion(Timeline(
                entries: [entry],
                policy: .after(now.addingTimeInterval(60 * 60))
            ))
            return
        }

        // Slot-align to absolute hour boundaries so reloads inside the
        // same hour produce identical entries — fixes the perceived
        // mid-hour card jump after the app calls reloadAllTimelines().
        let firstSlot = Int(now.timeIntervalSince1970 / Self.stepInterval)
        let firstSlotStart = Date(
            timeIntervalSince1970: Double(firstSlot) * Self.stepInterval
        )
        let offset = WidgetShuffleOffsetStore.read(.lockScreen)
        // True shuffle: deterministic permutation seeded by the stored
        // value. Tapping shuffle reseeds → a random word; hourly steps walk
        // the shuffled order rather than the raw pool order.
        var generator = WidgetSeededGenerator(seed: UInt64(bitPattern: Int64(offset)))
        let sequence = pool.shuffled(using: &generator)

        var entries: [LockScreenWordEntry] = []
        entries.reserveCapacity(Self.entriesPerTimeline)
        for step in 0..<Self.entriesPerTimeline {
            let date = firstSlotStart.addingTimeInterval(
                Double(step) * Self.stepInterval
            )
            let slot = firstSlot + step
            let index = ((slot) % sequence.count + sequence.count) % sequence.count
            entries.append(LockScreenWordEntry(
                date: date,
                card: sequence[index]
            ))
        }
        let nextRefresh = entries.last?.date.addingTimeInterval(Self.stepInterval)
            ?? now.addingTimeInterval(Self.stepInterval)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    // Words-only filter. Two layers:
    //   1. `contentType == "Words"` — drops every card sourced from a
    //      Phrases or Sentences deck.
    //   2. The foreign string must be a SINGLE whitespace-delimited
    //      token. "Words" decks can still contain multi-word entries
    //      (e.g. "good morning" filed as one vocab item), so the
    //      content-type filter alone lets phrase-shaped cards leak
    //      onto the lock screen. CJK strings without whitespace
    //      (e.g. 你好, おはよう) pass through correctly because they
    //      naturally have zero whitespace separators.
    private func pool() -> [WidgetCard] {
        guard let snapshot = WidgetSnapshotIO.read() else { return [] }
        let language = WidgetLockScreenLanguageStore.read()
            ?? snapshot.languages.first
        guard let language else { return [] }
        return snapshot.cards.filter {
            guard $0.language == language, $0.contentType == "Words" else {
                return false
            }
            let trimmed = $0.foreign.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.contains(where: { $0.isWhitespace })
        }
    }

    private func pickCard() -> WidgetCard? {
        pool().randomElement()
    }
}

struct LockScreenWordEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockScreenWordEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            default:
                rectangularView
            }
        }
        // Tap target: deep-link to the deck the displayed card belongs
        // to. Mirrors the home-screen widget — main app resolves
        // `tongues://deck/{deckID}` to DeckDetailView via the
        // WidgetDeepLinkRouter wired up in TONGUESApp. The shuffle
        // Button inside `rectangularView` keeps its own tap precedence,
        // so only taps outside it trigger the deep link.
        .widgetURL(deepLink)
    }

    // Empty entries fall through with nil so the widget tap simply
    // launches the app on its default screen.
    private var deepLink: URL? {
        guard let card = entry.card else { return nil }
        return URL(string: "tongues://deck/\(card.deckID)")
    }

    // Small (.accessoryCircular): foreign word centered, English
    // beneath it in subtle secondary text. Bounded by the system's
    // circular crop.
    @ViewBuilder
    private var circularView: some View {
        if let card = entry.card {
            VStack(spacing: 0) {
                Text(card.foreign)
                    .font(.system(size: 14, weight: .bold))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                Text(card.english)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .multilineTextAlignment(.center)
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            Image(systemName: "text.book.closed")
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    // Large (.accessoryRectangular): three stacked lines —
    //   1. foreign word (visual anchor)
    //   2. pronunciation / transliteration when present
    //   3. English translation
    // The language label was removed per product spec. A small
    // shuffle button sits at top-trailing for jumping to a different
    // word in the same language pool.
    @ViewBuilder
    private var rectangularView: some View {
        if let card = entry.card {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.foreign)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let translit = card.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(card.english)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(intent: AdvanceLockScreenWordIntent()) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            Text("Add a deck to start cycling words.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    // "Chinese (Mandarin)" → "Mandarin" — same compaction the home
    // screen widget uses.
    private func shortLanguageLabel(_ language: String) -> String {
        if let open = language.firstIndex(of: "("),
           let close = language.firstIndex(of: ")"),
           open < close {
            return String(language[language.index(after: open)..<close])
        }
        return language
    }
}

struct LockScreenWordWidget: Widget {
    let kind: String = "LockScreenWordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenWordProvider()) { entry in
            LockScreenWordEntryView(entry: entry)
        }
        .configurationDisplayName("Word Cycle (Lock)")
        .description("Cycles random words from your chosen language on the lock screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}
