import Foundation

// The tool-using tutor. ChatViewModel routes a user turn here (instead
// of ConversationClient.sendTurn) when the message looks like a meta /
// planning request — "what should I work on?", "make me a study plan",
// "build me a deck about X", "how am I doing?".
//
// The loop: send the turn with tool definitions → while Claude stops on
// `tool_use`, execute the requested tools locally against the app's own
// services (Firestore data is already client-accessible) → append
// results → re-send. Mutating tools (create_deck, update_curriculum)
// only STAGE proposals; the user confirms in the UI before anything is
// committed. record_placement is the one direct write (it's additive
// metadata about the learner, not user content).
enum TutorAgent {

    // MARK: - Public types

    struct Context {
        let language: String
        let dialect: String
        let level: String
        let learnerModel: LearnerModel?
    }

    struct Reply {
        let text: String
        let transliteration: String?
        let englishTranslation: String?
        let corrections: [ConversationCorrection]
        // Proposals staged by tools during the loop, in creation order.
        // The view model attaches them to the assistant message(s).
        let attachments: [MessageAttachment]
    }

    enum Intent {
        case conversation
        case meta
    }

    /// Learner-facing labels for the activity chips shown while the
    /// loop runs ("Reviewing your decks…").
    static func chipLabel(forTool name: String) -> String {
        switch name {
        case "get_learner_model":  return "Reviewing your progress…"
        case "list_decks":         return "Looking at your decks…"
        case "get_deck_progress":  return "Checking deck progress…"
        case "create_deck":        return "Building a deck…"
        case "get_curriculum":     return "Reading your plan…"
        case "update_curriculum":  return "Drafting your plan…"
        case "get_review_history": return "Scanning review history…"
        case "record_placement":   return "Updating your level…"
        default:                   return "Thinking…"
        }
    }

    // MARK: - Routing

    /// Decides whether a user turn is ordinary target-language
    /// conversation (cheap existing path) or a meta/planning request
    /// (agent loop). Non-Latin-script messages skip the classifier —
    /// they're conversation by construction. Any failure falls back to
    /// conversation, so the worst case is today's behavior.
    static func classifyIntent(_ userText: String) async -> Intent {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return .conversation }

        // ASCII-letter ratio gate: messages written mostly in a non-Latin
        // script can't be English meta requests.
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return .conversation }
        let asciiLetters = letters.filter { $0.isASCII }
        let asciiRatio = Double(asciiLetters.count) / Double(letters.count)
        guard asciiRatio > 0.7 else { return .conversation }

        let prompt = """
        A user is inside a language-learning chat where they normally practice speaking a foreign language with an AI tutor. Classify their latest message:

        "\(trimmed.prefix(300))"

        • "meta" — the message is in English and asks ABOUT their learning: progress, level, what to study next, making/changing a study plan or curriculum, creating flashcard decks, reviewing weak areas, statistics.
        • "conversation" — anything else: target-language practice, small talk, questions about vocabulary/grammar usage, continuing a roleplay (even in English).

        Reply with exactly one word: meta or conversation.
        """
        guard let raw = try? await AnthropicClient.sendMessage(
            [AnthropicMessage(role: "user", content: prompt)],
            model: "claude-haiku-4-5-20251001",
            maxTokens: 8
        ) else { return .conversation }
        return raw.lowercased().contains("meta") ? .meta : .conversation
    }

    // MARK: - Agent loop

    private static let maxIterations = 6
    private static let maxDecksPerTurn = 3

    static func respond(
        history: [ConversationMessage],
        userText: String,
        context: Context,
        onToolEvent: @escaping @Sendable (String) -> Void
    ) async throws -> Reply {
        let system = buildSystemPrompt(context: context)

        // Skip attachment-only carrier messages (empty text) and merge
        // consecutive same-role turns — the API rejects empty text
        // blocks, and tutor notices can sit back-to-back with replies.
        var messages: [AnthropicToolMessage] = []
        for m in history.suffix(30) {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role = m.role == .user ? "user" : "assistant"
            if let last = messages.last, last.role == role,
               let lastText = last.content.first?.text {
                messages[messages.count - 1] = AnthropicToolMessage(
                    role: role,
                    content: [.text(lastText + "\n\n" + text)]
                )
            } else {
                messages.append(AnthropicToolMessage(
                    role: role,
                    content: [.text(text)]
                ))
            }
        }
        messages.append(.user(wrapUserTurn(userText, context: context)))

        var staged: [MessageAttachment] = []
        var decksCreated = 0

        for _ in 0..<maxIterations {
            let response = try await AnthropicClient.sendToolMessage(
                messages,
                system: system,
                tools: toolDefinitions,
                model: "claude-sonnet-4-6",
                maxTokens: 4096
            )

            guard response.wantsToolUse else {
                return parseFinalReply(response.joinedText, staged: staged)
            }

            messages.append(response.asAssistantMessage)
            var results: [AnthropicToolContentBlock] = []
            for use in response.toolUses {
                guard let id = use.id, let name = use.name else { continue }
                onToolEvent(chipLabel(forTool: name))
                let outcome = await execute(
                    tool: name,
                    input: use.input ?? .object([:]),
                    context: context,
                    staged: &staged,
                    decksCreated: &decksCreated
                )
                results.append(.toolResult(
                    toolUseId: id,
                    content: outcome.content,
                    isError: outcome.isError
                ))
            }
            messages.append(AnthropicToolMessage(role: "user", content: results))
        }

        // Iteration cap hit — ask for a graceful wrap-up without tools.
        messages.append(.user(
            "Stop using tools now. Summarize what you found so far and answer the user with the final JSON object only."
        ))
        let final = try await AnthropicClient.sendToolMessage(
            messages,
            system: system,
            tools: nil,
            model: "claude-sonnet-4-6",
            maxTokens: 2048
        )
        return parseFinalReply(final.joinedText, staged: staged)
    }

    // MARK: - Placement grading (Phase 4)

    /// Grades a placement conversation's transcript into a CEFR-style
    /// level + confidence, records it on the learner model, and returns
    /// the payload for the result card. Deterministic workflow call —
    /// not part of the agent loop.
    static func gradePlacement(
        history: [ConversationMessage],
        language: String,
        dialect: String,
        fallbackLevel: String
    ) async throws -> PlacementResultPayload {
        let transcript = history.map { msg in
            let role = msg.role == .user ? "Learner" : "Tutor"
            var line = "\(role): \(msg.text)"
            if msg.role == .user, let corrections = msg.corrections, !corrections.isEmpty {
                let notes = corrections.map { "\($0.original)→\($0.corrected)" }.joined(separator: "; ")
                line += "  [tutor corrections: \(notes)]"
            }
            return line
        }.joined(separator: "\n")

        let prompt = """
        You are assessing a learner's proficiency in \(dialect) \(language) from this placement conversation. Tutor turns stepped difficulty up and down; learner turns carry inline correction notes where the tutor flagged errors.

        Transcript:
        \(transcript)

        Assess their productive level on the CEFR scale (A1, A2, B1, B2, C1, C2). Weigh: range of vocabulary, grammatical control (correction density and severity), sentence complexity, and how they handled harder tutor turns. Be conservative — placing slightly low is better for motivation than slightly high.

        Submit your assessment by calling `submit_placement_assessment`.
        """
        struct Decoded: Codable {
            let level: String
            let confidence: Double
            let rationale: String
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "level": .schemaEnum(
                    ["A1", "A2", "B1", "B2", "C1", "C2"],
                    description: "CEFR level."
                ),
                "confidence": .schemaNumber("Confidence in the placement, 0.0-1.0."),
                "rationale": .schemaString("One sentence in English explaining the placement.")
            ],
            required: ["level", "confidence", "rationale"]
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_placement_assessment",
            toolDescription: "Submit the learner's CEFR placement.",
            schema: schema,
            userPrompt: prompt,
            model: "claude-sonnet-4-6",
            maxTokens: 256,
            as: Decoded.self
        )
        try await LearnerModelService.recordPlacement(
            language: language,
            dialect: dialect,
            level: decoded.level,
            confidence: decoded.confidence,
            fallbackLevel: fallbackLevel
        )
        return PlacementResultPayload(
            language: language,
            level: decoded.level,
            confidence: decoded.confidence,
            rationale: decoded.rationale
        )
    }

    // MARK: - System prompt

    private static func buildSystemPrompt(context: Context) -> String {
        var lines: [String] = []
        lines.append("You are the TONGUES tutor — a warm, knowledgeable language-learning coach with tools that read the learner's real data and stage real artifacts (decks, study plans) for them.")
        lines.append("")
        lines.append("Target language: \(context.dialect) \(context.language)")
        lines.append("Learner level: \(context.level)")
        lines.append("")
        if let model = context.learnerModel {
            lines.append("Learner model (derived from their actual flashcard schedules, conversation corrections, pronunciation drills, and goals):")
            lines.append(model.promptJSON)
            lines.append("")
        }
        lines.append("Rules:")
        lines.append("• When the learner asks about progress, what to study next, their level, decks, or plans — use tools. NEVER invent numbers, deck names, or progress; if a tool fails, say what you couldn't check.")
        lines.append("• Consult get_learner_model and/or list_decks BEFORE recommending anything, so recommendations name their actual weak areas and existing decks.")
        lines.append("• create_deck and update_curriculum only STAGE proposals — the learner confirms in the UI. After staging, briefly describe what you built and tell them they can save/accept it with the card below your message.")
        lines.append("• Make at most one curriculum proposal and at most \(maxDecksPerTurn) decks per reply.")
        lines.append("• Plans should have 4–6 units, each ≤ 2 weeks at the learner's observed pace, with concrete can-do goals and activities. Build units around their goals, destinations, interests, and weak areas. Recycle lapsing vocabulary.")
        lines.append("• Conduct planning/meta discussion in English. Keep replies concise — a short paragraph, not a lecture.")
        lines.append("• If the user's message was actually target-language practice, just reply conversationally in \(context.language) without tools.")
        return lines.joined(separator: "\n")
    }

    private static func wrapUserTurn(_ userText: String, context: Context) -> String {
        """
        \(userText)

        ---

        After any tool use, your FINAL message must be ONLY a single JSON object, no prose or markdown fences, matching:

        {
          "reply": "your answer to the user (English for meta/planning topics; \(context.language) for conversational practice)",
          "transliteration": "Latin-script romanization if `reply` is in a non-Latin script, else null",
          "english_translation": "English translation if `reply` is not in English, else null",
          "corrections": []
        }

        `corrections` follows the usual rules (genuine errors in the user's last message only, max 3, ignore punctuation/capitalization) — it will almost always be [] for English meta requests.
        """
    }

    // MARK: - Final reply parsing

    private static func parseFinalReply(
        _ raw: String,
        staged: [MessageAttachment]
    ) -> Reply {
        struct DecodedCorrection: Codable {
            let original: String
            let corrected: String
            let explanation: String
        }
        struct Decoded: Codable {
            let reply: String
            let transliteration: String?
            let english_translation: String?
            let corrections: [DecodedCorrection]?
        }
        let json = DeckGenerator.extractJSON(from: raw)
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Decoded.self, from: data) {
            let corrections = (decoded.corrections ?? []).map {
                ConversationCorrection(
                    original: $0.original,
                    corrected: $0.corrected,
                    explanation: $0.explanation
                )
            }
            let translit = decoded.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = decoded.english_translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Reply(
                text: decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines),
                transliteration: (translit?.isEmpty == false) ? translit : nil,
                englishTranslation: (english?.isEmpty == false) ? english : nil,
                corrections: corrections,
                attachments: staged
            )
        }
        // Model answered in prose despite instructions — degrade to using
        // it verbatim rather than erroring the whole turn.
        return Reply(
            text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            transliteration: nil,
            englishTranslation: nil,
            corrections: [],
            attachments: staged
        )
    }

    // MARK: - Tool definitions

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func schema(
        _ properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            dict["required"] = .array(required.map { .string($0) })
        }
        return .object(dict)
    }

    static let toolDefinitions: [AnthropicTool] = [
        AnthropicTool(
            name: "get_learner_model",
            description: "Returns the learner's full profile for the current language: level estimate with confidence, goals and motivations from onboarding, vocabulary state from spaced-repetition schedules (mature/young/new/due counts, words they keep forgetting), recurring grammar-error patterns from past conversations, pronunciation trouble spots, and study habits. Always consult this before making recommendations or plans.",
            inputSchema: schema([:])
        ),
        AnthropicTool(
            name: "list_decks",
            description: "Lists the learner's flashcard decks for the current language with per-deck progress: card counts, how many are due now, how many are new, and the mastered fraction.",
            inputSchema: schema([:])
        ),
        AnthropicTool(
            name: "get_deck_progress",
            description: "Detailed progress for one deck: due/new/mature counts plus the weakest cards (most lapses, lowest stability).",
            inputSchema: schema(
                ["deck_id": prop("string", "The deck id from list_decks.")],
                required: ["deck_id"]
            )
        ),
        AnthropicTool(
            name: "create_deck",
            description: "Generates a new flashcard deck on a topic, calibrated to the learner's level, automatically skipping words they've already mastered and recycling words they keep forgetting. The deck is STAGED as a proposal — the learner taps Save on the card to add it to their library. Use when the learner asks for a deck, or to scaffold a curriculum unit they've accepted.",
            inputSchema: schema(
                [
                    "topic": prop("string", "What the deck should cover, e.g. 'ordering at an izakaya'."),
                    "content_type": prop("string", "One of: Words, Phrases, Sentences. Default Phrases."),
                    "amount": prop("string", "Item count: 5, 10, 20, or 50. Default 10."),
                    "level": prop("string", "CEFR-style level override. Defaults to the learner's level."),
                    "plan_unit_id": prop("string", "If this deck scaffolds a curriculum unit, that unit's id.")
                ],
                required: ["topic"]
            )
        ),
        AnthropicTool(
            name: "get_curriculum",
            description: "Returns the learner's current curriculum plan for this language (units, goals, status, mastery gates), or reports that none exists.",
            inputSchema: schema([:])
        ),
        AnthropicTool(
            name: "update_curriculum",
            description: "Stages a new or revised curriculum plan as a proposal the learner confirms in the UI. Provide the COMPLETE plan (all units, including unchanged ones when revising). Never modify completed units.",
            inputSchema: schema(
                [
                    "goal_statement": prop("string", "One-line learner-facing goal, e.g. 'Conversational Japanese for an Osaka trip'."),
                    "target_level": prop("string", "CEFR-style target, e.g. 'B1'."),
                    "units": .object([
                        "type": .string("array"),
                        "description": .string("Ordered units."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "id": prop("string", "Stable unit id like 'u1'. Reuse ids when revising."),
                                "title": prop("string", "Short unit title."),
                                "canDo": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string")]),
                                    "description": .string("1-3 checkable can-do goals.")
                                ]),
                                "activities": .object([
                                    "type": .string("array"),
                                    "description": .string("2-4 activities. Each: {type: deck|conversation|pronunciation|content, label: learner-facing one-liner, spec: object — for deck: {topic, contentType, amount}; for conversation: {scenario}; for pronunciation: {focus}; for content: {kind, topic}}."),
                                    "items": .object(["type": .string("object")])
                                ]),
                                "matureFraction": prop("number", "Mastery gate 0-1, default 0.8."),
                                "conversationCheck": prop("boolean", "Whether the unit ends with a checked conversation.")
                            ]),
                            "required": .array([.string("title"), .string("canDo"), .string("activities")])
                        ])
                    ])
                ],
                required: ["goal_statement", "target_level", "units"]
            )
        ),
        AnthropicTool(
            name: "get_review_history",
            description: "Recent flashcard study sessions for this language: when, which deck, how many cards, accuracy.",
            inputSchema: schema(
                ["limit": prop("number", "Max sessions to return. Default 10.")]
            )
        ),
        AnthropicTool(
            name: "record_placement",
            description: "Records the learner's assessed proficiency level after you've evaluated their performance (e.g. at the end of a placement conversation, or when their conversation history clearly contradicts the current estimate). Writes directly to the learner model.",
            inputSchema: schema(
                [
                    "level": prop("string", "CEFR-style level, e.g. 'A2'."),
                    "confidence": prop("number", "0-1 confidence in the assessment."),
                    "rationale": prop("string", "One sentence on what the assessment is based on.")
                ],
                required: ["level", "confidence", "rationale"]
            )
        )
    ]

    // MARK: - Tool execution

    private struct ToolOutcome {
        let content: String
        var isError: Bool = false
    }

    private static func execute(
        tool: String,
        input: JSONValue,
        context: Context,
        staged: inout [MessageAttachment],
        decksCreated: inout Int
    ) async -> ToolOutcome {
        do {
            switch tool {
            case "get_learner_model":
                let model = try await LearnerModelService.loadOrRebuild(
                    language: context.language,
                    dialect: context.dialect,
                    fallbackLevel: context.level
                )
                return ToolOutcome(content: model.promptJSON)

            case "list_decks":
                return ToolOutcome(content: try await listDecksJSON(context: context))

            case "get_deck_progress":
                guard let deckId = input["deck_id"]?.stringValue else {
                    return ToolOutcome(content: "Missing deck_id.", isError: true)
                }
                return ToolOutcome(content: try await deckProgressJSON(deckId: deckId))

            case "create_deck":
                guard decksCreated < maxDecksPerTurn else {
                    return ToolOutcome(
                        content: "Deck limit reached for this reply (\(maxDecksPerTurn)). Describe the remaining decks instead of creating them.",
                        isError: true
                    )
                }
                guard let topic = input["topic"]?.stringValue, !topic.isEmpty else {
                    return ToolOutcome(content: "Missing topic.", isError: true)
                }
                let outcome = try await stageDeck(
                    topic: topic,
                    contentType: input["content_type"]?.stringValue ?? "Phrases",
                    amount: input["amount"]?.stringValue ?? "10",
                    level: input["level"]?.stringValue ?? context.level,
                    planUnitId: input["plan_unit_id"]?.stringValue,
                    context: context,
                    staged: &staged
                )
                decksCreated += 1
                return outcome

            case "get_curriculum":
                let languageID = Conversation.languageID(for: context.language)
                if let plan = try await FirebaseCurriculumService.fetch(languageID: languageID) {
                    return ToolOutcome(content: plan.promptJSON)
                }
                return ToolOutcome(content: "No curriculum plan exists for \(context.language) yet.")

            case "update_curriculum":
                return await stagePlan(input: input, context: context, staged: &staged)

            case "get_review_history":
                let limit = input["limit"]?.intValue ?? 10
                return ToolOutcome(content: try await reviewHistoryJSON(
                    language: context.language, limit: limit
                ))

            case "record_placement":
                guard let level = input["level"]?.stringValue,
                      let confidence = input["confidence"]?.numberValue else {
                    return ToolOutcome(content: "Missing level or confidence.", isError: true)
                }
                let rationale = input["rationale"]?.stringValue ?? ""
                try await LearnerModelService.recordPlacement(
                    language: context.language,
                    dialect: context.dialect,
                    level: level,
                    confidence: confidence,
                    fallbackLevel: context.level
                )
                staged.append(.placementResult(PlacementResultPayload(
                    language: context.language,
                    level: level,
                    confidence: confidence,
                    rationale: rationale
                )))
                return ToolOutcome(content: "Recorded: \(level) (confidence \(confidence)).")

            default:
                return ToolOutcome(content: "Unknown tool: \(tool)", isError: true)
            }
        } catch {
            return ToolOutcome(
                content: "Tool failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Tool implementations

    private static func matureStability(_ schedule: CardSchedule) -> Double {
        schedule.stability ?? Double(schedule.intervalDays)
    }

    private static func listDecksJSON(context: Context) async throws -> String {
        async let decksTask = FirebaseDeckService.fetchDecks()
        async let schedulesTask: [String: CardSchedule]? = try? await FirebaseDeckService.fetchAllSchedules()
        let decks = (try await decksTask).filter { $0.allLanguages.contains(context.language) }
        let schedules = (await schedulesTask) ?? [:]
        let now = Date()

        guard !decks.isEmpty else {
            return "The learner has no \(context.language) decks yet."
        }
        let rows = decks.map { deck -> String in
            var due = 0, new = 0, mature = 0
            for item in deck.items {
                guard let schedule = schedules[item.id.uuidString] else { new += 1; continue }
                if schedule.nextReviewAt <= now { due += 1 }
                if matureStability(schedule) >= LearnerModelService.matureStabilityDays { mature += 1 }
            }
            let total = deck.items.count
            let masteredPct = total > 0 ? Int((Double(mature) / Double(total) * 100).rounded()) : 0
            let topic = deck.interests.isEmpty ? deck.userPrompt : deck.interests.joined(separator: ", ")
            let unit = deck.planUnitId.map { ", \"planUnitId\": \"\($0)\"" } ?? ""
            return "{\"id\": \"\(deck.id ?? "?")\", \"title\": \"\(deck.title)\", \"level\": \"\(deck.level)\", \"contentType\": \"\(deck.contentType)\", \"topic\": \"\(topic.prefix(60))\", \"cards\": \(total), \"due\": \(due), \"new\": \(new), \"masteredPercent\": \(masteredPct)\(unit)}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }

    private static func deckProgressJSON(deckId: String) async throws -> String {
        let decks = try await FirebaseDeckService.fetchDecks()
        guard let deck = decks.first(where: { $0.id == deckId }) else {
            return "No deck with id \(deckId)."
        }
        let schedules = (try? await FirebaseDeckService.fetchSchedules(
            cardIds: deck.items.map { $0.id.uuidString }
        )) ?? [:]
        let now = Date()
        var due = 0, new = 0, mature = 0
        var weakest: [(word: String, lapses: Int, stability: Double)] = []
        for item in deck.items {
            guard let schedule = schedules[item.id.uuidString] else { new += 1; continue }
            if schedule.nextReviewAt <= now { due += 1 }
            let stability = matureStability(schedule)
            if stability >= LearnerModelService.matureStabilityDays { mature += 1 }
            if schedule.lapses >= 1 {
                weakest.append((schedule.word, schedule.lapses, stability))
            }
        }
        let weakList = weakest
            .sorted { ($0.lapses, -$0.stability) > ($1.lapses, -$1.stability) }
            .prefix(8)
            .map { "{\"word\": \"\($0.word)\", \"lapses\": \($0.lapses), \"stabilityDays\": \(String(format: "%.1f", $0.stability))}" }
            .joined(separator: ", ")
        return "{\"title\": \"\(deck.title)\", \"cards\": \(deck.items.count), \"due\": \(due), \"new\": \(new), \"mature\": \(mature), \"weakestCards\": [\(weakList)]}"
    }

    private static func stageDeck(
        topic: String,
        contentType: String,
        amount: String,
        level: String,
        planUnitId: String?,
        context: Context,
        staged: inout [MessageAttachment]
    ) async throws -> ToolOutcome {
        // Gap-awareness inputs from FSRS state.
        let schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]
        let inLanguage = schedules.values.filter { $0.language == context.language }
        let known = inLanguage
            .filter { matureStability($0) >= LearnerModelService.matureStabilityDays }
            .map { $0.word }
        let recycle = inLanguage
            .filter { $0.lapses >= 2 }
            .sorted { $0.lapses > $1.lapses }
            .prefix(8)
            .map { $0.word }

        let validContent = ["Words", "Phrases", "Sentences"]
        let resolvedContent = validContent.contains(contentType) ? contentType : "Phrases"
        let validAmounts = ["5", "10", "20", "50"]
        let resolvedAmount = validAmounts.contains(amount) ? amount : "10"

        let deck = try await DeckGenerator.generate(
            userPrompt: topic,
            interests: [],
            language: context.language,
            dialect: context.dialect,
            contentType: resolvedContent,
            amount: resolvedAmount,
            level: level,
            tones: [],
            knownWordsToAvoid: Array(known.prefix(60)),
            recycleWords: Array(recycle)
        )

        staged.append(.deckProposal(DeckProposalPayload(
            title: deck.title,
            language: deck.language,
            dialect: deck.dialect,
            level: deck.level,
            contentType: deck.contentType,
            topic: topic,
            items: deck.items,
            planUnitId: planUnitId
        )))

        let sample = deck.items.prefix(5)
            .map { "\($0.word) — \($0.translation)" }
            .joined(separator: "; ")
        return ToolOutcome(
            content: "Staged deck proposal \"\(deck.title)\" (\(deck.items.count) \(resolvedContent.lowercased())). Sample: \(sample). The learner will see a Save card under your reply."
        )
    }

    private static func stagePlan(
        input: JSONValue,
        context: Context,
        staged: inout [MessageAttachment]
    ) async -> ToolOutcome {
        // Re-encode the tool input into the GeneratedPlanPayload shape.
        guard let goal = input["goal_statement"]?.stringValue,
              let target = input["target_level"]?.stringValue,
              let unitsValue = input["units"], unitsValue.arrayValue != nil else {
            return ToolOutcome(content: "Missing goal_statement, target_level, or units.", isError: true)
        }
        let payloadJSON: String? = {
            let dict: JSONValue = .object([
                "goalStatement": .string(goal),
                "targetLevel": .string(target),
                "units": .array((unitsValue.arrayValue ?? []).map { unit in
                    var mapped: [String: JSONValue] = [:]
                    mapped["id"] = unit["id"] ?? .null
                    mapped["title"] = unit["title"] ?? .string("Unit")
                    mapped["canDo"] = unit["canDo"] ?? .array([])
                    mapped["matureFraction"] = unit["matureFraction"] ?? .null
                    mapped["conversationCheck"] = unit["conversationCheck"] ?? .null
                    mapped["activities"] = .array((unit["activities"]?.arrayValue ?? []).map { activity in
                        var spec: [String: JSONValue] = [:]
                        for (key, value) in activity["spec"]?.objectValue ?? [:] {
                            // Coerce to string — the model sometimes sends
                            // numbers for amount despite the schema.
                            let coerced = value.stringValue
                                ?? value.numberValue.map { String(Int($0)) }
                                ?? ""
                            spec[key] = .string(coerced)
                        }
                        return .object([
                            "type": activity["type"] ?? .string("deck"),
                            "label": activity["label"] ?? .string(""),
                            "spec": .object(spec)
                        ])
                    })
                    return .object(mapped)
                })
            ])
            return dict.jsonString
        }()
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GeneratedPlanPayload.self, from: data),
              !payload.units.isEmpty else {
            return ToolOutcome(content: "Could not parse the plan structure. Re-check the units array shape.", isError: true)
        }

        // Revision number continues from any existing plan; completed
        // units from the existing plan are preserved verbatim.
        let languageID = Conversation.languageID(for: context.language)
        let existing = try? await FirebaseCurriculumService.fetch(languageID: languageID)
        var plan = payload.asPlan(
            language: context.language,
            dialect: context.dialect,
            revision: (existing?.revision ?? 0) + 1
        )
        if let existing {
            plan.createdAt = existing.createdAt
            // Protect completed work: any unit id that was completed in
            // the saved plan stays completed with its decks attached.
            plan.units = plan.units.map { unit in
                guard let prior = existing.units.first(where: { $0.id == unit.id }),
                      prior.statusEnum == .completed else { return unit }
                var kept = prior
                kept.order = unit.order
                return kept
            }
            // Keep exactly one active unit: the first non-completed.
            var sawActive = false
            plan.units = plan.units.map { unit in
                var u = unit
                if u.statusEnum != .completed {
                    u.status = sawActive
                        ? CurriculumUnit.Status.locked.rawValue
                        : CurriculumUnit.Status.active.rawValue
                    sawActive = true
                }
                return u
            }
        }

        staged.append(.planProposal(PlanProposalPayload(plan: plan)))
        return ToolOutcome(
            content: "Staged plan proposal (revision \(plan.revision), \(plan.units.count) units). The learner will see an Accept card under your reply."
        )
    }

    private static func reviewHistoryJSON(language: String, limit: Int) async throws -> String {
        let sessions = try await FirebaseDeckService.fetchStudySessions()
        let filtered = sessions.filter { $0.language == language }.prefix(max(1, min(limit, 25)))
        guard !filtered.isEmpty else { return "No study sessions for \(language) yet." }
        let formatter = ISO8601DateFormatter()
        let rows = filtered.map { session in
            "{\"date\": \"\(formatter.string(from: session.completedAt))\", \"deck\": \"\(session.deckTitle)\", \"reviewed\": \(session.totalReviewed), \"correct\": \(session.correctCount), \"incorrect\": \(session.incorrectCount)}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}
