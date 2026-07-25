import Foundation

// Which writing system a card belongs to, and therefore which practice
// engine drives it. The handwriting feature only surfaces for these four
// scripts; every other language returns `nil` from `resolve` and shows no
// practice affordance.
//
// Two tiers (see the feature spec):
//   • strokeMatch — Chinese + Japanese (bundled HanziWriter / KanjiVG medians)
//     and Korean (composed per-syllable from jamo medians, see HangulComposer).
//     True stroke-order matching.
//   • template   — Arabic. Trace-the-template with ink-coverage scoring plus an
//     animated directional guide; the cursive/contextual shaping makes discrete
//     per-stroke medians unreliable, so it stays a guided-tracing experience.
enum HandwritingScript: String, Hashable {
    case chinese
    case japanese
    case korean
    case arabic

    enum Tier {
        case strokeMatch   // Chinese, Japanese, Korean
        case template      // Arabic
    }

    var tier: Tier {
        switch self {
        // Korean joins stroke matching via jamo composition (HangulComposer)
        // — its syllables decompose into a small closed set of jamo with
        // canonical stroke order, so the same matcher drives it.
        case .chinese, .japanese, .korean: return .strokeMatch
        case .arabic:                       return .template
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
