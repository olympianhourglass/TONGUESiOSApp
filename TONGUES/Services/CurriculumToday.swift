import Foundation

// Builds the per-language "Today" queue: one short, ranked list of the single
// next best actions a learner should take right now. Pure and derived — a view
// over the plan + FSRS state, never persisted — so it recomputes cheaply on
// every load. Priority order:
//   1. Review debt  — clearing FSRS-due cards is always the highest-value beat.
//   2. Next activity — the first uncompleted activity in the focus unit
//      (the lowest-order active unit that isn't finished).
//   3. Checkpoint    — the focus unit's conversation checkpoint, once its
//      vocabulary gate is met but the conversation is still pending.
enum CurriculumToday {

    /// Max items surfaced — a daily queue should read as "a few things," not a
    /// backlog.
    static let maxItems = 3

    static func build(
        plan: CurriculumPlan,
        decks: [DeckDocument],
        schedules: [String: CardSchedule],
        dueCount: Int
    ) -> [CurriculumTodayItem] {
        var items: [CurriculumTodayItem] = []

        // 1. Review debt — always first when there's any.
        if dueCount > 0 {
            items.append(CurriculumTodayItem(
                id: "review",
                kind: .review,
                title: L("Review %d cards", dueCount),
                subtitle: L("Keep what you've learned from slipping away"),
                systemImage: "arrow.triangle.2.circlepath"
            ))
        }

        // 2. Focus unit: lowest-order active unit not yet fully done.
        let focus = plan.units
            .filter { $0.statusEnum == .active }
            .sorted { $0.order < $1.order }
            .first { CurriculumReconciler.unitProgress($0, decks: decks, schedules: schedules) < 0.999 }

        if let unit = focus {
            if let next = unit.plannedActivities.first(where: { $0.completedAt == nil }) {
                items.append(item(for: next, unit: unit))
            }

            // 3. Conversation checkpoint: vocab gate met, conversation pending.
            if unit.masteryGate.conversationCheck {
                let mastery = CurriculumReconciler.unitMastery(unit, decks: decks, schedules: schedules)
                let convo = unit.plannedActivities.first { $0.type == "conversation" }
                if mastery >= unit.masteryGate.matureFraction,
                   let convo, convo.completedAt == nil,
                   !items.contains(where: { $0.activityId == convo.id }) {
                    items.append(item(for: convo, unit: unit))
                }
            }
        }

        return Array(items.prefix(maxItems))
    }

    // MARK: - Activity → Today item

    private static func item(for activity: PlannedActivity, unit: CurriculumUnit) -> CurriculumTodayItem {
        let kind = kind(for: activity.type)
        return CurriculumTodayItem(
            id: activity.id,
            kind: kind,
            title: activity.label,
            subtitle: subtitle(for: kind, unit: unit),
            systemImage: systemImage(for: kind),
            unitId: unit.id,
            activityId: activity.id,
            spec: activity.spec
        )
    }

    private static func kind(for type: String) -> CurriculumTodayItem.Kind {
        switch type {
        case "conversation":  return .conversation
        case "pronunciation": return .pronunciation
        case "content":       return .content
        default:              return .deck
        }
    }

    private static func subtitle(for kind: CurriculumTodayItem.Kind, unit: CurriculumUnit) -> String {
        switch kind {
        case .deck:          return L("Build the vocabulary for “%@”", unit.title)
        case .conversation:  return L("Put “%@” to work in a real conversation", unit.title)
        case .pronunciation: return L("Sharpen how you sound")
        case .content:       return L("Read something that uses what you've learned")
        case .review:        return L("Keep what you've learned from slipping away")
        }
    }

    private static func systemImage(for kind: CurriculumTodayItem.Kind) -> String {
        switch kind {
        case .review:        return "arrow.triangle.2.circlepath"
        case .deck:          return "rectangle.stack"
        case .conversation:  return "bubble.left.and.bubble.right"
        case .pronunciation: return "waveform"
        case .content:       return "book"
        }
    }
}
