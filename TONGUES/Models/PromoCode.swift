import Foundation

// A redeemable in-app promo code that grants a subscription tier for a
// fixed window, bypassing StoreKit / App Store Connect entirely. On
// redemption the grant is written to the user's Firestore subscription
// doc (promoTier / promoExpiresAt) so it survives the StoreKit
// entitlement sync and follows the account across devices.
//
// Codes are defined here in the binary — validating a typed code is a
// local lookup, no network round-trip. To mint or retire codes, edit
// `all` and ship an app update. Matching is case-insensitive and
// whitespace-trimmed so "  tonguesvip " still resolves.
struct PromoCode {
    let code: String
    let tier: SubscriptionTier
    let durationDays: Int
    // Global cap on how many distinct accounts may redeem this code.
    // Enforced via a shared Firestore counter (see
    // SubscriptionService.redeemPromoCode); re-redeeming from the same
    // account is idempotent and never consumes an extra slot.
    let maxRedemptions: Int

    static let all: [PromoCode] = [
        // Creator comps: full Max access to explore every feature for a
        // year, each capped at 100 distinct accounts.
        PromoCode(code: "TONGUESVIP",     tier: .max, durationDays: 365, maxRedemptions: 100),
        PromoCode(code: "TONGUESCREATOR", tier: .max, durationDays: 365, maxRedemptions: 100)
    ]

    // Codes whose redeemers are permanently exempt from the Free tier's
    // one-time usage lockout. Even after the grant expires and the account
    // falls back to Free, these users (creator comps) are never forced into
    // the paywall by exhausting the one-off allowance — their Free usage
    // stays on the monthly-refreshing caps instead. Compared against the
    // last-redeemed code stored on the subscription doc (state.promoCode),
    // which persists past expiry.
    static let freeLockoutExemptCodes: Set<String> = ["TONGUESVIP", "TONGUESCREATOR"]

    // True when a previously-redeemed code grants permanent exemption from
    // the Free one-off lockout. Nil / unknown codes are not exempt.
    static func grantsFreeLockoutExemption(_ code: String?) -> Bool {
        guard let code else { return false }
        return freeLockoutExemptCodes.contains(code.uppercased())
    }

    // Resolves a user-typed string to a defined code, or nil if none match.
    // Strips ALL whitespace (not just the edges) and uppercases before
    // comparing, so codes shared with a space — "TONGUES VIP",
    // "TONGUES Creator" — still resolve to the space-free stored codes.
    static func match(_ input: String) -> PromoCode? {
        let normalized = input
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased()
        guard !normalized.isEmpty else { return nil }
        return all.first { $0.code.uppercased() == normalized }
    }
}

// Thrown by SubscriptionService.redeemPromoCode when the typed code
// doesn't match any defined promo code.
enum PromoRedemptionError: LocalizedError {
    case invalidCode
    case capReached

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "That code isn't valid. Check it and try again."
        case .capReached:
            return "This code has reached its redemption limit."
        }
    }
}
