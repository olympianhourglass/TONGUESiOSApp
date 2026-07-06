import Foundation
import FirebaseAuth
import FirebaseFirestore

// A single XP award the user just earned. Call sites bundle multiple
// grants (e.g. per-card XP + deck completion + perfect-session bonus)
// into one transaction; the UI surfaces each grant as its own toast.
struct XPGrant: Hashable, Identifiable {
    var id = UUID()
    let amount: Int
    let reason: String
}

// Persistent XP bookkeeping. One document per user keeps the read cheap
// (a single getDocument on Library load) while still letting us dedupe
// one-time bonuses (language first, streak milestones, multimodal) and
// per-day awards (daily first-session).
struct UserXPState: Codable, Hashable {
    var total: Int = 0
    var lastDailyAwardedOn: Date? = nil
    var awardedStreakMilestones: [Int] = []
    var seenContentTypes: [String] = []
    var seenLanguages: [String] = []
    var awardedMultimodalDeckIds: [String] = []
    var studiedDeckIds: [String] = []
    var listenedDeckIds: [String] = []
    // Lifetime session counters. Feed the Statistics tab's "Preferred
    // Learning Method" card (flashcards = active, audio = passive). We
    // bump on every meaningful session — repeat-studying the same deck
    // counts each time, since the question is "what behavior do you
    // gravitate toward?", not "how much breadth have you covered?"
    var flashcardSessionCount: Int = 0
    var audioSessionCount: Int = 0
    // XP earned per calendar day, keyed by "yyyy-MM-dd" (user-local).
    // String keys instead of Date so the dict serializes cleanly through
    // Firestore. Source for the Statistics tab's weekly trend chart.
    var xpByDayKey: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case total
        case lastDailyAwardedOn
        case awardedStreakMilestones
        case seenContentTypes
        case seenLanguages
        case awardedMultimodalDeckIds
        case studiedDeckIds
        case listenedDeckIds
        case flashcardSessionCount
        case audioSessionCount
        case xpByDayKey
    }

    init() {}

    // Custom decoder so missing keys fall back to their defaults instead
    // of throwing. Without this, every time we add a new field (e.g.
    // `xpByDayKey`) older Firestore docs would fail to decode and the
    // next commit would overwrite them with an empty state — total
    // would reset to 0 and look "not persistent". `decodeIfPresent` for
    // every field is the safety net that prevents that class of bug
    // going forward.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.total                       = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
        self.lastDailyAwardedOn          = try? c.decodeIfPresent(Date.self, forKey: .lastDailyAwardedOn)
        self.awardedStreakMilestones     = (try? c.decodeIfPresent([Int].self, forKey: .awardedStreakMilestones)) ?? []
        self.seenContentTypes            = (try? c.decodeIfPresent([String].self, forKey: .seenContentTypes)) ?? []
        self.seenLanguages               = (try? c.decodeIfPresent([String].self, forKey: .seenLanguages)) ?? []
        self.awardedMultimodalDeckIds    = (try? c.decodeIfPresent([String].self, forKey: .awardedMultimodalDeckIds)) ?? []
        self.studiedDeckIds              = (try? c.decodeIfPresent([String].self, forKey: .studiedDeckIds)) ?? []
        self.listenedDeckIds             = (try? c.decodeIfPresent([String].self, forKey: .listenedDeckIds)) ?? []
        self.flashcardSessionCount       = (try? c.decodeIfPresent(Int.self, forKey: .flashcardSessionCount)) ?? 0
        self.audioSessionCount           = (try? c.decodeIfPresent(Int.self, forKey: .audioSessionCount)) ?? 0
        self.xpByDayKey                  = (try? c.decodeIfPresent([String: Int].self, forKey: .xpByDayKey)) ?? [:]
    }
}

// MARK: - Day-key helpers

// Stable, locale-independent date key used throughout the XP system so
// the storage format doesn't shift if the user changes regions. Stays
// aligned with the user's *current* calendar day at write time, which
// is what the weekly trend chart cares about.
private let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

extension UserXPState {
    static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func date(for dayKey: String) -> Date? {
        dayKeyFormatter.date(from: dayKey)
    }
}

enum XPService {
    private static let db = Firestore.firestore()

    // Streak milestones (in days) and their XP rewards. Order matters: the
    // service walks low → high to catch every newly-crossed threshold on
    // the same load.
    static let streakMilestones: [(days: Int, reward: Int)] = [
        (7, 50),
        (30, 200),
        (100, 500)
    ]

    private static func docRef() throws -> DocumentReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("xp").document("state")
    }

    // Reads the user's XP state. First-time users (doc missing) → empty
    // state. Existing doc that fails to decode → THROW. Returning empty
    // here would let the next commit overwrite the existing data with
    // zeros, which is the failure mode that made XP look non-persistent
    // when new fields were added to the schema.
    static func fetchState() async throws -> UserXPState {
        let ref = try docRef()
        let snap = try await ref.getDocument()
        guard snap.exists else { return UserXPState() }
        do {
            let state = try snap.data(as: UserXPState.self)
            return state
        } catch {
            print("⚠️ XPService.fetchState decode failed — preserving existing doc by refusing to write. Error: \(error)")
            throw error
        }
    }

    // MARK: - Flashcard session bundle

    // Awarded at the end of a completed deck. `cardGrades` is the array of
    // grades the user submitted, in order, so we can compute per-card +
    // perfect-session bonuses.
    @discardableResult
    static func awardFlashcardSession(
        deckId: String,
        language: String,
        cardGrades: [ReviewResult],
        handwrittenCount: Int = 0
    ) async throws -> [XPGrant] {
        var state = try await fetchState()
        var grants: [XPGrant] = []

        // Per-card: 1 XP for again/hard, 2 XP for good/easy. Sums silently
        // into one grant so we don't spam a toast per card.
        let perCardXP = cardGrades.reduce(0) { sum, grade in
            sum + (grade.isLapse || grade == .hard ? 1 : 2)
        }
        if perCardXP > 0 {
            grants.append(XPGrant(amount: perCardXP, reason: "Reviews"))
        }

        // Deck completed.
        grants.append(XPGrant(amount: 10, reason: "Deck complete"))

        // Handwriting bonus: words the learner wrote out by hand this
        // session (3 XP each). Rewards the extra effort over recall alone.
        if handwrittenCount > 0 {
            grants.append(XPGrant(amount: handwrittenCount * 3, reason: "Handwriting"))
        }

        // Perfect session: nothing graded "again" (= memory lapse). Hards
        // are still allowed since the user did recall the card.
        if !cardGrades.isEmpty, !cardGrades.contains(where: { $0.isLapse }) {
            grants.append(XPGrant(amount: 10, reason: "Perfect session"))
        }

        // First deck in a new language.
        if !state.seenLanguages.contains(language) {
            state.seenLanguages.append(language)
            grants.append(XPGrant(amount: 25, reason: "New language"))
        }

        // Mark this deck as studied; check for multimodal completion.
        if !state.studiedDeckIds.contains(deckId) {
            state.studiedDeckIds.append(deckId)
        }
        state.flashcardSessionCount += 1
        if let multimodal = multimodalGrantIfNeeded(deckId: deckId, state: &state) {
            grants.append(multimodal)
        }

        try await commit(grants: grants, into: &state)
        return grants
    }

    // MARK: - Audio session bundle

    // Awarded when the user leaves a listening session that actually
    // played for at least a minute or completed the playlist. Per-minute
    // XP is bounded by both wall-clock and unique items advanced, so
    // backgrounded audio can't farm.
    @discardableResult
    static func awardAudioSession(
        deckId: String,
        secondsListened: TimeInterval,
        cardsAdvanced: Int,
        playlistCompleted: Bool
    ) async throws -> [XPGrant] {
        var state = try await fetchState()
        var grants: [XPGrant] = []

        // Per-minute XP. Cap at the number of cards advanced so a 10-min
        // audio session that only progressed 2 items can earn at most 2 XP.
        // This is the anti-passive-farming guard discussed in design.
        let minutes = Int(secondsListened / 60.0)
        let perMinuteXP = max(0, min(minutes, cardsAdvanced))
        if perMinuteXP > 0 {
            grants.append(XPGrant(amount: perMinuteXP, reason: "Listening time"))
        }

        if playlistCompleted {
            grants.append(XPGrant(amount: 10, reason: "Audio complete"))
        }

        // Multimodal check only when there was meaningful audio activity.
        var mutated = false
        if perMinuteXP > 0 || playlistCompleted {
            if !state.listenedDeckIds.contains(deckId) {
                state.listenedDeckIds.append(deckId)
            }
            state.audioSessionCount += 1
            mutated = true
            if let multimodal = multimodalGrantIfNeeded(deckId: deckId, state: &state) {
                grants.append(multimodal)
            }
        }

        // Even when no XP grants fired (e.g. listened for 30s with no
        // playlist completion), the counter bump above is data the
        // preferred-method calc depends on — so we still commit. The
        // fast-path "no activity at all" case skips the write to avoid
        // a needless network round trip.
        if grants.isEmpty && !mutated {
            return []
        }
        try await commit(grants: grants, into: &state)
        return grants
    }

    // MARK: - Deck creation bundle

    // Awarded right after a deck is persisted. Tracks first-time content
    // types so e.g. the user's first Phrases deck earns the bonus, even
    // if they've already created Word decks.
    @discardableResult
    static func awardDeckCreation(
        contentType: String,
        language: String
    ) async throws -> [XPGrant] {
        var state = try await fetchState()
        var grants: [XPGrant] = [
            XPGrant(amount: 5, reason: "Deck generated")
        ]
        if !state.seenContentTypes.contains(contentType) {
            state.seenContentTypes.append(contentType)
            grants.append(XPGrant(amount: 5, reason: "First \(contentType) deck"))
        }
        try await commit(grants: grants, into: &state)
        return grants
    }

    // MARK: - Daily & streak bonuses

    // Awards the daily first-session bonus exactly once per local
    // calendar day. Idempotent — safe to call from multiple event sites
    // (flashcard finish, audio finish, deck save).
    @discardableResult
    static func awardDailyBonusIfNeeded() async throws -> [XPGrant] {
        var state = try await fetchState()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let last = state.lastDailyAwardedOn, calendar.isDate(last, inSameDayAs: today) {
            return []
        }
        state.lastDailyAwardedOn = today
        let grants = [XPGrant(amount: 5, reason: "Daily session")]
        try await commit(grants: grants, into: &state)
        return grants
    }

    // Walks the milestone list and awards every threshold the current
    // streak has crossed but hasn't been credited for yet. Safe to call
    // every load — already-awarded milestones are filtered out.
    @discardableResult
    static func awardStreakMilestoneIfNeeded(currentStreak: Int) async throws -> [XPGrant] {
        var state = try await fetchState()
        var grants: [XPGrant] = []
        for milestone in streakMilestones where currentStreak >= milestone.days {
            if state.awardedStreakMilestones.contains(milestone.days) { continue }
            state.awardedStreakMilestones.append(milestone.days)
            grants.append(XPGrant(amount: milestone.reward, reason: "\(milestone.days)-day streak"))
        }
        guard !grants.isEmpty else { return [] }
        try await commit(grants: grants, into: &state)
        return grants
    }

    // MARK: - Internal helpers

    private static func multimodalGrantIfNeeded(
        deckId: String,
        state: inout UserXPState
    ) -> XPGrant? {
        guard state.studiedDeckIds.contains(deckId),
              state.listenedDeckIds.contains(deckId),
              !state.awardedMultimodalDeckIds.contains(deckId) else {
            return nil
        }
        state.awardedMultimodalDeckIds.append(deckId)
        return XPGrant(amount: 10, reason: "Multimodal mastery")
    }

    private static func commit(grants: [XPGrant], into state: inout UserXPState) async throws {
        let added = grants.reduce(0) { $0 + $1.amount }
        state.total += added
        // Roll the same total into today's daily bucket so the weekly
        // trend chart has per-day granularity without a separate event
        // log. Today's key uses the user's current calendar day.
        if added > 0 {
            let key = UserXPState.dayKey(for: Date())
            state.xpByDayKey[key, default: 0] += added
        }
        let ref = try docRef()
        try await ref.setData(from: state, merge: true)
        print("XPService.commit → +\(added) XP, total now \(state.total) (flashcards: \(state.flashcardSessionCount), audio: \(state.audioSessionCount))")
    }
}
