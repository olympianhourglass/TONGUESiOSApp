import Foundation
import FirebaseAuth
import FirebaseFirestore

struct DeckDocument: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    let title: String
    let language: String
    let dialect: String
    let level: String
    let contentType: String
    let amount: String
    let tones: [String]
    let interests: [String]
    let userPrompt: String
    let items: [GeneratedItem]
    let languages: [String]?
    // Raw value of `DeckCoverStyle`. Optional so existing Firestore docs
    // (saved before this field existed) decode cleanly; legacy decks fall
    // back to a stable random style via `resolvedCoverStyle`.
    let coverStyle: String?
    // FSRS target retention rate (0...1). Optional so existing docs decode;
    // resolved through `resolvedTargetRetention` (default 0.9).
    let targetRetention: Double?
    // Whether the deck owner has opted to make this deck visible to other
    // users (future browse-decks-by-other-people feature). Optional so legacy
    // docs decode; nil is treated as private.
    let isPublic: Bool?
    // Curriculum provenance. When the tutor agent generates a deck for a
    // plan unit, `planUnitId` carries that unit's id and `source` is
    // "agent"; user-created decks leave both nil (treated as "user").
    // Optional so every legacy doc decodes unchanged.
    let planUnitId: String?
    let source: String?
    let createdAt: Date

    init(
        id: String? = nil,
        title: String,
        language: String,
        dialect: String,
        level: String,
        contentType: String,
        amount: String,
        tones: [String],
        interests: [String],
        userPrompt: String,
        items: [GeneratedItem],
        languages: [String]? = nil,
        coverStyle: String? = nil,
        targetRetention: Double? = nil,
        isPublic: Bool? = nil,
        planUnitId: String? = nil,
        source: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.dialect = dialect
        self.level = level
        self.contentType = contentType
        self.amount = amount
        self.tones = tones
        self.interests = interests
        self.userPrompt = userPrompt
        self.items = items
        self.languages = languages
        self.coverStyle = coverStyle
        self.targetRetention = targetRetention
        self.isPublic = isPublic
        self.planUnitId = planUnitId
        self.source = source
        self.createdAt = createdAt
    }

    var allLanguages: [String] {
        languages ?? [language]
    }

    /// FSRS desired retention. Nil = use the global default (0.9). A higher
    /// value packs reviews closer together; lower spreads them out.
    var resolvedTargetRetention: Double {
        targetRetention ?? 0.9
    }
}

struct StudySession: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    let deckId: String
    let deckTitle: String
    let language: String
    let startedAt: Date
    let completedAt: Date
    let totalReviewed: Int
    let correctCount: Int
    let incorrectCount: Int
    let reviews: [CardReview]
}

/// FSRS schedule state for a single card. Doc id == `cardId` so we can read/write
/// per-card in O(1) and query "all due cards" with a single `nextReviewAt` range query.
///
/// `stability` and `difficulty` are the two FSRS state variables (memory half-life
/// in days and intrinsic hardness 1...10). Both are optional so SM-2-era documents
/// decode cleanly; they're seeded from `intervalDays` on the first FSRS review.
/// `easeFactor` and `repetitions` are SM-2 leftovers kept optional for back-compat
/// reads only — never set on new writes.
struct CardSchedule: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    let cardId: String
    let deckId: String
    let word: String
    let language: String
    var stability: Double?
    var difficulty: Double?
    var intervalDays: Int
    var lapses: Int
    var lastReviewedAt: Date
    var nextReviewAt: Date
    let createdAt: Date

    // Legacy SM-2 fields, read-only / nil on new writes.
    var easeFactor: Double?
    var repetitions: Int?
}

/// Firestore schema:
///
///   users/{uid}/decks/{deckId}              ← per-user private decks
///   users/{uid}/studySessions/{sessionId}   ← per-user flashcard session history (event log)
///   users/{uid}/cardSchedules/{cardId}      ← per-card SM-2 schedule state (current state)
///   wordInfos/{lang__word}                  ← global, shared word metadata cache
///
/// Decks live under the user so security rules can be `request.auth.uid == uid`
/// and queries stay scoped without a `where("ownerId", ==, uid)` filter.
/// Sessions are the source-of-truth event log (raw correct/incorrect events) — keep them
/// so we can replay/migrate when the scheduling algorithm changes (SM-2 → FSRS, etc.).
/// cardSchedules are the derived state used to answer "what's due now?" in a single query.
/// wordInfos stay top-level so 100 users learning 慢 only generate the metadata once.
enum FirebaseDeckService {
    private static let db = Firestore.firestore()
    private static let wordInfoCollection = "wordInfos"

    // MARK: - User-scoped deck collection

    private static func userDecks() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("decks")
    }

    static func saveDeck(
        _ deck: GeneratedDeck,
        title overrideTitle: String? = nil,
        coverStyle: String? = nil,
        isPublic: Bool = false,
        planUnitId: String? = nil,
        source: String? = nil
    ) async throws -> String {
        let collection = try userDecks()
        let now = Date()
        // Stamp `addedAt` on any items that don't already carry one so the
        // Statistics tab's "added this week/month" math has true per-item
        // timestamps instead of falling back to the deck's createdAt.
        let stampedItems = deck.items.map { item -> GeneratedItem in
            item.addedAt == nil ? item.withAddedAt(now) : item
        }
        let document = DeckDocument(
            title: overrideTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? deck.title,
            language: deck.language,
            dialect: deck.dialect,
            level: deck.level,
            contentType: deck.contentType,
            amount: deck.amount,
            tones: deck.tones,
            interests: deck.interests,
            userPrompt: deck.userPrompt,
            items: stampedItems,
            languages: [deck.language],
            coverStyle: coverStyle,
            isPublic: isPublic,
            planUnitId: planUnitId,
            source: source,
            createdAt: now
        )
        let ref = collection.document(deck.id.uuidString)
        try await ref.setData(from: document)

        // Fire-and-forget XP award. Failures are non-fatal — the deck
        // already saved, we just lose the toast for this generation.
        Task {
            do {
                let creationGrants = try await XPService.awardDeckCreation(
                    contentType: deck.contentType,
                    language: deck.language
                )
                let dailyGrants = try await XPService.awardDailyBonusIfNeeded()
                await MainActor.run {
                    XPToastCenter.shared.enqueue(creationGrants + dailyGrants)
                }
            } catch {
                print("XP award (deck creation) failed: \(error)")
            }
        }

        return ref.documentID
    }

    static func fetchDecks() async throws -> [DeckDocument] {
        let collection = try userDecks()
        let snapshot = try await collection
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return try snapshot.documents.compactMap { snapshot in
            try snapshot.data(as: DeckDocument.self).canonicalizingContentType()
        }
    }

    static func deleteDeck(id: String) async throws {
        let collection = try userDecks()
        try await collection.document(id).delete()
    }

    // Fetches decks marked `isPublic == true` across all users, filtered
    // to a set of languages the caller cares about (typically the
    // signed-in user's saved language preferences). Used by the Explore
    // tab's "Decks Others Have Made" row.
    //
    // Implementation note: this is a collection-group query across every
    // user's `decks` subcollection. Firestore needs a composite index
    // on (isPublic, language, createdAt desc) — set that up in the
    // console if the query starts failing in production. Security rules
    // must also allow read on documents where `isPublic == true`
    // regardless of ownership.
    //
    // `whereField(_:in:)` caps at 10 values, which fits comfortably
    // within the 5-language onboarding limit. We further drop the
    // signed-in user's own decks client-side so the row only surfaces
    // content other people made.
    static func fetchPublicDecks(
        languages: [String],
        limit: Int = 20
    ) async throws -> [DeckDocument] {
        guard !languages.isEmpty else { return [] }
        let capped = Array(languages.prefix(10))
        let snapshot = try await db.collectionGroup("decks")
            .whereField("isPublic", isEqualTo: true)
            .whereField("language", in: capped)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()

        let currentUID = Auth.auth().currentUser?.uid
        return snapshot.documents.compactMap { doc -> DeckDocument? in
            // Path is users/{uid}/decks/{deckId}; skip the caller's own
            // decks so this row never echoes their library back at them.
            let ownerUID = doc.reference.parent.parent?.documentID
            guard ownerUID != currentUID else { return nil }
            return (try? doc.data(as: DeckDocument.self))?.canonicalizingContentType()
        }
    }

    static func addItems(
        toDeck deckId: String,
        items newItems: [GeneratedItem],
        sourceLanguage: String
    ) async throws {
        let collection = try userDecks()
        let ref = collection.document(deckId)
        let snapshot = try await ref.getDocument()
        let existing = try snapshot.data(as: DeckDocument.self)

        let now = Date()
        // New items get their own `addedAt`, so a "generate more" run two
        // months after the deck was created shows up under "this week" in
        // the Statistics tab instead of inheriting the deck's createdAt.
        let stamped = newItems.map {
            $0.withLanguage(sourceLanguage).withAddedAt(now)
        }
        let combinedItems = existing.items + stamped
        let combinedLanguages = Set(existing.allLanguages + [sourceLanguage]).sorted()

        let updated = DeckDocument(
            id: existing.id,
            title: existing.title,
            language: existing.language,
            dialect: existing.dialect,
            level: existing.level,
            contentType: existing.contentType,
            amount: existing.amount,
            tones: existing.tones,
            interests: existing.interests,
            userPrompt: existing.userPrompt,
            items: combinedItems,
            languages: combinedLanguages,
            coverStyle: existing.coverStyle,
            targetRetention: existing.targetRetention,
            isPublic: existing.isPublic,
            planUnitId: existing.planUnitId,
            source: existing.source,
            createdAt: existing.createdAt
        )
        try await ref.setData(from: updated)
    }

    /// Replaces the entire `items` array of a deck. Used by the
    /// per-word "Add Synonyms / Plurals / Phrases" flow on the deck
    /// detail screen — the caller inserts the new items at the right
    /// position locally and persists the full ordering back, so the
    /// resulting deck reflects in-place insertion rather than the
    /// append-only behavior of `addItems`.
    static func replaceItems(
        inDeck deckId: String,
        items: [GeneratedItem]
    ) async throws {
        let collection = try userDecks()
        let ref = collection.document(deckId)
        let snapshot = try await ref.getDocument()
        let existing = try snapshot.data(as: DeckDocument.self)

        let combinedLanguages = Set(
            items.compactMap { $0.language }
            + existing.allLanguages
        ).sorted()

        let updated = DeckDocument(
            id: existing.id,
            title: existing.title,
            language: existing.language,
            dialect: existing.dialect,
            level: existing.level,
            contentType: existing.contentType,
            amount: existing.amount,
            tones: existing.tones,
            interests: existing.interests,
            userPrompt: existing.userPrompt,
            items: items,
            languages: combinedLanguages,
            coverStyle: existing.coverStyle,
            targetRetention: existing.targetRetention,
            isPublic: existing.isPublic,
            planUnitId: existing.planUnitId,
            source: existing.source,
            createdAt: existing.createdAt
        )
        try await ref.setData(from: updated)
    }

    /// Replaces a single item's `word` + `translation` inside an existing
    /// deck. Used by Sentence Studio's Save: the user iteratively rewrites
    /// one of the deck's sentences and persists the final version back to
    /// the same slot (same id, same `addedAt`, same surrounding items).
    /// Other fields (transliteration, language, kind, partsOfSpeech,
    /// addedAt) carry through unchanged.
    static func updateItem(
        inDeck deckId: String,
        itemId: UUID,
        word: String,
        translation: String
    ) async throws {
        let collection = try userDecks()
        let ref = collection.document(deckId)
        let snapshot = try await ref.getDocument()
        let existing = try snapshot.data(as: DeckDocument.self)

        let updatedItems: [GeneratedItem] = existing.items.map { item in
            guard item.id == itemId else { return item }
            var replacement = GeneratedItem(
                word: word,
                translation: translation,
                transliteration: item.transliteration,
                language: item.language,
                kind: item.kind,
                partsOfSpeech: item.partsOfSpeech,
                addedAt: item.addedAt
            )
            // `id` is `var` on GeneratedItem; preserve the original so
            // FSRS schedules, save-pinned references, and widget cards
            // all stay valid after the rewrite.
            replacement.id = item.id
            return replacement
        }

        let updated = DeckDocument(
            id: existing.id,
            title: existing.title,
            language: existing.language,
            dialect: existing.dialect,
            level: existing.level,
            contentType: existing.contentType,
            amount: existing.amount,
            tones: existing.tones,
            interests: existing.interests,
            userPrompt: existing.userPrompt,
            items: updatedItems,
            languages: existing.languages,
            coverStyle: existing.coverStyle,
            targetRetention: existing.targetRetention,
            isPublic: existing.isPublic,
            planUnitId: existing.planUnitId,
            source: existing.source,
            createdAt: existing.createdAt
        )
        try await ref.setData(from: updated)
    }

    // Removes a single item from a deck. Used by the deck detail list's
    // swipe-to-delete. Rewrites the doc with the item filtered out; the
    // deck's other fields are preserved verbatim.
    static func removeItem(inDeck deckId: String, itemId: UUID) async throws {
        let collection = try userDecks()
        let ref = collection.document(deckId)
        let snapshot = try await ref.getDocument()
        let existing = try snapshot.data(as: DeckDocument.self)

        let remaining = existing.items.filter { $0.id != itemId }
        // Nothing matched — no write needed.
        guard remaining.count != existing.items.count else { return }

        let updated = DeckDocument(
            id: existing.id,
            title: existing.title,
            language: existing.language,
            dialect: existing.dialect,
            level: existing.level,
            contentType: existing.contentType,
            amount: existing.amount,
            tones: existing.tones,
            interests: existing.interests,
            userPrompt: existing.userPrompt,
            items: remaining,
            languages: existing.languages,
            coverStyle: existing.coverStyle,
            targetRetention: existing.targetRetention,
            isPublic: existing.isPublic,
            planUnitId: existing.planUnitId,
            source: existing.source,
            createdAt: existing.createdAt
        )
        try await ref.setData(from: updated)
    }

    /// Updates only the FSRS target retention for a deck. Used by the deck
    /// detail view's retention adjuster — leaves everything else untouched.
    static func updateTargetRetention(deckId: String, retention: Double) async throws {
        let collection = try userDecks()
        try await collection.document(deckId).updateData([
            "targetRetention": retention
        ])
    }

    // Renames a deck. Public decks live in this same per-user collection
    // (surfaced via a collection-group query on `isPublic`), so updating
    // the single document changes the title everywhere it appears.
    static func renameDeck(deckId: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "FirebaseDeckService", code: 40,
                userInfo: [NSLocalizedDescriptionKey: "A deck needs a title."]
            )
        }
        let collection = try userDecks()
        try await collection.document(deckId).updateData([
            "title": trimmed
        ])
    }

    // MARK: - Study sessions

    private static func userStudySessions() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("studySessions")
    }

    static func saveStudySession(_ session: StudySession) async throws -> String {
        let collection = try userStudySessions()
        let ref = collection.document()
        try await ref.setData(from: session)
        return ref.documentID
    }

    static func fetchStudySessions(deckId: String? = nil) async throws -> [StudySession] {
        let collection = try userStudySessions()
        var query: Query = collection.order(by: "completedAt", descending: true)
        if let deckId {
            query = query.whereField("deckId", isEqualTo: deckId)
        }
        let snapshot = try await query.getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: StudySession.self) }
    }

    // MARK: - Card schedules (SM-2 state)

    private static func userCardSchedules() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("cardSchedules")
    }

    static func fetchAllSchedules() async throws -> [String: CardSchedule] {
        let collection = try userCardSchedules()
        let snapshot = try await collection.getDocuments()
        var map: [String: CardSchedule] = [:]
        for doc in snapshot.documents {
            map[doc.documentID] = try doc.data(as: CardSchedule.self)
        }
        return map
    }

    static func fetchSchedules(cardIds: [String]) async throws -> [String: CardSchedule] {
        guard !cardIds.isEmpty else { return [:] }
        let collection = try userCardSchedules()
        return try await withThrowingTaskGroup(of: (String, CardSchedule?).self) { group in
            for cardId in cardIds {
                group.addTask {
                    let snap = try await collection.document(cardId).getDocument()
                    guard snap.exists else { return (cardId, nil) }
                    return (cardId, try snap.data(as: CardSchedule.self))
                }
            }
            var result: [String: CardSchedule] = [:]
            for try await (cardId, schedule) in group {
                if let schedule { result[cardId] = schedule }
            }
            return result
        }
    }

    /// Reads existing schedules for every card touched in this session, applies the
    /// FSRS update in chronological order, and writes the new schedule docs in a single batch.
    static func applyReviews(
        _ reviews: [CardReview],
        deckId: String,
        targetRetention: Double
    ) async throws {
        guard !reviews.isEmpty else { return }
        let collection = try userCardSchedules()
        let uniqueCardIds = Array(Set(reviews.map { $0.cardId }))
        var working = try await fetchSchedules(cardIds: uniqueCardIds)

        for review in reviews.sorted(by: { $0.reviewedAt < $1.reviewedAt }) {
            working[review.cardId] = FSRSScheduler.apply(
                review: review,
                existing: working[review.cardId],
                deckId: deckId,
                targetRetention: targetRetention
            )
        }

        let batch = db.batch()
        for (cardId, schedule) in working {
            let ref = collection.document(cardId)
            try batch.setData(from: schedule, forDocument: ref)
        }
        try await batch.commit()
    }

    static func fetchDueSchedules(at date: Date = Date(), limit: Int? = nil) async throws -> [CardSchedule] {
        let collection = try userCardSchedules()
        var query: Query = collection
            .whereField("nextReviewAt", isLessThanOrEqualTo: date)
            .order(by: "nextReviewAt")
        if let limit { query = query.limit(to: limit) }
        let snapshot = try await query.getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: CardSchedule.self) }
    }

    // MARK: - Global word info cache

    private static func wordInfoDocId(word: String, language: String) -> String {
        let raw = "\(language)__\(word)"
        return raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "#", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "[", with: "_")
            .replacingOccurrences(of: "]", with: "_")
    }

    static func fetchWordInfo(word: String, language: String) async throws -> WordInfo? {
        let ref = db.collection(wordInfoCollection).document(wordInfoDocId(word: word, language: language))
        let snapshot = try await ref.getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: WordInfo.self)
    }

    static func saveWordInfo(_ info: WordInfo, word: String, language: String) async throws {
        let ref = db.collection(wordInfoCollection).document(wordInfoDocId(word: word, language: language))
        try await ref.setData(from: info)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
