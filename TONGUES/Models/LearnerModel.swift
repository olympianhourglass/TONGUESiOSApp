import Foundation

// The unified per-user, per-language memory the curriculum agent reads
// before every planning decision. One doc per language at
// `users/{uid}/learnerModels/{languageID}`.
//
// Everything in here is *derived* — FSRS schedules, conversation
// corrections, pronunciation attempts, XP state and onboarding answers
// remain the sources of truth. LearnerModelService rebuilds this doc
// when it goes stale, so losing or deleting it is always safe.
struct LearnerModel: Codable, Hashable {
    // MARK: Level

    struct LevelEstimate: Codable, Hashable {
        var value: String          // CEFR-style label, e.g. "A2"
        var confidence: Double     // 0...1
        // Where the estimate came from: "onboarding" (self-reported),
        // "placement" (conversational placement), "inferred" (drifted
        // from observed correction density / FSRS difficulty).
        var source: String
        var updatedAt: Date
    }

    // MARK: Goals (verbatim from onboarding; the planner quotes these)

    struct Goals: Codable, Hashable {
        var motivation: String?
        var fluencyScene: String?
        var firstUnderstand: String?
        var heritage: String?
        var destinations: [String]
        var interests: [String]
        var targetDate: Date?
    }

    // MARK: Vocabulary state (from FSRS schedules)

    struct WeakWord: Codable, Hashable {
        let word: String
        let lapses: Int
        let stability: Double
    }

    struct VocabSummary: Codable, Hashable {
        var totalCards: Int = 0
        var matureCards: Int = 0      // stability ≥ 21 days
        var youngCards: Int = 0       // reviewed but not yet mature
        var newCards: Int = 0         // never reviewed
        var dueNow: Int = 0
        var lapsingWords: [WeakWord] = []   // highest-lapse cards, capped
        var recentTopics: [String] = []     // interests of recently studied decks
    }

    // MARK: Skills (from conversation corrections + pronunciation drills)

    struct RecurringError: Codable, Hashable {
        let pattern: String        // Clustered label, e.g. "gender agreement"
        let count: Int
        let example: String?       // One original → corrected sample
    }

    struct PronunciationTrouble: Codable, Hashable {
        let target: String         // Sentence drilled
        let bestScore: Int
        let attempts: Int
    }

    struct Skills: Codable, Hashable {
        var recurringErrors: [RecurringError] = []
        var pronunciationTrouble: [PronunciationTrouble] = []
        // Rolling conversational-accuracy signal (Phase 4 calibration):
        // corrections per user turn over the recent window. Lower = cleaner.
        var recentCorrectionsPerTurn: Double? = nil
        var recentTurnsSampled: Int? = nil
    }

    // MARK: Habits (from XP state + session history)

    struct Habits: Codable, Hashable {
        var streakDays: Int = 0
        var totalXP: Int = 0
        var preferredMethod: String = "—"   // Active / Passive / Balanced
        var estimatedMinutesPerDay: Double? = nil
    }

    // MARK: Stored fields

    var language: String
    var languageID: String
    var dialect: String
    var levelEstimate: LevelEstimate
    var goals: Goals
    var vocab: VocabSummary
    var skills: Skills
    var habits: Habits
    var updatedAt: Date

    // MARK: Prompt rendering

    /// Compact JSON the agent sees. Kept deliberately small — weak words
    /// and error patterns are already capped at build time.
    var promptJSON: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// One-line goals summary injected into the plain conversation system
    /// prompt (the non-agent path) so everyday chat carries the learner's
    /// motivation without shipping the whole model.
    var goalsLine: String? {
        var parts: [String] = []
        if let m = goals.motivation, !m.isEmpty { parts.append("motivation: \(m)") }
        if !goals.destinations.isEmpty {
            parts.append("destinations: \(goals.destinations.prefix(3).joined(separator: ", "))")
        }
        if !goals.interests.isEmpty {
            parts.append("interests: \(goals.interests.prefix(5).joined(separator: ", "))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
