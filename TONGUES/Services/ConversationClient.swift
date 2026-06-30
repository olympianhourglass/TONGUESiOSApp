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

    struct Reply {
        // Assistant's turn, in the target language using its native
        // script.
        let text: String
        // Latin-script transliteration of `text` when the target
        // language uses a non-Latin script — nil otherwise.
        let transliteration: String?
        // English translation. Tap-to-translate on the assistant
        // bubble opens this; we ask Claude to ship it with every turn
        // so the round-trip latency is hidden inside the same call.
        let englishTranslation: String?
        // Inline corrections targeted at the user's most recent turn.
        // Empty array when the user's message was clean.
        let corrections: [ConversationCorrection]
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

    // MARK: - Conversation turn

    static func sendTurn(
        history: [ConversationMessage],
        userText: String,
        context: Context
    ) async throws -> Reply {
        let system = buildSystemPrompt(context: context)

        // Build the message list Claude sees. We map our domain
        // ConversationMessage into AnthropicToolMessage and append the
        // new user turn at the end. Attachment-only carrier messages
        // (empty text) are skipped and consecutive same-role turns are
        // merged — the API rejects empty text blocks, and tutor notices
        // / placement cards can produce back-to-back assistant turns.
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
        // Append the new user turn with a small reminder of the
        // corrections rules. The tool's input_schema enforces the shape;
        // this prompt only carries content/judgement guidance.
        let wrappedUser = """
        \(userText)

        ---

        Reply by calling the `submit_conversation_turn` tool.

        Content rules for `corrections`:
        • Only include genuine errors in the user's MOST RECENT message — grammar, agreement, vocabulary, register, idiomatic word choice.
        • If their message was clean, return an empty array.
        • Each `original` MUST be a verbatim substring of their last message. Do not paraphrase it.
        • Cap at 3 corrections per turn even if there are more — pick the most useful ones.
        • COMPLETELY IGNORE punctuation and capitalization. The user is typing on a phone and the on-screen keyboard makes those mechanical to enter — never flag a missing period, comma, question mark, accent on a capital, or initial-letter case as an error. Judge the words themselves only.
        """
        messages.append(.user(wrappedUser))

        struct DecodedCorrection: Codable {
            let original: String
            let corrected: String
            let explanation: String
        }
        struct DecodedTurn: Codable {
            let reply: String
            let transliteration: String?
            let english_translation: String?
            let corrections: [DecodedCorrection]?
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "reply": .schemaString("Your next conversational turn in \(context.dialect) \(context.language), using its native script."),
                "transliteration": .schemaNullableString("Latin-script romanization of `reply` for non-Latin scripts; null for languages that already use Latin script."),
                "english_translation": .schemaString("Natural English translation of `reply`."),
                "corrections": .schemaArray(items: .schemaObject(
                    properties: [
                        "original": .schemaString("Exact substring from the user's last message containing the mistake."),
                        "corrected": .schemaString("What they should have written."),
                        "explanation": .schemaString("Short English explanation (under 25 words) of why.")
                    ],
                    required: ["original", "corrected", "explanation"]
                ))
            ],
            required: ["reply", "english_translation", "corrections"]
        )

        let decoded: DecodedTurn = try await AnthropicClient.sendStructured(
            toolName: "submit_conversation_turn",
            toolDescription: "Submit the assistant's next conversational turn plus any inline corrections.",
            schema: schema,
            messages: messages,
            system: system,
            model: "claude-opus-4-7",
            maxTokens: 2048,
            as: DecodedTurn.self
        )

        let corrections = (decoded.corrections ?? []).map {
            ConversationCorrection(
                original: $0.original,
                corrected: $0.corrected,
                explanation: $0.explanation
            )
        }
        let trimmed = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let translit = decoded.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = decoded.english_translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(
            text: trimmed,
            transliteration: (translit?.isEmpty == false) ? translit : nil,
            englishTranslation: (english?.isEmpty == false) ? english : nil,
            corrections: corrections
        )
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
        let schema = JSONValue.schemaObject(
            properties: [
                "summary": .schemaString("One or two sentences describing what the conversation was about, written warmly in second person ('you talked about…')."),
                "phrases": .schemaArray(items: .schemaObject(
                    properties: [
                        "foreign": .schemaString("The phrase in \(context.dialect) \(context.language) using its native script."),
                        "translation": .schemaString("Natural English translation."),
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
        let schema = JSONValue.schemaObject(
            properties: [
                "overall_score": .schemaInt("Integer 0-100, weighted by word importance."),
                "coaching_tip": .schemaString("One warm, specific English sentence (under 30 words)."),
                "words": .schemaArray(items: .schemaObject(
                    properties: [
                        "expected": .schemaString("The word as it appears in TARGET."),
                        "heard": .schemaNullableString("The closest word in HEARD that aligns; null if missing."),
                        "grade": .schemaEnum(
                            ["good", "shaky", "off", "missing"],
                            description: "Per-word grade."
                        ),
                        "hint": .schemaNullableString("Short phoneme / mouth-position tip (under 25 words); null if the word was good.")
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
        let prompt = """
        Translate the following \(language) word or short phrase into English. Output ONLY the translation, no quotes, no preamble, no explanation.

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
        var lines: [String] = []
        lines.append("You are a warm, patient language-learning conversation partner inside the TONGUES app.")
        lines.append("")
        lines.append("Target language: \(context.dialect) \(context.language)")
        lines.append("Learner proficiency level: \(context.level)")
        lines.append("")
        lines.append("Behavior:")
        lines.append("• ALWAYS reply in \(context.dialect) \(context.language) using its native script unless the learner explicitly switches to English to ask a question about the language itself.")
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
