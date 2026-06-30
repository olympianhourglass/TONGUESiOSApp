import WidgetKit
import AppIntents

// User-facing configuration for the Word Cycle widget. iOS shows this
// when the user long-presses the widget → Edit Widget. Only two
// dropdowns are exposed: a single unified "Source" picker (FSRS, every
// language the user has, every deck the user has — all flattened into
// one list) and "Background color". Each widget instance keeps its own
// values; iOS owns per-instance configuration.

// What a source represents. Encoded into the entity's id with a kind
// prefix so the provider can dispatch on it without an extra field
// (AppEntity ids are plain Strings).
enum WidgetSourceKind: String {
    case fsrs
    case language
    case deck
}

// Palette swatches surfaced as a separate dropdown in the Edit Widget
// panel. Each enum case carries its hex string so the provider can
// hand the pre-resolved color down to the entry view.
enum WidgetBackgroundColorOption: String, AppEnum {
    case slate
    case black
    case redOrange
    case deepCrimson
    case sage

    var hex: String {
        switch self {
        case .slate:        return "4E5B65"
        case .black:        return "000000"
        case .redOrange:    return "FF2C02"
        case .deepCrimson:  return "3C0F06"
        case .sage:         return "A5A597"
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Background color")

    static var caseDisplayRepresentations: [WidgetBackgroundColorOption: DisplayRepresentation] = [
        .slate:       DisplayRepresentation(title: "Slate"),
        .black:       DisplayRepresentation(title: "Black"),
        .redOrange:   DisplayRepresentation(title: "Red"),
        .deepCrimson: DisplayRepresentation(title: "Crimson"),
        .sage:        DisplayRepresentation(title: "Sage")
    ]
}

// One row in the unified source dropdown. The id format is:
//   "fsrs"               → FSRS across everything
//   "lang:<Language>"    → every word card in that language
//   "deck:<deckID>"      → every word card in that deck
// Phrases and sentences are excluded from language/deck sources at
// pool-build time in WordCycleProvider; FSRS keeps everything.
struct WidgetSourceEntity: AppEntity, Hashable {
    let id: String
    let title: String
    let subtitle: String?

    var kind: WidgetSourceKind {
        if id == "fsrs" { return .fsrs }
        if id.hasPrefix("lang:") { return .language }
        if id.hasPrefix("deck:") { return .deck }
        return .fsrs
    }

    // Strips the kind prefix to get the language name / deck id back.
    var value: String? {
        if id == "fsrs" { return nil }
        if let range = id.range(of: ":") {
            return String(id[range.upperBound...])
        }
        return nil
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Source")

    var displayRepresentation: DisplayRepresentation {
        if let subtitle {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
        }
        return DisplayRepresentation(title: "\(title)")
    }

    static var defaultQuery = WidgetSourceQuery()

    static let fsrs = WidgetSourceEntity(
        id: "fsrs",
        title: "Most at risk (FSRS)",
        subtitle: "All cards across decks"
    )

    static func language(_ name: String) -> WidgetSourceEntity {
        WidgetSourceEntity(id: "lang:\(name)", title: name, subtitle: "Language · Words")
    }

    static func deck(deckID: String, title: String, language: String) -> WidgetSourceEntity {
        WidgetSourceEntity(id: "deck:\(deckID)", title: title, subtitle: "\(language) · Words")
    }
}

struct WidgetSourceQuery: EntityQuery {
    // Resolves an existing id back into an entity. Used by iOS when
    // restoring a previously-picked source from the saved intent state.
    func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
        let snapshot = WidgetSnapshotIO.read()
        return identifiers.compactMap { id -> WidgetSourceEntity? in
            if id == "fsrs" { return .fsrs }
            if id.hasPrefix("lang:") {
                let name = String(id.dropFirst("lang:".count))
                return .language(name)
            }
            if id.hasPrefix("deck:") {
                let deckID = String(id.dropFirst("deck:".count))
                if let deck = snapshot?.decks.first(where: { $0.deckID == deckID }) {
                    return .deck(deckID: deck.deckID, title: deck.title, language: deck.language)
                }
                return WidgetSourceEntity(id: id, title: "Deck", subtitle: nil)
            }
            return nil
        }
    }

    // Populates the Edit Widget dropdown. FSRS sits at the top, then
    // every language alphabetically, then every deck — single flat list.
    func suggestedEntities() async throws -> [WidgetSourceEntity] {
        var result: [WidgetSourceEntity] = [.fsrs]
        guard let snapshot = WidgetSnapshotIO.read() else { return result }
        for lang in snapshot.languages {
            result.append(.language(lang))
        }
        for deck in snapshot.decks {
            result.append(.deck(deckID: deck.deckID, title: deck.title, language: deck.language))
        }
        return result
    }

    func defaultResult() async -> WidgetSourceEntity? { .fsrs }
}

// The intent surfaced to iOS as the widget's configuration. Exactly
// two dropdowns: source + background color. iOS persists each widget
// instance's pick independently.
struct WordCycleConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Word Cycle Settings"
    static var description = IntentDescription("Pick which words this widget cycles through.")

    @Parameter(title: "Source")
    var source: WidgetSourceEntity?

    @Parameter(title: "Background color", default: .slate)
    var backgroundColor: WidgetBackgroundColorOption
}
