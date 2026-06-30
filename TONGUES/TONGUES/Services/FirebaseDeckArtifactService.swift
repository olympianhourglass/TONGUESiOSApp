import FirebaseAuth
import FirebaseFirestore
import Foundation

// Per-deck "artifacts" subcollection — long-form items the user saved
// from a GenerateContentSheet result. Schema:
//
//   users/{uid}/decks/{deckId}/artifacts/{artifactId}
//
// Lives under the deck so security rules + ownership scoping piggyback
// on the existing decks rule (`request.auth.uid == uid`), matching how
// every other per-deck collection is stored.
enum FirebaseDeckArtifactService {
    private static let db = Firestore.firestore()

    private static func collection(forDeck deckId: String) throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw AuthError.notAuthenticated
        }
        return db.collection("users")
            .document(uid)
            .collection("decks")
            .document(deckId)
            .collection("artifacts")
    }

    @discardableResult
    static func save(_ artifact: Artifact) async throws -> String {
        // Cap check fires here (not at generate) so a user who
        // re-rolls content several times only pays the budget once,
        // when they actually decide to keep an artifact.
        await SubscriptionService.shared.refresh()
        try await SubscriptionService.shared.ensureCapacity(in: .artifacts, requested: 1)

        let coll = try collection(forDeck: artifact.deckId)
        // Auto-generated document ID — @DocumentID on Artifact is
        // stripped on write and populated on read by Firestore Codable,
        // so we never have to hand-manage the id round-trip.
        let ref = coll.document()
        try await ref.setData(from: artifact)
        await SubscriptionService.shared.consume(1, in: .artifacts)
        return ref.documentID
    }

    static func fetch(forDeck deckId: String) async throws -> [Artifact] {
        let coll = try collection(forDeck: deckId)
        let snap = try await coll
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return try snap.documents.compactMap { doc in
            try doc.data(as: Artifact.self)
        }
    }

    static func delete(_ artifact: Artifact) async throws {
        guard let id = artifact.id else { return }
        let coll = try collection(forDeck: artifact.deckId)
        try await coll.document(id).delete()
    }
}
