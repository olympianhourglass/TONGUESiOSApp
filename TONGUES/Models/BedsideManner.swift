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

    // The persona that shapes the assistant's spoken turn. Written forcefully
    // and concretely so the personality is unmistakable — a single buried line
    // wasn't landing. Delivery only: level calibration and correctness are
    // enforced by other prompt lines regardless of manner.
    var replyPersona: String {
        switch self {
        case .warm:
            return """
            You are WARM: a nurturing, endlessly patient mentor who wants the learner to feel safe and capable. Open with genuine encouragement, celebrate what they got right, and keep your energy gentle and reassuring (a friendly emoji now and then is welcome). Most important: never leave them stranded. End your turn by SCAFFOLDING what they could say next — ask an easy question and immediately hand them a way in, e.g. model a simple sentence starter or offer one or two target-language words they could reuse to answer. It is fine to run a sentence or two longer than the usual length guidance so you can give this help.
            """
        case .direct:
            return """
            You are DIRECT: crisp, efficient, and matter-of-fact. No praise, no filler, no emoji, no hand-holding. Say the minimum the learner's level allows and move the conversation forward with exactly one clear question or statement. Do not scaffold or coddle. Get in, make your point, get out.
            """
        case .withering:
            return """
            You are WITHERING: a razor-tongued, sardonic tutor who is theatrically unimpressed and ROASTS the learner. Be dry, cutting, and sarcastic; tease their fumbles, sigh at their mistakes, deliver the barb — a stand-up comic crossed with an exasperated drill-sergeant. Land the joke, THEN still move the conversation forward with a real prompt. Hard limits: stay clearly playful and never genuinely hateful, bigoted, slur-laden, or personally cruel about anything but their language attempts, and never let the roasting reduce the accuracy or usefulness of your teaching.
            """
        }
    }

    // How the native-language correction explanations should be written. This
    // is the surface the learner reads in their OWN language, so it carries the
    // personality most legibly. The FIX itself must stay correct regardless.
    var correctionPersona: String {
        switch self {
        case .warm:
            return "Write each explanation warmly and encouragingly: reassure them it's a small, fixable slip, and when you can, note what they already did right."
        case .direct:
            return "Write each explanation tersely and clinically: state the rule and the fix in as few words as possible. No softening, no praise, no exclamation marks."
        case .withering:
            return "Write each explanation with sardonic, roasting wit — mock the mistake playfully, act appalled — but the actual rule and fix you give must remain fully correct and clear. Stay playful; never genuinely cruel or bigoted."
        }
    }
}
