import Foundation
import FirebaseAuth
import FirebaseFirestore

// Builds, caches and persists the per-language LearnerModel doc.
//
// The model is pure derivation over data the app already stores —
// decks + FSRS schedules, study sessions, conversation corrections,
// pronunciation attempts, XP state, onboarding answers — so a rebuild
// is mostly arithmetic plus the Firestore reads the Study tab already
// performs on load. We rebuild when the stored doc is missing or older
// than `staleness`, and callers can force a rebuild after events that
// obviously move it (finished study session, placement).
enum LearnerModelService {
    private static let db = Firestore.firestore()
    /// Rebuild cadence. The doc is cheap to rebuild but there's no need
    /// to do it more than ~daily for planning purposes.
    static let staleness: TimeInterval = 24 * 60 * 60

    /// Stability threshold (days) above which a card counts as "mature" —
    /// i.e. genuinely known for curriculum-gating purposes. Mirrors the
    /// common Anki convention of a 21-day interval.
    static let matureStabilityDays: Double = 21

    private static func collection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("learnerModels")
    }

    // MARK: - Load / persist

    static func fetch(languageID: String) async throws -> LearnerModel? {
        let snapshot = try await collection().document(languageID).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: LearnerModel.self)
    }

    static func save(_ model: LearnerModel) async throws {
        try await collection().document(model.languageID).setData(from: model)
    }

    /// Returns a fresh-enough model, rebuilding + persisting if the
    /// stored one is missing or stale. The level estimate and any
    /// placement/calibration state carry over from the stored doc —
    /// rebuilds refresh the *derived* sections without clobbering them.
    static func loadOrRebuild(
        language: String,
        dialect: String,
        fallbackLevel: String
    ) async throws -> LearnerModel {
        let languageID = Conversation.languageID(for: language)
        let existing = try? await fetch(languageID: languageID)
        if let existing, Date().timeIntervalSince(existing.updatedAt) < staleness {
            return existing
        }
        let rebuilt = try await build(
            language: language,
            dialect: dialect,
            fallbackLevel: fallbackLevel,
            carryOver: existing
        )
        try? await save(rebuilt)
        return rebuilt
    }

    // MARK: - Build

    static func build(
        language: String,
        dialect: String,
        fallbackLevel: String,
        carryOver: LearnerModel? = nil
    ) async throws -> LearnerModel {
        let languageID = Conversation.languageID(for: language)

        // Fire the independent reads concurrently; each is individually
        // optional so one failing source degrades that section instead
        // of the whole build.
        async let decksTask: [DeckDocument]? = try? await FirebaseDeckService.fetchDecks()
        async let schedulesTask: [String: CardSchedule]? = try? await FirebaseDeckService.fetchAllSchedules()
        async let sessionsTask: [StudySession]? = try? await FirebaseDeckService.fetchStudySessions()
        async let conversationsTask: [Conversation]? = try? await FirebaseConversationService.list(
            languageID: languageID, limit: 10
        )
        async let attemptsTask: [PronunciationAttempt]? = try? await FirebasePronunciationService.recent(
            languageID: languageID, limit: 30
        )
        async let xpTask: UserXPState? = try? await XPService.fetchState()
        async let profileTask: UserProfile? = try? await UserService.fetchProfile()

        let allDecks = (await decksTask) ?? []
        let schedules = (await schedulesTask) ?? [:]
        let sessions = (await sessionsTask) ?? []
        let conversations = (await conversationsTask) ?? []
        let attempts = (await attemptsTask) ?? []
        let xp = await xpTask
        let profile = await profileTask

        let decks = allDecks.filter { $0.allLanguages.contains(language) }
        let now = Date()

        // ---- Vocab (FSRS) ----
        var vocab = LearnerModel.VocabSummary()
        var lapsing: [LearnerModel.WeakWord] = []
        for deck in decks {
            for item in deck.items {
                vocab.totalCards += 1
                guard let schedule = schedules[item.id.uuidString] else {
                    vocab.newCards += 1
                    continue
                }
                if schedule.nextReviewAt <= now { vocab.dueNow += 1 }
                let stability = schedule.stability ?? Double(schedule.intervalDays)
                if stability >= matureStabilityDays {
                    vocab.matureCards += 1
                } else {
                    vocab.youngCards += 1
                }
                if schedule.lapses >= 2 {
                    lapsing.append(LearnerModel.WeakWord(
                        word: schedule.word,
                        lapses: schedule.lapses,
                        stability: stability
                    ))
                }
            }
        }
        vocab.lapsingWords = Array(
            lapsing.sorted { $0.lapses > $1.lapses }.prefix(12)
        )
        // Topics of the most recently studied decks in this language.
        let recentDeckIds = Set(
            sessions
                .filter { $0.language == language }
                .prefix(8)
                .map { $0.deckId }
        )
        vocab.recentTopics = Array(
            Set(
                decks
                    .filter { deck in deck.id.map { recentDeckIds.contains($0) } ?? false }
                    .flatMap { $0.interests }
            ).prefix(8)
        )

        // ---- Skills ----
        var skills = LearnerModel.Skills()
        let corrections = conversations
            .flatMap { $0.messages }
            .compactMap { $0.corrections }
            .flatMap { $0 }
        skills.recurringErrors = await clusterCorrections(
            corrections, language: language
        )
        // Pronunciation: worst-performing drill targets (best score still low).
        var bestByTarget: [String: (best: Int, count: Int)] = [:]
        for attempt in attempts {
            let entry = bestByTarget[attempt.target]
            bestByTarget[attempt.target] = (
                best: max(entry?.best ?? 0, attempt.grade.overallScore),
                count: (entry?.count ?? 0) + 1
            )
        }
        skills.pronunciationTrouble = bestByTarget
            .filter { $0.value.best < 70 }
            .sorted { $0.value.best < $1.value.best }
            .prefix(5)
            .map {
                LearnerModel.PronunciationTrouble(
                    target: $0.key,
                    bestScore: $0.value.best,
                    attempts: $0.value.count
                )
            }
        // Calibration signal carries over (it's updated incrementally by
        // recordConversationSignal, not derivable from stored data alone
        // without rescanning every thread).
        skills.recentCorrectionsPerTurn = carryOver?.skills.recentCorrectionsPerTurn
        skills.recentTurnsSampled = carryOver?.skills.recentTurnsSampled

        // ---- Habits ----
        var habits = LearnerModel.Habits()
        if let xp {
            habits.totalXP = xp.total
            if xp.flashcardSessionCount > xp.audioSessionCount {
                habits.preferredMethod = "Active"
            } else if xp.audioSessionCount > xp.flashcardSessionCount {
                habits.preferredMethod = "Passive"
            } else if xp.flashcardSessionCount > 0 {
                habits.preferredMethod = "Balanced"
            }
        }
        habits.streakDays = computeStreak(sessions: sessions)
        habits.estimatedMinutesPerDay = estimateMinutesPerDay(sessions: sessions)

        // ---- Goals ----
        let onboarding = profile?.onboarding
        let goals = LearnerModel.Goals(
            motivation: onboarding?.motivationDetail,
            fluencyScene: onboarding?.fluencyScene,
            firstUnderstand: onboarding?.firstUnderstand,
            heritage: onboarding?.heritageBackground,
            destinations: (onboarding?.destinations ?? []).map { $0.name },
            interests: onboarding?.interests ?? [],
            targetDate: carryOver?.goals.targetDate
        )

        // ---- Level ----
        // Placement / calibrated estimates survive rebuilds; otherwise we
        // fall back to the onboarding-claimed level at low confidence.
        let level: LearnerModel.LevelEstimate
        if let kept = carryOver?.levelEstimate, kept.source != "onboarding" {
            level = kept
        } else {
            let claimed = onboarding?.languagePreferences?
                .first(where: { canonicalLanguageName($0.language) == language })?
                .level
            level = LearnerModel.LevelEstimate(
                value: claimed ?? fallbackLevel,
                confidence: 0.4,
                source: "onboarding",
                updatedAt: now
            )
        }

        return LearnerModel(
            language: language,
            languageID: languageID,
            dialect: dialect,
            levelEstimate: level,
            goals: goals,
            vocab: vocab,
            skills: skills,
            habits: habits,
            updatedAt: now
        )
    }

    // MARK: - Phase 4: placement + continuous calibration

    /// Writes a placement result onto the stored model (creating one if
    /// needed). Placement beats every other estimate source.
    static func recordPlacement(
        language: String,
        dialect: String,
        level: String,
        confidence: Double,
        fallbackLevel: String
    ) async throws {
        var model = try await loadOrRebuild(
            language: language, dialect: dialect, fallbackLevel: fallbackLevel
        )
        model.levelEstimate = LearnerModel.LevelEstimate(
            value: level,
            confidence: min(1.0, max(0.0, confidence)),
            source: "placement",
            updatedAt: Date()
        )
        model.updatedAt = Date()
        try await save(model)
    }

    /// Rolling conversational-accuracy update. Called fire-and-forget
    /// after each chat turn with the number of corrections the AI
    /// returned. Maintains an exponential moving average of corrections
    /// per turn and nudges level-estimate confidence: a stable, clean
    /// signal raises confidence; a noisy one lowers it so the planner
    /// knows to trust the level less.
    static func recordConversationSignal(
        language: String,
        correctionCount: Int
    ) async {
        let languageID = Conversation.languageID(for: language)
        guard var model = try? await fetch(languageID: languageID) else { return }

        let alpha = 0.15  // EMA smoothing
        let sample = Double(correctionCount)
        let previous = model.skills.recentCorrectionsPerTurn ?? sample
        let ema = previous * (1 - alpha) + sample * alpha
        model.skills.recentCorrectionsPerTurn = ema
        model.skills.recentTurnsSampled = (model.skills.recentTurnsSampled ?? 0) + 1

        // Confidence drift: after enough samples, an EMA comfortably
        // under 1 correction/turn supports the current estimate; over 2
        // suggests the level label is off in one direction or another.
        if let turns = model.skills.recentTurnsSampled, turns >= 10 {
            var confidence = model.levelEstimate.confidence
            if ema < 1.0 {
                confidence = min(0.95, confidence + 0.01)
            } else if ema > 2.0 {
                confidence = max(0.2, confidence - 0.02)
            }
            model.levelEstimate.confidence = confidence
        }
        try? await save(model)
    }

    // MARK: - Correction clustering

    /// Groups raw inline corrections into named error patterns via one
    /// cheap Haiku call (same pattern as DeckGenerator's topic summary).
    /// Empty input or any failure returns [] — the learner model just
    /// carries no error section until the next rebuild.
    private static func clusterCorrections(
        _ corrections: [ConversationCorrection],
        language: String
    ) async -> [LearnerModel.RecurringError] {
        guard corrections.count >= 3 else { return [] }
        let sample = corrections.suffix(40).map {
            "• \"\($0.original)\" → \"\($0.corrected)\" (\($0.explanation))"
        }.joined(separator: "\n")
        let prompt = """
        These are corrections a tutor gave a \(language) learner across recent conversations:

        \(sample)

        Cluster them into at most 5 recurring error patterns. Name each pattern with a short grammatical label (e.g. "gender agreement", "past-tense conjugation", "word order"). Count how many of the corrections above fall under each pattern, and include one representative example as "original → corrected".

        Submit the clusters by calling `submit_error_clusters`.
        """
        struct Decoded: Codable {
            struct Pattern: Codable {
                let pattern: String
                let count: Int
                let example: String?
            }
            let patterns: [Pattern]
        }
        let schema = JSONValue.schemaObject(
            properties: [
                "patterns": .schemaArray(
                    items: .schemaObject(
                        properties: [
                            "pattern": .schemaString("Short grammatical label, e.g. 'gender agreement'."),
                            "count": .schemaInt("How many corrections fall under this pattern."),
                            "example": .schemaString("Representative example as 'original → corrected'.")
                        ],
                        required: ["pattern", "count"]
                    ),
                    description: "Up to 5 clusters."
                )
            ],
            required: ["patterns"]
        )
        guard let decoded: Decoded = try? await AnthropicClient.sendStructured(
            toolName: "submit_error_clusters",
            toolDescription: "Submit clustered recurring error patterns.",
            schema: schema,
            userPrompt: prompt,
            model: "claude-haiku-4-5-20251001",
            maxTokens: 512,
            as: Decoded.self
        ) else { return [] }
        return decoded.patterns
            .sorted { $0.count > $1.count }
            .map {
                LearnerModel.RecurringError(
                    pattern: $0.pattern, count: $0.count, example: $0.example
                )
            }
    }

    // MARK: - Habit math

    private static func computeStreak(sessions: [StudySession]) -> Int {
        guard !sessions.isEmpty else { return 0 }
        let calendar = Calendar.current
        let days = Set(sessions.map { calendar.startOfDay(for: $0.completedAt) })
        let today = calendar.startOfDay(for: Date())
        let anchor: Date
        if days.contains(today) {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) {
            anchor = yesterday
        } else {
            return 0
        }
        var streak = 0
        var cursor = anchor
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// Mean study minutes per *active* day over the trailing 14 days.
    /// Nil until the user has at least one session in the window.
    private static func estimateMinutesPerDay(sessions: [StudySession]) -> Double? {
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -14, to: Date()) else {
            return nil
        }
        var secondsByDay: [Date: TimeInterval] = [:]
        for session in sessions where session.completedAt >= windowStart {
            let day = calendar.startOfDay(for: session.completedAt)
            let span = max(0, session.completedAt.timeIntervalSince(session.startedAt))
            secondsByDay[day, default: 0] += span
        }
        guard !secondsByDay.isEmpty else { return nil }
        let total = secondsByDay.values.reduce(0, +)
        return (total / Double(secondsByDay.count)) / 60.0
    }
}
