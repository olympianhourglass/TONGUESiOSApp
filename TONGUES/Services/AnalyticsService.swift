import Foundation
import SwiftUI
import FirebaseAnalytics
import FirebaseAuth

// Single funnel for every analytics event in the app.
//
// Nothing outside this file imports FirebaseAnalytics. Views and services
// call `AnalyticsService.log(.some_event, [...])`, which means:
//   • Event names + params live in one auditable place (no typo'd string
//     literals scattered across 40 call sites, and no accidental drift
//     between two spellings of the same event).
//   • Swapping or dual-writing to another platform (Amplitude, PostHog,
//     RevenueCat) is a change to `dispatch(_:_:)` alone.
//   • GA4's hard limits are enforced centrally rather than hoped for.
//
// GA4 constraints this file guarantees (silently dropped otherwise):
//   • Event name ≤ 40 chars, starts with a letter, no reserved prefix.
//   • ≤ 25 params per event; param name ≤ 40 chars; string value ≤ 100.
//   • User property name ≤ 24 chars, value ≤ 36 chars, ≤ 25 per project.
//
// IMPORTANT: never log user content. No deck words, chat text, prompts,
// emails, or display names — those live in Firestore. Analytics records
// SHAPE (which feature, how much, which tier), never substance. The
// `sanitize` step below is the backstop, not the policy.
enum AnalyticsService {

    // MARK: - Events

    // Snake_case, ≤40 chars. Grouped by funnel so the taxonomy stays
    // legible as it grows. Avoid GA4 reserved names (first_open,
    // session_start, app_open, screen_view are auto-collected).
    enum Event: String {
        // Onboarding funnel — the install → activated user path.
        case onboardingStarted          = "onboarding_started"
        case onboardingLanguageSelected = "onboarding_language_selected"
        case onboardingQuestionAnswered = "onboarding_question_answered"
        case onboardingSignInStarted    = "onboarding_signin_started"
        case onboardingSignInCompleted  = "onboarding_signin_completed"
        case onboardingSignInFailed     = "onboarding_signin_failed"
        case onboardingSlideViewed      = "onboarding_slide_viewed"
        case onboardingSlideshowDone    = "onboarding_slideshow_done"
        case onboardingCompleted        = "onboarding_completed"
        case starterDecksSeedStarted    = "starter_decks_seed_started"
        case starterDecksSeedFinished   = "starter_decks_seed_finished"

        // Monetization — the number that matters now the paywall is hard.
        case paywallViewed              = "paywall_viewed"
        case paywallTierSelected        = "paywall_tier_selected"
        case paywallCycleSelected       = "paywall_cycle_selected"
        case paywallDismissed           = "paywall_dismissed"
        case paywallLockShown           = "paywall_lock_shown"
        case trialStarted               = "trial_started"
        case purchaseCompleted          = "purchase_completed"
        case purchaseCancelled          = "purchase_cancelled"
        case purchaseFailed             = "purchase_failed"
        case restoreAttempted           = "restore_attempted"
        case restoreSucceeded           = "restore_succeeded"
        case promoCodeRedeemed          = "promo_code_redeemed"
        case manageSubscriptionOpened   = "manage_subscription_opened"
        case subscriptionCapHit         = "subscription_cap_hit"

        // Navigation / feature share.
        case tabSelected                = "tab_selected"

        // Deck creation.
        case deckGenerationStarted      = "deck_generation_started"
        case deckGenerationFailed       = "deck_generation_failed"
        case deckCreated                = "deck_created"

        // Study (flashcards).
        case studySessionStarted        = "study_session_started"
        case studySessionCompleted      = "study_session_completed"
        case reviewModeUsed             = "review_mode_used"
        case handwritingPracticed       = "handwriting_practiced"

        // Audio / listening.
        case audioSessionStarted        = "audio_session_started"
        case audioSessionEnded          = "audio_session_ended"
        case audioMiniplayerAction      = "audio_miniplayer_action"

        // Artifacts (long-form generated content).
        case artifactGenerated          = "artifact_generated"
        case artifactGenerationFailed   = "artifact_generation_failed"
        case artifactSaved              = "artifact_saved"
        case artifactOpened             = "artifact_opened"
        case artifactReadAloud          = "artifact_read_aloud"
        case comprehensionAnswered      = "comprehension_answered"

        // Vocabulary capture — the core "I learned a word" loop.
        case wordInspected              = "word_inspected"
        case wordAddedToDeck            = "word_added_to_deck"

        // Chat / conversation practice.
        case chatMessageSent            = "chat_message_sent"
        case chatLanguageSwitched       = "chat_language_switched"

        // Retention / churn funnel. `subscriptionCancelDetected` is the one
        // that matters most: it fires from the renewal-state read, so it
        // catches the majority who cancel in iOS Settings and never open our
        // cancel flow at all.
        case cancelFlowOpened           = "cancel_flow_opened"
        case cancelReasonGiven          = "cancel_reason_given"
        case cancelContinued            = "cancel_continued"
        case saveOfferShown             = "save_offer_shown"
        case saveOfferAccepted          = "save_offer_accepted"
        case saveOfferDeclined          = "save_offer_declined"
        case downgradeOffered           = "downgrade_offered"
        case downgradeAccepted          = "downgrade_accepted"
        case subscriptionCancelDetected = "subscription_cancel_detected"
        case subscriptionResumed        = "subscription_resumed"
        case winBackBannerShown         = "winback_banner_shown"
        case winBackBannerDismissed     = "winback_banner_dismissed"
        case winBackOfferShown          = "winback_offer_shown"
        case winBackOfferAccepted       = "winback_offer_accepted"

        // Review + feedback loop. `reviewPromptAnswered` carries the sentiment,
        // so the split between happy and unhappy users is measurable — and so
        // is whether the unhappy ones actually follow through to feedback.
        case reviewPromptShown          = "review_prompt_shown"
        case reviewPromptAnswered       = "review_prompt_answered"
        // Fired when a would-be prompt was held back by a recent failure, and
        // when such a failure armed that suppression. Together they show how
        // often a bad experience saved us from soliciting a 1-star review.
        case reviewPromptSuppressed     = "review_prompt_suppressed"
        case reviewPromptSuppressionArmed = "review_suppression_armed"
        case appStoreReviewRequested    = "appstore_review_requested"
        case feedbackOpened             = "feedback_opened"
        case feedbackSubmitted          = "feedback_submitted"

        // Account lifecycle.
        case accountSignedOut           = "account_signed_out"
        case accountDeleted             = "account_deleted"
    }

    // MARK: - Params

    // Param keys. Kept as an enum for the same reason as events: one
    // spelling, discoverable at the call site.
    enum Param: String {
        case source
        case tier
        case cycle
        case price
        case trialEligible      = "trial_eligible"
        case isTrial            = "is_trial"
        case reason
        case method
        case isNewUser          = "is_new_user"
        case index
        case questionId         = "question_id"
        case language
        case dialect
        case level
        case appLanguage        = "app_language"
        case contentType        = "content_type"
        case itemCount          = "item_count"
        case deckId             = "deck_id"
        case tab
        case mode
        case modes
        case durationSeconds    = "duration_seconds"
        case cardsGraded        = "cards_graded"
        case correctCount       = "correct_count"
        case accuracy
        case completed
        case fullDeck           = "full_deck"
        case cardsAdvanced      = "cards_advanced"
        case ambientSound       = "ambient_sound"
        case ambientMusic       = "ambient_music"
        case theme
        case action
        case flavor
        case kind
        case wasCached          = "was_cached"
        case bucket
        case remaining
        case script
        case isCorrect          = "is_correct"
        case turnIndex          = "turn_index"
        case tone
        case count
        case planned
        case succeeded
        case code
        case sentiment
        case characters
    }

    // MARK: - User properties

    // GA4 caps names at 24 chars and values at 36, and allows 25 per
    // project. Numeric properties are BUCKETED — raw counts would explode
    // cardinality and make the segments useless.
    enum UserProperty: String {
        case tier             = "tier"
        case isInTrial        = "is_in_trial"
        case nativeLanguage   = "native_language"
        case targetLanguage   = "target_language"
        case learnerLevel     = "learner_level"
        case appLanguage      = "app_language"
        case deckCount        = "deck_count_bucket"
        case streak           = "streak_bucket"
        case daysSinceInstall = "days_install_bucket"
        case cohortWeek       = "cohort_week"
    }

    // MARK: - Opt-out

    private static let optOutKey = "analyticsOptOut"

    // Honors a user-level opt-out. Flipping this also tells the Firebase SDK
    // to stop collecting entirely, so the automatic events (sessions,
    // screen views) stop too — not just our custom ones.
    static var isOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: optOutKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: optOutKey)
            Analytics.setAnalyticsCollectionEnabled(!newValue)
        }
    }

    // MARK: - Lifecycle

    // Called once from TONGUESApp after FirebaseApp.configure(). Applies the
    // stored opt-out and stamps the install date used for the
    // days-since-install cohorting below.
    static func start() {
        Analytics.setAnalyticsCollectionEnabled(!isOptedOut)
        _ = installDate   // stamps on first launch
    }

    private static let installDateKey = "analyticsInstallDate"

    private static var installDate: Date {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: installDateKey) as? Date {
            return stored
        }
        let now = Date()
        defaults.set(now, forKey: installDateKey)
        return now
    }

    // MARK: - Logging

    static func log(_ event: Event, _ params: [Param: Any] = [:]) {
        guard !isOptedOut else { return }
        dispatch(event.rawValue, sanitize(params))
    }

    // Firebase's own screen_view, so GA4's screen reports work. Views call
    // `.trackScreen("Study")` (see the View extension at the bottom).
    static func logScreen(_ name: String) {
        guard !isOptedOut else { return }
        dispatch(
            AnalyticsEventScreenView,
            [AnalyticsParameterScreenName: truncate(name, to: 100)]
        )
    }

    // The single write point. Swap or fan out to another SDK here.
    private static func dispatch(_ name: String, _ params: [String: Any]) {
        #if DEBUG
        print("📊 \(name) \(params.isEmpty ? "" : "\(params)")")
        #endif
        Analytics.logEvent(name, parameters: params.isEmpty ? nil : params)
    }

    // Enforces GA4's limits and strips anything that looks like PII. String
    // values are truncated to 100 chars; anything resembling an email is
    // dropped outright rather than hashed, because we have no reason to
    // correlate on it.
    private static func sanitize(_ params: [Param: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in params {
            guard out.count < 25 else { break }
            switch value {
            case let string as String:
                guard !looksLikeEmail(string) else { continue }
                out[key.rawValue] = truncate(string, to: 100)
            case let bool as Bool:
                // GA4 has no boolean type; 1/0 keeps it usable in BigQuery
                // and readable in the console.
                out[key.rawValue] = bool ? 1 : 0
            case let int as Int:
                out[key.rawValue] = int
            case let double as Double:
                out[key.rawValue] = double
            case let convertible as CustomStringConvertible:
                let described = convertible.description
                guard !looksLikeEmail(described) else { continue }
                out[key.rawValue] = truncate(described, to: 100)
            default:
                continue
            }
        }
        return out
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        value.contains("@") && value.contains(".")
    }

    private static func truncate(_ value: String, to limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit))
    }

    // MARK: - User properties

    // Re-stamps every segmentation property. Cheap, idempotent, and safe to
    // call on launch, after auth, after a purchase, and after the deck list
    // loads — each of those can change a property's value.
    @MainActor
    static func refreshUserProperties(
        deckCount: Int? = nil,
        streak: Int? = nil,
        profile: UserProfile? = nil
    ) {
        guard !isOptedOut else { return }

        // Keying events to the Firebase uid lets us stitch a user's path
        // together across sessions and devices. It's an opaque id, not PII.
        Analytics.setUserID(Auth.auth().currentUser?.uid)

        let subscription = SubscriptionService.shared
        set(.tier, subscription.currentTier.rawValue)
        set(.isInTrial, StoreKitClient.shared.isInTrial ? "true" : "false")
        set(.appLanguage, Localizer.shared.language.rawValue)

        if let primary = profile?.onboarding?.languagePreferences?.first {
            set(.targetLanguage, primary.language)
            set(.learnerLevel, primary.level)
        }
        if let native = profile?.interfaceLanguage {
            set(.nativeLanguage, native)
        }
        if let deckCount {
            set(.deckCount, bucket(deckCount, thresholds: [0, 1, 3, 6, 21]))
        }
        if let streak {
            set(.streak, bucket(streak, thresholds: [0, 1, 3, 7, 30]))
        }

        let days = Calendar.current.dateComponents(
            [.day],
            from: installDate,
            to: Date()
        ).day ?? 0
        set(.daysSinceInstall, bucket(days, thresholds: [0, 1, 2, 8, 31]))
        set(.cohortWeek, Self.cohortFormatter.string(from: installDate))
    }

    private static func set(_ property: UserProperty, _ value: String?) {
        Analytics.setUserProperty(
            value.map { truncate($0, to: 36) },
            forName: property.rawValue
        )
    }

    // Collapses a count into a low-cardinality band ("0", "1-2", "3-5",
    // "6-20", "21+"). Keeps segments meaningful and values inside GA4's
    // 36-char ceiling.
    private static func bucket(_ value: Int, thresholds: [Int]) -> String {
        let sorted = thresholds.sorted()
        guard let last = sorted.last else { return "\(value)" }
        if value >= last { return "\(last)+" }
        for (index, lower) in sorted.enumerated() {
            let upper = index + 1 < sorted.count ? sorted[index + 1] : last
            if value >= lower && value < upper {
                let top = upper - 1
                return lower == top ? "\(lower)" : "\(lower)-\(top)"
            }
        }
        return "\(value)"
    }

    // ISO week of install — the cohort axis for retention curves.
    private static let cohortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "YYYY-'W'ww"
        return f
    }()
}

// Declarative screen tracking: `.trackScreen("Study")` on any view root.
extension View {
    func trackScreen(_ name: String) -> some View {
        onAppear { AnalyticsService.logScreen(name) }
    }
}
