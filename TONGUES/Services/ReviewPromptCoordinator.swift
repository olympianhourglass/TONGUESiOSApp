import Foundation
import Observation

// Decides WHEN to ask "how's it going?" — the sentiment gate that routes happy
// users to Apple's rating sheet and unhappy ones to the feedback composer.
//
// WHY THIS IS CENTRAL
//     Ask-for-review logic goes wrong in two predictable ways: asking too
//     early (on a weak signal, so the answer is meaningless), and asking right
//     after something broke (which converts a bug into a 1-star review). Both
//     failure modes are about TIMING, not UI — so the timing lives here, in one
//     place, rather than being duplicated at each trigger site.
//
//     Apple additionally throttles `requestReview()` to roughly three prompts
//     per user per year and may silently ignore a call. We therefore get very
//     few shots; spending one on a user who just hit a generation failure is
//     pure waste.
@MainActor
@Observable
final class ReviewPromptCoordinator {
    static let shared = ReviewPromptCoordinator()
    private init() {}

    // What earned the ask. Logged with the prompt so it's possible to compare
    // sentiment by trigger — i.e. whether a 3-day streak really does produce
    // happier answers than a first deck.
    enum Trigger: String {
        case firstDeck = "first_deck"
        case threeDayStreak = "three_day_streak"
    }

    // MARK: - Tunables

    // A streak this long means the habit stuck — the strongest positive signal
    // this app has.
    static let streakThreshold = 3

    // How long a failure suppresses the ask. A day is enough to get past the
    // immediate frustration without losing the window entirely.
    private static let suppressionHours = 24

    // MARK: - Persistence
    //
    // Deliberately UserDefaults, not Firestore: this is device-local UI
    // pacing, it must work offline and before auth resolves, and re-asking
    // once on a new device is harmless (Apple's own throttle is the real
    // backstop).

    // Latched the first time we ask, ever. The whole point of a sentiment gate
    // is that it's a one-shot — asking repeatedly is what makes prompts feel
    // like nagging.
    private static let askedKey = "reviewPromptAskedEver"
    // Timestamp of the last thing that went wrong for this user.
    private static let badExperienceKey = "reviewPromptLastBadExperience"

    private(set) var hasAskedEver: Bool = UserDefaults.standard.bool(forKey: askedKey)

    // MARK: - Eligibility

    // True when a recent failure should hold the ask back.
    var isSuppressed: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.badExperienceKey) as? Date,
              let expiry = Calendar.current.date(
                  byAdding: .hour, value: Self.suppressionHours, to: last
              ) else { return false }
        return expiry > Date()
    }

    // The single gate every trigger calls. Returns true at most once per
    // install, and never while suppressed. Latches immediately on success so
    // two triggers firing in the same session can't double-prompt.
    func shouldAsk(for trigger: Trigger) -> Bool {
        guard !hasAskedEver else { return false }
        guard !isSuppressed else {
            AnalyticsService.log(.reviewPromptSuppressed, [
                .source: trigger.rawValue,
                .reason: "recent_bad_experience"
            ])
            return false
        }
        // Only a subscriber sees the app at all, but be explicit: never ask
        // someone who is currently locked out behind the paywall.
        guard SubscriptionService.shared.hasAccess else { return false }

        hasAskedEver = true
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        return true
    }

    // Convenience for the streak trigger.
    func shouldAskForStreak(_ streak: Int) -> Bool {
        guard streak >= Self.streakThreshold else { return false }
        return shouldAsk(for: .threeDayStreak)
    }

    // MARK: - Suppression

    // Call from any failure the user actually felt: a failed generation, a
    // failed purchase, a cap they ran into. Cheap, idempotent, and it protects
    // one of the very few review prompts Apple will let us spend.
    func noteBadExperience(_ what: String) {
        UserDefaults.standard.set(Date(), forKey: Self.badExperienceKey)
        AnalyticsService.log(.reviewPromptSuppressionArmed, [.reason: what])
    }

    // Clears the suppression window. Nothing calls this today; it exists so a
    // future "we fixed it for you" moment can re-open the window deliberately
    // rather than by waiting.
    func clearSuppression() {
        UserDefaults.standard.removeObject(forKey: Self.badExperienceKey)
    }
}
