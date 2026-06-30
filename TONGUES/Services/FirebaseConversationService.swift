import Foundation
import FirebaseAuth
import FirebaseFirestore

// Per-thread persistence for the conversation tab. One Firestore doc
// per chat at `users/{uid}/conversations/{conversation.id}` (the id is
// a UUID generated client-side, so reads and writes go to a known
// path without an extra round trip).
//
// Cost / efficiency notes:
//   • Messages embed in the doc — a single read returns the whole
//     thread. Firestore charges per doc, not per byte, so an embedded
//     model is cheaper than a subcollection for chat-sized workloads.
//   • The history list query uses `whereField("languageID", isEqualTo:
//     ...)` with `.order(by: "updatedAt", desc).limit(50)` so the
//     menu can render without scanning the user's entire archive.
//   • The doc is trimmed to `messageWindowCap` before every write to
//     keep the payload bounded even on long-running threads.
//   • Persistence is gated by the caller — we only write when there
//     IS a message to save, so an empty "new chat" never costs a
//     write.
enum FirebaseConversationService {
    private static let db = Firestore.firestore()
    // Trim to the most recent N messages on write. Keeps doc size
    // predictable; truncation is asymmetric so older entries fall off
    // first.
    private static let messageWindowCap = 400
    // Default cap on history-list queries. The UI shows a chronological
    // strip; older chats fade off the bottom.
    private static let defaultListLimit = 50

    private static func conversationsCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("conversations")
    }

    // Load a single thread by id. Returns nil when the doc doesn't
    // exist yet (e.g. a brand-new chat that hasn't been persisted).
    static func fetch(id: String) async throws -> Conversation? {
        let collection = try conversationsCollection()
        let snapshot = try await collection.document(id).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: Conversation.self)
    }

    // Lists the user's threads for a given language, newest first.
    // Bounded by `limit` so the history sheet never pulls more than it
    // can render in one screenful + scroll.
    //
    // The query intentionally avoids combining `whereField(languageID)`
    // with `order(by: updatedAt)` — that combination requires a
    // composite Firestore index, and a missing index produces a
    // `failed-precondition` error that previously caused the history
    // sheet to silently appear empty. Equality-only on a single field
    // is auto-indexed, so we fetch the language's docs unsorted and
    // sort + cap client-side.
    static func list(
        languageID: String,
        limit: Int = defaultListLimit
    ) async throws -> [Conversation] {
        let collection = try conversationsCollection()
        let query = collection
            .whereField("languageID", isEqualTo: languageID)
        let snapshot = try await query.getDocuments()
        let decoded = snapshot.documents.compactMap { doc -> Conversation? in
            do {
                return try doc.data(as: Conversation.self)
            } catch {
                print("[Chat] Conversation decode failed for \(doc.documentID): \(error)")
                return nil
            }
        }
        return Array(
            decoded
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }

    // Lists every conversation the signed-in user has, across all
    // languages, newest first. Used by the chat-history sheet so the
    // user sees one unified timeline of past chats rather than a
    // per-language slice. Sorted + capped client-side to avoid
    // composite-index requirements.
    static func listAll(
        limit: Int = defaultListLimit
    ) async throws -> [Conversation] {
        let collection = try conversationsCollection()
        let snapshot = try await collection.getDocuments()
        let decoded = snapshot.documents.compactMap { doc -> Conversation? in
            do {
                return try doc.data(as: Conversation.self)
            } catch {
                print("[Chat] Conversation decode failed for \(doc.documentID): \(error)")
                return nil
            }
        }
        return Array(
            decoded
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }

    // Persists a conversation. Trims to the trailing window before
    // writing so older messages don't bloat the doc over time.
    static func save(_ conversation: Conversation) async throws {
        let collection = try conversationsCollection()
        var trimmed = conversation
        if trimmed.messages.count > messageWindowCap {
            trimmed.messages = Array(
                trimmed.messages.suffix(messageWindowCap)
            )
        }
        trimmed.updatedAt = Date()
        try await collection.document(trimmed.id).setData(from: trimmed)
    }

    // Removes a single thread. Used by swipe-to-delete + the overflow
    // "Clear conversation" action.
    static func delete(id: String) async throws {
        let collection = try conversationsCollection()
        try await collection.document(id).delete()
    }
}
