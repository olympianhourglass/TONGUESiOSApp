import SwiftUI
import WidgetKit
import AppIntents

// Card-style widget body. Mirrors the dark slate card design the
// product approved:
//   - language label, top-left, light gray
//   - English word, ~mid-card, slightly lighter
//   - target-language word, large bold, the visual anchor
//
// Tap target: the whole card deep-links into the deck the current
// card belongs to via `widgetURL`. Main app's URL handler resolves
// `tongues://deck/{deckID}` to DeckDetailView.
struct WordCycleEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WordCycleEntry

    var body: some View {
        ZStack(alignment: .topLeading) {
            slate

            if let card = entry.card {
                content(card: card)
            } else {
                emptyState
            }
        }
        .overlay(alignment: .bottom) {
            // Small widget parks the shuffle at the bottom center, ~8pt
            // above the widget's bottom edge — leaves the left-aligned
            // language / English / foreign stack untouched while still
            // giving the shuffle a discoverable footer affordance. The
            // medium widget places its shuffle inline next to the
            // foreign word (see `content(card:)`) so it sits on the
            // same row as the visual anchor.
            if family == .systemSmall, entry.card != nil, showsShuffle {
                shuffleButton
                    .padding(.bottom, 8)
            }
        }
        // ContainerBackground tints the widget's system background so
        // we can keep our solid slate look on iOS 17+ where the system
        // composes widgets over a tinted home screen.
        .containerBackground(for: .widget) { slate }
        .widgetURL(deepLink)
    }

    // Audio-context `shuffle` glyph reads as "next track"-style
    // affordance. Its tap target takes precedence over the surrounding
    // `.widgetURL`, so tapping outside the button still deep-links
    // into the deck.
    // FSRS is a risk-ordered mode — shuffling would defeat its purpose —
    // so the shuffle button is hidden when the source is FSRS. Language
    // and deck sources keep it.
    private var showsShuffle: Bool {
        entry.sourceID != WidgetSourceEntity.fsrs.id
    }

    private var shuffleButton: some View {
        Button(intent: AdvanceWordCycleIntent(sourceID: entry.sourceID)) {
            Image(systemName: "shuffle")
                .font(.system(
                    size: family == .systemSmall ? 11 : 13,
                    weight: .semibold
                ))
                .foregroundStyle(foreground.opacity(0.65))
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    private var slate: some View {
        // Per-widget-instance background pulled from the configuration
        // intent (set via long-press → Edit Widget).
        Color(widgetHex: entry.backgroundHex)
    }

    // Foreground for text + icons, chosen for legibility against whatever
    // background the user picked: black on light backgrounds (e.g. the
    // "Pleasant" blue), white on the dark ones. Threshold sits above the
    // mid-gray "Sage" swatch so only clearly-light backgrounds flip.
    private var foreground: Color {
        Color.perceivedLuminance(ofHex: entry.backgroundHex) > 0.7 ? .black : .white
    }

    private func content(card: WidgetCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Language / deck label
            Text(entry.headerLabel)
                .font(.custom("NeueHaasDisplay-Light", size: family == .systemSmall ? 13 : 15))
                .foregroundStyle(foreground.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            // English word (smaller, positioned right above the target word)
            Text(card.english)
                .font(.custom("NeueHaasDisplay-Light", size: family == .systemSmall ? 15 : 18))
                .foregroundStyle(foreground.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            // Target-language word (the visual anchor). On medium / large
            // widgets the shuffle button rides on the same row at the
            // trailing edge so it stays vertically tied to the anchor
            // rather than floating in the corner. Small widgets render
            // the foreign word alone here — their shuffle lives at the
            // bottom-center, set up in the parent overlay.
            HStack(alignment: .center, spacing: 8) {
                Text(card.foreign)
                    .font(.custom("NeueHaasDisplay-Bold", size: family == .systemSmall ? 26 : 36))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .padding(.top, 2)

                if family != .systemSmall, showsShuffle {
                    Spacer(minLength: 0)
                    shuffleButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Pronunciation / transliteration directly below the
            // foreign anchor when the card has one. Italic + dimmed so
            // the eye still treats the foreign word as the primary
            // hit. Empty/nil transliterations render nothing so
            // Latin-script languages don't get a hollow gap.
            if let translit = card.transliteration, !translit.isEmpty {
                Text(translit)
                    .font(.custom("NeueHaasDisplay-Light", size: family == .systemSmall ? 12 : 14))
                    .italic()
                    .foregroundStyle(foreground.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, family == .systemSmall ? 14 : 18)
        // Small widgets get an extra 16pt above the language label so
        // the content sits lower; medium keeps its symmetric 18pt.
        .padding(.top, family == .systemSmall ? 30 : 18)
        .padding(.bottom, family == .systemSmall ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No cards yet")
                .font(.custom("NeueHaasDisplay-Light", size: family == .systemSmall ? 14 : 16))
                .foregroundStyle(foreground.opacity(0.6))
            Text("Add a deck to start cycling words here.")
                .font(.custom("NeueHaasDisplay-Light", size: family == .systemSmall ? 12 : 13))
                .foregroundStyle(foreground.opacity(0.45))
                .lineLimit(2)
        }
        .padding(family == .systemSmall ? 14 : 18)
    }

    // MARK: - Deep link

    // Empty entries fall through with nil so the widget tap simply
    // launches the app on its default screen.
    private var deepLink: URL? {
        guard let card = entry.card else { return nil }
        return URL(string: "tongues://deck/\(card.deckID)")
    }
}

// Converts a 6-char hex string ("4E5B65") into a SwiftUI Color.
// Invalid inputs fall back to the palette default so the widget never
// renders a transparent background.
extension Color {
    init(widgetHex hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else {
            self = Color(red: 78 / 255, green: 91 / 255, blue: 101 / 255)
            return
        }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    // Rec. 601 perceived luminance of a 6-char hex, 0 (black) → 1 (white).
    // Used to pick a legible foreground over the widget background. Returns
    // 0 (treated as dark) for invalid input.
    static func perceivedLuminance(ofHex hex: String) -> Double {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else { return 0 }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
