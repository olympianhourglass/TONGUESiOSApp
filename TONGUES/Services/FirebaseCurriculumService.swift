import Foundation
import FirebaseAuth
import FirebaseFirestore

// Persistence for curriculum plans. One doc per language at
// `users/{uid}/curricula/{languageID}` so the Study tab and chat can
// both fetch "the plan for this language" with a single point read.
enum FirebaseCurriculumService {
    private static let db = Firestore.firestore()

    private static func collection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users").document(uid).collection("curricula")
    }

    static func fetch(languageID: String) async throws -> CurriculumPlan? {
        let snapshot = try await collection().document(languageID).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: CurriculumPlan.self)
    }

    /// Every plan the user has, across languages. Used by the Study tab
    /// to pick the most relevant Today strip when the user studies more
    /// than one language.
    static func fetchAll() async throws -> [CurriculumPlan] {
        let snapshot = try await collection().getDocuments()
        return snapshot.documents.compactMap {
            try? $0.data(as: CurriculumPlan.self)
        }
    }

    static func save(_ plan: CurriculumPlan) async throws {
        var stamped = plan
        stamped.updatedAt = Date()
        try await collection().document(plan.languageID).setData(from: stamped)
    }

    static func delete(languageID: String) async throws {
        try await collection().document(languageID).delete()
    }

    /// Clears the pending tutor notice after chat has surfaced it.
    static func clearTutorNotice(languageID: String) async throws {
        try await collection().document(languageID).updateData([
            "pendingTutorNotice": FieldValue.delete()
        ])
    }
}
