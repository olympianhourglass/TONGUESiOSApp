import Foundation
import FirebaseAuth
import FirebaseFirestore

// Persists the learner's saved grammatical + cultural insights, one doc
// per insight at users/{uid}/savedInsights/{id}. Small per-user list, so
// we fetch everything ordered by date and split by kind in memory (no
// composite index needed).
enum FirebaseSavedInsightService {
    private static let db = Firestore.firestore()

    private static func collection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("savedInsights")
    }

    // Saves (or overwrites) a single insight.
    static func save(_ insight: SavedInsight) async throws {
        let ref = try collection()
        try await ref.document(insight.id).setData(from: insight)
    }

    // Every saved insight, newest first.
    static func fetchAll(limit: Int = 300) async throws -> [SavedInsight] {
        let ref = try collection()
        let snapshot = try await ref
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: SavedInsight.self) }
    }

    static func delete(id: String) async throws {
        try await collection().document(id).delete()
    }
}
