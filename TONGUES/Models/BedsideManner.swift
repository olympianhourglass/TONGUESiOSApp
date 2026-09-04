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

    // Radial-gradient colors for the AI sand-avatar disc, per manner: Direct
    // keeps the app's current blue, Warm is a light green, Withering is red.
    // `discRim` is the base color at the disc's edge; `discCore` is the brighter
    // center glow. Passed to the aiSandAvatar Metal shader as float3s.
    var discRim: SIMD3<Float> {
        switch self {
        case .warm:      return SIMD3(0.373, 0.698, 0.478)   // green
        case .direct:    return SIMD3(0.349, 0.486, 0.698)   // #597CB2 blue
        case .withering: return SIMD3(0.780, 0.110, 0.120)   // red
        }
    }

    var discCore: SIMD3<Float> {
        switch self {
        case .warm:      return SIMD3(0.550, 0.820, 0.620)
        case .direct:    return SIMD3(0.530, 0.690, 0.890)
        case .withering: return SIMD3(0.970, 0.340, 0.400)
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
