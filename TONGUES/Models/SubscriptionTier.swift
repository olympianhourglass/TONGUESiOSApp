import Foundation

// Subscription tiers. `free` is the implicit baseline for users who
// haven't purchased anything; the three paid tiers map 1:1 to the
// App Store Connect products declared in SubscriptionProduct.swift.
//
// Caps are enforced per calendar month — see SubscriptionService for
// the yyyy-MM keying. "Sentences" includes Phrases per product spec;
// Words is its own bucket; Artifacts (saved long-form content) is the
// third bucket.
enum SubscriptionTier: String, Codable, CaseIterable, Hashable {
    case free
    case beginner
    case pro
    case max

    // Short tab label on the paywall + the noun the cap-error copy
    // uses when referring to a user's plan ("Standard plans support
    // up to 3 saved languages"). Kept short so the three tabs fit on
    // one row even at smaller screen widths.
    var displayName: String {
        switch self {
        case .free:     return "Free"
        case .beginner: return "Standard"
        case .pro:      return "Pro"
        case .max:      return "Max"
        }
    }

    // Editorial headline displayed on the tier card. More flavor than
    // `displayName` — sets the audience for the plan ("Just Exploring",
    // "The Daily Learner", "Polyglots & Power Users") and matches the
    // copy in the Figma paywall design.
    var headline: String {
        switch self {
        case .free:     return "Just Visiting"
        case .beginner: return "Just Exploring"
        case .pro:      return "The Daily Learner"
        case .max:      return "Polyglots & Power Users"
        }
    }

    var tagline: String {
        switch self {
        case .free:     return "Sign up to start generating."
        case .beginner: return "Just enough to get a feel."
        case .pro:      return "Steady weekly study."
        case .max:      return "Generate without thinking about it."
        }
    }

    // Monthly cap of individual word entries the user is allowed to
    // generate across every deck. Counts toward `wordsByMonthKey`.
    var monthlyWords: Int {
        switch self {
        case .free:     return 0
        case .beginner: return 200
        case .pro:      return 1_000
        case .max:      return 5_000
        }
    }

    // Monthly cap covering both Sentences and Phrases content types
    // (the Phrases bucket shares the Sentences counter per spec).
    var monthlySentences: Int {
        switch self {
        case .free:     return 0
        case .beginner: return 10
        case .pro:      return 600
        case .max:      return 3_000
        }
    }

    // Monthly cap of saved long-form artifacts (Story / Conversation /
    // News / Song / Poem / Joke). Counted at save, not at generate, so
    // users can re-roll without burning the budget.
    var monthlyArtifacts: Int {
        switch self {
        case .free:     return 0
        case .beginner: return 1
        case .pro:      return 5
        case .max:      return 200
        }
    }

    // Monthly cap of listen sessions (the ListenSessionView audio
    // playback). Pro + Max are effectively unlimited via Int.max so
    // the cap check arithmetic stays uniform with the other buckets.
    var monthlyAudioSessions: Int {
        switch self {
        case .free:     return 0
        case .beginner: return 50
        case .pro:      return Int.max
        case .max:      return Int.max
        }
    }

    // Total cap on saved languages on the user's profile (NOT monthly —
    // a snapshot count). Beginner keeps the 3-language ceiling; Pro
    // raises it to 5; Max removes it. Free reuses the Beginner cap so a
    // brand-new onboarding user can complete language selection without
    // paying.
    var maxLanguages: Int {
        switch self {
        case .free:     return 3
        case .beginner: return 3
        case .pro:      return 5
        case .max:      return Int.max
        }
    }

    // Display fallback when the StoreKit `Product` hasn't loaded yet
    // (offline, App Store Connect products still propagating, preview
    // canvases, etc.). Real prices come from `Product.displayPrice` at
    // runtime — these are the App Store Connect-side values so the
    // sheet never shows "—". Yearly values are the *per-month*
    // equivalent (yearly_total / 12) so the paywall can display both
    // cadences in the same "$X / month" format.
    func fallbackPrice(for cycle: SubscriptionBillingCycle) -> String {
        switch (self, cycle) {
        case (.free, _):                return "Free"
        case (.beginner, .monthly):     return "$8.99"
        case (.beginner, .yearly):      return "$6.99"
        case (.pro, .monthly):          return "$14.99"
        case (.pro, .yearly):           return "$12.99"
        case (.max, .monthly):          return "$29.99"
        case (.max, .yearly):           return "$24.99"
        }
    }

    var fallbackPrice: String { fallbackPrice(for: .monthly) }

    // Length of the introductory free trial offered on every paid
    // tier. Mirrors the `introductoryOffer` block configured in
    // TONGUES.storekit (and, eventually, in App Store Connect — the
    // local config is just for debug builds).
    //
    // The CTA copy on the paywall + the onboarding free-trial tease
    // both read from here, so changing the number in one place
    // propagates everywhere automatically.
    var freeTrialDays: Int {
        switch self {
        case .free:                       return 0
        case .beginner, .pro, .max:       return 1
        }
    }

    // Compact human label used in CTAs ("Start 1-Day Free Trial",
    // "Start 7-Day Free Trial", …). Pluralisation handled here so
    // call sites just interpolate the string.
    var freeTrialLabel: String {
        let n = freeTrialDays
        return n == 1 ? "1-Day" : "\(n)-Day"
    }

    // Ranking used to pick the "highest" entitlement when the user has
    // overlapping StoreKit transactions (e.g. mid-upgrade). Higher
    // value wins.
    var rank: Int {
        switch self {
        case .free:     return 0
        case .beginner: return 1
        case .pro:      return 2
        case .max:      return 3
        }
    }

    // Anthropic model the deck generator should use for this tier.
    // The paid ladder reflects the price ladder as a quality ladder:
    // • Standard (Just Exploring) → Sonnet (balanced quality)
    // • Pro                       → Sonnet (balanced)
    // • Max                       → Opus (highest quality)
    // Free reuses Haiku for the rare path where a deck generation
    // somehow reaches the API before a cap check (it never should, but
    // the cheapest model keeps the blast radius small).
    var generationModel: String {
        switch self {
        case .free:            return "claude-haiku-4-5-20251001"
        case .beginner, .pro:  return "claude-sonnet-4-6"
        case .max:             return "claude-opus-4-7"
        }
    }

    // Short label rendered on the PremiumActionSheet tier cards so
    // the user can see the model upgrade is part of the value prop.
    var generationModelLabel: String {
        switch self {
        case .free:            return "Haiku"
        case .beginner, .pro:  return "Sonnet"
        case .max:             return "Opus"
        }
    }
}

// The resource buckets the cap system tracks. Drives error messages,
// the "X of Y used this month" rows on PremiumActionSheet, and the
// Firestore field name on the state doc.
enum SubscriptionBucket: String, Hashable {
    case words
    case sentences
    case artifacts
    case audioSessions

    var label: String {
        switch self {
        case .words:         return "words"
        case .sentences:     return "sentences"
        case .artifacts:     return "artifacts"
        case .audioSessions: return "audio sessions"
        }
    }

    var titleLabel: String {
        switch self {
        case .words:         return "Words"
        case .sentences:     return "Sentences"
        case .artifacts:     return "Artifacts"
        case .audioSessions: return "Audio sessions"
        }
    }

    func cap(for tier: SubscriptionTier) -> Int {
        switch self {
        case .words:         return tier.monthlyWords
        case .sentences:     return tier.monthlySentences
        case .artifacts:     return tier.monthlyArtifacts
        case .audioSessions: return tier.monthlyAudioSessions
        }
    }
}

// Surfaced by DeckGenerator / FirebaseDeckArtifactService / the
// audio + language entry points when an action would push the user
// over their tier's cap. Call sites catch this, present the cap
// alert + paywall, and let the user upgrade in place.
enum SubscriptionError: LocalizedError {
    case capExceeded(bucket: SubscriptionBucket, tier: SubscriptionTier, remaining: Int, requested: Int)
    case languageCapExceeded(tier: SubscriptionTier, max: Int)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .capExceeded(let bucket, let tier, let remaining, _):
            if remaining <= 0 {
                return "You've used all of your \(tier.displayName) \(bucket.label) for this month."
            }
            return "Only \(remaining) \(bucket.label) left on \(tier.displayName) this month."
        case .languageCapExceeded(let tier, let max):
            return "\(tier.displayName) plans support up to \(max) saved languages. Upgrade to add more."
        case .notAuthenticated:
            return "Sign in to keep generating."
        }
    }
}
