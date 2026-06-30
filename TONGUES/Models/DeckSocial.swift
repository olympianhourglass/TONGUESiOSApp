import Foundation

// MARK: - Deck rating

// One user's rating on one deck. Stored at
// `deckRatings/{deckId}_{raterUID}` so each (deck, rater) pair owns a
// stable doc id; re-rating is a setData merge on the same path. We
// keep `deckId` + `raterUID` as fields too so `whereField` queries
// can index either side.
struct DeckRating: Codable, Identifiable, Hashable {
    var id: String { "\(deckId)_\(raterUID)" }
    let deckId: String
    let raterUID: String
    let value: Int           // 1–5, clamped on write.
    let createdAt: Date
    var updatedAt: Date
}

// Aggregate result from `FirebaseDeckRatingService.aggregate(deckId:)`.
// Computed on read by averaging every rating doc that matches the
// deck id. Cheap as long as decks don't accumulate thousands of
// ratings — once they do we'd promote this to a Cloud Function that
// maintains a denormalized field on the deck doc.
struct DeckRatingAggregate: Hashable {
    let deckId: String
    let averageValue: Double
    let count: Int

    // Rounded 1-decimal value for display ("4.3 ★"). Returns 0.0 for
    // unrated decks.
    var roundedAverage: Double {
        (averageValue * 10).rounded() / 10
    }
}

// MARK: - Deck comment

// One free-form comment on a deck. Stored at `deckComments/{id}`
// where `id` is a UUID. Author info is denormalized onto the doc at
// write time so listing comments doesn't require a per-comment user
// fetch — the author's profile changing later won't retroactively
// update the comment's displayed name, but that's acceptable for the
// kind of light social copy this powers (a stale display name on an
// old comment is recoverable).
struct DeckComment: Codable, Identifiable, Hashable {
    let id: String
    let deckId: String
    let authorUID: String
    var authorDisplayName: String?
    var body: String
    let createdAt: Date
    var editedAt: Date?
}
