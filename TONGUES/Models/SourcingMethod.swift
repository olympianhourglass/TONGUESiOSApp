import Foundation

// How a word entered the user's library. Drives the Statistics tab's
// "Sourcing Method" distribution. Stamped onto each GeneratedItem at the point
// it's gathered; the raw value is what's persisted on the item.
enum SourcingMethod: String, CaseIterable, Identifiable, Hashable {
    case generate           // Create New Deck → Generate
    case camera             // Create New Deck → Camera
    case direct             // Create New Deck → Direct (translate)
    case songVideo          // Create New Deck → Song or Video Link
    case largeBodyText      // Create New Deck → Large Body Text
    case artifact           // Added a word from a generated artifact
    case conversation       // Added words from a conversation with the AI

    var id: String { rawValue }

    // English display label (localized at the call site via `L(...)`).
    var displayName: String {
        switch self {
        case .generate:      return "Generate"
        case .camera:        return "Camera"
        case .direct:        return "Direct"
        case .songVideo:     return "Song or Video"
        case .largeBodyText: return "Large Text"
        case .artifact:      return "Artifact"
        case .conversation:  return "Conversation"
        }
    }
}

// One sourcing method's share of the user's total gathered words, for the
// distribution bar + rows.
struct SourcingMethodShare: Identifiable, Hashable {
    let method: SourcingMethod
    let percent: Double
    var id: String { method.id }
}
