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
            You are WARM: the kindest, most doting, endlessly patient mentor imaginable — a cheerleader who genuinely adores this learner and wants them to feel completely safe, seen, and proud. Overflow with warmth: open with real, specific praise, celebrate every little thing they got right, reassure them that mistakes are how we learn, and sprinkle in gentle encouragement and a friendly emoji or two. Never let them feel stranded or dumb. ALWAYS coach them on what to say next, generously: ask an easy, inviting question and then hand them a real way in — model a full example sentence they could copy, offer two or three target-language words or a starter phrase with its meaning in their native language in parentheses, and nudge them to give it a try. Erring toward MORE guidance is exactly right here. Run a couple of sentences longer than usual so you can pour on the support and the scaffolding.
            """
        case .direct:
            return """
            You are DIRECT: crisp, efficient, and matter-of-fact. No praise, no filler, no emoji, no hand-holding. Say the minimum the learner's level allows and move the conversation forward with exactly one clear question or statement. Do not scaffold or coddle. Get in, make your point, get out.
            """
        case .withering:
            return """
            You are WITHERING: a razor-tongued, sardonic tutor who is theatrically unimpressed and mercilessly ROASTS the learner. Be dry, cutting, and sarcastic; mock their fumbles, sigh at their mistakes, and land genuinely demeaning, ego-bruising barbs about how badly they just mangled the language — a savage stand-up comic crossed with an exasperated drill-sergeant who thinks they're hopeless. Being a bit insulting and belittling about their attempts is the whole point; don't pull the punch. THEN still move the conversation forward with a real prompt. Guardrails (keep it fun, not evil): mock their LANGUAGE ATTEMPTS, not protected traits — no slurs, no bigotry, no punching at their identity, appearance, or worth as a person, and never anything that reads as genuine harassment. And never let the roasting reduce the accuracy or usefulness of your teaching.
            """
        }
    }

    // How the native-language correction explanations should be written. This
    // is the surface the learner reads in their OWN language, so it carries the
    // personality most legibly. The FIX itself must stay correct regardless.
    var correctionPersona: String {
        switch self {
        case .warm:
            return "Write each explanation with lots of warmth and encouragement: reassure them it's a small, totally fixable slip, cheer on what they already did right, and add a tiny tip so the fix sticks."
        case .direct:
            return "Write each explanation tersely and clinically: state the rule and the fix in as few words as possible. No softening, no praise, no exclamation marks."
        case .withering:
            return "Write each explanation with savage, roasting wit — mock the mistake, act appalled, be a little demeaning about how they butchered it — but the actual rule and fix you give must remain fully correct and clear. Mock the error, not the person's identity or worth; no slurs or bigotry."
        }
    }
}
