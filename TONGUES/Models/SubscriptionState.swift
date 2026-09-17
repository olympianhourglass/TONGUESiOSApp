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
    var tier: String = SubscriptionTier.locked.rawValue
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

    // Per-month ElevenLabs characters GENERATED on a cache miss — the only
    // thing that actually costs money, since cache hits are shared across all
    // users and free. A soft budget: when the tier's monthly allowance runs
    // out, native-voice TTS silently falls back to Apple's on-device voice
    // rather than blocking playback. Keyed by "yyyy-MM".
    var ttsCharsByMonthKey: [String: Int] = [:]

    // In-app promo-code grant. Set when a user redeems a code (e.g.
    // creators redeeming TONGUESVIP). Kept in SEPARATE fields from the
    // StoreKit-derived `tier` on purpose: StoreKitClient.syncEntitlements
    // rewrites `tier` on every launch and would otherwise wipe a promo
    // unlock. `resolvedTier` layers this over the StoreKit tier instead.
    var promoTier: String? = nil
    var promoExpiresAt: Date? = nil
    var promoCode: String? = nil
    var promoRedeemedAt: Date? = nil

    // RETENTION ("save offer") grant. Kept in its own fields rather than
    // reusing the promo ones so a save offer can never clobber a creator comp
    // — a user can legitimately hold both. Granted by RetentionService when
    // someone reaches the cancel flow, capped per account.
    var retentionTier: String? = nil
    var retentionExpiresAt: Date? = nil
    var retentionGrantedAt: Date? = nil
    var retentionGrantCount: Int = 0
    // When the user last opened the cancellation flow, and when they last
    // dismissed the win-back banner. Both are throttles: we ask once per
    // billing period, not on every visit to Settings.
    var cancellationIntentAt: Date? = nil
    var winBackDismissedAt: Date? = nil
    // Last known auto-renew state, so a flip to `false` can be detected as a
    // fresh cancellation rather than re-firing on every launch.
    var lastKnownWillAutoRenew: Bool? = nil

    // The tier from a still-valid retention grant, else `.locked`.
    var activeRetentionTier: SubscriptionTier {
        guard let raw = retentionTier,
              let granted = SubscriptionTier(rawValue: raw),
              let expiry = retentionExpiresAt,
              expiry > Date() else { return .locked }
        return granted
    }

    // The tier granted by a still-valid promo redemption, or `.locked` when
    // there's none / it has expired. Isolated here so the StoreKit sync
    // can never clobber a promo grant.
    var activePromoTier: SubscriptionTier {
        guard let raw = promoTier,
              let promo = SubscriptionTier(rawValue: raw),
              let expiry = promoExpiresAt,
              expiry > Date() else { return .locked }
        return promo
    }

    // The effective tier the whole app gates on: the highest (by rank) of the
    // StoreKit entitlement, any active promo grant, and any active retention
    // grant. Whichever gives the user the most access wins.
    var resolvedTier: SubscriptionTier {
        let base = SubscriptionTier(rawValue: tier) ?? .locked
        return [base, activePromoTier, activeRetentionTier]
            .max(by: { $0.rank < $1.rank }) ?? base
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
        case ttsCharsByMonthKey
        case promoTier
        case promoExpiresAt
        case promoCode
        case promoRedeemedAt
        case retentionTier
        case retentionExpiresAt
        case retentionGrantedAt
        case retentionGrantCount
        case cancellationIntentAt
        case winBackDismissedAt
        case lastKnownWillAutoRenew
    }

    init() {}

    // Defensive decoder mirroring UserXPState — every field via
    // decodeIfPresent with a default fallback so adding a new key
    // later never wipes existing docs on the next write.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tier                  = (try? c.decodeIfPresent(String.self, forKey: .tier)) ?? SubscriptionTier.locked.rawValue
        self.tierStartedAt         = try? c.decodeIfPresent(Date.self, forKey: .tierStartedAt)
        self.lastVerifiedAt        = try? c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        self.activeTransactionId   = try? c.decodeIfPresent(String.self, forKey: .activeTransactionId)
        self.activeProductId       = try? c.decodeIfPresent(String.self, forKey: .activeProductId)
        self.wordsByMonthKey         = (try? c.decodeIfPresent([String: Int].self, forKey: .wordsByMonthKey)) ?? [:]
        self.sentencesByMonthKey     = (try? c.decodeIfPresent([String: Int].self, forKey: .sentencesByMonthKey)) ?? [:]
        self.artifactsByMonthKey     = (try? c.decodeIfPresent([String: Int].self, forKey: .artifactsByMonthKey)) ?? [:]
        self.audioSessionsByMonthKey = (try? c.decodeIfPresent([String: Int].self, forKey: .audioSessionsByMonthKey)) ?? [:]
        self.ttsCharsByMonthKey      = (try? c.decodeIfPresent([String: Int].self, forKey: .ttsCharsByMonthKey)) ?? [:]
        self.promoTier               = try? c.decodeIfPresent(String.self, forKey: .promoTier)
        self.promoExpiresAt          = try? c.decodeIfPresent(Date.self, forKey: .promoExpiresAt)
        self.promoCode               = try? c.decodeIfPresent(String.self, forKey: .promoCode)
        self.promoRedeemedAt         = try? c.decodeIfPresent(Date.self, forKey: .promoRedeemedAt)
        self.retentionTier           = try? c.decodeIfPresent(String.self, forKey: .retentionTier)
        self.retentionExpiresAt      = try? c.decodeIfPresent(Date.self, forKey: .retentionExpiresAt)
        self.retentionGrantedAt      = try? c.decodeIfPresent(Date.self, forKey: .retentionGrantedAt)
        self.retentionGrantCount     = (try? c.decodeIfPresent(Int.self, forKey: .retentionGrantCount)) ?? 0
        self.cancellationIntentAt    = try? c.decodeIfPresent(Date.self, forKey: .cancellationIntentAt)
        self.winBackDismissedAt      = try? c.decodeIfPresent(Date.self, forKey: .winBackDismissedAt)
        self.lastKnownWillAutoRenew  = try? c.decodeIfPresent(Bool.self, forKey: .lastKnownWillAutoRenew)
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
