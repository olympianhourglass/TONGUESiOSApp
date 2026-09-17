import Foundation

// Why someone is leaving. Collected in the cancellation flow (and offered
// again on the win-back banner) so the next retention iteration is driven by
// data instead of a guess.
//
// Each case maps to a different remedy, which is the whole point of asking:
//   • tooExpensive  → the downgrade path, or a cheaper plan
//   • notUsingIt    → onboarding / habit problem, not a pricing one
//   • missingFeature / contentQuality → product feedback, routed to the composer
//   • technicalIssue → a bug we can actually fix
//   • finishedLearning → not churn to fight; a win-back later is the right play
enum CancellationReason: String, CaseIterable, Identifiable, Codable {
    case tooExpensive
    case notUsingIt
    case missingFeature
    case contentQuality
    case technicalIssue
    case finishedLearning
    case other

    var id: String { rawValue }

    // Shown in the picker. Kept first-person and blame-free so the list reads
    // as a genuine question rather than a defence of the product.
    var label: String {
        switch self {
        case .tooExpensive:    return "It's too expensive"
        case .notUsingIt:      return "I'm not using it enough"
        case .missingFeature:  return "It's missing something I need"
        case .contentQuality:  return "The content wasn't good enough"
        case .technicalIssue:  return "Something wasn't working"
        case .finishedLearning: return "I got what I needed"
        case .other:           return "Something else"
        }
    }

    // Reasons where a free extension is a plausible save. Offering "2 more
    // weeks free" to someone who's simply done learning, or who hit a bug, is
    // tone-deaf — those get a more honest response instead.
    var isSaveableWithTime: Bool {
        switch self {
        case .tooExpensive, .notUsingIt:            return true
        case .missingFeature, .contentQuality,
             .technicalIssue, .finishedLearning,
             .other:                                return false
        }
    }

    // Reasons that are really product feedback, so the flow should offer the
    // feedback composer rather than a discount.
    var wantsFeedback: Bool {
        switch self {
        case .missingFeature, .contentQuality,
             .technicalIssue, .other:               return true
        case .tooExpensive, .notUsingIt,
             .finishedLearning:                     return false
        }
    }
}
