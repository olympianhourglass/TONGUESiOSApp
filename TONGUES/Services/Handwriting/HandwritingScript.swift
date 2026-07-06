import Foundation

// Which writing system a card belongs to, and therefore which practice
// engine drives it. The handwriting feature only surfaces for these four
// scripts; every other language returns `nil` from `resolve` and shows no
// practice affordance.
//
// Two tiers (see the feature spec):
//   • strokeMatch — Chinese + Japanese. True stroke-order matching against
//     bundled median data (HanziWriter / KanjiVG).
//   • template   — Korean + Arabic. Trace-the-template with ink-coverage
//     scoring; handles Arabic RTL/contextual shaping and Hangul composition
//     by rendering the whole word as a faint guide.
enum HandwritingScript: String, Hashable {
    case chinese
    case japanese
    case korean
    case arabic

    enum Tier {
        case strokeMatch   // Chinese, Japanese
        case template      // Korean, Arabic
    }

    var tier: Tier {
        switch self {
        case .chinese, .japanese: return .strokeMatch
        case .korean, .arabic:    return .template
        }
    }

    /// True when characters should be laid out / traced right-to-left.
    var isRightToLeft: Bool { self == .arabic }

    var displayName: String {
        switch self {
        case .chinese:  return "Chinese"
        case .japanese: return "Japanese"
        case .korean:   return "Korean"
        case .arabic:   return "Arabic"
        }
    }

    /// Resolve the script from a deck/card language label. Prefers the
    /// per-item language when present, falling back to the deck language.
    /// Matches the labels used in `DeckAttribute.language` (e.g.
    /// "Chinese (Mandarin)", "Taiwanese", "Japanese", "Korean", "Arabic").
    static func resolve(itemLanguage: String?, deckLanguage: String) -> HandwritingScript? {
        resolve(from: itemLanguage) ?? resolve(from: deckLanguage)
    }

    static func resolve(from language: String?) -> HandwritingScript? {
        guard let raw = language?.lowercased() else { return nil }
        if raw.contains("chinese") || raw.contains("mandarin")
            || raw.contains("cantonese") || raw.contains("taiwanese") {
            return .chinese
        }
        if raw.contains("japanese") { return .japanese }
        if raw.contains("korean") { return .korean }
        if raw.contains("arabic") { return .arabic }
        return nil
    }
}
