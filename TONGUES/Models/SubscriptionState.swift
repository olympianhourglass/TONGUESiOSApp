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

    // In-app promo-code grant. Set when a user redeems a code (e.g.
    // creators redeeming TONGUESVIP). Kept in SEPARATE fields from the
    // StoreKit-derived `tier` on purpose: StoreKitClient.syncEntitlements
    // rewrites `tier` on every launch and would otherwise wipe a promo
    // unlock. `resolvedTier` layers this over the StoreKit tier instead.
    var promoTier: String? = nil
    var promoExpiresAt: Date? = nil
    var promoCode: String? = nil
    var promoRedeemedAt: Date? = nil

    // The tier granted by a still-valid promo redemption, or `.free` when
    // there's none / it has expired. Isolated here so the StoreKit sync
    // can never clobber a promo grant.
    var activePromoTier: SubscriptionTier {
        guard let raw = promoTier,
              let promo = SubscriptionTier(rawValue: raw),
              let expiry = promoExpiresAt,
              expiry > Date() else { return .free }
        return promo
    }

    // The effective tier the whole app gates on: the higher (by rank) of
    // the StoreKit entitlement and any active promo grant. A paid
    // subscription always wins over a lower promo, and vice versa.
    var resolvedTier: SubscriptionTier {
        let base = SubscriptionTier(rawValue: tier) ?? .free
        let promo = activePromoTier
        return promo.rank > base.rank ? promo : base
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
        case promoTier
        case promoExpiresAt
        case promoCode
        case promoRedeemedAt
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
        self.promoTier               = try? c.decodeIfPresent(String.self, forKey: .promoTier)
        self.promoExpiresAt          = try? c.decodeIfPresent(Date.self, forKey: .promoExpiresAt)
        self.promoCode               = try? c.decodeIfPresent(String.self, forKey: .promoCode)
        self.promoRedeemedAt         = try? c.decodeIfPresent(Date.self, forKey: .promoRedeemedAt)
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
