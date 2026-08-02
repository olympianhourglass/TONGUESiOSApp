import Foundation

// Claude wrapper specialized for the conversation tab. Holds the
// system-prompt templating + the JSON parsing for AI replies. Every
// turn round-trips through here: the chat view model collects the
// user's text + the deck context, this client builds the system prompt
// and asks Claude to return a structured reply containing the assistant
// turn, optional inline corrections for the user's previous message,
// and an optional transliteration.
enum ConversationClient {

    // MARK: - Public types

    // A single assistant turn — just the words the learner reads and
    // hears. Deliberately minimal: this is the ONLY thing the learner
    // waits on, so it comes back from a fast model with a tight schema.
    // Inline corrections and the tap-to-translate gloss are computed
    // separately, off the critical path, so they never delay the
    // conversational back-and-forth (see `analyzeUserTurn`).
    struct AssistantReply {
        let text: String
        let transliteration: String?
    }

    // Candidate things the LEARNER could say next, offered when they
    // tap the "stuck" helper. Each is a ready-to-send turn in the
    // target language plus a gloss so they understand what they'd be
    // sending before they commit to it.
    struct SuggestedReply: Identifiable, Hashable {
        var id = UUID()
        let foreign: String
        let transliteration: String?
        let translation: String
    }

    // Result of the background pass over a learner's turn: any inline
    // corrections plus, for Chinese, a pinyin romanization of what they
    // wrote so their own bubble can show it (mirroring the assistant
    // side). `transliteration` is nil for Latin-script languages.
    struct UserTurnAnalysis {
        let corrections: [ConversationCorrection]
        let transliteration: String?
    }

    // Context the chat view model assembles per send. `dueWords` is the
    // small pool of vocab we ask Claude to fold in opportunistically
    // when natural — the conversation doubles as spaced-repetition
    // exposure.
    struct Context {
        let language: String
        let dialect: String
        let level: String
        let scenarioPrompt: String?     // From a starter chip; nil after the conversation moves on.
        let dueWords: [String]          // Foreign-side words from FSRS-due cards.
        // One-line summary of the learner's goals/interests from the
        // learner model. Optional with a default so existing call sites
        // construct Context unchanged.
        var goalsSummary: String? = nil
    }

    // MARK: - Wire message building

    // Maps our domain ConversationMessage history into the Anthropic
    // tool-message format shared by every turn-level call below.
    // Attachment-only carrier messages (empty text) are dropped — the
    // API rejects empty text blocks — and consecutive same-role turns
    // are merged, since tutor notices / placement cards can produce
    // back-to-back assistant turns that would otherwise break the
    // required user/assistant alternation.
    private static func buildMessages(from history: [ConversationMessage]) -> [AnthropicToolMessage] {
        var messages: [AnthropicToolMessage] = []
        for m in history {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role = m.role == .user ? "user" : "assistant"
            if let last = messages.last,
               last.role == role,
               let lastText = last.content.first?.text {
                messages[messages.count - 1] = AnthropicToolMessage(
                    role: role,
                    content: [.text(lastText + "\n\n" + text)]
                )
            } else {
                messages.append(AnthropicToolMessage(role: role, content: [.text(text)]))
            }
        }
        return messages
    }

    // MARK: - Conversation turn (fast path)

    // The latency-critical call: returns ONLY the assistant's next turn
    // (plus a transliteration). It runs on a fast model with a tight
    // token budget so the reply bubble lands quickly and the
    // conversation keeps its rhythm. Correction feedback and the
    // tap-to-translate gloss are produced by separate calls that never
    // block this one — see `analyzeUserTurn` and `quickTranslate`.
    static func sendReply(
        history: [ConversationMessage],
        userText: String,
        context: Context
    ) async throws -> AssistantReply {
        let system = buildSystemPrompt(context: context)
        var messages = buildMessages(from: history)
        messages.append(.user(userText))

        struct DecodedReply: Codable {
            let reply: String
            let transliteration: String?
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "reply": .schemaString("Your next conversational turn in \(context.dialect) \(context.language), using its native script."),
                "transliteration": .schemaNullableString("Latin-script romanization of `reply` for non-Latin scripts; null for languages that already use Latin script.")
            ],
            required: ["reply"]
        )
        let decoded: DecodedReply = try await AnthropicClient.sendStructured(
            toolName: "submit_reply",
            toolDescription: "Submit the assistant's next conversational turn.",
            schema: schema,
            messages: messages,
            system: system,
            model: "claude-sonnet-4-6",
            maxTokens: 700,
            as: DecodedReply.self
        )
        let trimmed = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let translit = decoded.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantReply(
            text: trimmed,
            transliteration: (translit?.isEmpty == false) ? translit : nil
        )
    }

    // MARK: - Correction analysis (off critical path)

    // Judges the learner's most recent message for mistakes. Called in
    // the background AFTER the reply is already on screen, so its
    // latency is invisible — corrections quietly attach to the
    // learner's bubble when they arrive. Runs on the stronger model
    // because accuracy matters more than speed once we're off the
    // critical path.
    static func analyzeUserTurn(
        history: [ConversationMessage],
        userText: String,
        context: Context
    ) async throws -> UserTurnAnalysis {
        let native = AppLanguage.currentNative.promptName
        // For Chinese we also romanize the learner's own message so
        // their bubble can show pinyin, matching the assistant side.
        let wantsTransliteration = DeckGenerator.isChinese(context.language)

        var system = """
        You are a meticulous \(context.dialect) \(context.language) tutor reviewing a learner's message for mistakes. The learner's native language is \(native); write every explanation in \(native).
        """
        if wantsTransliteration {
            // Reuse the app's authoritative pinyin rules so the learner's
            // romanization matches the standard used everywhere else.
            system += "\n\n" + DeckGenerator.chineseGenerationGuidance
        }

        var messages = buildMessages(from: history)
        // Prominent, standalone task so the model doesn't skip it — the
        // correction-focused framing otherwise tends to drop an optional
        // pinyin field.
        let transliterationSection = wantsTransliteration
            ? "\n\nPinyin — set `transliteration` (REQUIRED): the standard Hanyu Pinyin, with tone-mark diacritics, for the learner's ENTIRE message, one space between syllables. Always provide it, even when `corrections` is empty."
            : ""
        let wrappedUser = """
        \(userText)

        ---

        Analyze the learner's message above (using the earlier turns for context) and submit your analysis by calling `submit_analysis`.

        Corrections — set `corrections`:
        • Only include genuine errors — grammar, agreement, vocabulary, register, idiomatic word choice.
        • If the message was clean, return an empty array.
        • Each `original` MUST be a verbatim substring of the message. Do not paraphrase it.
        • Cap at 3 corrections even if there are more — pick the most useful ones.
        • COMPLETELY IGNORE punctuation and capitalization. The learner is typing on a phone and the on-screen keyboard makes those mechanical to enter — never flag a missing period, comma, question mark, accent on a capital, or initial-letter case as an error. Judge the words themselves only.\(transliterationSection)
        """
        messages.append(.user(wrappedUser))

        struct DecodedCorrection: Codable {
            let original: String
            let corrected: String
            let explanation: String
        }
        struct Decoded: Codable {
            let corrections: [DecodedCorrection]?
            let transliteration: String?
        }
        var properties: [String: JSONValue] = [
            "corrections": .schemaArray(items: .schemaObject(
                properties: [
                    "original": .schemaString("Exact substring from the learner's message containing the mistake."),
                    "corrected": .schemaString("What they should have written."),
                    "explanation": .schemaString("Short \(native) explanation (under 25 words) of why.")
                ],
                required: ["original", "corrected", "explanation"]
            ))
        ]
        var required = ["corrections"]
        if wantsTransliteration {
            // Required + non-null so the model can't silently omit it —
            // the correction-focused prompt otherwise tends to skip it.
            properties["transliteration"] = .schemaString("Standard Hanyu Pinyin (with tone-mark diacritics) for the learner's entire message, one space between syllables.")
            required.append("transliteration")
        }
        let schema = JSONValue.schemaObject(
            properties: properties,
            required: required
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_analysis",
            toolDescription: "Submit corrections (and, for Chinese, a pinyin romanization) for the learner's most recent message.",
            schema: schema,
            messages: messages,
            system: system,
            model: "claude-opus-4-7",
            maxTokens: 700,
            as: Decoded.self
        )
        let corrections = (decoded.corrections ?? []).map {
            ConversationCorrection(
                original: $0.original,
                corrected: $0.corrected,
                explanation: $0.explanation
            )
        }
        let translit = decoded.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserTurnAnalysis(
            corrections: corrections,
            transliteration: (translit?.isEmpty == false) ? translit : nil
        )
    }

    // MARK: - Suggested replies ("I'm stuck")

    // Given the conversation so far, proposes a few things the LEARNER
    // could say next — level-appropriate, natural, and varied so a
    // learner who freezes up has a real way forward. The foreign side
    // is ready to send; the gloss and transliteration let them
    // understand what they're choosing before they do.
    static func suggestReplies(
        history: [ConversationMessage],
        context: Context
    ) async throws -> [SuggestedReply] {
        let native = AppLanguage.currentNative.promptName
        let system = """
        You help a \(context.dialect) \(context.language) learner keep a conversation going when they don't know what to say. Their proficiency level is \(context.level); their native language is \(native).
        """
        var messages = buildMessages(from: history)
        let ask = """
        Suggest 3 short, natural things the LEARNER could say next in this conversation, calibrated to their level. Make them genuinely different from each other (for example a question, a direct answer, and a reaction) so they have real choices. Keep each to one short sentence. Submit them by calling `submit_suggestions`.
        """
        messages.append(.user(ask))

        struct DecodedSuggestion: Codable {
            let foreign: String
            let transliteration: String?
            let translation: String
        }
        struct Decoded: Codable {
            let suggestions: [DecodedSuggestion]
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "suggestions": .schemaArray(items: .schemaObject(
                    properties: [
                        "foreign": .schemaString("A natural thing the learner could say next, in \(context.dialect) \(context.language) native script, at their level."),
                        "transliteration": .schemaNullableString("Latin-script romanization of `foreign` for non-Latin scripts; null for languages that already use Latin script."),
                        "translation": .schemaString("Natural \(native) translation of `foreign`.")
                    ],
                    required: ["foreign", "translation"]
                ))
            ],
            required: ["suggestions"]
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_suggestions",
            toolDescription: "Submit a few candidate replies the learner could send next.",
            schema: schema,
            messages: messages,
            system: system,
            model: "claude-sonnet-4-6",
            maxTokens: 600,
            as: Decoded.self
        )
        return decoded.suggestions.prefix(3).map { s in
            let translit = s.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SuggestedReply(
                foreign: s.foreign.trimmingCharacters(in: .whitespacesAndNewlines),
                transliteration: (translit?.isEmpty == false) ? translit : nil,
                translation: s.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - Recap

    // End-of-conversation summarizer. Asks Claude to extract a small
    // batch of useful phrases the user encountered + a brief summary
    // line for the recap UI's header.
    static func recap(
        history: [ConversationMessage],
        context: Context
    ) async throws -> ConversationRecap {
        let system = """
        You are a study coach summarizing a language-learning conversation between a learner and a tutor for the TONGUES app.

        Target language: \(context.dialect) \(context.language)
        Learner level: \(context.level)

        Your job is to scan the conversation and surface the most useful study-worthy phrases the learner encountered or attempted — vocabulary, idioms, collocations, common functional phrases — calibrated to their level. Skip ultra-basic items (hello, thank you, yes / no) unless the level is the lowest beginner tier.
        """

        let transcript = history.map { msg in
            let role = msg.role == .user ? "Learner" : "Tutor"
            return "\(role): \(msg.text)"
        }.joined(separator: "\n")

        let prompt = """
        Conversation transcript:
        \(transcript)

        Submit a recap by calling `submit_conversation_recap`.

        Content rules:
        • 5 to 10 phrases. Favor genuinely useful, study-worthy entries.
        • Keep the foreign side idiomatic and in the deck's dialect.
        • Skip items only the assistant said in passing — focus on entries the learner is likely to need again.
        """

        struct DecodedPhrase: Codable {
            let foreign: String
            let translation: String
            let transliteration: String?
            let partsOfSpeech: [String]?
        }
        struct DecodedRecap: Codable {
            let summary: String
            let phrases: [DecodedPhrase]
        }
        let native = AppLanguage.currentNative.promptName
        let schema = JSONValue.schemaObject(
            properties: [
                "summary": .schemaString("One or two sentences in \(native) describing what the conversation was about, written warmly in second person ('you talked about…')."),
                "phrases": .schemaArray(items: .schemaObject(
                    properties: [
                        "foreign": .schemaString("The phrase in \(context.dialect) \(context.language) using its native script."),
                        "translation": .schemaString("Natural \(native) translation."),
                        "transliteration": .schemaNullableString("Latin-script romanization for non-Latin scripts; null for Latin-script languages."),
                        "partsOfSpeech": .schemaArray(
                            items: .schemaString("Standard English grammatical category."),
                            description: "One or more of: Noun, Verb, Adjective, Adverb, Phrase, Idiom, Sentence."
                        )
                    ],
                    required: ["foreign", "translation"]
                ))
            ],
            required: ["summary", "phrases"]
        )
        let decoded: DecodedRecap = try await AnthropicClient.sendStructured(
            toolName: "submit_conversation_recap",
            toolDescription: "Submit the end-of-conversation recap (summary + study-worthy phrases).",
            schema: schema,
            userPrompt: prompt,
            system: system,
            model: "claude-haiku-4-5-20251001",
            maxTokens: 2048,
            as: DecodedRecap.self
        )
        let phrases = decoded.phrases.map {
            RecapPhrase(
                foreign: $0.foreign,
                translation: $0.translation,
                transliteration: $0.transliteration,
                partsOfSpeech: $0.partsOfSpeech ?? ["Phrase"]
            )
        }
        return ConversationRecap(phrases: phrases, summary: decoded.summary)
    }

    // MARK: - Pronunciation grading

    // Returned by `gradePronunciation`. Drives the drill sheet's
    // colored word strip + the per-word tap hint + the coaching tip.
    // Codable so the drill sheet can persist past attempts to
    // Firestore via `FirebasePronunciationService`.
    struct PronunciationGrade: Hashable, Codable {
        let overallScore: Int       // 0–100
        let coachingTip: String     // One short English sentence for the user.
        let words: [WordScore]
    }

    struct WordScore: Identifiable, Hashable, Codable {
        var id: UUID = UUID()
        let expected: String        // Word from the target sentence.
        let heard: String?          // Closest match in the user's STT transcript, or nil if missed.
        let grade: Mark
        let hint: String?           // Phoneme-level / mouth-position tip; nil for clean words.

        enum Mark: String, Codable, Hashable {
            case good       // user nailed it
            case shaky      // recognizable but off
            case off        // mispronounced
            case missing    // dropped from the sentence entirely
        }
    }

    // Sends the target + the STT transcript of the learner's attempt
    // to Claude and asks for a structured per-word grade. The model
    // does the alignment (word matching despite reorderings, partial
    // hits, dropped tokens) because string-distance heuristics get
    // tripped up by language-specific phonotactics.
    static func gradePronunciation(
        target: String,
        attempted: String,
        language: String,
        dialect: String
    ) async throws -> PronunciationGrade {
        let system = """
        You are a strict but encouraging pronunciation coach for learners of \(dialect) \(language). The learner just attempted to say a target sentence. You'll be given:
          • TARGET: what they were asked to say (the canonical \(dialect) \(language) sentence).
          • HEARD: what the device's speech-to-text picked up. The STT is calibrated for \(dialect) \(language) but is imperfect — it may have misheard sounds the learner actually produced correctly.

        Your job is to align TARGET to HEARD word-by-word and judge each one.
        """

        // Emoji are decorative — drop them so they aren't treated as a
        // token the learner has to pronounce or graded against.
        let cleanTarget = target.strippingEmoji()

        let prompt = """
        TARGET: \(cleanTarget)
        HEARD: \(attempted)

        Submit the per-word grade by calling `submit_pronunciation_grade`.

        Content rules:
        • Iterate over EVERY token in TARGET in order. COMPLETELY IGNORE all punctuation and capitalization in both TARGET and HEARD — do not treat a missing comma, period, question mark, accent on a capital, or initial-letter case as an error. Compare the lowercased word-forms only.
        • `good`: the heard word is the right word, accurate enough for a native speaker to follow without effort.
        • `shaky`: the heard word resembles the target — same shape, but a vowel quality, tone, or consonant length is off. Still understandable.
        • `off`: the heard word looks like a different word entirely. The learner produced something a native would have to puzzle out.
        • `missing`: the target word didn't show up in HEARD at all.
        • Be tolerant of STT artifacts: if HEARD is plausibly the right pronunciation but the STT garbled it (e.g., one-letter difference in a tonal language), grade `shaky` rather than `off`.
        • Hints should be SPECIFIC: name the phoneme, the position, or the contour (e.g. "rolling 'r' too hard — try a single tap"; "second tone should rise — feels flat here").
        • Overall score: weight by word importance. A missing key noun hurts more than a missing filler.
        """

        struct DecodedWord: Codable {
            let expected: String
            let heard: String?
            let grade: String
            let hint: String?
        }
        struct Decoded: Codable {
            let overall_score: Int
            let coaching_tip: String
            let words: [DecodedWord]
        }
        let native = AppLanguage.currentNative.promptName
        let schema = JSONValue.schemaObject(
            properties: [
                "overall_score": .schemaInt("Integer 0-100, weighted by word importance."),
                "coaching_tip": .schemaString("One warm, specific sentence in \(native) (under 30 words)."),
                "words": .schemaArray(items: .schemaObject(
                    properties: [
                        "expected": .schemaString("The word as it appears in TARGET."),
                        "heard": .schemaNullableString("The closest word in HEARD that aligns; null if missing."),
                        "grade": .schemaEnum(
                            ["good", "shaky", "off", "missing"],
                            description: "Per-word grade."
                        ),
                        "hint": .schemaNullableString("Short phoneme / mouth-position tip in \(native) (under 25 words); null if the word was good.")
                    ],
                    required: ["expected", "grade"]
                ))
            ],
            required: ["overall_score", "coaching_tip", "words"]
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_pronunciation_grade",
            toolDescription: "Submit the per-word pronunciation grade and overall coaching tip.",
            schema: schema,
            userPrompt: prompt,
            system: system,
            model: "claude-haiku-4-5-20251001",
            maxTokens: 1024,
            as: Decoded.self
        )
        let words = decoded.words.map {
            WordScore(
                expected: $0.expected,
                heard: $0.heard,
                grade: WordScore.Mark(rawValue: $0.grade.lowercased()) ?? .shaky,
                hint: ($0.hint?.isEmpty == false) ? $0.hint : nil
            )
        }
        return PronunciationGrade(
            overallScore: max(0, min(100, decoded.overall_score)),
            coachingTip: decoded.coaching_tip
                .trimmingCharacters(in: .whitespacesAndNewlines),
            words: words
        )
    }

    // MARK: - Quick translate

    // Lightweight per-token translation triggered when the user taps a
    // word inside an assistant bubble. Uses Haiku for cost; falls back
    // to the input verbatim on any failure.
    static func quickTranslate(
        _ token: String,
        in language: String
    ) async throws -> String {
        let native = AppLanguage.currentNative.promptName
        let prompt = """
        Translate the following \(language) word or short phrase into \(native). Output ONLY the translation, no quotes, no preamble, no explanation.

        \(language): \(token)
        """
        let reply = try await AnthropicClient.sendMessage(
            [AnthropicMessage(role: "user", content: prompt)],
            model: "claude-haiku-4-5-20251001",
            maxTokens: 96
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - System-prompt construction

    private static func buildSystemPrompt(context: Context) -> String {
        let native = AppLanguage.currentNative.promptName
        var lines: [String] = []
        lines.append("You are a warm, patient language-learning conversation partner inside the TONGUES app.")
        lines.append("")
        lines.append("Target language: \(context.dialect) \(context.language)")
        lines.append("Learner proficiency level: \(context.level)")
        lines.append("The learner's native language is \(native); any explanations or translations you give must be in \(native).")
        lines.append("")
        lines.append("Behavior:")
        lines.append("• ALWAYS reply in \(context.dialect) \(context.language) using its native script unless the learner explicitly switches to \(native) to ask a question about the language itself.")
        lines.append("• Calibrate your vocabulary and grammar to the learner's level: simpler structures and high-frequency vocab at beginner levels, richer constructions at advanced levels.")
        lines.append("• Keep turns short. Beginners: 1 short sentence. Intermediate: 1–2 sentences. Advanced: 2–3.")
        lines.append("• Maintain a warm, encouraging tone. Use the target language's natural register for friendly conversation.")
        lines.append("• When the learner makes a mistake, include it in the `corrections` array of your JSON reply — don't break the conversational flow to call it out inline.")
        lines.append("• IGNORE punctuation and capitalization entirely when judging the learner's input. They're typing on a phone keyboard where those are awkward; never treat a missing period, comma, question mark, accent on a capital, or initial-letter case as an error. Read past them as if they weren't relevant.")
        lines.append("• Don't lecture. Don't enumerate grammar rules unless the learner explicitly asks.")
        lines.append("• Vary your prompts so the conversation doesn't feel like an interrogation — sometimes ask, sometimes share something brief, sometimes react.")

        if !context.dueWords.isEmpty {
            let joined = context.dueWords.prefix(12).joined(separator: ", ")
            lines.append("")
            lines.append("Vocabulary the learner is currently reviewing in their flashcards (weave these in naturally when the conversation invites it, but never force them — the conversation comes first):")
            lines.append(joined)
        }

        if let goals = context.goalsSummary, !goals.isEmpty {
            lines.append("")
            lines.append("About this learner (steer topics toward what they care about when natural): \(goals)")
        }

        if let scenario = context.scenarioPrompt, !scenario.isEmpty {
            lines.append("")
            lines.append("Opening scenario for this conversation:")
            lines.append(scenario)
        }

        return lines.joined(separator: "\n")
    }

}
