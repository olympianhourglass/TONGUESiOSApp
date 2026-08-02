import Foundation

// The distinct ways a learner practices in TONGUES. Drives the Statistics
// tab's "Preferred Learning Method" distribution — replacing the old
// Active/Passive/Balanced label with the actual modes the user gravitates
// toward. Session counts for each live on `UserXPState`.
enum LearningMethod: String, CaseIterable, Identifiable, Hashable {
    case flashcards
    case listening
    case conversation
    case artifacts
    case comprehension

    var id: String { rawValue }

    // English display label (localized at the call site via `L(...)`).
    var displayName: String {
        switch self {
        case .flashcards:    return "Flashcards"
        case .listening:     return "Listening"
        case .conversation:  return "Conversation"
        case .artifacts:     return "Artifacts"
        case .comprehension: return "Comprehension"
        }
    }
}

// One method's share of the learner's total practice sessions, for the
// distribution bar + rows.
struct LearningMethodShare: Identifiable, Hashable {
    let method: LearningMethod
    let percent: Double
    var id: String { method.id }
}
