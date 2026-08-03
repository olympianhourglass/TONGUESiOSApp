import Foundation
import Observation

@Observable
@MainActor
final class LibraryViewModel {
    // Timestamp of the last `loadDecks()` start, so `refreshIfNeeded()` can
    // re-aggregate on tab re-entry (keeping the Preferred Language / favorite
    // topic stats current after studying) without hammering Firestore on
    // rapid tab-switching.
    private var lastLoadStartedAt: Date?

    var decks: [DeckDocument] = []
    var urgencies: [String: DeckUrgency] = [:]
    // Total flashcard reviews per language, summed across every study session
    // saved to Firestore. Source of truth for the library's "Preferred
    // Language" stat — biggest tally wins.
    var reviewsByLanguage: [String: Int] = [:]
    // Time-weighted "Preferred Language" inputs. Flashcard time (real, from
    // StudySession durations) + `learningSecondsByLanguage` (audio real +
    // conversation/comprehension estimates, snapshot from XPService) form the
    // time half; `itemsByLanguage` is the lower-weighted content half.
    var flashcardSecondsByLanguage: [String: Double] = [:]
    var learningSecondsByLanguage: [String: Double] = [:]
    var itemsByLanguage: [String: Int] = [:]
    // Number of cards reviewed per calendar day (start-of-day in the user's
    // current calendar). Source data for both the daily streak walk and
    // the Statistics tab's contribution heatmap, which colors cells by the
    // count. O(1) lookups for both consumers.
    var practiceCountsByDay: [Date: Int] = [:]
    // Total cards reviewed per deck across the full session history. Used
    // by the Statistics tab to identify the user's most-practiced decks
    // so their titles/interests can feed the "favorite topic" summary.
    var reviewsByDeck: [String: Int] = [:]
    // Length of the longest "meta session" — a contiguous run of activity
    // (flashcard reviews + deck generations, with audio when we start
    // logging it) where consecutive events are no more than the gap
    // threshold below apart. Lifetime maximum across the user's history.
    var longestSessionSeconds: TimeInterval = 0
    // Mean duration of the user's saved flashcard sessions, in seconds.
    // Used for the Statistics tab's "Your average session length is ..."
    // headline. Sessions with malformed timestamps are clamped to 0 so
    // they don't drag the average negative.
    var averageSessionSeconds: TimeInterval = 0
    // Language whose longest meta-session (per-language 5-min-gap merge
    // over its study sessions) was the longest. Empty until at least
    // one flashcard session has been saved.
    var longestSessionLanguage: String = ""
    // Time-of-day label ("in the morning" / "in the afternoon" / etc.)
    // where the user's FSRS reviews land most accurately *and* most
    // consistently. See `computeBestLearningTime` for the scoring.
    var bestLearningTimeLabel: String = ""
    // Specific clock-time version of the same signal — the weighted mean
    // hour-of-day where the user has graded reviews good/easy. Drives
    // the Statistics tab's Day Statistics → "Optimal Learning Time"
    // headline. Always agrees with `bestLearningTimeLabel`'s bucket
    // because both derive from the same mean.
    var optimalLearningTimeLabel: String = ""
    // Total XP across every award source. Read from the XPService doc on
    // every loadDecks so the Library card reflects the latest awards.
    var totalXP: Int = 0
    // Lifetime per-method session counters from XPService, snapshot at load
    // time. Drive the Statistics tab's "Preferred Learning Method" distribution.
    var flashcardSessionCount: Int = 0
    var audioSessionCount: Int = 0
    var conversationSessionCount: Int = 0
    var artifactSessionCount: Int = 0
    var comprehensionSessionCount: Int = 0
    // XP earned per calendar day, decoded from UserXPState.xpByDayKey
    // into start-of-day Date keys so the weekly trend chart can index
    // directly by date without re-parsing per lookup.
    var xpByDay: [Date: Int] = [:]
    var isLoading = false
    var errorText: String?

    // Distribution of practice across the real learning methods (flashcards,
    // listening, conversation, artifacts), heaviest first, each with its share
    // of total sessions. Empty when the user hasn't practiced anything yet.
    var learningMethodShares: [LearningMethodShare] {
        let counts: [(LearningMethod, Int)] = [
            (.flashcards, flashcardSessionCount),
            (.listening, audioSessionCount),
            (.conversation, conversationSessionCount),
            (.artifacts, artifactSessionCount),
            (.comprehension, comprehensionSessionCount)
        ]
        let total = counts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return counts
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { LearningMethodShare(method: $0.0, percent: Double($0.1) / Double(total)) }
    }

    // Headline for the "Preferred Learning Method" stat: the method the learner
    // gravitates toward most (Flashcards / Listening / Conversation / Artifacts),
    // or "—" before any practice.
    var preferredLearningMethodLabel: String {
        learningMethodShares.first?.method.displayName ?? "—"
    }

    // Distribution of the library's WORDS by how they were gathered — Generate,
    // Camera, Direct, Song/Video, Large Text, Artifact, Conversation. Words with
    // no stored source (legacy, pre-feature) fall back to Generate, the default
    // acquisition path. Heaviest first; empty when the library is empty.
    var sourcingMethodShares: [SourcingMethodShare] {
        var counts: [SourcingMethod: Int] = [:]
        for deck in decks {
            for item in deck.items {
                let method = item.source.flatMap { SourcingMethod(rawValue: $0) } ?? .generate
                counts[method, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts
            .map { (method: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .map { SourcingMethodShare(method: $0.method, percent: Double($0.count) / Double(total)) }
    }

    // How long a gap is tolerated between two activity events before the
    // meta-session ends. 5 minutes is loose enough that brief app-switches
    // (checking a notification, glancing at iMessage) don't break the
    // session, but tight enough that a real walk-away clearly does.
    private static let sessionGapThreshold: TimeInterval = 5 * 60

    // Generous upper bound on active time per reviewed card. A single
    // StudySession's raw wall-clock (`completedAt - startedAt`) can balloon to
    // many hours when the app is backgrounded/suspended mid-session and the
    // session finalizes long after real activity stopped — producing absurd
    // "longest session" values (e.g. 12h) and inflating the time-weighted
    // preferred-language score. We cap credited time against the work actually
    // done: at most this many seconds per card reviewed.
    private static let maxSecondsPerCard: TimeInterval = 120

    // Real active time to credit a single flashcard session: the wall-clock
    // duration, clamped so it can't exceed `maxSecondsPerCard` per reviewed
    // card. Sessions with corrupt ordering (completedAt < startedAt) clamp to 0.
    static func activeSeconds(for session: StudySession) -> TimeInterval {
        let wallClock = max(0, session.completedAt.timeIntervalSince(session.startedAt))
        let workCap = Double(max(session.totalReviewed, 1)) * maxSecondsPerCard
        return min(wallClock, workCap)
    }

    // Reloads only if the last load started more than `minInterval` seconds
    // ago (and one isn't already in flight). Called on every Library
    // appearance so returning from the Study tab re-aggregates the latest
    // sessions — the fix for stats that "don't update frequently enough."
    // The 20s window keeps stats fresh while avoiding a full (unbounded)
    // session re-read on every quick tab bounce, to hold down Firestore reads.
    func refreshIfNeeded(minInterval: TimeInterval = 20) async {
        if isLoading { return }
        if let last = lastLoadStartedAt, Date().timeIntervalSince(last) < minInterval {
            return
        }
        await loadDecks()
    }

    func loadDecks() async {
        isLoading = true
        lastLoadStartedAt = Date()
        defer { isLoading = false }
        do {
            async let schedulesTask: [String: CardSchedule]? =
                try? await FirebaseDeckService.fetchAllSchedules()
            async let sessionsTask: [StudySession]? =
                try? await FirebaseDeckService.fetchStudySessions()

            let fetched = try await FirebaseDeckService.fetchDecks()
            let schedules = (await schedulesTask) ?? [:]
            let sessions = (await sessionsTask) ?? []

            let now = Date()
            var urgencyMap: [String: DeckUrgency] = [:]
            for deck in fetched {
                guard let id = deck.id else { continue }
                urgencyMap[id] = FSRSScheduler.urgency(
                    for: deck,
                    schedules: schedules,
                    at: now
                )
            }

            var totals: [String: Int] = [:]
            let calendar = Calendar.current
            var counts: [Date: Int] = [:]
            var byDeck: [String: Int] = [:]
            var flashcardSeconds: [String: Double] = [:]
            for session in sessions {
                totals[session.language, default: 0] += session.totalReviewed
                let day = calendar.startOfDay(for: session.completedAt)
                counts[day, default: 0] += session.totalReviewed
                byDeck[session.deckId, default: 0] += session.totalReviewed
                // Real flashcard time per language for the time-weighted score,
                // clamped so a suspended/backgrounded session can't inflate it.
                flashcardSeconds[session.language, default: 0] += Self.activeSeconds(for: session)
            }

            // Amount of content per language — the lower-weighted half of the
            // preferred-language score.
            var itemsByLang: [String: Int] = [:]
            for deck in fetched {
                itemsByLang[deck.language, default: 0] += deck.items.count
            }

            decks = fetched
            urgencies = urgencyMap
            reviewsByLanguage = totals
            flashcardSecondsByLanguage = flashcardSeconds
            itemsByLanguage = itemsByLang
            practiceCountsByDay = counts
            reviewsByDeck = byDeck
            longestSessionSeconds = Self.computeLongestMetaSession(
                studySessions: sessions,
                decks: fetched
            )
            averageSessionSeconds = Self.computeAverageSessionLength(studySessions: sessions)
            longestSessionLanguage = Self.computeLongestSessionLanguage(studySessions: sessions)
            let meanHour = Self.meanSuccessfulReviewHour(studySessions: sessions)
            bestLearningTimeLabel = Self.bestLearningBucketLabel(forMeanHour: meanHour)
            optimalLearningTimeLabel = Self.optimalLearningClockLabel(forMeanHour: meanHour)
            // Load XP after the streak is computable so the milestone
            // award has a fresh streak number to compare against. Streak
            // milestones are idempotent in the service, so calling on
            // every load is safe.
            if let state = try? await XPService.fetchState() {
                applyXPState(state)
            }
            let streakNow = dailyStreak
            if streakNow > 0 {
                if let milestoneGrants = try? await XPService.awardStreakMilestoneIfNeeded(currentStreak: streakNow),
                   !milestoneGrants.isEmpty {
                    XPToastCenter.shared.enqueue(milestoneGrants)
                    // Re-read total so the card surfaces the bumped value.
                    if let state = try? await XPService.fetchState() {
                        applyXPState(state)
                    }
                }
            }
            errorText = nil

            // Refresh the home/lock-screen widget snapshot off the same
            // decks + schedules we just loaded. Best-effort: failures
            // (App Group not provisioned, IO error) log and continue.
            WidgetSnapshotWriter.writeSnapshot(
                decks: fetched,
                schedules: schedules,
                now: now
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Library aggregates

    // Total cards across all decks that have been graded at least once
    // (i.e. no longer in FSRS' "new" bucket). This is the simplest "learned
    // so far" signal we can derive without keeping the raw schedule store
    // around — it reuses the urgency snapshot the Study/Library tabs already
    // compute. A stricter definition (e.g. stability ≥ 7 days) is a future
    // refinement once we surface schedules to the VM.
    // Total flashcards seen across every study session — every review counts,
    // right or wrong. Distinct from `itemsTouched` (unique cards graded): this
    // is the raw "how many cards have I encountered" volume, so it's ≥ learned.
    var totalCardsReviewed: Int {
        reviewsByLanguage.values.reduce(0, +)
    }

    // Time-weighted "Preferred Language" distribution: 70% time share (audio +
    // flashcard + conversation + comprehension) + 30% content share (words in
    // that language), so engagement leads but generated content still counts.
    // Sorted heaviest-first; percents sum to ~1. Drives both the Library metric
    // and the Statistics card — including the ordering of the list.
    var preferredLanguageBreakdown: [(language: String, percent: Double)] {
        var languages = Set<String>()
        languages.formUnion(flashcardSecondsByLanguage.keys)
        languages.formUnion(learningSecondsByLanguage.keys)
        languages.formUnion(itemsByLanguage.keys)
        guard !languages.isEmpty else { return [] }

        var timeByLang: [String: Double] = [:]
        for lang in languages {
            timeByLang[lang] = (flashcardSecondsByLanguage[lang] ?? 0)
                + (learningSecondsByLanguage[lang] ?? 0)
        }
        let totalTime = timeByLang.values.reduce(0, +)
        let totalContent = itemsByLanguage.values.reduce(0, +)

        let timeWeight = 0.7
        let contentWeight = 0.3
        var scores: [(String, Double)] = []
        for lang in languages {
            let timeShare = totalTime > 0 ? (timeByLang[lang] ?? 0) / totalTime : 0
            let contentShare = totalContent > 0
                ? Double(itemsByLanguage[lang] ?? 0) / Double(totalContent)
                : 0
            let score: Double
            if totalTime <= 0 {
                score = contentShare            // no sessions yet → content only
            } else if totalContent <= 0 {
                score = timeShare
            } else {
                score = timeWeight * timeShare + contentWeight * contentShare
            }
            if score > 0 { scores.append((lang, score)) }
        }
        let total = scores.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return scores
            .sorted { $0.1 > $1.1 }
            .map { (language: $0.0, percent: $0.1 / total) }
    }

    // Top language by the blended score, for the Library tab's metric card.
    var mostPracticedLanguage: String {
        preferredLanguageBreakdown.first?.language ?? "—"
    }

    var itemsTouched: Int {
        decks.reduce(0) { sum, deck in
            guard let id = deck.id, let urgency = urgencies[id] else { return sum }
            return sum + max(0, urgency.totalCount - urgency.newCount)
        }
    }

    // Top `limit` decks ordered by total reviews, exposed as a compact
    // payload for the Statistics tab's "favorite topic" LLM summary.
    // Returns a stable signature (sorted deck IDs joined) so the caller
    // can cache the summary and only re-fetch when the top set changes.
    // Inputs for the "favorite topic" label. Rather than the top-5 most-
    // practiced decks, this is the center of gravity across the learner's
    // ENTIRE deck collection: every deck contributes, weighted so that
    //   • simply creating a deck on a theme tilts the balance (a base weight),
    //   • and practicing a deck tilts it more (a log-scaled review bonus).
    // So a burst of new aerospace decks leans the label toward aerospace even
    // before they're practiced, while grinding one deck also pulls its way.
    //
    // Returns the decks heaviest-first (capped for prompt size) plus a
    // signature that changes whenever a deck is added/removed/renamed or its
    // practice crosses into a new weight bucket — the refresh trigger the
    // cached label keys off.
    func favoriteTopicDeckSummaries(limit: Int = 60) -> (signature: String, summaries: [DeckTopicSummary]) {
        guard !decks.isEmpty else { return ("", []) }
        let weighted: [(deck: DeckDocument, weight: Double)] = decks.map { deck in
            let reviews = deck.id.map { reviewsByDeck[$0] ?? 0 } ?? 0
            // Base 1 for existing + a bounded, log-scaled practice bonus so one
            // heavily-drilled deck can't completely drown out a cluster of
            // freshly-created decks on another theme.
            let weight = 1.0 + log2(Double(1 + reviews))
            return (deck, weight)
        }
        let summaries = weighted
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
            .map { entry in
                DeckTopicSummary(
                    id: entry.deck.id ?? "",
                    title: entry.deck.title,
                    interests: entry.deck.interests,
                    contentType: entry.deck.contentType,
                    weight: entry.weight
                )
            }
        // Signature spans the FULL collection (not just the capped prompt set)
        // so a deck added beyond the cap still refreshes the theme. Sorted by
        // id for determinism; title + coarse weight bucket so renames and real
        // practice jumps refresh, but day-to-day review increments don't.
        let signature = weighted
            .sorted { ($0.deck.id ?? "") < ($1.deck.id ?? "") }
            .map { "\($0.deck.id ?? ""):\($0.deck.title):\(Self.weightBucket($0.weight))" }
            .joined(separator: "|")
        return (signature, Array(summaries))
    }

    // Half-step buckets so a deck has to gain meaningful practice (or be
    // renamed/added) before the cache invalidates.
    private static func weightBucket(_ weight: Double) -> Int {
        Int((weight * 2).rounded())
    }

    // Count of items in every deck whose `contentType` matches the given
    // string ("Words" / "Phrases" / "Sentences"). Each deck has one content
    // type so this is a straight sum.
    func libraryItemCount(forContentType type: String) -> Int {
        decks
            .filter { $0.contentType == type }
            .reduce(0) { $0 + $1.items.count }
    }

    // Cards added in the last 7 / 30 days. Deliberately a ROLLING window, not
    // the calendar week/month: the calendar week resets at the locale's first
    // weekday (Sunday in the US), so cards added a few days ago would drop to
    // "0 this week" the moment the week rolled over — which reads as a bug.
    // A rolling window matches the intuitive "recently added."
    var cardsAddedThisWeek: Int {
        cardsAdded(inLastDays: 7)
    }

    var cardsAddedThisMonth: Int {
        cardsAdded(inLastDays: 30)
    }

    // Up to 10 decks ordered by recency of last modification — left side
    // of the Study tab's "Recently Added" row. Uses each deck's max
    // item `addedAt` when present (so a deck augmented via "Generate
    // more" surfaces with its new-item timestamp), falling back to the
    // deck's own `createdAt` for legacy items written before
    // per-item timestamps existed.
    var recentlyModifiedDecks: [DeckDocument] {
        decks
            .sorted { Self.lastModified(of: $0) > Self.lastModified(of: $1) }
            .prefix(10)
            .map { $0 }
    }

    static func lastModified(of deck: DeckDocument) -> Date {
        let mostRecentItemAdd = deck.items.compactMap { $0.addedAt }.max()
        return max(deck.createdAt, mostRecentItemAdd ?? deck.createdAt)
    }

    // Consecutive calendar days, ending today (or yesterday if the user
    // hasn't practiced yet today), on which a study session was completed.
    // Standard streak rule: missing a full calendar day breaks the streak.
    // Allowing yesterday as the anchor keeps the streak "alive" until
    // midnight, matching the convention apps like Duolingo use.
    var dailyStreak: Int {
        guard !practiceCountsByDay.isEmpty else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let anchor: Date
        if practiceCountsByDay[today] != nil {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  practiceCountsByDay[yesterday] != nil {
            anchor = yesterday
        } else {
            return 0
        }

        var streak = 0
        var cursor = anchor
        while practiceCountsByDay[cursor] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    // Sweep all known activity events into time intervals, sort, then walk
    // forward merging anything <= `sessionGapThreshold` apart. Returns the
    // duration of the single longest merged interval ever recorded.
    //
    // Events currently included:
    //   • StudySession  → [startedAt, completedAt] interval
    //   • DeckDocument  → [createdAt, createdAt] zero-length point
    //   • (TODO) audio listening sessions — once we start logging them,
    //     drop them in as additional intervals and the merge math takes
    //     care of the rest.
    private static func computeLongestMetaSession(
        studySessions: [StudySession],
        decks: [DeckDocument]
    ) -> TimeInterval {
        var intervals: [(start: Date, end: Date)] = []
        intervals.reserveCapacity(studySessions.count + decks.count)
        for session in studySessions {
            // Use active (work-capped) duration, not raw wall-clock, so a
            // session left open in the background can't produce a 12h interval.
            let end = session.startedAt.addingTimeInterval(activeSeconds(for: session))
            intervals.append((session.startedAt, end))
        }
        for deck in decks {
            intervals.append((deck.createdAt, deck.createdAt))
        }
        guard !intervals.isEmpty else { return 0 }

        intervals.sort { $0.start < $1.start }
        var longest = intervals[0].end.timeIntervalSince(intervals[0].start)
        var current = intervals[0]
        for next in intervals.dropFirst() {
            if next.start.timeIntervalSince(current.end) <= sessionGapThreshold {
                current.end = max(current.end, next.end)
            } else {
                current = next
            }
            let span = current.end.timeIntervalSince(current.start)
            if span > longest { longest = span }
        }
        return longest
    }

    // Mirrors a freshly-fetched XPState into the VM's local snapshots.
    // Decodes the day-keyed XP dictionary into start-of-day Date keys so
    // the weekly trend chart can index by `Calendar.startOfDay(...)`
    // without re-parsing strings per lookup.
    private func applyXPState(_ state: UserXPState) {
        totalXP = state.total
        flashcardSessionCount = state.flashcardSessionCount
        audioSessionCount = state.audioSessionCount
        conversationSessionCount = state.conversationSessionCount
        artifactSessionCount = state.artifactSessionCount
        comprehensionSessionCount = state.comprehensionSessionCount
        learningSecondsByLanguage = state.learningSecondsByLanguage
        let calendar = Calendar.current
        var decoded: [Date: Int] = [:]
        for (key, value) in state.xpByDayKey {
            guard let parsed = UserXPState.date(for: key) else { continue }
            let day = calendar.startOfDay(for: parsed)
            decoded[day, default: 0] += value
        }
        xpByDay = decoded
    }

    // Plain mean of every saved flashcard session's wall-clock duration.
    // Sessions whose completedAt < startedAt (legacy / corruption) clamp
    // to 0 so they don't pull the average negative.
    private static func computeAverageSessionLength(studySessions: [StudySession]) -> TimeInterval {
        guard !studySessions.isEmpty else { return 0 }
        let total = studySessions.reduce(0.0) { acc, session in
            acc + activeSeconds(for: session)
        }
        return total / Double(studySessions.count)
    }

    // For each language, runs the same 5-min-gap merge as the lifetime
    // longest-session calc, but restricted to that language's study
    // sessions. The language with the longest merged interval wins.
    private static func computeLongestSessionLanguage(studySessions: [StudySession]) -> String {
        guard !studySessions.isEmpty else { return "" }
        var byLanguage: [String: [(start: Date, end: Date)]] = [:]
        for session in studySessions {
            let end = session.startedAt.addingTimeInterval(activeSeconds(for: session))
            byLanguage[session.language, default: []].append((session.startedAt, end))
        }
        var bestLanguage = ""
        var bestDuration: TimeInterval = 0
        for (language, intervals) in byLanguage {
            let longest = mergeAndFindLongest(intervals: intervals)
            if longest > bestDuration {
                bestDuration = longest
                bestLanguage = language
            }
        }
        return bestLanguage
    }

    private static func mergeAndFindLongest(intervals: [(start: Date, end: Date)]) -> TimeInterval {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.start < $1.start }
        var longest = sorted[0].end.timeIntervalSince(sorted[0].start)
        var current = sorted[0]
        for next in sorted.dropFirst() {
            if next.start.timeIntervalSince(current.end) <= sessionGapThreshold {
                current.end = max(current.end, next.end)
            } else {
                current = next
            }
            let span = current.end.timeIntervalSince(current.start)
            if span > longest { longest = span }
        }
        return longest
    }

    // Weighted mean of the decimal hour-of-day across every review the
    // user has graded as a success. `easy` carries twice the weight of
    // `good` (confident recall outweighs ordinary recall); lapses and
    // hard grades are excluded so the mean reflects where the user is
    // genuinely on their game. Returns nil when no successes exist yet.
    private static func meanSuccessfulReviewHour(studySessions: [StudySession]) -> Double? {
        let calendar = Calendar.current
        var weightedSum: Double = 0
        var totalWeight: Double = 0
        for session in studySessions {
            for review in session.reviews {
                let weight: Double
                switch review.result {
                case .easy: weight = 2.0
                case .good: weight = 1.0
                default:    weight = 0
                }
                guard weight > 0 else { continue }
                let comps = calendar.dateComponents([.hour, .minute], from: review.reviewedAt)
                let decimalHour = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
                weightedSum += decimalHour * weight
                totalWeight += weight
            }
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }

    // Broad bucket version of the same mean. Falling out of one function
    // guarantees the broad label and the specific clock value can never
    // disagree (e.g. clock says 9:15 am but bucket says afternoon).
    private static func bestLearningBucketLabel(forMeanHour meanHour: Double?) -> String {
        guard let meanHour else { return "" }
        let bucket = timeBucket(for: Int(meanHour))
        return label(forBucket: bucket)
    }

    // Specific clock label. Mean hour gets rounded to the nearest 15
    // minutes — a coarser grid than the underlying data so the value
    // reads as a guideline rather than false-precise (e.g. "9:15 am",
    // not "9:23 am").
    private static func optimalLearningClockLabel(forMeanHour meanHour: Double?) -> String {
        guard let meanHour else { return "" }
        let totalMinutes = Int((meanHour * 60).rounded())
        let rounded = Int((Double(totalMinutes) / 15.0).rounded()) * 15
        let hours24 = ((rounded / 60) % 24 + 24) % 24
        let minutes = ((rounded % 60) + 60) % 60
        var hour12 = hours24 % 12
        if hour12 == 0 { hour12 = 12 }
        let period = hours24 < 12 ? "am" : "pm"
        return String(format: "%d:%02d %@", hour12, minutes, period)
    }

    private static func timeBucket(for hour: Int) -> String {
        switch hour {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default:      return "night"
        }
    }

    private static func label(forBucket bucket: String) -> String {
        switch bucket {
        case "morning":   return "in the morning"
        case "afternoon": return "in the afternoon"
        case "evening":   return "in the evening"
        case "night":     return "at night"
        default:          return ""
        }
    }

    private func cardsAdded(inLastDays days: Int) -> Int {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -days, to: Date()) else {
            return 0
        }
        return decks.reduce(0) { sum, deck in
            // Per-item `addedAt` is the source of truth — falls back to the
            // deck's `createdAt` only for legacy items written before the
            // field existed, so freshly appended cards count toward the
            // window even on old decks.
            sum + deck.items.reduce(0) { itemSum, item in
                let stamp = item.addedAt ?? deck.createdAt
                return itemSum + (stamp >= start ? 1 : 0)
            }
        }
    }

    func deleteDeck(_ deck: DeckDocument) async {
        guard let id = deck.id else { return }
        let previous = decks
        decks.removeAll { $0.id == id }
        do {
            try await FirebaseDeckService.deleteDeck(id: id)
        } catch {
            decks = previous
            errorText = error.localizedDescription
        }
    }
}

// Slim representation of a deck for the Statistics tab's favorite-topic
// LLM call. Carries only the fields the prompt needs so we don't ship
// the full item array (which could be hundreds of cards) into the
// network request.
struct DeckTopicSummary: Hashable, Sendable {
    let id: String
    let title: String
    let interests: [String]
    let contentType: String
    // Relative pull this deck exerts on the "favorite topic": a base for
    // simply existing (so creating decks on a theme tilts it) plus a
    // log-scaled bonus for how much it's been practiced.
    let weight: Double
}
