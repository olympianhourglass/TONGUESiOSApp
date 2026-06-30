import Foundation

// Workflow-style (single call, no tools) plan generation + revision.
// Used by PlanView's "Create my plan" path and the Phase-3 weekly
// replanner. Chat-initiated plans go through TutorAgent's
// update_curriculum tool instead — same output shape, different driver.
enum CurriculumPlanner {

    private static func planSchema() -> JSONValue {
        let activity = JSONValue.schemaObject(
            properties: [
                "type": .schemaEnum(
                    ["deck", "conversation", "pronunciation", "content"],
                    description: "Activity type."
                ),
                "label": .schemaString("Learner-facing one-line description of the activity."),
                "spec": .object([
                    "type": .string("object"),
                    "description": .string("Concrete parameters. Keys: topic (deck/content), contentType (Words|Phrases|Sentences, deck only), amount (5|10|20|50, deck only), scenario (conversation: what the AI tutor should roleplay), focus (pronunciation), kind (content: Story|Conversation|News Article|Songs|Poems|Jokes). All values are strings."),
                    "additionalProperties": .object(["type": .string("string")])
                ])
            ],
            required: ["type", "label"]
        )
        let unit = JSONValue.schemaObject(
            properties: [
                "id": .schemaString("Stable unit identifier, e.g. 'u1'."),
                "title": .schemaString("Short unit title."),
                "canDo": .schemaArray(
                    items: .schemaString("One checkable, learner-facing can-do goal."),
                    description: "1-3 can-do goals, CEFR-style."
                ),
                "activities": .schemaArray(items: activity, description: "2-4 activities mixing types."),
                "matureFraction": .schemaNumber("Fraction of vocabulary the learner should mature before moving on (e.g. 0.8)."),
                "conversationCheck": .schemaBool("Whether this unit ends with a conversation checkpoint.")
            ],
            required: ["title", "canDo", "activities"]
        )
        return .schemaObject(
            properties: [
                "goalStatement": .schemaString("One-line learner-facing goal."),
                "targetLevel": .schemaString("CEFR-style label (e.g. B1)."),
                "units": .schemaArray(items: unit, description: "4-6 ordered units.")
            ],
            required: ["goalStatement", "targetLevel", "units"]
        )
    }

    /// Generates a brand-new plan from the learner model. Returns the
    /// materialized plan WITHOUT saving — callers render it for
    /// confirmation and save on accept.
    static func generatePlan(
        learnerModel: LearnerModel,
        targetDate: Date? = nil
    ) async throws -> CurriculumPlan {
        let dateLine = targetDate.map {
            "Target date: \(ISO8601DateFormatter().string(from: $0)) — fit the plan inside it."
        } ?? "No hard deadline."
        let prompt = """
        Design a study curriculum for this language learner.

        Their full profile (level estimate, goals, vocabulary state, recurring errors, habits):

        \(learnerModel.promptJSON)

        \(dateLine)

        Requirements:
        • 4 to 6 ordered units (aim for 5), each completable in ≤ 2 weeks at the learner's observed minutes-per-day (assume 10 if unknown).
        • Build units around their stated goals, destinations, and interests — quote their own motivations in unit titles/goals where natural.
        • Each unit: 1–3 concrete can-do goals (CEFR style: "Can order food and handle simple requests"), and 2–4 activities mixing types (deck, conversation, pronunciation, content).
        • Weave their weak areas in: recurring error patterns get targeted units or activities; lapsing vocabulary gets recycled into early deck topics.
        • Difficulty ramps from their current level estimate toward a realistic target level.
        • Activity specs must be concrete enough to execute (real topics, not "miscellaneous vocabulary").

        Submit the curriculum by calling `submit_curriculum_plan`.
        """
        var payload: GeneratedPlanPayload = try await AnthropicClient.sendStructured(
            toolName: "submit_curriculum_plan",
            toolDescription: "Submit the generated curriculum plan.",
            schema: planSchema(),
            userPrompt: prompt,
            system: DeckGenerator.audiencePolicy,
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            as: GeneratedPlanPayload.self
        )
        guard !payload.units.isEmpty else {
            throw NSError(domain: "CurriculumPlanner", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Planner returned an empty unit list"
            ])
        }
        // Hard cap regardless of what the model returned — shorter plans
        // generate faster and read less daunting. (Fresh plans only; the
        // revise path never truncates because completed units must
        // survive verbatim.)
        if payload.units.count > 6 {
            payload = GeneratedPlanPayload(
                goalStatement: payload.goalStatement,
                targetLevel: payload.targetLevel,
                units: Array(payload.units.prefix(6))
            )
        }
        return payload.asPlan(
            language: learnerModel.language,
            dialect: learnerModel.dialect,
            revision: 1,
            targetDate: targetDate
        )
    }

    /// Revises the remaining (non-completed) units of an existing plan
    /// against a fresh learner model. Returns the revised plan +
    /// learner-facing change notes; does NOT save.
    static func revisePlan(
        existing: CurriculumPlan,
        learnerModel: LearnerModel
    ) async throws -> (plan: CurriculumPlan, changes: [String]) {
        let prompt = """
        You maintain a language-learning curriculum.

        Here is the current plan:

        \(existing.promptJSON)

        And the learner's fresh profile (what they've actually mastered, what they keep getting wrong, their pace):

        \(learnerModel.promptJSON)

        Revise the plan's remaining units to fit reality:
        • NEVER change units whose status is "completed" — copy them through with the same id, title, canDo, and activities.
        • You may reorder, retitle, merge, split, add, or drop non-completed units. Keep stable ids where a unit survives ("u3" stays "u3").
        • Pull weak areas forward; push already-mastered material back or drop it.
        • Keep the plan at 4–6 units total (including completed ones).
        • If their pace is slower than planned, shrink units rather than extending the timeline; never guilt the learner.
        • Also produce 1-3 short learner-facing change notes ("Pulled the particles unit forward — は/が keeps tripping you up").

        Submit your revision by calling `submit_revised_curriculum`.
        """
        struct Wrapper: Codable {
            let changes: [String]
            let plan: GeneratedPlanPayload
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "changes": .schemaArray(
                    items: .schemaString("One short, learner-facing change note."),
                    description: "1-3 change notes."
                ),
                "plan": planSchema()
            ],
            required: ["changes", "plan"]
        )
        let decoded: Wrapper = try await AnthropicClient.sendStructured(
            toolName: "submit_revised_curriculum",
            toolDescription: "Submit the revised curriculum plan and learner-facing change notes.",
            schema: schema,
            userPrompt: prompt,
            system: DeckGenerator.audiencePolicy,
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            as: Wrapper.self
        )

        var revised = decoded.plan.asPlan(
            language: existing.language,
            dialect: existing.dialect,
            revision: existing.revision + 1,
            targetDate: existing.targetDate
        )
        revised.createdAt = existing.createdAt
        revised.createdBy = existing.createdBy
        // Enforce the never-touch-completed-work rule structurally, not
        // just by prompt: completed units from the saved plan override
        // whatever the model returned for the same id, and deck links on
        // surviving units carry through.
        revised.units = revised.units.map { unit in
            if let prior = existing.units.first(where: { $0.id == unit.id }) {
                if prior.statusEnum == .completed {
                    var kept = prior
                    kept.order = unit.order
                    return kept
                }
                var merged = unit
                merged.deckIds = prior.deckIds
                return merged
            }
            return unit
        }
        // Exactly one active unit: first non-completed in order.
        var sawActive = false
        revised.units = revised.units.map { unit in
            var u = unit
            if u.statusEnum != .completed {
                u.status = sawActive
                    ? CurriculumUnit.Status.locked.rawValue
                    : CurriculumUnit.Status.active.rawValue
                sawActive = true
            }
            return u
        }
        return (revised, decoded.changes)
    }

}
