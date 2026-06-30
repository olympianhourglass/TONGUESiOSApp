import Foundation
import FirebaseAuth
import FirebaseFirestore

// Persists pronunciation drill attempts so the user can see
// improvement on the same target sentence across sessions, and so the
// Statistics surface can later chart per-language progress.
//
// One doc per attempt at `users/{uid}/pronunciationAttempts/{id}`.
// Each doc carries the target, transcript, score, coaching tip, and
// per-word grades — no audio (the temp .caf file lives only for the
// session's replay). Embedded `grade` keeps reads single-doc.
//
// Read pattern:
//   • `recent(languageID:limit:)` for the drill sheet's "past
//     attempts on this phrase" strip — bounded.
//   • `recent(languageID:limit:)` returns ALL attempts in the language
//     ordered by date; callers can filter to a specific target in
//     memory. The list is small (caller passes limit:20) so the in-memory
//     filter is fine and avoids the composite-index requirement of
//     filtering by `target` server-side.
enum FirebasePronunciationService {
    private static let db = Firestore.firestore()
    private static let defaultLimit = 50

    private static func collection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("pronunciationAttempts")
    }

    // Saves a single attempt. Failures bubble to the caller; the drill
    // sheet logs them but doesn't block the user.
    static func save(_ attempt: PronunciationAttempt) async throws {
        let ref = try collection()
        try await ref.document(attempt.id).setData(from: attempt)
    }

    // Loads recent attempts for a language, newest first. Bounded by
    // `limit` (default 50). Callers can filter further in memory.
    static func recent(
        languageID: String,
        limit: Int = defaultLimit
    ) async throws -> [PronunciationAttempt] {
        let ref = try collection()
        let query = ref
            .whereField("languageID", isEqualTo: languageID)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap {
            try? $0.data(as: PronunciationAttempt.self)
        }
    }

    static func delete(id: String) async throws {
        let ref = try collection()
        try await ref.document(id).delete()
    }
}
