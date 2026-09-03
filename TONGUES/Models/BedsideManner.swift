import SwiftUI

// The user-chosen "bedside manner" for the conversation partner — how blunt or
// gentle the AI's tone is. Set from the chat overflow (•••) menu. It drives two
// things: the persona line injected into the conversation system prompt, and
// the tint of the overflow-menu icon so the current manner is glanceable.
//
// Tone only shapes delivery. It must never change teaching accuracy, level
// calibration, or correction behavior — those are governed by other prompt
// lines regardless of manner.
enum BedsideManner: String, CaseIterable, Identifiable {
    case warm
    case direct
    case withering

    var id: String { rawValue }

    // The one thing persisted; everything else derives from it.
    static let storageKey = "bedsideManner"

    // Menu label (localize at the call site with L(...)).
    var displayName: String {
        switch self {
        case .warm:      return "Warm"
        case .direct:    return "Direct"
        case .withering: return "Withering"
        }
    }

    // Tint for the overflow (•••) icon: purple = Direct (the default), a light
    // green = Warm, red = Withering.
    var iconColor: Color {
        switch self {
        case .warm:      return Color(libraryHex: "5FB27A")   // light green
        case .direct:    return Color(libraryHex: "7C5CFF")   // purple (default)
        case .withering: return Color(libraryHex: "D6453F")   // red
        }
    }

    // The persona instruction folded into the conversation system prompt.
    // Behavioral and short; corrections + level calibration are handled by
    // other lines and stay constant across manners.
    var promptLine: String {
        switch self {
        case .warm:
            return "Adopt a WARM bedside manner: gentle, encouraging, and patient. Celebrate small wins, soften corrections, and be generous with reassurance."
        case .direct:
            return "Adopt a DIRECT bedside manner: friendly but concise and matter-of-fact. Skip effusive praise, keep the momentum, and get to the point."
        case .withering:
            return "Adopt a WITHERING bedside manner: dry, sardonic, and playfully harsh — a witty drill-sergeant who ribs the learner for mistakes. Keep it in good fun; never be genuinely cruel, demeaning, or discouraging, and never let the persona compromise the accuracy or clarity of your teaching and corrections."
        }
    }
}
