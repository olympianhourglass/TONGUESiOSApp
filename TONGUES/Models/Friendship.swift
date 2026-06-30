import Foundation

// One friendship doc. Stored at `friendships/{compositeID}` where
// `compositeID` is the two UIDs sorted lexicographically and joined by
// "_". This shape gives us:
//   • Stable, idempotent doc id — `sendFriendRequest(to:)` can always
//     compute the same id without first checking whether one exists.
//   • Symmetric reads — both parties query the same doc.
//   • Trivial Firestore rules — allow create/read/update/delete only
//     when `request.auth.uid in resource.data.participants` and (on
//     create) when `request.auth.uid in request.resource.data.participants`.
//
// `status` walks `pending → accepted`. Cancel / decline / unfriend
// just delete the doc.
struct Friendship: Codable, Identifiable, Hashable {
    var id: String { compositeID }
    let compositeID: String
    let participants: [String]   // Exactly two UIDs, sorted lexicographically.
    let initiatedBy: String      // UID that sent the original request.
    let status: Status
    let createdAt: Date
    var acceptedAt: Date?

    enum Status: String, Codable, Hashable {
        case pending
        case accepted
    }

    init(
        compositeID: String,
        participants: [String],
        initiatedBy: String,
        status: Status,
        createdAt: Date,
        acceptedAt: Date? = nil
    ) {
        self.compositeID = compositeID
        self.participants = participants
        self.initiatedBy = initiatedBy
        self.status = status
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
    }

    // The OTHER party to this friendship, from a viewer's perspective.
    // Useful when rendering "your friend" rows / request inboxes.
    func otherParty(from viewer: String) -> String? {
        participants.first(where: { $0 != viewer })
    }

    // Stable composite id from two UIDs. Sort guarantees both parties
    // compute the same value regardless of who calls.
    static func compositeID(uidA: String, uidB: String) -> String {
        [uidA, uidB].sorted().joined(separator: "_")
    }
}
