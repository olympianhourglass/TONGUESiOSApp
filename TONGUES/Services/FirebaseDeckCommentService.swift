import Foundation
import FirebaseAuth
import FirebaseFirestore

// Top-level `deckComments` collection. Each comment has a UUID id; the
// `deckId` is a queryable field so listing comments for a deck is a
// single indexed query. Author display name is denormalized at write
// time so renderings don't fan out to a per-comment profile fetch.
//
// Lightweight by design — no thread replies, no reactions, no edit
// history. If those are needed later, they grow as new fields on the
// existing doc or as subcollections; the current shape doesn't
// preclude them.
enum FirebaseDeckCommentService {
    private static let db = Firestore.firestore()
    private static let collectionName = "deckComments"
    private static let defaultListLimit = 100
    // Stay under Firestore's 1MB doc cap by a healthy margin while
    // still allowing room for a thoughtful paragraph.
    private static let bodyCharacterCap = 4_000

    private static func collection() -> CollectionReference {
        db.collection(collectionName)
    }

    private static func meUID() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return uid
    }

    // MARK: - Mutations

    // Posts a new comment authored by the caller. Returns the saved
    // doc so the UI can append it locally without re-querying. Throws
    // on empty bodies or unauthenticated callers.
    @discardableResult
    static func post(
        deckId: String,
        body: String,
        authorDisplayName: String? = nil
    ) async throws -> DeckComment {
        let me = try meUID()
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "DeckComment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Comment can't be empty."]
            )
        }
        let capped = String(trimmed.prefix(bodyCharacterCap))
        let comment = DeckComment(
            id: UUID().uuidString,
            deckId: deckId,
            authorUID: me,
            authorDisplayName: authorDisplayName,
            body: capped,
            createdAt: Date(),
            editedAt: nil
        )
        try await collection().document(comment.id).setData(from: comment)
        return comment
    }

    // Replaces the body of an existing comment. Author-only — the
    // service throws if the caller isn't the original poster, so the
    // future security rule can mirror that check server-side.
    static func edit(commentID: String, newBody: String) async throws {
        let me = try meUID()
        let trimmed = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "DeckComment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Comment can't be empty."]
            )
        }
        let capped = String(trimmed.prefix(bodyCharacterCap))
        let ref = collection().document(commentID)
        let snapshot = try await ref.getDocument()
        guard let existing = try? snapshot.data(as: DeckComment.self) else {
            throw NSError(
                domain: "DeckComment",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Comment not found."]
            )
        }
        guard existing.authorUID == me else {
            throw NSError(
                domain: "DeckComment",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "You can only edit your own comments."]
            )
        }
        try await ref.updateData([
            "body": capped,
            "editedAt": Timestamp(date: Date())
        ])
    }

    // Deletes a comment. Author-only on the service side; mirror on
    // the rule when locking down.
    static func delete(commentID: String) async throws {
        let me = try meUID()
        let ref = collection().document(commentID)
        let snapshot = try await ref.getDocument()
        guard let existing = try? snapshot.data(as: DeckComment.self) else {
            return
        }
        guard existing.authorUID == me else {
            throw NSError(
                domain: "DeckComment",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "You can only delete your own comments."]
            )
        }
        try await ref.delete()
    }

    // MARK: - Reads

    // Comments on a deck, newest first. Bounded by `limit` so a deck
    // with a runaway thread never reads more than the UI can render.
    static func fetch(
        forDeck deckId: String,
        limit: Int = defaultListLimit
    ) async throws -> [DeckComment] {
        let snapshot = try await collection()
            .whereField("deckId", isEqualTo: deckId)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: DeckComment.self) }
    }
}
