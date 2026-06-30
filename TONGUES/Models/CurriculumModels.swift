import Foundation

// MARK: - Curriculum plan
//
// The artifact the curriculum agent creates and maintains: ordered units
// with CEFR-style can-do goals, each carrying planned activities that map
// 1:1 onto surfaces the app already has (deck generation, conversation
// scenarios, pronunciation drills, reading content).
//
// Stored at `users/{uid}/curricula/{languageID}` — one active plan per
// language. All decode-side fields that postdate the first release are
// optional, mirroring the app-wide back-compat convention.

struct CurriculumPlan: Codable, Hashable, Identifiable {
    var id: String { languageID }

    var language: String
    var languageID: String
    var dialect: String
    var goalStatement: String        // e.g. "Conversational Japanese for an Osaka trip"
    var targetLevel: String          // CEFR-style label
    var targetDate: Date?
    var status: String               // "active" | "completed" | "archived"
    var units: [CurriculumUnit]
    var createdBy: String            // "agent" | "user"
    var revision: Int
    // One-line tutor message queued by the reconciler/replanner, surfaced
    // as an assistant chat bubble next time the user opens chat in this
    // language, then cleared. Keeps cross-view-model races out of the
    // notice path (the plan doc is the single mailbox).
    var pendingTutorNotice: String?
    // When the reconciler last ran a full drift check — drives the
    // weekly replan cadence.
    var lastReviewedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var activeUnit: CurriculumUnit? {
        units.first { $0.status == CurriculumUnit.Status.active.rawValue }
    }

    var completedUnitCount: Int {
        units.filter { $0.status == CurriculumUnit.Status.completed.rawValue }.count
    }

    /// Compact JSON for prompts (planning / replanning calls).
    var promptJSON: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

struct CurriculumUnit: Codable, Hashable, Identifiable {
    enum Status: String {
        case locked, active, completed
    }

    var id: String                   // "u1", "u2", … stable across revisions
    var order: Int
    var title: String
    var canDo: [String]              // Checkable goals, learner-facing
    var status: String               // Status.rawValue — string for Codable simplicity
    var deckIds: [String]            // Guided decks generated for this unit
    var plannedActivities: [PlannedActivity]
    var masteryGate: MasteryGate

    var statusEnum: Status { Status(rawValue: status) ?? .locked }
}

struct PlannedActivity: Codable, Hashable, Identifiable {
    // Activity types map onto existing surfaces:
    //   "deck"          → DeckGenerator + Library
    //   "conversation"  → chat scenario
    //   "pronunciation" → PronunciationDrillSheet focus
    //   "content"       → DeckGenerator.generateContent kinds
    var id: String = UUID().uuidString
    var type: String
    var label: String                // Learner-facing one-liner
    // Free-form spec the executor reads. Keys by type:
    //   deck:          topic, contentType ("Words"/"Phrases"/"Sentences"), amount
    //   conversation:  scenario (prompt text for the AI's opener)
    //   pronunciation: focus
    //   content:       kind (Story/Conversation/News Article/…), topic
    var spec: [String: String]
    // Set once the activity has produced its artifact (deck created,
    // conversation completed). The Today strip skips done activities.
    var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, type, label, spec, completedAt
    }
}

struct MasteryGate: Codable, Hashable {
    /// Fraction of the unit's deck cards that must be FSRS-mature
    /// (stability ≥ LearnerModelService.matureStabilityDays) to pass.
    var matureFraction: Double = 0.8
    /// Whether the unit closes with a checked conversation in chat.
    var conversationCheck: Bool = false
}

// MARK: - Decoding helper for model-generated plans
//
// The planner asks the model for this exact shape; dates ride as ISO8601
// strings. Kept separate from CurriculumPlan so prompt-schema drift never
// breaks Firestore decoding of already-saved plans.
struct GeneratedPlanPayload: Codable {
    struct Unit: Codable {
        struct Activity: Codable {
            let type: String
            let label: String
            let spec: [String: String]?
        }
        let id: String?
        let title: String
        let canDo: [String]
        let activities: [Activity]
        let matureFraction: Double?
        let conversationCheck: Bool?
    }
    let goalStatement: String
    let targetLevel: String
    let units: [Unit]

    /// Materializes the payload into a full plan doc. The first unit is
    /// unlocked; everything else starts locked.
    func asPlan(
        language: String,
        dialect: String,
        revision: Int = 1,
        targetDate: Date? = nil
    ) -> CurriculumPlan {
        let now = Date()
        let units = self.units.enumerated().map { index, unit in
            CurriculumUnit(
                id: unit.id ?? "u\(index + 1)",
                order: index + 1,
                title: unit.title,
                canDo: unit.canDo,
                status: index == 0
                    ? CurriculumUnit.Status.active.rawValue
                    : CurriculumUnit.Status.locked.rawValue,
                deckIds: [],
                plannedActivities: unit.activities.map {
                    PlannedActivity(
                        type: $0.type,
                        label: $0.label,
                        spec: $0.spec ?? [:]
                    )
                },
                masteryGate: MasteryGate(
                    matureFraction: unit.matureFraction ?? 0.8,
                    conversationCheck: unit.conversationCheck ?? false
                )
            )
        }
        return CurriculumPlan(
            language: language,
            languageID: Conversation.languageID(for: language),
            dialect: dialect,
            goalStatement: goalStatement,
            targetLevel: targetLevel,
            targetDate: targetDate,
            status: "active",
            units: units,
            createdBy: "agent",
            revision: revision,
            pendingTutorNotice: nil,
            lastReviewedAt: Date(),
            createdAt: now,
            updatedAt: now
        )
    }
}
