import Foundation
import FirebaseAuth
import FirebaseFirestore

// Top-level `deckRatings` collection keyed by `{deckId}_{raterUID}`.
// Flat structure avoids cross-user subcollection writes (any
// authenticated user can rate any deck if Firestore rules allow it)
// and keeps the per-user "your rating on this deck" lookup to a single
// doc id.
//
// Aggregation strategy: compute on read. Each call to `aggregate`
// queries every rating doc for the deck and averages them client-side.
// Fine while deck.ratings.count stays small (sub-thousand). When that
// stops being true, promote `averageValue` + `count` to denormalized
// fields on the parent deck doc and maintain via Cloud Function on
// every rating write.
enum FirebaseDeckRatingService {
    private static let db = Firestore.firestore()
    private static let collectionName = "deckRatings"
    private static let aggregateReadLimit = 500

    private static func collection() -> CollectionReference {
        db.collection(collectionName)
    }

    private static func meUID() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return uid
    }

    private static func docID(deckId: String, raterUID: String) -> String {
        "\(deckId)_\(raterUID)"
    }

    // MARK: - Mutations

    // Sets the caller's rating on `deckId`. Clamps to [1, 5]. Creates
    // a new doc on first rating; subsequent calls update the existing
    // one (same composite id).
    static func setRating(deckId: String, value: Int) async throws {
        let me = try meUID()
        let clamped = max(1, min(5, value))
        let now = Date()
        let id = docID(deckId: deckId, raterUID: me)
        let snapshot = try await collection().document(id).getDocument()
        let rating: DeckRating
        if let existing = try? snapshot.data(as: DeckRating.self) {
            rating = DeckRating(
                deckId: existing.deckId,
                raterUID: existing.raterUID,
                value: clamped,
                createdAt: existing.createdAt,
                updatedAt: now
            )
        } else {
            rating = DeckRating(
                deckId: deckId,
                raterUID: me,
                value: clamped,
                createdAt: now,
                updatedAt: now
            )
        }
        try await collection().document(id).setData(from: rating)
    }

    // Removes the caller's rating on `deckId`. No-op if they hadn't
    // rated.
    static func removeRating(deckId: String) async throws {
        let me = try meUID()
        let id = docID(deckId: deckId, raterUID: me)
        try await collection().document(id).delete()
    }

    // MARK: - Reads

    // The caller's existing rating value on `deckId`, or nil if they
    // haven't rated.
    static func myRating(deckId: String) async throws -> Int? {
        let me = try meUID()
        let id = docID(deckId: deckId, raterUID: me)
        let snapshot = try await collection().document(id).getDocument()
        return (try? snapshot.data(as: DeckRating.self))?.value
    }

    // All ratings on a deck, newest first. Bounded by `aggregateReadLimit`
    // so a runaway deck doesn't read thousands of docs.
    static func ratings(forDeck deckId: String) async throws -> [DeckRating] {
        let snapshot = try await collection()
            .whereField("deckId", isEqualTo: deckId)
            .order(by: "updatedAt", descending: true)
            .limit(to: aggregateReadLimit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: DeckRating.self) }
    }

    // Per-deck aggregate, computed by querying every rating doc and
    // averaging client-side. Cheap while ratings stay bounded.
    static func aggregate(deckId: String) async throws -> DeckRatingAggregate {
        let all = try await ratings(forDeck: deckId)
        guard !all.isEmpty else {
            return DeckRatingAggregate(deckId: deckId, averageValue: 0, count: 0)
        }
        let total = all.reduce(0) { $0 + $1.value }
        let average = Double(total) / Double(all.count)
        return DeckRatingAggregate(
            deckId: deckId,
            averageValue: average,
            count: all.count
        )
    }
}
