import Foundation

// A single aligned foreign+English sentence (or song/poem line) returned
// by Claude inside `GeneratedContent.pairs`. JSON-codable so the
// content-generation prompt can ask for an array of these directly.
struct SentencePair: Codable, Hashable {
    let foreign: String
    let english: String
}

// What `DeckGenerator.generateContent` returns. `pairs` is the source of
// truth from the model; `prose` is derived from it so the existing
// "Story" view path (which expects a flat string with an "English:"
// marker) keeps working without any of its consumers caring that the
// underlying data is now structured.
struct GeneratedContent {
    let prose: String
    let pairs: [SentencePair]

    static func from(pairs: [SentencePair]) -> GeneratedContent {
        let foreignBlock = pairs.map(\.foreign).joined(separator: " ")
        let englishBlock = pairs.map(\.english).joined(separator: " ")
        let proseString = "\(foreignBlock)\n\nEnglish: \(englishBlock)"
        return GeneratedContent(prose: proseString, pairs: pairs)
    }
}

enum DeckGenerator {
    // System-level audience policy. Passed into the Anthropic `system`
    // field on every generation call so it carries stronger steering
    // weight than inline user-prompt text. TONGUES is a 17+ adult
    // language-learning app and learners have opted into authentic
    // vocabulary — profanity, sexual terms, anatomy, drug/club slang,
    // insults. This policy exists because soft-refusals (blank titles,
    // omitted fields, asterisked words) make the app fail the user:
    // a traveler who only knows the polite words gets blindsided
    // abroad.
    static let audiencePolicy = """
    You are generating content for TONGUES, an adult (17+) language-learning app for travelers. Learners have explicitly opted in to authentic vocabulary across every register, including profanity, sexual terms, anatomy, drug and nightlife slang, insults, and other vulgar or NSFW expressions adults routinely need to recognize and use abroad. This is standard practice for adult language curricula (Pimsleur, Babbel, university foreign-language departments all include this material) — there is nothing controversial about teaching it.

    Operating rules:
    • Produce authentic, idiomatic words a fluent native speaker would actually use. Do NOT sanitize, euphemize, censor with asterisks, substitute milder synonyms, add safety warnings, refuse, or moralize. Translations are equally direct in English — no bleeping ("f***"), no "[vulgar]" placeholders.
    • Every required field in every tool call must be fully populated — including the deck title, which should name the topic directly (e.g. "Mexican Spanish Curse Words", "Berlin Club Slang") rather than be blanked or hedged. A complete, normal-looking deck is the only acceptable output shape.
    • The ONLY content you refuse is material that sexualizes minors or that would be illegal regardless of educational framing. Adult vulgar vocabulary, profanity, sexual or drug terms between consenting adults, insults, and street slang all fall comfortably inside scope — generate them without hesitation or qualification.
    """

    static func generate(
        userPrompt: String,
        interests: [String],
        language: String,
        dialect: String,
        contentType: String,
        amount: String,
        level: String,
        tones: [String],
        // Gap-aware generation (guided decks). `knownWordsToAvoid` lists
        // foreign-side words the learner already has mature FSRS state on
        // (skip them); `recycleWords` are lapsing words the prompt should
        // deliberately work back in. Both default empty so every existing
        // call site behaves identically.
        knownWordsToAvoid: [String] = [],
        recycleWords: [String] = [],
        // When true, the cap pre-check + usage consumption are skipped
        // entirely. Used for the onboarding starter-deck seeding, which is
        // free and must never touch the paywall or the free-deck grace.
        skipCapCheck: Bool = false
    ) async throws -> GeneratedDeck {
        // Cap pre-check. Phrases share the Sentences bucket; Words is
        // its own bucket. Anything else falls back to Words so a
        // future content type can't silently bypass the gate.
        let bucket: SubscriptionBucket = (contentType == "Sentences" || contentType == "Phrases")
            ? .sentences
            : .words
        let requestedCount = Int(amount) ?? 10
        if !skipCapCheck {
            await SubscriptionService.shared.refresh()
            try await SubscriptionService.shared.ensureCapacity(in: bucket, requested: requestedCount)
        }
        // Model laddered to tier: Beginner → Haiku, Pro → Sonnet,
        // Max → Opus. Captured here before the API call so a mid-flight
        // tier change can't swap models inside one generation.
        let model = await SubscriptionService.shared.currentTier.generationModel

        let singularForm = singular(for: contentType)
        let prompt = buildPrompt(
            userPrompt: userPrompt,
            interests: interests,
            language: language,
            dialect: dialect,
            contentType: contentType,
            amount: amount,
            level: level,
            tones: tones,
            knownWordsToAvoid: knownWordsToAvoid,
            recycleWords: recycleWords
        )
        let (decoded, rawJSON) = try await AnthropicClient.sendStructuredOutput(
            toolName: "submit_deck",
            toolDescription: "Submit the generated vocabulary deck to the TONGUES app.",
            schema: deckSchema(language: language, singularForm: singularForm),
            messages: [.user(prompt)],
            system: audiencePolicy,
            model: model,
            maxTokens: 16000,
            as: GenerationResult.self
        )
        let stampedItems = decoded.items.map { $0.withLanguage(language) }
        // Decks count against the bucket by the count actually returned
        // — Claude occasionally returns slightly fewer items than the
        // requested amount, and we shouldn't charge for items the user
        // didn't get. Onboarding seeding skips this so it's truly free.
        if !skipCapCheck {
            await SubscriptionService.shared.consume(stampedItems.count, in: bucket)
        }
        return GeneratedDeck(
            title: decoded.title,
            items: stampedItems,
            language: language,
            dialect: dialect,
            level: level,
            contentType: contentType,
            amount: amount,
            tones: tones,
            interests: interests,
            userPrompt: userPrompt,
            promptSent: prompt,
            rawJSON: rawJSON
        )
    }

    // Singular noun for the content type (Words → "word", Phrases →
    // "phrase", Sentences → "sentence"). Shared by the prompt builder
    // and the schema builder so both stay in lock-step.
    private static func singular(for contentType: String) -> String {
        switch contentType {
        case "Sentences": return "sentence"
        case "Phrases":   return "phrase"
        default:          return "word"
        }
    }

    private static func deckSchema(language: String, singularForm: String) -> JSONValue {
        .schemaObject(
            properties: [
                "title": .schemaString("A short, evocative deck title in English (3-6 words). MUST be in English, never the target language."),
                "items": .schemaArray(items: .schemaObject(
                    properties: [
                        "word": .schemaString("The \(singularForm) written in \(language) using its native script."),
                        "translation": .schemaString("Natural, idiomatic English translation."),
                        "transliteration": .schemaNullableString("Latin-script romanization with diacritics for non-Latin scripts (Arabic, Chinese, Japanese, Korean, Hebrew, Russian, Thai, Hindi, etc.). Null for languages that already use Latin script."),
                        "partsOfSpeech": .schemaArray(
                            items: .schemaEnum(
                                ["Noun", "Verb", "Adjective", "Adverb", "Pronoun", "Preposition", "Conjunction", "Interjection", "Determiner", "Phrase", "Idiom", "Sentence"]
                            ),
                            description: "One or more standard English grammatical categories. Always include — never omit."
                        )
                    ],
                    required: ["word", "translation"]
                ))
            ],
            required: ["title", "items"]
        )
    }

    private static func buildPrompt(
        userPrompt: String,
        interests: [String],
        language: String,
        dialect: String,
        contentType: String,
        amount: String,
        level: String,
        tones: [String],
        knownWordsToAvoid: [String] = [],
        recycleWords: [String] = []
    ) -> String {
        var personalization = ""
        if !knownWordsToAvoid.isEmpty {
            let list = knownWordsToAvoid.prefix(60).joined(separator: ", ")
            personalization += "\n\nThe learner has already mastered these — do NOT use any of them as a standalone deck item (they may still appear inside longer phrases or sentences):\n\(list)"
        }
        if !recycleWords.isEmpty {
            let list = recycleWords.prefix(8).joined(separator: ", ")
            personalization += "\n\nThe learner keeps forgetting these — deliberately work a few back in where they fit the topic (as items themselves, or inside phrases/sentences):\n\(list)"
        }
        let interestsLine = interests.isEmpty ? "(none specified)" : interests.joined(separator: ", ")
        let userText = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPromptLine = userText.isEmpty ? "(none)" : userText
        let tonesLine = tones.isEmpty ? "neutral" : tones.joined(separator: " + ")
        let contentLower = contentType.lowercased()
        let singularForm = singular(for: contentType)

        return """
        Generate a language-learning vocabulary deck for the TONGUES app.

        Deck criteria:
        • Target language: \(language)
        • Variety / dialect: \(dialect)
        • Proficiency level: \(level)
        • Content type: \(contentLower) (individual \(singularForm)s)
        • Number of items: exactly \(amount)
        • Tone: \(tonesLine)
        • Topic categories: \(interestsLine)
        • Additional context from the user: "\(userPromptLine)"

        Generate exactly \(amount) \(contentLower) in \(dialect) \(language), calibrated to a \(level) learner, on the topics above. Each item should feel authentic to a native speaker and pedagogically useful at this level.\(personalization)

        Submit your output by calling the `submit_deck` tool. Its input_schema defines the JSON shape; the rules below specify what to put in each field.

        Content rules:
        • The "title" MUST be written in English — never in \(language) or any other non-English language. Name the topic directly (e.g. "Mexican Spanish Curse Words", "Berlin Club Slang") — never leave it blank, hedged, or euphemistic.
        • Exactly \(amount) items in the "items" array.
        • Each "word" must be linguistically authentic in \(dialect) \(language).
        • Difficulty must match \(level).
        • Each "translation" must read naturally in English.
        • For non-Latin scripts, include accurate romanization with diacritics.
        • All items must be on-topic for the categories above.
        • Match the requested tone: \(tonesLine).
        • For nouns in any gendered language:
          - If the language uses definite articles (e.g. Romance: el/la, le/la/l', il/la/lo, o/a; German: der/die/das; Dutch: de/het; Greek: ο/η/το; Hebrew: ה־; etc.), include the singular definite article as a prefix on "word" so the learner sees grammatical gender at a glance (e.g. "el perro", "la casa", "le chien", "la maison", "der Hund", "die Katze", "das Haus", "il libro", "lo zaino", "la macchina", "o livro", "a mesa", "ο σκύλος", "ה־כלב").
          - If the language has grammatical gender but no comparable article (Russian, Polish, Czech, Ukrainian, most Slavic; Arabic, etc.), still leave "word" as the bare noun, but append a short gender tag in parentheses to "translation": "(m.)", "(f.)", "(n.)", or "(m. pl.)" / "(f. pl.)" when plurality differs from English.
          - Pick the canonical lemma — singular for nouns, masculine singular for adjectives — unless the user prompt explicitly asks otherwise.
        • For non-nouns (verbs, adjectives, adverbs), do NOT prepend articles.
        """
    }

    static func generateWordInfo(
        word: String,
        translation: String,
        language: String,
        dialect: String
    ) async throws -> WordInfo {
        let prompt = buildWordInfoPrompt(
            word: word,
            translation: translation,
            language: language,
            dialect: dialect
        )
        return try await AnthropicClient.sendStructured(
            toolName: "submit_word_info",
            toolDescription: "Submit structured metadata for the word.",
            schema: wordInfoSchema(language: language),
            userPrompt: prompt,
            system: audiencePolicy,
            as: WordInfo.self
        )
    }

    private static func wordInfoSchema(language: String) -> JSONValue {
        .schemaObject(
            properties: [
                "meaning": .schemaString("A slightly expanded English meaning or definition, max ~10 words."),
                "partsOfSpeech": .schemaArray(
                    items: .schemaString("One standard English grammatical category."),
                    description: "1-3 standard English categories: Noun, Verb, Adjective, Adverb, Pronoun, Preposition, Conjunction, Interjection, Determiner, Phrase, etc."
                ),
                "pronunciation": .schemaString("Phonetic spelling in Latin script with middle dots (·) separating syllables, readable by an English speaker (e.g. 'shuhn·duh·shoo·EE')."),
                "language": .schemaString("Always exactly: \(language)"),
                "wordFrequency": .schemaString("Estimated frequency as a percentage string with a percent sign (e.g. '0.025%' or '1.2%'). A rough but plausible estimate."),
                "pronunciationDifficulty": .schemaEnum(
                    ["EASY", "MODERATE", "HARD", "EXPERT"],
                    description: "A single uppercase token."
                )
            ],
            required: ["meaning", "partsOfSpeech", "pronunciation", "language", "wordFrequency", "pronunciationDifficulty"]
        )
    }

    private static func buildWordInfoPrompt(
        word: String,
        translation: String,
        language: String,
        dialect: String
    ) -> String {
        return """
        Provide structured metadata for this word.

        Word to analyze:
        • Word: \(word)
        • English translation: \(translation)
        • Source language: \(dialect) \(language)

        Submit your output by calling the `submit_word_info` tool. All values must be plausible; educated estimates are acceptable.
        """
    }

    static func generateEtymology(
        word: String,
        sourceLanguage: String,
        explanationLanguage: String
    ) async throws -> Etymology {
        let prompt = buildEtymologyPrompt(
            word: word,
            sourceLanguage: sourceLanguage,
            explanationLanguage: explanationLanguage
        )
        return try await AnthropicClient.sendStructured(
            toolName: "submit_etymology",
            toolDescription: "Submit structured etymology data for the word.",
            schema: etymologySchema(),
            userPrompt: prompt,
            system: audiencePolicy,
            as: Etymology.self
        )
    }

    private static func etymologySchema() -> JSONValue {
        let morpheme = JSONValue.schemaObject(
            properties: [
                "surface": .schemaString("The morpheme as it appears in the word (native script)."),
                "type": .schemaString("Morpheme type: prefix, root, suffix, combining, radical, etc."),
                "gloss": .schemaString("Short meaning gloss in the learner's explanation language."),
                "originLanguage": .schemaString("Origin language of this morpheme (in the explanation language)."),
                "rootId": .schemaString("Stable identifier like 'gr.tele' or 'la.sal' — reused across morphemes/related entries so the UI can color-tie them.")
            ],
            required: ["surface", "type", "gloss", "originLanguage", "rootId"]
        )
        let lineageEntry = JSONValue.schemaObject(
            properties: [
                "form": .schemaString("The form at this stage, in its native script. Do NOT translate."),
                "language": .schemaString("Language name (in the explanation language)."),
                "period": .schemaString("Period label (in the explanation language)."),
                "periodSort": .schemaInt("Integer year — negative for BCE — used for chronological ordering."),
                "meaning": .schemaString("Meaning at this stage (in the explanation language)."),
                "current": .schemaBool("True only on the final, modern entry.")
            ],
            required: ["form", "language", "period", "periodSort", "meaning"]
        )
        let related = JSONValue.schemaObject(
            properties: [
                "word": .schemaString("Related/cognate word (native script)."),
                "gloss": .schemaString("Short gloss (in the explanation language)."),
                "rootId": .schemaString("Same rootId as the morpheme it shares.")
            ],
            required: ["word", "gloss", "rootId"]
        )
        let summary = JSONValue.schemaObject(
            properties: [
                "originLanguage": .schemaString("Earliest known origin language (in the explanation language)."),
                "rootForm": .schemaString("Original root form (in its native script)."),
                "originalMeaning": .schemaString("What the root originally meant (in the explanation language)."),
                "highlight": .schemaString("One vivid sentence the learner will remember (in the explanation language).")
            ],
            required: ["originLanguage", "rootForm", "originalMeaning", "highlight"]
        )
        return .schemaObject(
            properties: [
                "word": .schemaString("The headword being analyzed, in its native script."),
                "pronunciation": .schemaString("IPA between slashes, e.g. /ˈsæl.ər.i/."),
                "partOfSpeech": .schemaString("Part of speech (in the explanation language)."),
                "summary": summary,
                "morphemes": .schemaArray(
                    items: morpheme,
                    description: "Include only when the word genuinely decomposes into recognizable morphemes; otherwise return an empty array."
                ),
                "lineage": .schemaArray(
                    items: lineageEntry,
                    description: "2–5 entries oldest → newest. The final entry must carry current = true."
                ),
                "related": .schemaArray(
                    items: related,
                    description: "2–4 cognates when possible; empty array when none."
                )
            ],
            required: ["word", "pronunciation", "partOfSpeech", "summary", "lineage"]
        )
    }

    private static func buildEtymologyPrompt(
        word: String,
        sourceLanguage: String,
        explanationLanguage: String
    ) -> String {
        return """
        You are a linguist providing structured etymology data for a language-learning app.

        Word to analyze: \(word)
        Source language: \(sourceLanguage)
        Learner's explanation language: \(explanationLanguage)

        IMPORTANT — language of the response:
        • Every human-readable text field (`originalMeaning`, `highlight`, `gloss`,
          `meaning`, `period`, `partOfSpeech`, `originLanguage`, `language`) MUST be
          written in \(explanationLanguage), so the learner can read it.
        • Surface forms — `word`, `form`, `surface` — stay in their original script
          and orthography. Do NOT translate or transliterate them.
        • Apply the etymological framework appropriate to \(sourceLanguage): for
          Indo-European words use prefix/root/suffix morphemes; for Chinese/Japanese
          treat radicals and component characters as morphemes; for Arabic surface
          the triconsonantal root; for Korean treat hanja/native components similarly.

        Submit your output by calling the `submit_etymology` tool.

        Content rules:
        • `morphemes`: include only when the word genuinely decomposes into recognizable morphemes (prefix/root/suffix/combining). If the word is mono-morphemic, return an empty array — the UI will fall back to the lineage chain.
        • `lineage`: 2–5 entries, ordered oldest → newest. The final entry must carry `"current": true`.
        • `periodSort`: integer years (negative for BCE) used for chronological ordering. Approximate values are fine.
        • `rootId`: stable identifiers like "gr.tele", "la.sal", "en.pay" — reuse the SAME id across morphemes and related entries so the UI can color-tie them.
        • `related`: 2–4 chips when possible; empty array when no good cognates exist.
        • Keep entries plausible; concise educated estimates are acceptable.
        """
    }

    // MARK: - Grammar breakdown

    // Produces a chunked grammatical explanation of a single sentence —
    // segment-by-segment roles plus the key grammar concepts — written in
    // the learner's explanation language.
    static func generateGrammarBreakdown(
        sentence: String,
        language: String,
        dialect: String,
        explanationLanguage: String
    ) async throws -> GrammarBreakdown {
        let prompt = buildGrammarPrompt(
            sentence: sentence,
            language: language,
            dialect: dialect,
            explanationLanguage: explanationLanguage
        )
        return try await AnthropicClient.sendStructured(
            toolName: "submit_grammar_breakdown",
            toolDescription: "Submit the structured grammatical breakdown of the sentence.",
            schema: grammarBreakdownSchema(),
            userPrompt: prompt,
            system: audiencePolicy,
            as: GrammarBreakdown.self
        )
    }

    private static func grammarBreakdownSchema() -> JSONValue {
        let chunk = JSONValue.schemaObject(
            properties: [
                "text": .schemaString("This contiguous segment of the sentence in its original native script. The segments, joined in order, must reconstruct the whole sentence."),
                "transliteration": .schemaNullableString("Romanization of this segment, or null when the language already uses Latin script."),
                "literal": .schemaString("Literal word-for-word gloss of this segment, in the learner's explanation language."),
                "role": .schemaString("Short grammatical-role label for the segment (e.g. 'Subject', 'Verb — present tense', 'Direct object', 'Preposition + noun'), in the learner's explanation language."),
                "explanation": .schemaString("One or two clear, beginner-friendly sentences in the learner's explanation language explaining what this segment does grammatically and why it takes this form (case, tense, agreement, mood, …).")
            ],
            required: ["text", "literal", "role", "explanation"]
        )
        let point = JSONValue.schemaObject(
            properties: [
                "title": .schemaString("Short name of the grammar concept (e.g. 'Subject–verb agreement', 'Dative case', 'Verb-final word order'), in the learner's explanation language."),
                "explanation": .schemaString("A clear, self-contained 2–4 sentence explanation of this grammar concept as it applies to this sentence, in the learner's explanation language."),
                "example": .schemaNullableString("A short extra example illustrating the concept (native script, optionally followed by a gloss), or null.")
            ],
            required: ["title", "explanation"]
        )
        return .schemaObject(
            properties: [
                "sentence": .schemaString("The sentence being analyzed, verbatim, in its native script."),
                "translation": .schemaString("Natural translation of the whole sentence in the learner's explanation language."),
                "summary": .schemaString("A 1–2 sentence plain-language overview of the sentence's grammatical structure, in the learner's explanation language."),
                "sentenceType": .schemaString("The sentence's communicative type: Declarative, Interrogative, Imperative, or Exclamatory (in the learner's explanation language)."),
                "register": .schemaString("Register/formality of the sentence: Formal, Informal, or Neutral (in the learner's explanation language)."),
                "chunks": .schemaArray(
                    items: chunk,
                    description: "Break the sentence into 3–8 meaningful grammatical segments, in reading order, that together reconstruct the whole sentence."
                ),
                "grammarPoints": .schemaArray(
                    items: point,
                    description: "2–5 notable grammar concepts a learner should understand from this sentence."
                ),
                "wordOrderNote": .schemaNullableString("A short note on how the word order compares to the learner's explanation language, or null when unremarkable.")
            ],
            required: ["sentence", "translation", "summary", "sentenceType", "register", "chunks", "grammarPoints"]
        )
    }

    private static func buildGrammarPrompt(
        sentence: String,
        language: String,
        dialect: String,
        explanationLanguage: String
    ) -> String {
        return """
        You are an expert language teacher creating a clear, structured grammatical breakdown of ONE sentence for a language-learning app. Your goal is to make the grammar feel obvious and approachable — break everything into small, easily readable chunks.

        Sentence to analyze: \(sentence)
        Language: \(dialect) \(language)
        Learner's explanation language: \(explanationLanguage)

        IMPORTANT — language of the response:
        • Every explanatory / human-readable field (`summary`, `role`, `literal`,
          `explanation`, `title`, `sentenceType`, `register`, `wordOrderNote`,
          `translation`) MUST be written in \(explanationLanguage) so the learner can read it.
        • Keep each chunk's `text` and any `example` foreign forms in the original
          \(language) native script — do NOT translate or transliterate those.

        Submit your output by calling the `submit_grammar_breakdown` tool.

        How to break it down:
        • `chunks`: split the sentence into 3–8 contiguous, meaningful segments IN
          READING ORDER (a subject, a verb, an object, a prepositional phrase, a
          particle, etc.). The segments joined back together must reproduce the full
          sentence. For each segment give: its `text` (native script), a
          `transliteration` (or null if Latin-script), a `literal` word-for-word gloss,
          a concise grammatical `role` label, and a friendly 1–2 sentence `explanation`
          of what it does and why it takes that form (case, tense, agreement, mood…).
        • `grammarPoints`: surface 2–5 of the most important grammar CONCEPTS in the
          sentence (e.g. verb conjugation, noun case, gender agreement, word order,
          particles, articles, aspect). Each point gets a short `title`, a clear 2–4
          sentence `explanation` tied to THIS sentence, and an optional extra `example`.
        • `summary`: one or two sentences giving the big-picture structure (e.g. "This
          is a simple present-tense statement: subject + verb + object…").
        • `sentenceType` and `register`: classify the sentence.
        • `wordOrderNote`: if the word order differs notably from \(explanationLanguage),
          explain it briefly; otherwise null.

        Write warmly and simply, as if tutoring a motivated beginner. Avoid dense
        jargon; when you must use a grammatical term, gloss it in plain words. Keep
        each explanation focused and skimmable.
        """
    }

    static func generateContent(
        kind: ContentGenerationKind,
        deck: DeckDocument,
        additionalDetails: String
    ) async throws -> GeneratedContent {
        // Artifact pre-check: even though we don't increment the
        // counter until save, gating generation on remaining quota
        // prevents the user from running up Claude usage they can't
        // act on. The actual consume() lands inside
        // FirebaseDeckArtifactService.save.
        await SubscriptionService.shared.refresh()
        try await SubscriptionService.shared.ensureCapacity(in: .artifacts, requested: 1)
        let model = await SubscriptionService.shared.currentTier.generationModel

        let prompt = buildContentPrompt(
            kind: kind,
            deck: deck,
            additionalDetails: additionalDetails
        )
        struct Response: Codable { let pairs: [SentencePair] }
        let decoded: Response = try await AnthropicClient.sendStructured(
            toolName: "submit_paired_content",
            toolDescription: "Submit paired foreign/English sentence content for the learner.",
            schema: contentSchema(deck: deck),
            userPrompt: prompt,
            system: audiencePolicy,
            model: model,
            as: Response.self
        )
        return GeneratedContent.from(pairs: decoded.pairs)
    }

    private static func contentSchema(deck: DeckDocument) -> JSONValue {
        .schemaObject(
            properties: [
                "pairs": .schemaArray(
                    items: .schemaObject(
                        properties: [
                            "foreign": .schemaString("One sentence (or, for songs/poems, one line) in \(deck.language) using its native script."),
                            "english": .schemaString("Natural English translation of THAT single foreign sentence/line — not a literal word-for-word gloss.")
                        ],
                        required: ["foreign", "english"]
                    ),
                    description: "6 to 15 pairs total. Each is exactly ONE foreign sentence (or one verse line) and its English translation."
                )
            ],
            required: ["pairs"]
        )
    }

    private static func buildContentPrompt(
        kind: ContentGenerationKind,
        deck: DeckDocument,
        additionalDetails: String
    ) -> String {
        let trimmedDetails = additionalDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let topicLine: String
        if trimmedDetails.isEmpty {
            let topics = deck.interests.isEmpty
                ? "(general interest)"
                : deck.interests.joined(separator: ", ")
            topicLine = "Topic (from deck interests): \(topics)"
        } else {
            topicLine = "Topic / user direction: \"\(trimmedDetails)\""
        }

        let vocabLines = deck.items.prefix(40).map { item -> String in
            let translit = item.transliteration.map { " (\($0))" } ?? ""
            return "• \(item.word)\(translit) — \(item.translation)"
        }.joined(separator: "\n")

        return """
        Generate paired language-learning reading content.

        Deck context:
        • Target language: \(deck.dialect) \(deck.language)
        • Learner level: \(deck.level)
        • \(topicLine)

        The learner is studying these vocabulary entries from the deck:
        \(vocabLines)

        Generate \(kind.promptDescription) in \(deck.dialect) \(deck.language), calibrated for a \(deck.level) learner, that naturally incorporates as many of the vocabulary entries above as possible. Use the topic above as the subject matter.

        Submit your output by calling the `submit_paired_content` tool.

        Content rules:
        • 6 to 15 pairs total. Roughly equivalent to 1–3 short paragraphs of prose, split sentence-by-sentence.
        • Each pair is exactly ONE foreign sentence (or one line for songs/poems) and its English translation. Translations align 1:1 with sentences.
        • For songs/poems: each verse line becomes its own pair so line breaks are preserved.
        • "foreign" field must be in \(deck.language) using its native script.
        • "english" field must be natural English (not a literal word-for-word gloss).
        • Don't include the English text inside the foreign field, or vice versa.
        """
    }

    static func generateRelated(
        relation: RelationKind,
        source: GeneratedItem,
        language: String,
        dialect: String,
        level: String,
        count: Int = 3
    ) async throws -> [GeneratedItem] {
        // Tier-laddered model. No cap check here — related lookups are
        // a tap-to-explore helper, not a deck generation.
        let model = await SubscriptionService.shared.currentTier.generationModel
        let prompt = buildRelatedPrompt(
            relation: relation,
            source: source,
            language: language,
            dialect: dialect,
            level: level,
            count: count
        )
        let decoded: GenerationResult = try await AnthropicClient.sendStructured(
            toolName: "submit_related_items",
            toolDescription: "Submit related vocabulary entries.",
            schema: deckSchema(language: language, singularForm: "word"),
            userPrompt: prompt,
            system: audiencePolicy,
            model: model,
            as: GenerationResult.self
        )
        return decoded.items.map { $0.withLanguage(language) }
    }

    private static func buildRelatedPrompt(
        relation: RelationKind,
        source: GeneratedItem,
        language: String,
        dialect: String,
        level: String,
        count: Int = 3
    ) -> String {
        let scriptHint = source.transliteration.map { " (transliteration: \($0))" } ?? ""
        return """
        Generate related language-learning entries.

        Source entry:
        • Word: \(source.word)\(scriptHint)
        • English translation: \(source.translation)
        • Language: \(dialect) \(language)
        • Learner level: \(level)

        Generate exactly \(count) \(relation.promptDescription) of the source word above, in \(dialect) \(language), calibrated to a \(level) learner.

        Submit your output by calling the `submit_related_items` tool. The `title` field is not displayed for related items — any short label is fine.

        Content rules:
        • Exactly \(count) items in the "items" array.
        • Each item must be linguistically authentic in \(dialect) \(language).
        • Match the requested relationship to the source word.
        • For non-Latin scripts, always include accurate romanization.
        • For nouns in any gendered language:
          - If the language uses definite articles (Romance: el/la, le/la/l', il/la/lo, o/a; German: der/die/das; Dutch: de/het; Greek: ο/η/το; Hebrew: ה־; etc.), include the singular definite article as a prefix on "word".
          - If the language has gender but no comparable article (Slavic, Arabic, etc.), append "(m.)", "(f.)", "(n.)", "(m. pl.)", or "(f. pl.)" to "translation".
          - Use the canonical lemma — singular for nouns, masculine singular for adjectives.
        • Do NOT prepend articles for non-nouns.
        """
    }

    static func findCorrespondingForeignWord(
        englishWord: String,
        foreignContext: String,
        englishContext: String,
        language: String,
        dialect: String
    ) async throws -> String? {
        let trimmedForeign = foreignContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForeign.isEmpty else { return nil }
        let trimmedEnglish = englishContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        You align one English word to the corresponding \(language) word inside a given passage.

        English word: \(englishWord)
        Source language: \(dialect) \(language)

        \(language) passage:
        \"\"\"
        \(trimmedForeign)
        \"\"\"

        English translation:
        \"\"\"
        \(trimmedEnglish)
        \"\"\"

        Identify the single \(language) word in the \(language) passage above that best corresponds in meaning to the English word. Submit it by calling `submit_aligned_word`.

        Rules:
        - Return one word, matching exactly as it appears in the \(language) passage (same form, same script, same capitalization).
        - The word must appear verbatim in the \(language) passage.
        - If no clear correspondence exists, return an empty string for "word".
        """
        struct CorrespondingForeignWord: Codable { let word: String }
        let schema = JSONValue.schemaObject(
            properties: [
                "word": .schemaString("The matching \(language) word, or empty string if no clear correspondence.")
            ],
            required: ["word"]
        )
        do {
            let result: CorrespondingForeignWord = try await AnthropicClient.sendStructured(
                toolName: "submit_aligned_word",
                toolDescription: "Submit the \(language) word that aligns to the English word.",
                schema: schema,
                userPrompt: prompt,
                as: CorrespondingForeignWord.self
            )
            let trimmed = result.word.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    static func findCorrespondingTokens(
        foreignWord: String,
        englishContext: String,
        language: String,
        dialect: String
    ) async throws -> [String] {
        let trimmedContext = englishContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else { return [] }
        let prompt = """
        You align one foreign word to the corresponding English token(s) inside a given English translation.

        Foreign word: \(foreignWord)
        Source language: \(dialect) \(language)
        English translation:
        \"\"\"
        \(trimmedContext)
        \"\"\"

        Identify the English word(s) in the translation above that correspond in meaning to the foreign word. Submit them by calling `submit_aligned_tokens`.

        Rules:
        - Return 0 to 3 single-word tokens that appear verbatim (case-insensitive) in the translation above.
        - Include inflected forms if more than one occurs (e.g. "run" and "running").
        - Each entry must be a single English word — no punctuation, no phrases.
        - If no clear correspondence exists, return an empty array.
        """
        struct CorrespondingTokens: Codable { let tokens: [String] }
        let schema = JSONValue.schemaObject(
            properties: [
                "tokens": .schemaArray(
                    items: .schemaString("A single English word that appears verbatim in the translation."),
                    description: "0 to 3 single-word tokens. Empty array if no correspondence."
                )
            ],
            required: ["tokens"]
        )
        do {
            let result: CorrespondingTokens = try await AnthropicClient.sendStructured(
                toolName: "submit_aligned_tokens",
                toolDescription: "Submit aligned English tokens for the foreign word.",
                schema: schema,
                userPrompt: prompt,
                as: CorrespondingTokens.self
            )
            return result.tokens
        } catch {
            return []
        }
    }

    // Asks Claude Haiku to map a user's dream destinations to language
    // suggestions. Cheap and fast; returns 3–5 LanguagePreferences keyed to
    // the destinations the user picked.
    static func suggestLanguages(forDestinations destinations: [String]) async throws -> [LanguagePreference] {
        guard !destinations.isEmpty else { return [] }
        let list = destinations.map { "• \($0)" }.joined(separator: "\n")
        let prompt = """
        A language-learning user picked these dream destinations:

        \(list)

        Suggest 3 to 5 languages they'd benefit most from learning to travel there.
        Choose the most useful language per region; favor primary spoken languages.
        Use realistic dialect names matching what the TONGUES app accepts (e.g.
        "MSA" or "Egyptian" for Arabic, "Standard" otherwise). Default level: "A1".

        Submit your suggestions by calling `submit_language_suggestions`.
        """
        struct Response: Codable { let suggestions: [Suggestion] }
        struct Suggestion: Codable { let language: String; let dialect: String; let level: String }
        do {
            let decoded: Response = try await AnthropicClient.sendStructured(
                toolName: "submit_language_suggestions",
                toolDescription: "Submit ranked language suggestions for the learner.",
                schema: languageSuggestionsSchema(),
                userPrompt: prompt,
                model: "claude-haiku-4-5-20251001",
                maxTokens: 1024,
                as: Response.self
            )
            return decoded.suggestions.map {
                LanguagePreference(language: $0.language, dialect: $0.dialect, level: $0.level)
            }
        } catch {
            print("suggestLanguages decode error: \(error)")
            return []
        }
    }

    private static func languageSuggestionsSchema() -> JSONValue {
        .schemaObject(
            properties: [
                "suggestions": .schemaArray(
                    items: .schemaObject(
                        properties: [
                            "language": .schemaString("Canonical English language name (e.g. 'Spanish', 'Chinese (Mandarin)')."),
                            "dialect": .schemaString("Realistic dialect name TONGUES accepts (e.g. 'MSA' or 'Egyptian' for Arabic, 'Standard' otherwise)."),
                            "level": .schemaString("CEFR-style starting level — default 'A1'.")
                        ],
                        required: ["language", "dialect", "level"]
                    ),
                    description: "3 to 5 ranked suggestions."
                )
            ],
            required: ["suggestions"]
        )
    }

    // Pulls a niche cultural insight about one of the user's destinations
    // for the Explore tab's CULTURAL INSIGHT card.
    //
    // Randomness: we pick the destination client-side (Swift's
    // `randomElement`) instead of asking the model to choose — the model
    // tends to anchor on whichever destination is first or most famous,
    // so client-side picking gives genuinely uniform variety across the
    // list. A short UUID salt is still folded into the prompt so even
    // when the same destination is picked twice in a row the model will
    // surface a *different* niche fact each time.
    //
    // Granularity: the destination string is whatever the user typed
    // during onboarding — could be a country ("Japan"), a city
    // ("Naples"), or "City, Country" ("Lyon, France"). The prompt asks
    // the model to drill down to the most specific place name it can,
    // so a city-level entry yields a neighborhood / city-specific
    // anecdote rather than a country-wide fact.
    //
    // The return field is `location` (renamed from `country`) to reflect
    // that the displayed label may be a city, region, or country.
    static func suggestCulturalInsight(forDestinations destinations: [String]) async throws -> (location: String, fact: String)? {
        guard let picked = destinations.randomElement() else { return nil }
        let salt = UUID().uuidString.prefix(8)
        let prompt = """
        A traveler is daydreaming about this destination:

        \(picked)

        Share a single niche cultural fact about this place — the most
        specific place name above. If it's a city or neighborhood, the
        fact MUST be about that city/neighborhood (a local custom, a
        quirky shop, a regional tradition, a quiet historical detail).
        Only fall back to a country-level fact if the destination really
        is just a country name. Skip clichés (famous landmarks, national
        dishes everyone knows, generic stereotypes). Pick something a
        local would know but most travelers wouldn't. Two or three
        sentences max; conversational tone.

        Variation salt (use to ensure a different fact than previous
        calls): \(salt)

        Submit your insight by calling `submit_cultural_insight`. `location` should be the exact place the fact is about — city name if city-specific, country name otherwise.
        """
        struct Response: Codable { let location: String; let fact: String }
        let schema = JSONValue.schemaObject(
            properties: [
                "location": .schemaString("Exact place the fact is about (city if city-specific, otherwise country)."),
                "fact": .schemaString("Two or three sentences, conversational tone.")
            ],
            required: ["location", "fact"]
        )
        do {
            let decoded: Response = try await AnthropicClient.sendStructured(
                toolName: "submit_cultural_insight",
                toolDescription: "Submit a niche cultural insight about the destination.",
                schema: schema,
                userPrompt: prompt,
                model: "claude-haiku-4-5-20251001",
                maxTokens: 512,
                as: Response.self
            )
            return (decoded.location, decoded.fact)
        } catch {
            print("suggestCulturalInsight decode error: \(error)")
            return nil
        }
    }

    // Adjacent-country companion to suggestLanguages(forDestinations:). For
    // each destination the user picked, returns languages spoken in the
    // *neighboring* countries — the row beneath "Where You Want to Go" on
    // Explore. The model is told to skip the primary languages of the
    // destinations themselves (those already populate the row above).
    static func suggestAdjacentLanguages(forDestinations destinations: [String]) async throws -> [LanguagePreference] {
        guard !destinations.isEmpty else { return [] }
        let list = destinations.map { "• \($0)" }.joined(separator: "\n")
        let prompt = """
        A language-learning user picked these dream destinations:

        \(list)

        Suggest 3 to 5 languages spoken in countries directly *adjacent* to
        those destinations (think regional neighbors a traveler might reach
        on a short trip). Do NOT include the primary languages of the
        destinations themselves — those are already covered. Favor primary
        spoken languages of each neighboring country and order by likely
        usefulness for a traveler.

        Use canonical English names matching the TONGUES app (e.g.
        "Chinese (Mandarin)", "Chinese (Cantonese)"). Use realistic dialect
        names matching what the app accepts (e.g. "MSA" or "Egyptian" for
        Arabic, "Standard" otherwise). Default level: "A1".

        Submit your suggestions by calling `submit_language_suggestions`.
        """
        struct Response: Codable { let suggestions: [Suggestion] }
        struct Suggestion: Codable { let language: String; let dialect: String; let level: String }
        do {
            let decoded: Response = try await AnthropicClient.sendStructured(
                toolName: "submit_language_suggestions",
                toolDescription: "Submit adjacent-country language suggestions.",
                schema: languageSuggestionsSchema(),
                userPrompt: prompt,
                model: "claude-haiku-4-5-20251001",
                maxTokens: 1024,
                as: Response.self
            )
            return decoded.suggestions.map {
                LanguagePreference(language: $0.language, dialect: $0.dialect, level: $0.level)
            }
        } catch {
            print("suggestAdjacentLanguages decode error: \(error)")
            return []
        }
    }

    // Coordinate-based companion to suggestLanguages(forDestinations:). The
    // Explore tab's "Languages Based on Where You Are" row sends the user's
    // current lat/lon and gets back the 3–5 most useful languages spoken at
    // that location. We keep the prompt deliberately simple — the model
    // already knows the geography; we just need it to map (lat, lon) → a
    // ranked list of widely spoken languages there.
    static func suggestLanguages(
        forCoordinate latitude: Double,
        longitude: Double
    ) async throws -> [LanguagePreference] {
        let prompt = """
        A language-learning user is physically located at:

        latitude: \(latitude)
        longitude: \(longitude)

        Suggest the 3 to 5 languages most useful to learn at that location.
        Order by usefulness for everyday life there (primary spoken language
        first, then minority / co-official / heritage languages). Use
        canonical English names matching the TONGUES app
        (e.g. "Chinese (Mandarin)", "Chinese (Cantonese)", "Spanish",
        "Portuguese"). Use realistic dialect names matching what the app
        accepts (e.g. "MSA" or "Egyptian" for Arabic, "Standard" otherwise).
        Default level: "A1". Do NOT include English unless it is genuinely
        the primary local language at that coordinate.

        Submit your suggestions by calling `submit_language_suggestions`.
        """
        struct Response: Codable { let suggestions: [Suggestion] }
        struct Suggestion: Codable { let language: String; let dialect: String; let level: String }
        do {
            let decoded: Response = try await AnthropicClient.sendStructured(
                toolName: "submit_language_suggestions",
                toolDescription: "Submit location-aware language suggestions.",
                schema: languageSuggestionsSchema(),
                userPrompt: prompt,
                model: "claude-haiku-4-5-20251001",
                maxTokens: 1024,
                as: Response.self
            )
            return decoded.suggestions.map {
                LanguagePreference(language: $0.language, dialect: $0.dialect, level: $0.level)
            }
        } catch {
            print("suggestLanguages(forCoordinate:) decode error: \(error)")
            return []
        }
    }

    // One-sentence summary of the user's onboarding choices, written to them
    // in second person. Uses Haiku — cheap, fast, fits well above the final
    // "Ready to meet that version of you?" screen.
    static func summarizeOnboarding(_ answers: OnboardingAnswers) async throws -> String {
        let name = (answers.name?.isEmpty == false ? answers.name! : "(no name)")
        let destinations = (answers.destinations ?? []).map { $0.name }
        let destinationLine = destinations.isEmpty ? "(none)" : destinations.prefix(3).joined(separator: ", ")
        let language = answers.languageOfInterest ?? "(none)"
        let interestsLine = (answers.interests ?? []).isEmpty
            ? "(none)"
            : (answers.interests ?? []).prefix(8).joined(separator: ", ")
        let prompt = """
        Write one warm, present-tense sentence (under 25 words) summarizing this language-learning user's onboarding choices. Address them in second person ("you"). No quotes, no preamble, no trailing period commentary — just the sentence.

        User answers:
        • Name: \(name)
        • Top destination: \(destinationLine)
        • Top language to learn: \(language)
        • What's pulling them toward the language: \(answers.motivationDetail ?? "(unspecified)")
        • Fluency-day vision: \(answers.fluencyScene ?? "(unspecified)")
        • Most wants to understand right now: \(answers.firstUnderstand ?? "(unspecified)")
        • Heritage relationship: \(answers.heritageBackground ?? "(unspecified)")
        • Interests: \(interestsLine)

        Output: the sentence only.
        """
        let reply = try await AnthropicClient.sendMessage(
            [AnthropicMessage(role: "user", content: prompt)],
            model: "claude-haiku-4-5-20251001",
            maxTokens: 256
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Four short example deck titles for the onboarding "ready" screen. Pulls
    // from the user's target language, destinations, and motivation so the
    // suggestions feel personal. Uses Haiku — cheap, fast, returns JSON.
    static func suggestSampleDecks(_ answers: OnboardingAnswers) async throws -> [String] {
        let dest = (answers.destinations ?? []).map { $0.name }
        let prompt = """
        Suggest exactly 4 short, evocative deck titles a TONGUES language-learning user could generate. Each should reflect their target language, a destination, or their motivation — mixing useful vocabulary with cultural texture.

        Constraints:
        • Each title 3 to 6 words.
        • Specific, not generic ("Café Talk in Paris" — not "Restaurant Words").
        • No quotes inside titles.

        User answers:
        • Target language: \(answers.languageOfInterest ?? "(none)")
        • Destinations: \(dest.isEmpty ? "(none)" : dest.prefix(3).joined(separator: ", "))
        • Pulling toward language: \(answers.motivationDetail ?? "(unspecified)")
        • Fluency-day vision: \(answers.fluencyScene ?? "(unspecified)")
        • Most wants to understand now: \(answers.firstUnderstand ?? "(unspecified)")
        • Heritage: \(answers.heritageBackground ?? "(unspecified)")

        Submit the four titles by calling `submit_sample_decks`.
        """
        struct Response: Codable { let decks: [String] }
        let schema = JSONValue.schemaObject(
            properties: [
                "decks": .schemaArray(
                    items: .schemaString("A 3-6 word deck title."),
                    description: "Exactly 4 specific, evocative deck titles."
                )
            ],
            required: ["decks"]
        )
        do {
            let decoded: Response = try await AnthropicClient.sendStructured(
                toolName: "submit_sample_decks",
                toolDescription: "Submit four short deck-title suggestions.",
                schema: schema,
                userPrompt: prompt,
                model: "claude-haiku-4-5-20251001",
                maxTokens: 512,
                as: Response.self
            )
            return decoded.decks
        } catch {
            print("suggestSampleDecks decode error: \(error)")
            return []
        }
    }

    // Suggests 10 short, specific sub-topics for a user–typed interest in
    // the onboarding "What are you most interested in?" screen. Used to
    // populate the row of sub-chips that appears below a custom-entered
    // chip (the built-in profession/hobby chips have hardcoded sub-chips
    // and bypass this call entirely). Haiku 4.5 + tight maxTokens keeps
    // the round-trip ~free.
    static func suggestRelatedInterests(forInterest interest: String) async throws -> [String] {
        let trimmed = interest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let prompt = """
        A language learner just told us they're interested in: "\(trimmed)"

        Suggest exactly 10 short, specific sub-topics, scenes, or related concepts that someone with that interest would want vocabulary for. Each chip is 1–3 words. Concrete is better than generic ("Espresso", not "Coffee terminology").

        Submit them by calling `submit_related_interests`.
        """
        struct Response: Codable { let chips: [String] }
        let schema = JSONValue.schemaObject(
            properties: [
                "chips": .schemaArray(
                    items: .schemaString("A 1-3 word, specific sub-topic chip."),
                    description: "Exactly 10 chips."
                )
            ],
            required: ["chips"]
        )
        do {
            let decoded: Response = try await AnthropicClient.sendStructured(
                toolName: "submit_related_interests",
                toolDescription: "Submit 10 sub-topic chips for the user's interest.",
                schema: schema,
                userPrompt: prompt,
                model: "claude-haiku-4-5-20251001",
                maxTokens: 256,
                as: Response.self
            )
            return decoded.chips
        } catch {
            print("suggestRelatedInterests decode error: \(error)")
            return []
        }
    }

    // Boils the user's most-practiced decks down to a 1–3 word topic label
    // for the Statistics tab's "Your Favorite Topic" card. Haiku 4.5 with a
    // tight 32-token cap keeps the call ~free; the caller caches the
    // result locally and only re-fires when the top-deck signature
    // changes (i.e. a deck enters or leaves the top set).
    static func summarizeFavoriteTopic(decks: [DeckTopicSummary]) async throws -> String {
        guard !decks.isEmpty else { return "" }
        let lines = decks.map { deck -> String in
            let interests = deck.interests.isEmpty
                ? ""
                : " — interests: \(deck.interests.joined(separator: ", "))"
            return "• \(deck.title) [\(deck.contentType)]\(interests)"
        }.joined(separator: "\n")
        let prompt = """
        A language learner has been practicing these vocabulary decks the most:

        \(lines)

        In 1–3 English words, name the overarching theme of what they're studying. Examples of the kind of label we want: "Literature", "Food & travel", "Skincare", "Business", "Pop culture".

        Return ONLY the label — no quotes, no period, no preamble, no explanation. Title Case.
        """
        let reply = try await AnthropicClient.sendMessage(
            [AnthropicMessage(role: "user", content: prompt)],
            model: "claude-haiku-4-5-20251001",
            maxTokens: 32
        )
        // Strip any wrapping quotes or trailing punctuation the model
        // sometimes adds despite the instruction.
        return reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”‘’"))
    }

    // Two-sentence portrait of the user's learning behavior + interests.
    // Feeds the Statistics tab's "Overall Summary" card. Lives on Haiku
    // 4.5 with a tight token cap — the call only fires when the inputs'
    // signature changes, so most app sessions reuse the cached string.
    static func summarizeOverallLearner(
        topLanguage: String?,
        preferredMethod: String,
        bestLearningTime: String,
        favoriteTopic: String,
        streakDays: Int,
        totalXP: Int,
        topLanguagesByPractice: [String]
    ) async throws -> String {
        let lines: [String] = [
            "• Most-practiced language: \(topLanguage ?? "(none yet)")",
            "• All practice languages (most → least): \(topLanguagesByPractice.isEmpty ? "(none)" : topLanguagesByPractice.joined(separator: ", "))",
            "• Preferred learning method: \(preferredMethod.isEmpty ? "(unknown)" : preferredMethod) (active = flashcards, passive = audio, balanced = mix)",
            "• Best time of day to learn: \(bestLearningTime.isEmpty ? "(unknown)" : bestLearningTime)",
            "• Favorite topic across decks: \(favoriteTopic.isEmpty ? "(unknown)" : favoriteTopic)",
            "• Daily streak: \(streakDays) \(streakDays == 1 ? "day" : "days")",
            "• Total XP: \(totalXP)"
        ]
        let prompt = """
        A TONGUES language-learning user has this profile:

        \(lines.joined(separator: "\n"))

        Write 2 short sentences (under 40 words total) describing the kind of language learner they are and the interests they gravitate toward. Synthesize across the signals — don't list them. Address them in second person ("you"). Warm, present-tense, observational. No preamble, no quotes, no bullet points, no markdown — just the two sentences.
        """
        let reply = try await AnthropicClient.sendMessage(
            [AnthropicMessage(role: "user", content: prompt)],
            model: "claude-haiku-4-5-20251001",
            maxTokens: 160
        )
        return reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
    }

    // Tweaks the supplied sentence in-language for Sentence Studio. The
    // instruction wording stresses *subtle* changes — a one- or two-token
    // delta, not a rewrite — so the history reads as a sequence of small,
    // recognizable edits rather than a chain of unrelated sentences.
    enum SentenceTransformation {
        case shorten
        case lengthen
        case addClause(ClauseKind)
        case changeTone(ToneKind)
        case changeTense(TenseKind)
        // `label` is the raw proficiency string the app already uses
        // for the deck (e.g., "HSK 4" for Mandarin, "JLPT N3" for
        // Japanese, "A1" for CEFR languages, "TOPIK 5" for Korean…).
        // We pass it through to Claude verbatim — modern LLMs already
        // know the conventions and target vocabulary for each
        // framework, so wrapping it in an extra enum would just lose
        // information.
        case changeLevel(label: String)

        fileprivate var instruction: String {
            switch self {
            case .shorten:
                return "Rewrite the sentence to be SLIGHTLY shorter. Trim a modifier, redundancy, or a small subordinate clause. Keep the same overall meaning, register, tense, and key vocabulary. This is a subtle, light edit — not a dramatic cut. The result must still read naturally in the target language."
            case .lengthen:
                return "Rewrite the sentence to be SLIGHTLY longer. Add a small descriptor, modifier, or short clause that fits the existing meaning. Keep the same register and tense. This is a subtle, light edit — not a dramatic expansion. The result must still read naturally in the target language."
            case .addClause(let kind):
                return kind.promptInstruction
            case .changeTone(let kind):
                return kind.promptInstruction
            case .changeTense(let kind):
                return kind.promptInstruction
            case .changeLevel(let label):
                return "Recast the sentence at the \"\(label)\" proficiency level for learners of this language. Adjust vocabulary and grammatical complexity to fit a learner at \"\(label)\" — simpler / more elementary if the level represents a beginner stage, richer / more complex if it represents an advanced one. Use the conventions implied by the framework in the label (HSK for Mandarin, JLPT for Japanese, TOPIK for Korean, CEFR's A1–C2 for European languages, etc.). Keep the same core meaning and topic; the result must read idiomatically in the target language at exactly that level."
            }
        }
    }

    // Phrase/clause types the user can ask Claude to fold into the
    // current Sentence Studio sentence. Each case carries:
    //   - A display name for the picker row
    //   - A short grammatical description Claude uses to produce the
    //     right kind of construction
    // The prompts intentionally describe the construction in linguistic
    // terms rather than English-specific examples so the rewrite stays
    // idiomatic in non-English target languages.
    enum ClauseKind: CaseIterable, Identifiable, Hashable {
        case absolutePhrase
        case adverbialClause
        case appositivePhrase
        case conditionalClause
        case gerundPhrase
        case infinitivePhrase
        case interrogativeClause
        case participlePhrase
        case subjunctiveClause

        public var id: String { displayName }

        public var displayName: String {
            switch self {
            case .absolutePhrase:      return "Absolute Phrase"
            case .adverbialClause:     return "Adverbial Clause"
            case .appositivePhrase:    return "Appositive Phrase"
            case .conditionalClause:   return "Conditional Clause"
            case .gerundPhrase:        return "Gerund Phrase"
            case .infinitivePhrase:    return "Infinitive Phrase"
            case .interrogativeClause: return "Interrogative Clause"
            case .participlePhrase:    return "Participle Phrase"
            case .subjunctiveClause:   return "Subjunctive Clause"
            }
        }

        fileprivate var promptInstruction: String {
            let base = "Rewrite the sentence to fold in"
            let close = "Keep the original meaning, register, tense, and key vocabulary intact. The added material should integrate naturally, not feel bolted on, and the result must read like an idiomatic single sentence in the target language. This is one extra construction, not a rewrite."
            switch self {
            case .absolutePhrase:
                return "\(base) ONE small absolute phrase — a noun plus a participle (or similar non-finite form) that modifies the whole sentence rather than a single word (English example pattern: 'his arms folded, …'). Use the target language's natural equivalent of this construction. \(close)"
            case .adverbialClause:
                return "\(base) ONE small adverbial subordinate clause expressing time, reason, manner, or condition (English example pattern: 'when the rain stopped', 'because of the noise'). Use the target language's natural subordinator. \(close)"
            case .appositivePhrase:
                return "\(base) ONE small appositive phrase — a noun or noun phrase that renames or further identifies a noun already present in the sentence, set off by the target language's natural punctuation for appositives. \(close)"
            case .conditionalClause:
                return "\(base) ONE small conditional subordinate clause expressing a condition on the main action (English example pattern: 'if she arrives early'). Use the target language's natural conditional subordinator and verb mood. \(close)"
            case .gerundPhrase:
                return "\(base) ONE small gerund phrase — a noun-functioning verbal phrase (English example pattern: 'reading the report'). Use the target language's natural equivalent (gerundio, verbal noun, -ing form, etc.). \(close)"
            case .infinitivePhrase:
                return "\(base) ONE small infinitive phrase — a 'to + verb' construction acting as noun, adjective, or adverb (English example pattern: 'to finish the report'). Use the target language's natural infinitive form. \(close)"
            case .interrogativeClause:
                return "\(base) ONE small embedded interrogative clause — an indirect question (English example pattern: 'whether she had arrived', 'why he chose that'). Use the target language's natural construction for indirect questions. \(close)"
            case .participlePhrase:
                return "\(base) ONE small participle phrase — a participle plus its modifiers, attached to a noun in the sentence (English example pattern: 'standing alone on the hill'). Use the target language's natural participle form. \(close)"
            case .subjunctiveClause:
                return "\(base) ONE small subordinate clause whose verb is in the subjunctive mood — used for wishes, hypothetical situations, or polite suggestions. Use the target language's natural subjunctive construction. \(close)"
            }
        }
    }

    // Tone / register shifts the user can request inside Sentence
    // Studio. Each case maps to a brief stylistic description Claude
    // uses to re-cast the sentence — same idea, different voice. The
    // prompts intentionally describe the register linguistically so a
    // Japanese "Polite" rewrite reaches for keigo, a Spanish "Formal"
    // rewrite reaches for `usted`, etc., rather than translating an
    // English convention into the target language.
    enum ToneKind: CaseIterable, Identifiable, Hashable {
        case academic
        case casual
        case confident
        case formal
        case friendly
        case humorous
        case neutral
        case persuasive
        case polite

        public var id: String { displayName }

        public var displayName: String {
            switch self {
            case .academic:   return "Academic"
            case .casual:     return "Casual"
            case .confident:  return "Confident"
            case .formal:     return "Formal"
            case .friendly:   return "Friendly"
            case .humorous:   return "Humorous"
            case .neutral:    return "Neutral"
            case .persuasive: return "Persuasive"
            case .polite:     return "Polite"
            }
        }

        fileprivate var promptInstruction: String {
            let close = "Keep the same core meaning, approximate length, and topical vocabulary. Use the target language's natural conventions for this register — honorifics, pronoun choice, verb forms, hedging — rather than transliterating an English convention. The result must read like a single idiomatic sentence in this tone."
            switch self {
            case .academic:
                return "Rewrite the sentence in an ACADEMIC register — measured, precise, scholarly word choice, slightly more nominalized syntax where natural. \(close)"
            case .casual:
                return "Rewrite the sentence in a CASUAL, conversational register — relaxed word choice, contractions or colloquial forms where the target language uses them, the way a friend would say it. \(close)"
            case .confident:
                return "Rewrite the sentence in a CONFIDENT, assertive register — declarative, direct, no hedging, no qualifiers softening the claim. \(close)"
            case .formal:
                return "Rewrite the sentence in a FORMAL register — polished, professional, polite where applicable. Use the target language's formal pronouns / verb forms (e.g., usted, vous, keigo, 您) and avoid contractions and colloquialisms. \(close)"
            case .friendly:
                return "Rewrite the sentence in a FRIENDLY, warm register — approachable, lightly conversational, with small softeners that signal warmth in the target language. \(close)"
            case .humorous:
                return "Rewrite the sentence in a HUMOROUS register — playful, witty, with a light comedic touch (irony, understatement, or affectionate exaggeration) that still feels natural in the target language. \(close)"
            case .neutral:
                return "Rewrite the sentence in a NEUTRAL register — plain, unmarked, no strong stylistic colouring in either direction. Strip out any flourishes or markedly formal/informal cues. \(close)"
            case .persuasive:
                return "Rewrite the sentence in a PERSUASIVE register — compelling, rhetorically engaged, designed to convince the reader. Lean on the target language's natural devices for emphasis (modal particles, framing constructions, etc.). \(close)"
            case .polite:
                return "Rewrite the sentence in a POLITE register — courteous, considerate, with the target language's natural softeners and honorifics (e.g., Japanese 〜ます／ですform, Korean 요/세요, Spanish por favor / usted). \(close)"
            }
        }
    }

    // Tense / aspect targets for Sentence Studio's Change Tense menu.
    // 12 cases laid out as a time (Present / Past / Future) × aspect
    // (Simple / Continuous / Perfect / Perfect Continuous) matrix —
    // standard English grammar terminology that Claude can map to any
    // target language's natural equivalent. Not every target language
    // has all 12 morphological forms (Mandarin has aspect markers but
    // no tense morphology, Japanese has past / non-past, etc.); the
    // prompts explicitly tell Claude to use the closest semantic
    // equivalent — auxiliary verbs, aspect markers, time adverbials —
    // when a 1:1 form doesn't exist.
    enum TenseKind: CaseIterable, Identifiable, Hashable {
        case presentSimple, presentContinuous, presentPerfect, presentPerfectContinuous
        case pastSimple, pastContinuous, pastPerfect, pastPerfectContinuous
        case futureSimple, futureContinuous, futurePerfect, futurePerfectContinuous

        public var id: String { displayName }

        // Time bucket — drives the section header in the picker sheet.
        public var categoryName: String {
            switch self {
            case .presentSimple, .presentContinuous,
                 .presentPerfect, .presentPerfectContinuous:
                return "Present"
            case .pastSimple, .pastContinuous,
                 .pastPerfect, .pastPerfectContinuous:
                return "Past"
            case .futureSimple, .futureContinuous,
                 .futurePerfect, .futurePerfectContinuous:
                return "Future"
            }
        }

        // Aspect bucket — drives the chip label inside each section.
        public var aspectName: String {
            switch self {
            case .presentSimple, .pastSimple, .futureSimple:
                return "Simple"
            case .presentContinuous, .pastContinuous, .futureContinuous:
                return "Continuous"
            case .presentPerfect, .pastPerfect, .futurePerfect:
                return "Perfect"
            case .presentPerfectContinuous,
                 .pastPerfectContinuous,
                 .futurePerfectContinuous:
                return "Perfect Continuous"
            }
        }

        public var displayName: String { "\(categoryName) \(aspectName)" }

        fileprivate var promptInstruction: String {
            let close = "Use the target language's natural construction for this tense / aspect. If the language doesn't morphologically distinguish all of these combinations, reach for the closest semantic equivalent — auxiliary verbs, aspect markers, time adverbials, periphrastic constructions. Keep the same core meaning, subject, and topical vocabulary; only the time and aspect of the action change. The result must read idiomatically in the target language."
            switch self {
            case .presentSimple:
                return "Recast the sentence in the PRESENT SIMPLE — habitual actions, general truths, or current states (English example: 'she walks to work'). \(close)"
            case .presentContinuous:
                return "Recast the sentence in the PRESENT CONTINUOUS / progressive — an action happening right now, in progress at this moment (English example: 'she is walking to work'). \(close)"
            case .presentPerfect:
                return "Recast the sentence in the PRESENT PERFECT — a completed action with current relevance, or an experience up to now (English example: 'she has walked to work'). \(close)"
            case .presentPerfectContinuous:
                return "Recast the sentence in the PRESENT PERFECT CONTINUOUS — an action that started in the past and is still ongoing, emphasizing its duration (English example: 'she has been walking to work'). \(close)"
            case .pastSimple:
                return "Recast the sentence in the PAST SIMPLE — a completed action at a definite point in the past (English example: 'she walked to work'). \(close)"
            case .pastContinuous:
                return "Recast the sentence in the PAST CONTINUOUS / progressive — an action that was in progress at a specific moment in the past (English example: 'she was walking to work'). \(close)"
            case .pastPerfect:
                return "Recast the sentence in the PAST PERFECT — an action completed before another past action or reference point (English example: 'she had walked to work'). \(close)"
            case .pastPerfectContinuous:
                return "Recast the sentence in the PAST PERFECT CONTINUOUS — an action that had been ongoing up to a specific moment in the past, emphasizing its duration (English example: 'she had been walking to work'). \(close)"
            case .futureSimple:
                return "Recast the sentence in the FUTURE SIMPLE — an action that will happen at some point in the future (English example: 'she will walk to work'). \(close)"
            case .futureContinuous:
                return "Recast the sentence in the FUTURE CONTINUOUS / progressive — an action that will be in progress at a specific moment in the future (English example: 'she will be walking to work'). \(close)"
            case .futurePerfect:
                return "Recast the sentence in the FUTURE PERFECT — an action that will have been completed by a specific moment in the future (English example: 'she will have walked to work'). \(close)"
            case .futurePerfectContinuous:
                return "Recast the sentence in the FUTURE PERFECT CONTINUOUS — an action that will have been ongoing up to a specific moment in the future, emphasizing its duration (English example: 'she will have been walking to work'). \(close)"
            }
        }
    }

    struct TransformedSentence {
        let foreign: String
        let english: String
    }

    static func transformSentence(
        _ sentence: String,
        transformation: SentenceTransformation,
        language: String,
        dialect: String
    ) async throws -> TransformedSentence {
        let prompt = """
        Rewrite a sentence for a language-learning app.

        Target language: \(dialect) \(language)
        Source sentence: \(sentence)

        Task: \(transformation.instruction)

        Submit the rewrite by calling `submit_transformed_sentence`.
        """
        struct Decoded: Codable {
            let foreign: String
            let english: String
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "foreign": .schemaString("The rewritten sentence in \(dialect) \(language) using its native script."),
                "english": .schemaString("Natural English translation of THAT exact rewritten sentence.")
            ],
            required: ["foreign", "english"]
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_transformed_sentence",
            toolDescription: "Submit the rewritten sentence and its English translation.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-haiku-4-5-20251001",
            maxTokens: 400,
            as: Decoded.self
        )
        return TransformedSentence(
            foreign: decoded.foreign.trimmingCharacters(in: .whitespacesAndNewlines),
            english: decoded.english.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // Lightweight Haiku translation. Used by the flashcard language-picker
    // strip — swipes never persist anything, so a fresh string-only response
    // (no JSON) keeps the call cheap and fast.
    static func translate(_ english: String, to language: String) async throws -> String {
        let prompt = """
        Translate the following into \(language). Return ONLY the translated word or phrase in \(language)'s native script. No quotes, no explanation, no preamble.

        English: \(english)
        """
        let reply = try await AnthropicClient.sendMessage(
            [AnthropicMessage(role: "user", content: prompt)],
            model: "claude-haiku-4-5-20251001",
            maxTokens: 128
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Large-body extraction. Takes raw text (from a paste or a PDF
    // extracted via PDFKit), decides whether it's English or the
    // user's target foreign language, and returns up to `maxWords`
    // study-worthy items already oriented for deck-save (foreign as
    // `word`, English as `translation`). Calibrated to the deck's
    // proficiency level so a beginner doesn't get C2 vocabulary.
    //
    // Cost model: input is capped at `maxInputChars` upstream (default
    // 20K chars ≈ 5K tokens), output for ~75 items ≈ 5K tokens —
    // about $0.030 per run on Haiku 4.5.
    struct ExtractedBody {
        let direction: TranslationDirection  // .toEnglish means the source was already foreign
        let items: [GeneratedItem]
        // Language the items are actually saved under. For
        // English-source the items are translated into
        // `requestedForeignLanguage`. For foreign-source the items
        // are kept in whatever language Claude detected — which may
        // not match `requestedForeignLanguage` at all (the user's
        // selection is intentionally ignored on the foreign-source
        // path).
        let resolvedLanguage: String
        // Same idea for dialect — only meaningful when the source
        // was English and the user's chosen dialect drove the
        // translation. Falls back to "Standard" for foreign-source.
        let resolvedDialect: String
    }

    static func extractStudyWords(
        from text: String,
        foreignLanguage: String,
        dialect: String,
        level: String,
        maxWords: Int = 75
    ) async throws -> ExtractedBody {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "DeckGenerator", code: 40,
                userInfo: [NSLocalizedDescriptionKey: "No text to read."]
            )
        }

        let prompt = """
        Read a body of text and pick out the most useful study-worthy picks for a \(level) learner. Picks can be either single words OR short multi-word phrases / collocations / idioms — treat both as equally valid. Favor phrases when the source text actually contains them as a meaningful unit (e.g. "por favor", "tomar el sol", "auf Wiedersehen", "心配しないで"); favor single words otherwise.

        FIRST, detect what language the input is actually written in (any natural language — not constrained to a preset list).

        BRANCHING:
        • If the detected language is English, translate the picks INTO \(dialect) \(foreignLanguage). The English form goes in "translation"; the \(foreignLanguage) form goes in "word". Use the dialect spelling \(dialect).
        • If the detected language is anything OTHER than English (any foreign language at all — Spanish, Mandarin, Japanese, Tagalog, whatever), keep the picks in that detected language verbatim. The detected-language form goes in "word"; the English translation goes in "translation". The user-selected target language and dialect are IGNORED on this path — only the actual detected language matters.

        Then choose up to \(maxWords) items (fewer if the text is short) — mix words and phrases freely; favor picks the learner is likely to encounter again. Skip ultra-common function words unless the level is A1.

        Input text:
        \"\"\"
        \(trimmed)
        \"\"\"

        Submit your output by calling `submit_extracted_words`.

        Content rules:
        • Both "word" and "translation" must be present for every item.
        • Difficulty must match \(level).
        • De-duplicate: do not return the same lemma twice.
        """

        struct DecodedItem: Decodable {
            let word: String
            let translation: String
            let transliteration: String?
            let partsOfSpeech: [String]?
            let context: String?
        }
        struct Decoded: Decodable {
            let detected: String
            let detectedLanguage: String?
            let items: [DecodedItem]
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "detected": .schemaEnum(
                    ["english", "foreign"],
                    description: "Whether the input text was detected as English or any other language."
                ),
                "detectedLanguage": .schemaString("Human-readable English name of the detected language (e.g. 'English', 'Spanish', 'Japanese', 'Tagalog'). Canonical, no parentheses."),
                "items": .schemaArray(items: .schemaObject(
                    properties: [
                        "word": .schemaString("Canonical form in the chosen target language using its native script; include the singular definite article for languages that use them."),
                        "translation": .schemaString("Natural English translation (lowercase singular noun, base-form verb, etc.)."),
                        "transliteration": .schemaNullableString("Latin-script romanization with diacritics for non-Latin scripts; null otherwise."),
                        "partsOfSpeech": .schemaArray(
                            items: .schemaString("Standard English grammatical category."),
                            description: "One or more grammatical categories."
                        ),
                        "context": .schemaString("The snippet from the source where this appears (≤ 60 chars), verbatim.")
                    ],
                    required: ["word", "translation"]
                ))
            ],
            required: ["detected", "items"]
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_extracted_words",
            toolDescription: "Submit study-worthy vocabulary picks extracted from the text.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-haiku-4-5-20251001",
            maxTokens: 8192,
            as: Decoded.self
        )

        let direction: TranslationDirection = decoded.detected.lowercased() == "english"
            ? .fromEnglish
            : .toEnglish

        // English source → translate to the user's selection (use it
        // for both the saved item language and the deck's dialect).
        // Foreign source → keep whatever Claude detected; the user's
        // selection is ignored per spec, and dialect defaults to
        // "Standard" since we don't try to detect dialect.
        let resolvedLanguage: String
        let resolvedDialect: String
        switch direction {
        case .fromEnglish:
            resolvedLanguage = foreignLanguage
            resolvedDialect = dialect
        case .toEnglish:
            resolvedLanguage = decoded.detectedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? foreignLanguage
            resolvedDialect = "Standard"
        }

        let items = decoded.items.map { d in
            GeneratedItem(
                word: d.word,
                translation: d.translation,
                transliteration: d.transliteration,
                language: resolvedLanguage,
                partsOfSpeech: d.partsOfSpeech
            )
        }
        return ExtractedBody(
            direction: direction,
            items: items,
            resolvedLanguage: resolvedLanguage,
            resolvedDialect: resolvedDialect
        )
    }

    // MARK: - Song / video link extraction

    // What `extractFromMediaLink` returns. The page surfaces the
    // recognized title + the full foreign transcript + its English
    // translation, then offers two independently-savable lists: `words`
    // and `sentences`. Both lists arrive pre-sorted hardest → easiest
    // so the learner front-loads the picks that need the most work.
    struct MediaLinkExtraction {
        // False when Claude couldn't confidently identify the media at
        // the URL (it can't actually open the page — see note below).
        // The page shows a "couldn't recognize this" state in that case.
        let recognized: Bool
        // Best-guess title, e.g. "Despacito — Luis Fonsi". Empty when
        // unrecognized.
        let title: String
        // Canonical English name of the language the lyrics/transcript
        // are in (e.g. "Spanish", "Korean").
        let resolvedLanguage: String
        // The full original-language text as one long block.
        let transcript: String
        // English translation of the whole transcript.
        let englishTranslation: String
        // Vocabulary picks, hardest first. Foreign form in `word`,
        // English in `translation`.
        let words: [GeneratedItem]
        // Sentence picks, hardest first. Foreign sentence in `word`,
        // English in `translation`.
        let sentences: [GeneratedItem]
    }

    // Takes a YouTube / web video / song URL and produces a study-ready
    // breakdown: the original-language transcript, an English
    // translation, plus difficulty-ranked word and sentence lists.
    //
    // IMPORTANT — how the "fetch" works: the app's Anthropic client has
    // no web-fetch capability, so we can't literally download the page
    // or pull captions. Instead we hand the URL to a strong model and
    // ask it to identify the song/video from its own knowledge and
    // reproduce the lyrics/transcript. This is reliable for well-known
    // songs and popular videos (the dominant "paste a song link" use
    // case) and degrades gracefully (`recognized == false`) when the
    // model doesn't know the content. If a real caption/transcript API
    // is added later, only this method needs to change — the page +
    // save flow stay identical.
    static func extractFromMediaLink(
        url: String,
        foreignLanguage: String,
        dialect: String,
        level: String,
        maxWords: Int = 60,
        maxSentences: Int = 25
    ) async throws -> MediaLinkExtraction {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw NSError(
                domain: "DeckGenerator", code: 41,
                userInfo: [NSLocalizedDescriptionKey: "Paste a link first."]
            )
        }

        // PREFERRED PATH: pull the real captions via the transcript
        // provider, then break THOSE down (no hallucination). `try?` so
        // any failure — unconfigured key, non-YouTube link, no captions,
        // provider/network error — silently degrades to the model-recall
        // fallback below. When the key isn't set this returns nil
        // instantly, so the fallback stays the default until you wire a
        // provider in TranscriptClient.
        if let transcript = try? await TranscriptClient.fetchTranscript(forURL: trimmedURL),
           !transcript.text.isEmpty {
            return try await breakdown(
                fromRealTranscript: transcript,
                foreignLanguage: foreignLanguage,
                level: level,
                maxWords: maxWords,
                maxSentences: maxSentences
            )
        }

        // FALLBACK PATH: no real transcript available — ask the model to
        // identify the media from the URL and reproduce it from its own
        // knowledge. Reliable for well-known songs; degrades gracefully
        // (recognized == false) when it doesn't know the content.
        let prompt = """
        A language learner pasted this media link to study the song or video's spoken/sung content:

        \(trimmedURL)

        Using your own knowledge, identify what song or video this URL points to (match on the video ID, slug, title, artist, or any recognizable signal in the URL). Then reproduce its content for study.

        If you can confidently identify it:
        • Set "recognized" to true.
        • "title" — a clean title WRITTEN IN ENGLISH (English translation of the song/video name, or a 3–6 word English summary). Never output a title in a non-Latin script or foreign language; translate or transliterate proper names into English.
        • "detectedLanguage" — canonical English name of the language the lyrics/transcript are in (e.g. "Spanish", "Korean", "French"). If the content is multilingual, pick the dominant non-English language.
        • "transcript" — the FULL original-language lyrics or spoken transcript as one long block, with natural line breaks. Do not summarize; reproduce the actual words.
        • "translation" — a natural English translation of the entire transcript, line-aligned where practical.
        • "words" — up to \(maxWords) study-worthy vocabulary picks drawn from the transcript (single words OR short idiomatic phrases). For each: "word" (original-language form, native script), "translation" (natural English), "transliteration" (Latin romanization for non-Latin scripts, else null), and "difficulty" (an integer 1–100 for a \(level) learner, where 100 is hardest). Skip ultra-common function words unless the level is A1.
        • "sentences" — up to \(maxSentences) complete sentences/lines pulled verbatim from the transcript. For each: "word" (the original-language sentence), "translation" (its natural English translation), "transliteration" (romanization of the whole sentence for non-Latin scripts, else null), and "difficulty" (integer 1–100 for a \(level) learner).

        Ordering: return BOTH "words" and "sentences" sorted from MOST difficult to LEAST difficult (highest "difficulty" first).

        If you genuinely cannot identify the media or don't know its content, set "recognized" to false and leave the other fields empty/blank — do NOT invent or hallucinate lyrics.

        Submit by calling `submit_media_breakdown`.
        """

        struct DecodedWord: Decodable {
            let word: String
            let translation: String
            let transliteration: String?
            let difficulty: Int?
        }
        struct DecodedSentence: Decodable {
            let word: String
            let translation: String
            let transliteration: String?
            let difficulty: Int?
        }
        struct Decoded: Decodable {
            let recognized: Bool
            let title: String?
            let detectedLanguage: String?
            let transcript: String?
            let translation: String?
            let words: [DecodedWord]?
            let sentences: [DecodedSentence]?
        }

        let schema = JSONValue.schemaObject(
            properties: [
                "recognized": .schemaBool("True only if you can confidently identify the media and reproduce its real content."),
                "title": .schemaString("Clean title written IN ENGLISH (translate/transliterate any foreign or non-Latin name). Empty when unrecognized."),
                "detectedLanguage": .schemaString("Canonical English name of the transcript's language (e.g. 'Spanish'). Empty when unrecognized."),
                "transcript": .schemaString("Full original-language lyrics/transcript as one block with line breaks. Empty when unrecognized."),
                "translation": .schemaString("Natural English translation of the whole transcript. Empty when unrecognized."),
                "words": .schemaArray(items: .schemaObject(
                    properties: [
                        "word": .schemaString("Original-language vocabulary pick in native script."),
                        "translation": .schemaString("Natural English translation."),
                        "transliteration": .schemaNullableString("Latin romanization for non-Latin scripts; null otherwise."),
                        "difficulty": .schemaInt("Integer 1–100 for the learner's level; 100 is hardest.")
                    ],
                    required: ["word", "translation"]
                ), description: "Vocabulary picks, sorted hardest first."),
                "sentences": .schemaArray(items: .schemaObject(
                    properties: [
                        "word": .schemaString("A full original-language sentence/line, verbatim from the transcript."),
                        "translation": .schemaString("Natural English translation of that sentence."),
                        "transliteration": .schemaNullableString("Romanization of the whole sentence for non-Latin scripts; null otherwise."),
                        "difficulty": .schemaInt("Integer 1–100 for the learner's level; 100 is hardest.")
                    ],
                    required: ["word", "translation"]
                ), description: "Sentence picks, sorted hardest first.")
            ],
            required: ["recognized"]
        )

        // Sonnet, not Haiku: lyric/transcript recall is exactly where the
        // bigger model's broader knowledge pays off, and the cost is
        // bounded by the maxWords/maxSentences caps.
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_media_breakdown",
            toolDescription: "Submit the identified media's transcript, translation, and difficulty-ranked word + sentence breakdowns.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-sonnet-4-6",
            maxTokens: 32000,
            as: Decoded.self
        )

        guard decoded.recognized else {
            return MediaLinkExtraction(
                recognized: false,
                title: "",
                resolvedLanguage: foreignLanguage,
                transcript: "",
                englishTranslation: "",
                words: [],
                sentences: []
            )
        }

        let resolvedLanguage = decoded.detectedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? foreignLanguage

        // Sort hardest → easiest defensively client-side so the ordering
        // holds even if the model returns them out of order. Missing
        // difficulties sink to the bottom (treated as 0).
        let words = (decoded.words ?? [])
            .sorted { ($0.difficulty ?? 0) > ($1.difficulty ?? 0) }
            .map { d in
                GeneratedItem(
                    word: d.word,
                    translation: d.translation,
                    transliteration: d.transliteration,
                    language: resolvedLanguage
                )
            }
        let sentences = (decoded.sentences ?? [])
            .sorted { ($0.difficulty ?? 0) > ($1.difficulty ?? 0) }
            .map { d in
                GeneratedItem(
                    word: d.word,
                    translation: d.translation,
                    transliteration: d.transliteration,
                    language: resolvedLanguage
                )
            }

        return MediaLinkExtraction(
            recognized: true,
            title: decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            resolvedLanguage: resolvedLanguage,
            transcript: decoded.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            englishTranslation: decoded.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            words: words,
            sentences: sentences
        )
    }

    // Real-transcript path for extractFromMediaLink: we already have the
    // verbatim captions, so the model only translates + ranks (it never
    // invents content). Returns the same MediaLinkExtraction shape so
    // the page + save flow don't care which path produced it.
    private static func breakdown(
        fromRealTranscript transcript: TranscriptClient.TranscriptResult,
        foreignLanguage: String,
        level: String,
        maxWords: Int,
        maxSentences: Int
    ) async throws -> MediaLinkExtraction {
        // Two independent passes, run concurrently:
        //   1. Study breakdown (title + detected language + words +
        //      sentences) off a CAPPED transcript, so the lists are never
        //      starved of output budget.
        //   2. A FULL English translation of the ENTIRE transcript,
        //      chunked so length is never a limit — this is the
        //      complete native-language rendering the page shows beside
        //      the original. Long transcripts make this the slow part
        //      (hence the up-to-two-minutes warning in the UI).
        let cappedTranscript = String(transcript.text.prefix(maxTranscriptChars))

        async let breakdownResult = mediaStudyBreakdown(
            transcript: cappedTranscript,
            providerLanguage: transcript.detectedLanguage,
            level: level,
            maxWords: maxWords,
            maxSentences: maxSentences
        )
        async let fullTranslation = translateTranscript(transcript.text)

        let decoded = try await breakdownResult
        // Translation failure is non-fatal — we still return the
        // breakdown; the page just shows an empty translation block.
        let translation = (try? await fullTranslation) ?? ""

        // Prefer Claude's canonical language name; fall back to the
        // provider's tag, then the user's selection.
        let resolvedLanguage = decoded.detectedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? transcript.detectedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? foreignLanguage

        var words = mapBreakdownItems(decoded.words, language: resolvedLanguage)
        var sentences = mapBreakdownItems(decoded.sentences, language: resolvedLanguage)

        // Salvage retry: if the breakdown pass somehow returned both lists
        // empty, make ONE focused call for words + sentences only.
        if words.isEmpty && sentences.isEmpty {
            let salvage = try? await extractWordsAndSentencesOnly(
                transcript: cappedTranscript,
                resolvedLanguage: resolvedLanguage,
                level: level,
                maxWords: maxWords,
                maxSentences: maxSentences
            )
            if let salvage {
                words = salvage.words
                sentences = salvage.sentences
            }
        }

        // Title must be English: prefer Claude's English title; only fall
        // back to the provider title if Claude's is empty.
        let title = decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? transcript.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""

        return MediaLinkExtraction(
            recognized: true,
            title: title,
            resolvedLanguage: resolvedLanguage,
            transcript: transcript.text,
            englishTranslation: translation,
            words: words,
            sentences: sentences
        )
    }

    // Decoded shape of the study-breakdown call (no translation — that's
    // a separate full-length pass now).
    private struct MediaStudyBreakdown {
        let title: String?
        let detectedLanguage: String?
        let words: [DecodedBreakdownItem]?
        let sentences: [DecodedBreakdownItem]?
    }

    // The bounded study-breakdown pass: title, detected language, and the
    // difficulty-ranked word + sentence lists. Runs off a capped
    // transcript so the lists always fit the output budget.
    private static func mediaStudyBreakdown(
        transcript cappedTranscript: String,
        providerLanguage: String?,
        level: String,
        maxWords: Int,
        maxSentences: Int
    ) async throws -> MediaStudyBreakdown {
        let prompt = """
        Below is the REAL transcript/captions of a video the learner wants to study. It may be auto-generated (missing punctuation, ASR errors) — infer the intended words, but do NOT add content that isn't there.

        \(providerLanguage.map { "Provider-detected caption language: \($0)\n" } ?? "")
        Transcript:
        \"\"\"
        \(cappedTranscript)
        \"\"\"

        Produce a study breakdown by calling `submit_media_breakdown`. "words" and "sentences" must NEVER be empty when the transcript has content.

        • "title" — a short, clean title for this content, WRITTEN IN ENGLISH. Use the English translation of the song/video name, or a 3–6 word English summary of the topic. NEVER output a title in a non-Latin script or a foreign language; translate or transliterate proper names into English.
        • "detectedLanguage" — canonical English name of the transcript's language (e.g. "Spanish", "Korean"). If multilingual, the dominant non-English language.
        • "words" — \(maxWords) study-worthy vocabulary picks (single words OR short idiomatic phrases) drawn from the transcript (fewer ONLY if it's too short to yield that many). Each: "word" (original-language form, native script), "translation" (natural English), "transliteration" (Latin romanization for non-Latin scripts, else null), "difficulty" (integer 1–100 for a \(level) learner; 100 hardest). Skip ultra-common function words unless the level is A1.
        • "sentences" — up to \(maxSentences) complete sentences/lines pulled verbatim from the transcript (at least a few even for short/repetitive content). Each: "word" (the original-language sentence), "translation" (its English), "transliteration" (romanization for non-Latin scripts, else null), "difficulty" (integer 1–100).

        Return BOTH "words" and "sentences" sorted MOST → LEAST difficult.
        """

        struct Decoded: Decodable {
            let title: String?
            let detectedLanguage: String?
            let words: [DecodedBreakdownItem]?
            let sentences: [DecodedBreakdownItem]?
        }

        let schema = JSONValue.schemaObject(
            properties: [
                "title": .schemaString("Short clean title for the content, written IN ENGLISH (translate/transliterate any foreign or non-Latin name)."),
                "detectedLanguage": .schemaString("Canonical English name of the transcript's language (e.g. 'Spanish')."),
                "words": breakdownItemArraySchema(noun: "Vocabulary picks, sorted hardest first."),
                "sentences": breakdownItemArraySchema(noun: "Sentence picks, sorted hardest first.")
            ],
            required: ["words", "sentences"]
        )

        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_media_breakdown",
            toolDescription: "Submit the title, detected language, and difficulty-ranked word + sentence breakdowns of the transcript.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-sonnet-4-6",
            maxTokens: 16000,
            as: Decoded.self
        )
        return MediaStudyBreakdown(
            title: decoded.title,
            detectedLanguage: decoded.detectedLanguage,
            words: decoded.words,
            sentences: decoded.sentences
        )
    }

    // Full English translation of an ENTIRE transcript. Splits long
    // transcripts into line-aligned chunks and translates each so length
    // is never a limit — every line of the original gets a native-language
    // rendering. Chunks run sequentially; the caller runs this
    // concurrently with the study breakdown.
    private static func translateTranscript(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let chunks = chunkedByLines(trimmed, maxChars: 5_000)
        var pieces: [String] = []
        pieces.reserveCapacity(chunks.count)

        for chunk in chunks {
            let prompt = """
            Translate the following text into natural, fluent English. Output ONLY the English translation — no notes, no commentary, and do NOT include the original text. Preserve line breaks and the order of lines so the translation lines up with the source.

            Text:
            \"\"\"
            \(chunk)
            \"\"\"

            Call `submit_translation`.
            """
            struct Decoded: Decodable { let translation: String? }
            let schema = JSONValue.schemaObject(
                properties: [
                    "translation": .schemaString("The full English translation, line breaks preserved.")
                ],
                required: ["translation"]
            )
            let decoded: Decoded = try await AnthropicClient.sendStructured(
                toolName: "submit_translation",
                toolDescription: "Submit the English translation of the provided text.",
                schema: schema,
                userPrompt: prompt,
                system: audiencePolicy,
                model: "claude-sonnet-4-6",
                maxTokens: 16000,
                as: Decoded.self
            )
            pieces.append(decoded.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Splits text into <= maxChars chunks on line boundaries (hard-
    // splitting any single line longer than the cap) so translation
    // covers the whole transcript without exceeding a call's budget.
    private static func chunkedByLines(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.count > maxChars {
                if !current.isEmpty { chunks.append(current); current = "" }
                var idx = line.startIndex
                while idx < line.endIndex {
                    let end = line.index(idx, offsetBy: maxChars, limitedBy: line.endIndex) ?? line.endIndex
                    chunks.append(String(line[idx..<end]))
                    idx = end
                }
                continue
            }
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // Max characters of transcript handed to the breakdown model. Keeps
    // the word/sentence extraction bounded. The translation pass + the
    // page display both use the FULL transcript.
    private static let maxTranscriptChars = 8_000

    // Shared decode shape for a single word/sentence pick.
    private struct DecodedBreakdownItem: Decodable {
        let word: String
        let translation: String
        let transliteration: String?
        let difficulty: Int?
    }

    // Shared schema for a word/sentence array — keeps the two breakdown
    // call sites (primary + salvage) in lockstep.
    private static func breakdownItemArraySchema(noun: String) -> JSONValue {
        .schemaArray(items: .schemaObject(
            properties: [
                "word": .schemaString("Original-language text in native script (a vocab pick, or a full sentence/line verbatim from the transcript)."),
                "translation": .schemaString("Natural English translation."),
                "transliteration": .schemaNullableString("Latin romanization for non-Latin scripts; null otherwise."),
                "difficulty": .schemaInt("Integer 1–100 for the learner's level; 100 is hardest.")
            ],
            required: ["word", "translation"]
        ), description: noun)
    }

    // Sorts hardest → easiest (missing difficulty sinks to the bottom)
    // and maps to GeneratedItems stamped with the resolved language.
    private static func mapBreakdownItems(
        _ items: [DecodedBreakdownItem]?,
        language: String
    ) -> [GeneratedItem] {
        (items ?? [])
            .sorted { ($0.difficulty ?? 0) > ($1.difficulty ?? 0) }
            .map { d in
                GeneratedItem(
                    word: d.word,
                    translation: d.translation,
                    transliteration: d.transliteration,
                    language: language
                )
            }
    }

    // Focused fallback used when the combined breakdown returns no cards:
    // asks for ONLY the word + sentence lists so nothing competes with a
    // translation for the output budget.
    private static func extractWordsAndSentencesOnly(
        transcript cappedText: String,
        resolvedLanguage: String,
        level: String,
        maxWords: Int,
        maxSentences: Int
    ) async throws -> (words: [GeneratedItem], sentences: [GeneratedItem]) {
        let prompt = """
        From the \(resolvedLanguage) transcript below, extract study material for a \(level) learner. Output ONLY the two lists — no translation, no commentary.

        Transcript:
        \"\"\"
        \(cappedText)
        \"\"\"

        • "words" — \(maxWords) study-worthy vocabulary picks (single words OR short idiomatic phrases). Fewer only if the transcript truly can't yield that many distinct picks. Each: "word" (native script), "translation" (English), "transliteration" (romanization for non-Latin scripts, else null), "difficulty" (1–100, 100 hardest).
        • "sentences" — up to \(maxSentences) complete sentences/lines pulled verbatim from the transcript (at least a few even if repetitive). Each: "word" (the sentence), "translation" (English), "transliteration" (null for Latin scripts), "difficulty" (1–100).

        Both lists must be non-empty. Sort each MOST → LEAST difficult. Call `submit_breakdown`.
        """

        struct Decoded: Decodable {
            let words: [DecodedBreakdownItem]?
            let sentences: [DecodedBreakdownItem]?
        }

        let schema = JSONValue.schemaObject(
            properties: [
                "words": breakdownItemArraySchema(noun: "Vocabulary picks, hardest first."),
                "sentences": breakdownItemArraySchema(noun: "Sentence picks, hardest first.")
            ],
            required: ["words", "sentences"]
        )

        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_breakdown",
            toolDescription: "Submit difficulty-ranked word + sentence lists extracted from the transcript.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-sonnet-4-6",
            maxTokens: 16000,
            as: Decoded.self
        )
        return (
            mapBreakdownItems(decoded.words, language: resolvedLanguage),
            mapBreakdownItems(decoded.sentences, language: resolvedLanguage)
        )
    }

    // MARK: - Conversation analysis (Direct page → Conversation mode)

    struct ConversationAnalysis {
        // Language the study items are saved under (detected language for
        // foreign-source audio; the user's target for English-source).
        let resolvedLanguage: String
        let resolvedDialect: String
        // Natural English translation of the whole conversation.
        let translation: String
        // Study-worthy words/phrases, hardest first.
        let items: [GeneratedItem]
    }

    // Takes a speech-to-text transcript of a recorded conversation and
    // returns an English translation plus difficulty-ranked study picks.
    // Branches on detected language like `extractStudyWords`: foreign
    // audio keeps its language; English audio has its picks translated
    // into the user's selected target so the saved deck still teaches the
    // foreign language.
    static func analyzeConversation(
        transcript: String,
        foreignLanguage: String,
        dialect: String,
        level: String,
        maxItems: Int = 40
    ) async throws -> ConversationAnalysis {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "DeckGenerator", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Nothing was transcribed from the recording."]
            )
        }
        let capped = String(trimmed.prefix(maxTranscriptChars))

        let prompt = """
        Below is a speech-to-text transcript of a recorded real-world conversation (possibly two or more speakers). It may contain ASR errors, run-ons, or missing punctuation — infer the intended words and clean it up, but do NOT invent content that isn't implied by the transcript.

        Transcript:
        \"\"\"
        \(capped)
        \"\"\"

        FIRST detect the language the conversation is actually in.

        BRANCHING:
        • If the conversation is in English → set "detected" to "english". Translate the study picks INTO \(dialect) \(foreignLanguage): the \(foreignLanguage) form goes in "word", the English in "translation". "translation" (the whole-conversation field) just restates the English.
        • If the conversation is in any other language → set "detected" to "foreign". Keep the picks in that detected language ("word" = detected-language form, "translation" = English). "translation" is a natural English translation of the whole conversation.

        Call `submit_conversation`:
        • "detected" — "english" or "foreign".
        • "detectedLanguage" — canonical English name of the conversation's language (e.g. "Spanish"); for the English branch use "\(foreignLanguage)".
        • "translation" — English translation (or restatement) of the whole conversation.
        • "items" — \(maxItems) study-worthy words/phrases (fewer only if the conversation is too short), sorted MOST → LEAST difficult for a \(level) learner. Each: "word", "translation", "transliteration" (romanization for non-Latin scripts, else null), "difficulty" (1–100).
        """

        struct Decoded: Decodable {
            let detected: String?
            let detectedLanguage: String?
            let translation: String?
            let items: [DecodedBreakdownItem]?
        }

        let schema = JSONValue.schemaObject(
            properties: [
                "detected": .schemaEnum(["english", "foreign"], description: "Whether the conversation was detected as English or another language."),
                "detectedLanguage": .schemaString("Canonical English name of the conversation's language (e.g. 'Spanish')."),
                "translation": .schemaString("Natural English translation (or restatement) of the whole conversation."),
                "items": breakdownItemArraySchema(noun: "Study-worthy words/phrases, hardest first.")
            ],
            required: ["translation", "items"]
        )

        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_conversation",
            toolDescription: "Submit the conversation's English translation and difficulty-ranked study picks.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-sonnet-4-6",
            maxTokens: 16000,
            as: Decoded.self
        )

        let isEnglishSource = (decoded.detected ?? "foreign").lowercased() == "english"
        let resolvedLanguage: String
        let resolvedDialect: String
        if isEnglishSource {
            resolvedLanguage = foreignLanguage
            resolvedDialect = dialect
        } else {
            resolvedLanguage = decoded.detectedLanguage?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? foreignLanguage
            resolvedDialect = "Standard"
        }

        return ConversationAnalysis(
            resolvedLanguage: resolvedLanguage,
            resolvedDialect: resolvedDialect,
            translation: decoded.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            items: mapBreakdownItems(decoded.items, language: resolvedLanguage)
        )
    }

    // Direction-aware translation for the Direct page. Single Haiku
    // call that detects whether the input is English or the user's
    // foreign target language and translates the other way. Returns a
    // GeneratedItem with the foreign form as `word`, English as
    // `translation`, plus optional transliteration — same shape as
    // every other deck save path.
    enum TranslationDirection: String { case fromEnglish, toEnglish }
    struct DirectTranslateResult {
        let item: GeneratedItem
        let direction: TranslationDirection
    }

    static func directTranslate(
        text: String,
        foreignLanguage: String,
        dialect: String
    ) async throws -> DirectTranslateResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "DeckGenerator", code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Nothing to translate."]
            )
        }

        let prompt = """
        Translate between English and \(dialect) \(foreignLanguage) for a vocabulary app.

        The user's input is below between triple-pipes. First decide which language it's in (English vs. \(foreignLanguage)), then produce both forms.

        Input: |||\(trimmed)|||

        Submit your translation by calling `submit_direct_translation`.

        Content rules:
        • Preserve the user's original wording verbatim in the matching field — don't paraphrase the source side.
        • Keep both sides idiomatic and natural.
        """

        struct Decoded: Decodable {
            let detected: String
            let english: String
            let foreign: String
            let transliteration: String?
            let partsOfSpeech: [String]?
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "detected": .schemaEnum(
                    ["english", "foreign"],
                    description: "Which language the input was detected as."
                ),
                "english": .schemaString("Natural English form (the original if input was English, or a faithful translation if input was \(foreignLanguage))."),
                "foreign": .schemaString("Natural \(dialect) \(foreignLanguage) form using its native script; include the definite article for languages that use them when translating a single noun."),
                "transliteration": .schemaNullableString("Latin-script romanization with diacritics for non-Latin scripts; null otherwise."),
                "partsOfSpeech": .schemaArray(
                    items: .schemaString("Standard English grammatical category."),
                    description: "One or more of: Noun, Verb, Adjective, Adverb, Phrase, Sentence, Interjection."
                )
            ],
            required: ["detected", "english", "foreign"]
        )
        let decoded: Decoded = try await AnthropicClient.sendStructured(
            toolName: "submit_direct_translation",
            toolDescription: "Submit a bi-directional translation result.",
            schema: schema,
            userPrompt: prompt,
            system: audiencePolicy,
            model: "claude-haiku-4-5-20251001",
            maxTokens: 1024,
            as: Decoded.self
        )

        let item = GeneratedItem(
            word: decoded.foreign,
            translation: decoded.english,
            transliteration: decoded.transliteration,
            language: foreignLanguage,
            partsOfSpeech: decoded.partsOfSpeech
        )
        let direction: TranslationDirection = decoded.detected.lowercased() == "english"
            ? .fromEnglish
            : .toEnglish
        return DirectTranslateResult(item: item, direction: direction)
    }

    // Camera object identification + translation, single Haiku 4.5
    // vision call. Returns a GeneratedItem that can be dropped
    // straight into a deck (via DeckPickerSheet or saved as the seed
    // of a brand-new deck).
    struct IdentifyObjectResult {
        let item: GeneratedItem
        let englishLabel: String  // verbatim for the in-app "we saw X" line
    }

    static func identifyObject(
        imageData: Data,
        language: String,
        dialect: String
    ) async throws -> IdentifyObjectResult {
        let prompt = """
        Look at the attached photo and identify the SINGLE most prominent object.

        Submit your identification by calling `submit_identified_object`.

        Content rules:
        • "english" must be lowercase and singular.
        • "word" must be linguistically authentic in \(dialect) \(language).
        • For languages with definite articles (Spanish, French, Italian, German, Portuguese, Greek, etc.) include the singular definite article on "word" so the learner sees grammatical gender.
        • If the image is too blurry or ambiguous to identify a single dominant object, return the best honest guess anyway.
        """

        struct Decoded: Decodable {
            let english: String
            let word: String
            let transliteration: String?
            let partsOfSpeech: [String]?
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "english": .schemaString("The object's name in English (lowercase singular noun)."),
                "word": .schemaString("Same noun written in \(language) (\(dialect)) using its native script; include the definite article for languages that use them."),
                "transliteration": .schemaNullableString("Latin-script romanization with diacritics for non-Latin scripts; null for Latin-script languages."),
                "partsOfSpeech": .schemaArray(
                    items: .schemaString("Standard English grammatical category."),
                    description: "Usually [\"Noun\"]."
                )
            ],
            required: ["english", "word"]
        )
        let base64 = imageData.base64EncodedString()
        let decoded: Decoded = try await AnthropicClient.sendStructuredVision(
            toolName: "submit_identified_object",
            toolDescription: "Submit the identified object's English name and target-language translation.",
            schema: schema,
            imageBase64: base64,
            userPrompt: prompt,
            as: Decoded.self
        )

        let item = GeneratedItem(
            word: decoded.word,
            translation: decoded.english,
            transliteration: decoded.transliteration,
            language: language,
            partsOfSpeech: decoded.partsOfSpeech ?? ["Noun"]
        )
        return IdentifyObjectResult(item: item, englishLabel: decoded.english)
    }

    static func extractJSON(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let fenceRange = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<fenceRange.lowerBound])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
