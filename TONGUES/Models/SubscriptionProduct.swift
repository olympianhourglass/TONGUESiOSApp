import Foundation

// Billing cadence for a subscription purchase. The paywall lets the
// user toggle between monthly and yearly per tier; both map to
// distinct App Store Connect products living in the same subscription
// group so users can crossgrade between cadences/tiers.
enum SubscriptionBillingCycle: String, CaseIterable, Hashable {
    case monthly
    case yearly

    var label: String {
        switch self {
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }
}

// App Store Connect product configuration. Six auto-renewing
// subscriptions (3 tiers × 2 cadences) live in a single subscription
// group so the user can crossgrade in the system Manage Subscriptions
// sheet. Update these constants if Connect IDs change — every other
// file in the codebase references them through `SubscriptionProduct`.
enum SubscriptionProduct {
    // Subscription group reference name in App Store Connect.
    static let subscriptionGroupId = "22192397"

    static let beginnerMonthly = "com.tongues.subscription.beginner.monthly"
    static let proMonthly      = "com.tongues.subscription.pro.monthly"
    static let maxMonthly      = "com.tongues.subscription.max.monthly"

    static let beginnerYearly  = "com.tongues.subscription.beginner.yearly"
    static let proYearly       = "com.tongues.subscription.pro.yearly"
    static let maxYearly       = "com.tongues.subscription.max.yearly"

    static let allIds: [String] = [
        beginnerMonthly, proMonthly, maxMonthly,
        beginnerYearly,  proYearly,  maxYearly
    ]

    // Walks both directions of the product ↔ tier mapping. Returns the
    // tier regardless of cadence — the caller is usually deciding
    // entitlement, not pricing display. Centralized here so
    // StoreKitClient never has to hand-match strings.
    static func tier(forProductId id: String) -> SubscriptionTier? {
        switch id {
        case beginnerMonthly, beginnerYearly: return .beginner
        case proMonthly,      proYearly:      return .pro
        case maxMonthly,      maxYearly:      return .max
        default:                              return nil
        }
    }

    // Cadence look-up so the paywall can show the matching `Product`
    // for the user's currently-selected billing toggle.
    static func cycle(forProductId id: String) -> SubscriptionBillingCycle? {
        switch id {
        case beginnerMonthly, proMonthly, maxMonthly: return .monthly
        case beginnerYearly,  proYearly,  maxYearly:  return .yearly
        default:                                      return nil
        }
    }

    static func productId(
        forTier tier: SubscriptionTier,
        cycle: SubscriptionBillingCycle = .monthly
    ) -> String? {
        switch (tier, cycle) {
        case (.free, _):                return nil
        case (.beginner, .monthly):     return beginnerMonthly
        case (.beginner, .yearly):      return beginnerYearly
        case (.pro, .monthly):          return proMonthly
        case (.pro, .yearly):           return proYearly
        case (.max, .monthly):          return maxMonthly
        case (.max, .yearly):           return maxYearly
        }
    }
}
