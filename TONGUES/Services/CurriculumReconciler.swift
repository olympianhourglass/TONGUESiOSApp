import Foundation

// Phase 3 — the loop that makes the curriculum react.
//
// `reconcile(plan:)` is the deterministic, zero-AI pass that runs on
// app open / Study-tab load: recompute the active unit's mastery from
// FSRS schedules, complete + unlock units whose gates pass, and decide
// whether enough has drifted to justify a (paid) replan call. The
// replan itself runs at most weekly, writes the revision back, and
// queues a learner-facing tutor notice on the plan doc that chat
// surfaces as an assistant bubble.
enum CurriculumReconciler {

    struct Outcome {
        var plan: CurriculumPlan
        var unitsCompleted: [CurriculumUnit] = []
        var didReplan: Bool = false
        var changed: Bool = false
    }

    /// Days between drift checks / replans.
    static let replanCadence: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Mastery

    /// Fraction of the unit's deck cards that are FSRS-mature. Units
    /// with no generated decks yet report 0 (nothing to gate on).
    static func unitMastery(
        _ unit: CurriculumUnit,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) -> Double {
        let unitDecks = decks.filter { deck in
            deck.id.map { unit.deckIds.contains($0) } ?? false
        }
        let items = unitDecks.flatMap { $0.items }
        guard !items.isEmpty else { return 0 }
        let mature = items.filter { item in
            guard let schedule = schedules[item.id.uuidString] else { return false }
            let stability = schedule.stability ?? Double(schedule.intervalDays)
            return stability >= LearnerModelService.matureStabilityDays
        }.count
        return Double(mature) / Double(items.count)
    }

    /// Whether the unit's mastery gate passes. The conversationCheck
    /// half of the gate is satisfied by any completed "conversation"
    /// activity (the chat view model stamps those).
    static func gatePasses(
        _ unit: CurriculumUnit,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) -> Bool {
        // A unit that never generated any decks can't pass on vocab alone.
        guard !unit.deckIds.isEmpty else { return false }
        let mastery = unitMastery(unit, decks: decks, schedules: schedules)
        guard mastery >= unit.masteryGate.matureFraction else { return false }
        if unit.masteryGate.conversationCheck {
            let conversationDone = unit.plannedActivities.contains {
                $0.type == "conversation" && $0.completedAt != nil
            }
            guard conversationDone else { return false }
        }
        return true
    }

    // MARK: - Deterministic reconcile (free, on app open)

    /// Completes gated units, unlocks the next one, and persists if
    /// anything moved. Pure bookkeeping — no AI calls.
    static func reconcile(plan: CurriculumPlan) async -> Outcome {
        var outcome = Outcome(plan: plan)
        guard plan.status == "active" else { return outcome }

        let decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
        let schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]

        var units = plan.units.sorted { $0.order < $1.order }
        var changed = false

        // Walk forward: complete every consecutive passing unit, then
        // make the first non-completed unit active and the rest locked.
        for index in units.indices {
            guard units[index].statusEnum == .active else { continue }
            if gatePasses(units[index], decks: decks, schedules: schedules) {
                units[index].status = CurriculumUnit.Status.completed.rawValue
                outcome.unitsCompleted.append(units[index])
                changed = true
            }
        }
        var sawActive = false
        for index in units.indices {
            guard units[index].statusEnum != .completed else { continue }
            let desired = sawActive
                ? CurriculumUnit.Status.locked.rawValue
                : CurriculumUnit.Status.active.rawValue
            if units[index].status != desired {
                units[index].status = desired
                changed = true
            }
            sawActive = true
        }

        outcome.plan.units = units
        if units.allSatisfy({ $0.statusEnum == .completed }) && !units.isEmpty {
            outcome.plan.status = "completed"
            changed = true
        }

        if changed {
            if !outcome.unitsCompleted.isEmpty {
                let names = outcome.unitsCompleted.map { "“\($0.title)”" }.joined(separator: ", ")
                outcome.plan.pendingTutorNotice =
                    "You've mastered \(names) — the next unit is unlocked. Nice work."
            }
            outcome.changed = true
            try? await FirebaseCurriculumService.save(outcome.plan)
        }
        return outcome
    }

    // MARK: - Weekly replan (one AI call, gated)

    /// Runs the deterministic reconcile, then — at most once per
    /// `replanCadence`, and only when there's real drift — asks the
    /// planner to revise the remaining units, saves the revision, and
    /// queues the tutor-notice chat message. Designed to be called
    /// fire-and-forget from Study-tab load.
    static func reconcileAndMaybeReplan(languageID: String) async {
        guard let plan = try? await FirebaseCurriculumService.fetch(languageID: languageID) else {
            return
        }
        var outcome = await reconcile(plan: plan)
        guard outcome.plan.status == "active" else { return }

        let lastReview = outcome.plan.lastReviewedAt ?? outcome.plan.createdAt
        guard Date().timeIntervalSince(lastReview) >= replanCadence else { return }

        // Stamp the review time FIRST so concurrent/failed runs don't
        // retry the paid call on every app open within the window.
        outcome.plan.lastReviewedAt = Date()
        try? await FirebaseCurriculumService.save(outcome.plan)

        guard await detectDrift(plan: outcome.plan) else { return }

        do {
            let model = try await LearnerModelService.loadOrRebuild(
                language: outcome.plan.language,
                dialect: outcome.plan.dialect,
                fallbackLevel: outcome.plan.targetLevel
            )
            let (revised, changes) = try await CurriculumPlanner.revisePlan(
                existing: outcome.plan,
                learnerModel: model
            )
            var toSave = revised
            toSave.lastReviewedAt = Date()
            let noticeBody = changes.isEmpty
                ? "I've refreshed your study plan based on how you've been doing."
                : changes.joined(separator: " ")
            toSave.pendingTutorNotice = "I took a look at your recent progress. \(noticeBody) Open your plan to see the changes."
            try await FirebaseCurriculumService.save(toSave)
        } catch {
            print("[Curriculum] Replan failed: \(error.localizedDescription)")
        }
    }

    /// Cheap drift heuristics deciding whether a replan call is worth
    /// the tokens: stale active unit, due-card pileup, or pace far off
    /// the unit sizing.
    private static func detectDrift(plan: CurriculumPlan) async -> Bool {
        guard let active = plan.activeUnit else { return false }

        let decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
        let schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]

        // 1. Active unit has decks but mastery has stalled low for a full
        //    cadence window (the user is grinding without progressing, or
        //    ignoring the unit entirely).
        if !active.deckIds.isEmpty {
            let mastery = unitMastery(active, decks: decks, schedules: schedules)
            if mastery < active.masteryGate.matureFraction * 0.5 { return true }
        } else {
            // Unit active for a week+ and the user never even generated
            // its decks — plan and behavior have diverged.
            return true
        }

        // 2. Review debt: a large overdue pile means the plan's pace is
        //    wrong for this learner right now.
        let now = Date()
        let language = plan.language
        let dueCount = schedules.values.filter {
            $0.language == language && $0.nextReviewAt <= now
        }.count
        if dueCount >= 40 { return true }

        return false
    }
}
