import Foundation

// Persistent subscription state for a user. Stored at
// users/{uid}/subscription/state — one doc per user, matching the
// XPService pattern. Holds both the current entitlement (mirrored from
// StoreKit by StoreKitClient) and the per-month usage counters that
// drive cap enforcement.
//
// All three usage maps are keyed by yyyy-MM (user-local calendar
// month). Old months stay in the doc — they're cheap and useful for a
// future "your year in TONGUES" surface.
struct UserSubscriptionState: Codable, Hashable {
    var tier: String = SubscriptionTier.free.rawValue
    var tierStartedAt: Date? = nil
    var lastVerifiedAt: Date? = nil
    // StoreKit Transaction.id (UInt64) stringified. Stored so a
    // re-application of the same transaction is a no-op.
    var activeTransactionId: String? = nil
    var activeProductId: String? = nil

    // Per-month usage. Keyed by "yyyy-MM".
    var wordsByMonthKey: [String: Int] = [:]
    var sentencesByMonthKey: [String: Int] = [:]   // includes Phrases
    var artifactsByMonthKey: [String: Int] = [:]
    var audioSessionsByMonthKey: [String: Int] = [:]

    // One-time free-deck grace: a brand-new (free) user gets to generate
    // and save a single deck before the paywall appears. Flipped true the
    // first time they save a deck. Lifetime flag, not monthly.
    var freeDeckUsed: Bool = false

    var resolvedTier: SubscriptionTier {
        SubscriptionTier(rawValue: tier) ?? .free
    }

    enum CodingKeys: String, CodingKey {
        case tier
        case tierStartedAt
        case lastVerifiedAt
        case activeTransactionId
        case activeProductId
        case wordsByMonthKey
        case sentencesByMonthKey
        case artifactsByMonthKey
        case audioSessionsByMonthKey
        case freeDeckUsed
    }

    init() {}

    // Defensive decoder mirroring UserXPState — every field via
    // decodeIfPresent with a default fallback so adding a new key
    // later never wipes existing docs on the next write.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tier                  = (try? c.decodeIfPresent(String.self, forKey: .tier)) ?? SubscriptionTier.free.rawValue
        self.tierStartedAt         = try? c.decodeIfPresent(Date.self, forKey: .tierStartedAt)
        self.lastVerifiedAt        = try? c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        self.activeTransactionId   = try? c.decodeIfPresent(String.self, forKey: .activeTransactionId)
        self.activeProductId       = try? c.decodeIfPresent(String.self, forKey: .activeProductId)
        self.wordsByMonthKey         = (try? c.decodeIfPresent([String: Int].self, forKey: .wordsByMonthKey)) ?? [:]
        self.sentencesByMonthKey     = (try? c.decodeIfPresent([String: Int].self, forKey: .sentencesByMonthKey)) ?? [:]
        self.artifactsByMonthKey     = (try? c.decodeIfPresent([String: Int].self, forKey: .artifactsByMonthKey)) ?? [:]
        self.audioSessionsByMonthKey = (try? c.decodeIfPresent([String: Int].self, forKey: .audioSessionsByMonthKey)) ?? [:]
        self.freeDeckUsed            = (try? c.decodeIfPresent(Bool.self, forKey: .freeDeckUsed)) ?? false
    }

    // Returns the count consumed in the given bucket for the supplied
    // month key. Convenience helper used by the cap check + the UI's
    // "X of Y used this month" rows.
    func usage(in bucket: SubscriptionBucket, monthKey: String) -> Int {
        switch bucket {
        case .words:         return wordsByMonthKey[monthKey, default: 0]
        case .sentences:     return sentencesByMonthKey[monthKey, default: 0]
        case .artifacts:     return artifactsByMonthKey[monthKey, default: 0]
        case .audioSessions: return audioSessionsByMonthKey[monthKey, default: 0]
        }
    }
}
