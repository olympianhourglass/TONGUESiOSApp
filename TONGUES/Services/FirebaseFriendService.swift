import Foundation
import FirebaseAuth
import FirebaseFirestore

// Backend-only API for the friend-request flow. Persists each
// friendship as a single doc at `friendships/{compositeID}` (see
// `Friendship.compositeID`), keyed on the sorted pair of UIDs so:
//   • Both parties can find the same doc without a separate lookup.
//   • Permissions can be expressed as "must be in participants".
//   • No cross-user subcollection writes are required — A can update
//     a friendship doc that B will also read, without writing into
//     B's user document.
//
// Cost shape:
//   • Send / accept / decline / unfriend = 1 write each.
//   • Friend list read = 1 query (capped by `defaultLimit`).
//   • Per-pair status lookup = 1 doc read.
enum FirebaseFriendService {
    private static let db = Firestore.firestore()
    private static let collectionName = "friendships"
    private static let defaultLimit = 200

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

    // Sends a friend request to `targetUID`. No-op if a friendship doc
    // already exists for the pair (accepted or pending). Throws
    // `.notAuthenticated` if the caller isn't signed in.
    static func sendRequest(to targetUID: String) async throws {
        let me = try meUID()
        guard me != targetUID else { return }
        let id = Friendship.compositeID(uidA: me, uidB: targetUID)
        let ref = collection().document(id)
        let existing = try await ref.getDocument()
        if existing.exists { return }
        let friendship = Friendship(
            compositeID: id,
            participants: [me, targetUID].sorted(),
            initiatedBy: me,
            status: .pending,
            createdAt: Date()
        )
        try await ref.setData(from: friendship)
    }

    // Promotes a pending request from `fromUID` to accepted. Throws if
    // no pending doc exists or the doc isn't addressed to the caller.
    static func acceptRequest(from fromUID: String) async throws {
        let me = try meUID()
        let id = Friendship.compositeID(uidA: me, uidB: fromUID)
        let ref = collection().document(id)
        let snapshot = try await ref.getDocument()
        guard let existing = try? snapshot.data(as: Friendship.self) else {
            throw NSError(
                domain: "Friendship",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No pending request from that user."]
            )
        }
        guard existing.status == .pending, existing.initiatedBy == fromUID else {
            return
        }
        try await ref.updateData([
            "status": Friendship.Status.accepted.rawValue,
            "acceptedAt": Timestamp(date: Date())
        ])
    }

    // Declines an incoming request OR cancels an outgoing one OR
    // unfriends an accepted relation. Deletes the underlying doc in
    // all three cases — the action is the same; the relation just
    // ceases to exist.
    static func dissolve(with otherUID: String) async throws {
        let me = try meUID()
        let id = Friendship.compositeID(uidA: me, uidB: otherUID)
        try await collection().document(id).delete()
    }

    // MARK: - Queries

    // All accepted friendships involving the caller, ordered by most
    // recently accepted first.
    static func fetchFriends(limit: Int = defaultLimit) async throws -> [Friendship] {
        let me = try meUID()
        let snapshot = try await collection()
            .whereField("participants", arrayContains: me)
            .whereField("status", isEqualTo: Friendship.Status.accepted.rawValue)
            .order(by: "acceptedAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: Friendship.self) }
    }

    // Incoming requests = pending docs the caller is the *recipient*
    // of (initiatedBy != me).
    static func fetchIncomingRequests(limit: Int = defaultLimit) async throws -> [Friendship] {
        let me = try meUID()
        let snapshot = try await collection()
            .whereField("participants", arrayContains: me)
            .whereField("status", isEqualTo: Friendship.Status.pending.rawValue)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents
            .compactMap { try? $0.data(as: Friendship.self) }
            .filter { $0.initiatedBy != me }
    }

    // Outgoing requests = pending docs the caller initiated.
    static func fetchOutgoingRequests(limit: Int = defaultLimit) async throws -> [Friendship] {
        let me = try meUID()
        let snapshot = try await collection()
            .whereField("participants", arrayContains: me)
            .whereField("status", isEqualTo: Friendship.Status.pending.rawValue)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents
            .compactMap { try? $0.data(as: Friendship.self) }
            .filter { $0.initiatedBy == me }
    }

    // Per-pair status lookup. Useful for showing "Add friend" /
    // "Pending" / "Friends" on a profile card without scanning the
    // full list.
    static func relationship(with otherUID: String) async throws -> Friendship? {
        let me = try meUID()
        let id = Friendship.compositeID(uidA: me, uidB: otherUID)
        let snapshot = try await collection().document(id).getDocument()
        guard snapshot.exists else { return nil }
        return try? snapshot.data(as: Friendship.self)
    }
}
