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

    // MARK: - Weighted progress

    // Every unit is a set of components that each fill 0…1:
    //   • one *vocab* component (present when the unit has decks or a deck
    //     activity), filled by FSRS maturity relative to the unit's gate;
    //   • one component per NON-deck activity (conversation / pronunciation /
    //     content), filled 1 when that activity has been completed.
    // Unit progress is the mean of its components, so every activity type moves
    // the bar — not just vocabulary — and a unit with no decks can still finish.
    static func unitComponents(
        _ unit: CurriculumUnit,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) -> (filled: Double, total: Int) {
        let hasVocab = !unit.deckIds.isEmpty
            || unit.plannedActivities.contains { $0.type == "deck" }
        let nonDeckActivities = unit.plannedActivities.filter { $0.type != "deck" }

        var filled = 0.0
        var total = 0

        if hasVocab {
            let gate = max(unit.masteryGate.matureFraction, 0.01)
            let mastery = unitMastery(unit, decks: decks, schedules: schedules)
            filled += min(1, mastery / gate)
            total += 1
        }
        for activity in nonDeckActivities {
            filled += activity.completedAt != nil ? 1 : 0
            total += 1
        }
        return (filled, total)
    }

    /// 0…1 progress toward completing the unit — the value the progress bar
    /// and percentage in Plan render.
    static func unitProgress(
        _ unit: CurriculumUnit,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) -> Double {
        let (filled, total) = unitComponents(unit, decks: decks, schedules: schedules)
        guard total > 0 else { return 0 }
        return min(1, filled / Double(total))
    }

    /// Whether the unit's gate passes: every component filled. The
    /// conversation half is only enforced when the unit actually carries a
    /// conversation activity, so a unit that sets `conversationCheck` without
    /// one is never left with an unsatisfiable gate.
    static func gatePasses(
        _ unit: CurriculumUnit,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) -> Bool {
        let (filled, total) = unitComponents(unit, decks: decks, schedules: schedules)
        // A unit with nothing to do (no decks, no activities) can't complete.
        guard total > 0 else { return false }
        guard filled >= Double(total) - 0.001 else { return false }
        if unit.masteryGate.conversationCheck {
            let hasConversationActivity = unit.plannedActivities.contains { $0.type == "conversation" }
            let conversationDone = unit.plannedActivities.contains {
                $0.type == "conversation" && $0.completedAt != nil
            }
            // Only block on the conversation checkpoint if there's actually a
            // conversation activity to satisfy it.
            if hasConversationActivity, !conversationDone { return false }
        }
        return true
    }

    // MARK: - Deterministic reconcile (free, on app open)

    /// Completes gated units, unlocks the next one, and persists if
    /// anything moved. Pure bookkeeping — no AI calls. Fetches the deck +
    /// schedule state itself; callers that already hold it should use the
    /// `decks:schedules:` overload to avoid a second round-trip.
    static func reconcile(plan: CurriculumPlan) async -> Outcome {
        let decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
        let schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]
        return await reconcile(plan: plan, decks: decks, schedules: schedules)
    }

    static func reconcile(
        plan: CurriculumPlan,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) async -> Outcome {
        var outcome = Outcome(plan: plan)
        guard plan.status == "active" else { return outcome }

        var units = plan.units.sorted { $0.order < $1.order }
        var changed = false

        // Non-sequential curriculum: every unit is always unlocked. Complete
        // any unit whose mastery gate passes; keep every other unit active
        // (this also heals any legacy plans that still carry locked units).
        for index in units.indices {
            guard units[index].statusEnum != .completed else { continue }
            if gatePasses(units[index], decks: decks, schedules: schedules) {
                units[index].status = CurriculumUnit.Status.completed.rawValue
                outcome.unitsCompleted.append(units[index])
                changed = true
            } else if units[index].statusEnum != .active {
                units[index].status = CurriculumUnit.Status.active.rawValue
                changed = true
            }
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
                    "You've mastered \(names) — nice work. Jump into whichever unit you like next."
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

        // Fetch once and hand into the drift check (no second round-trip).
        let decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
        let schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]
        guard await detectDrift(plan: outcome.plan, decks: decks, schedules: schedules) else { return }

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

    /// Cheap drift heuristics deciding whether a replan call is worth the
    /// tokens: stalled mastery, over-performance, a genuinely diverged
    /// (started-but-abandoned) unit, or a due-card pileup. Decks + schedules
    /// are passed in — the caller already fetched them.
    private static func detectDrift(
        plan: CurriculumPlan,
        decks: [DeckDocument],
        schedules: [String: CardSchedule]
    ) async -> Bool {
        guard let active = plan.activeUnit else { return false }
        let language = plan.language

        // Whether the learner has actually studied this language at all —
        // used to distinguish "started but stuck" from "just hasn't begun".
        let hasStudiedLanguage = schedules.values.contains {
            $0.language == language && $0.intervalDays > 0
        }

        if !active.deckIds.isEmpty {
            let mastery = unitMastery(active, decks: decks, schedules: schedules)
            // 1a. Grinding without progressing — mastery stuck well below gate.
            if mastery < active.masteryGate.matureFraction * 0.5 { return true }
            // 1b. Over-performing — already past the gate a full cadence before
            //     schedule, so the plan can safely deepen / accelerate.
            if mastery >= active.masteryGate.matureFraction { return true }
        } else if hasStudiedLanguage {
            // Unit active with no decks generated, yet the learner is studying
            // the language elsewhere — plan and behavior have diverged. (A user
            // who simply hasn't started their fresh plan is NOT drift, which is
            // why this is gated on real activity.)
            return true
        }

        // 2. Review debt: a large overdue pile means the plan's pace is wrong
        //    for this learner right now.
        let now = Date()
        let dueCount = schedules.values.filter {
            $0.language == language && $0.nextReviewAt <= now
        }.count
        if dueCount >= 40 { return true }

        return false
    }
}
