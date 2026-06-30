import Foundation

// Structured payloads the tutor agent can attach to an assistant chat
// bubble — the "visible agency" layer. Each case renders as a native
// card in ChatView (deck preview with a Save button, plan proposal with
// Accept, etc.) instead of a wall of text.
//
// Codable strategy: a `type` discriminator + per-case payload key.
// Unknown future types decode to `.unsupported` so old app versions
// keep loading conversations written by newer ones — same degradation
// philosophy as every optional field in this codebase.
enum MessageAttachment: Codable, Hashable {
    case deckProposal(DeckProposalPayload)
    case planProposal(PlanProposalPayload)
    case planUpdate(PlanUpdatePayload)
    case progressSnapshot(ProgressSnapshotPayload)
    case placementResult(PlacementResultPayload)
    case unsupported

    private enum CodingKeys: String, CodingKey {
        case type, deck, plan, update, progress, placement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "deckProposal":
            if let payload = try? container.decode(DeckProposalPayload.self, forKey: .deck) {
                self = .deckProposal(payload)
            } else {
                self = .unsupported
            }
        case "planProposal":
            if let payload = try? container.decode(PlanProposalPayload.self, forKey: .plan) {
                self = .planProposal(payload)
            } else {
                self = .unsupported
            }
        case "planUpdate":
            if let payload = try? container.decode(PlanUpdatePayload.self, forKey: .update) {
                self = .planUpdate(payload)
            } else {
                self = .unsupported
            }
        case "progressSnapshot":
            if let payload = try? container.decode(ProgressSnapshotPayload.self, forKey: .progress) {
                self = .progressSnapshot(payload)
            } else {
                self = .unsupported
            }
        case "placementResult":
            if let payload = try? container.decode(PlacementResultPayload.self, forKey: .placement) {
                self = .placementResult(payload)
            } else {
                self = .unsupported
            }
        default:
            self = .unsupported
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .deckProposal(let payload):
            try container.encode("deckProposal", forKey: .type)
            try container.encode(payload, forKey: .deck)
        case .planProposal(let payload):
            try container.encode("planProposal", forKey: .type)
            try container.encode(payload, forKey: .plan)
        case .planUpdate(let payload):
            try container.encode("planUpdate", forKey: .type)
            try container.encode(payload, forKey: .update)
        case .progressSnapshot(let payload):
            try container.encode("progressSnapshot", forKey: .type)
            try container.encode(payload, forKey: .progress)
        case .placementResult(let payload):
            try container.encode("placementResult", forKey: .type)
            try container.encode(payload, forKey: .placement)
        case .unsupported:
            try container.encode("unsupported", forKey: .type)
        }
    }
}

// A deck the agent generated but did NOT save — the user disposes.
// Carries everything needed to materialize a GeneratedDeck on Save,
// plus `savedDeckId` once the user accepts so the card flips to a
// checkmark and double-saves are blocked.
struct DeckProposalPayload: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var language: String
    var dialect: String
    var level: String
    var contentType: String          // "Words" / "Phrases" / "Sentences"
    var topic: String                // What the agent was asked for
    var items: [GeneratedItem]
    var planUnitId: String?          // Set when generated for a curriculum unit
    var savedDeckId: String?

    func asGeneratedDeck() -> GeneratedDeck {
        GeneratedDeck(
            id: id,
            title: title,
            items: items,
            language: language,
            dialect: dialect,
            level: level,
            contentType: contentType,
            amount: "\(items.count)",
            tones: [],
            interests: [],
            userPrompt: topic,
            promptSent: "tutor-agent",
            rawJSON: ""
        )
    }
}

// A curriculum plan the agent drafted but did NOT save — the user
// accepts via the card. `accepted` flips once saved so the card shows a
// checkmark and re-accepts are blocked.
struct PlanProposalPayload: Codable, Hashable {
    var plan: CurriculumPlan
    var accepted: Bool?
}

// Summary of a plan revision the reconciler/replanner produced. The
// changes list is learner-facing prose ("Pulled the particles unit
// forward"), not a machine diff.
struct PlanUpdatePayload: Codable, Hashable {
    var headline: String
    var changes: [String]
    var revision: Int
}

// Compact progress stats the agent can show as a card when the user
// asks "how am I doing?".
struct ProgressSnapshotPayload: Codable, Hashable {
    var language: String
    var levelLabel: String
    var totalCards: Int
    var matureCards: Int
    var dueNow: Int
    var streakDays: Int
    var weakWords: [String]
}

// Outcome of a conversational placement (Phase 4).
struct PlacementResultPayload: Codable, Hashable {
    var language: String
    var level: String
    var confidence: Double
    var rationale: String
}
