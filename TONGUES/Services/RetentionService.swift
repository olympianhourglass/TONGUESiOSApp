import Foundation
import StoreKit
import FirebaseAuth
import FirebaseFirestore
import Observation

// Churn detection + save offers.
//
// THE CONSTRAINT THIS IS BUILT AROUND
//     Apple owns cancellation; an app can neither block nor intercept it.
//     That leaves exactly two windows, and this service covers both:
//
//     1. INTENT — the user taps our own "Manage subscription" row. We can show
//        one honest interstitial first (CancellationFlowSheet). Only catches
//        people who cancel through our UI.
//     2. GRACE — `willAutoRenew` has flipped to false but the paid period
//        hasn't ended. Catches EVERYONE, including the majority who cancel
//        from iOS Settings and never touch our UI. This is the valuable one.
//
//     Once the period actually lapses, Apple's own Win-Back Offers take over
//     (configured in App Store Connect, surfaced by the App Store itself).
//     `eligibleWinBackOfferIDs` below is how we merchandise those in-app.
//
// ETHICAL LINE
//     Nothing here obstructs cancelling. The interstitial always shows a
//     full-weight "Continue to cancel", the banner is dismissible and stays
//     dismissed, and every prompt is capped so it can't become nagging.
//     Obstructing cancellation is both a guideline problem and a bad deal for
//     the user, which tends to come back as 1-star reviews anyway.
@MainActor
@Observable
final class RetentionService {
    static let shared = RetentionService()
    private init() {}

    // MARK: - Persistence
    //
    // Retention fields are written straight to the same subscription doc that
    // SubscriptionService owns (users/{uid}/subscription/state), then that
    // service is refreshed so `resolvedTier` picks the grant up. Writing here
    // rather than adding mutators to SubscriptionService keeps this feature
    // self-contained — its `state` is `private(set)`, so a cross-file mutator
    // would have to live in that file, and there's no need to touch it.

    private static func stateDoc() -> DocumentReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return Firestore.firestore()
            .collection("users").document(uid)
            .collection("subscription").document("state")
    }

    // Merges the given fields into the subscription doc and reloads the
    // service so the UI reflects them immediately. Returns false when the
    // write failed, so a caller never reports success the user didn't get.
    @discardableResult
    private func patchState(_ fields: [String: Any]) async -> Bool {
        guard let doc = Self.stateDoc() else { return false }
        do {
            try await doc.setData(fields, merge: true)
            await SubscriptionService.shared.refresh()
            return true
        } catch {
            print("RetentionService.patchState failed: \(error)")
            return false
        }
    }

    // MARK: - Tunables

    // Days of continued access granted by the in-house save offer, and the
    // lifetime cap on how many times one account can take it. The cap is what
    // stops the offer becoming a permanent free ride.
    static let saveOfferDays = 14
    static let maxSaveOffersPerAccount = 1

    // Don't re-show the banner for this long after a dismissal.
    private static let bannerSnoozeDays = 3

    // MARK: - Observable churn state

    // Nil = unknown (not yet read, or no subscription). False = a cancellation
    // is pending: still entitled, but it won't renew.
    private(set) var willAutoRenew: Bool?
    private(set) var expiresAt: Date?
    // Win-back offer IDs this Apple ID is eligible for, best first, straight
    // from StoreKit. Non-empty only once the subscription has actually lapsed.
    private(set) var eligibleWinBackOfferIDs: [String] = []

    // A cancellation is pending but access hasn't lapsed yet — the grace
    // window where a save is still possible.
    var isCancellationPending: Bool {
        willAutoRenew == false && SubscriptionService.shared.hasAccess
    }

    // Whether to show the win-back banner right now: a pending cancellation,
    // not snoozed, and no save grant already running (don't re-pitch someone
    // who just accepted one).
    var shouldShowWinBackBanner: Bool {
        guard isCancellationPending else { return false }
        let state = SubscriptionService.shared.state
        if state.activeRetentionTier.grantsAccess { return false }
        if let dismissed = state.winBackDismissedAt,
           let deadline = Calendar.current.date(
               byAdding: .day, value: Self.bannerSnoozeDays, to: dismissed
           ),
           deadline > Date() {
            return false
        }
        return true
    }

    // Whether the in-house save offer can still be given.
    var isSaveOfferAvailable: Bool {
        let state = SubscriptionService.shared.state
        guard state.retentionGrantCount < Self.maxSaveOffersPerAccount else { return false }
        // Pointless to "extend" access the user doesn't currently have.
        return SubscriptionService.shared.hasAccess
    }

    // Days remaining on the current paid period, for the banner's copy.
    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
        return days.map { Swift.max(0, $0) }
    }

    // MARK: - Detection

    // Reads the subscription group's renewal state. Called on launch, after
    // every entitlement sync, and when Settings appears — so a cancellation
    // made in iOS Settings is noticed the next time the app is foregrounded.
    func refreshRenewalState() async {
        guard let product = StoreKitClient.shared.products.values.first,
              let subscription = product.subscription,
              let statuses = try? await subscription.status else {
            willAutoRenew = nil
            expiresAt = nil
            eligibleWinBackOfferIDs = []
            return
        }

        var renews: Bool?
        var expiry: Date?
        var winBackIDs: [String] = []

        for status in statuses {
            guard case .verified(let renewalInfo) = status.renewalInfo,
                  case .verified(let transaction) = status.transaction else { continue }
            // Win-back eligibility is reported regardless of active state; it's
            // only ever non-empty once the subscription has lapsed.
            if !renewalInfo.eligibleWinBackOfferIDs.isEmpty {
                winBackIDs = renewalInfo.eligibleWinBackOfferIDs
            }
            guard status.state == .subscribed || status.state == .inGracePeriod else { continue }
            renews = renewalInfo.willAutoRenew
            expiry = transaction.expirationDate
        }

        willAutoRenew = renews
        expiresAt = expiry
        eligibleWinBackOfferIDs = winBackIDs

        await recordAutoRenewTransition(to: renews)
    }

    // Logs the moment auto-renew flips off, exactly once, so churn shows up in
    // analytics even when the user cancelled from iOS Settings and we never
    // saw the intent.
    private func recordAutoRenewTransition(to renews: Bool?) async {
        guard let renews else { return }
        let service = SubscriptionService.shared
        let previous = service.state.lastKnownWillAutoRenew
        guard previous != renews else { return }

        if previous == true || previous == nil, renews == false {
            AnalyticsService.log(.subscriptionCancelDetected, [
                .tier: service.currentTier.rawValue,
                .source: "renewal_state"
            ])
        } else if previous == false, renews == true {
            AnalyticsService.log(.subscriptionResumed, [
                .tier: service.currentTier.rawValue
            ])
        }
        await patchState(["lastKnownWillAutoRenew": renews])
    }

    // MARK: - Save offer (in-house grant)

    // Extends access for `saveOfferDays` at the user's CURRENT tier, without
    // involving StoreKit at all. The user's App Store cancellation still
    // stands — we're adding on top of it, not reversing it, which keeps this
    // honest: they remain cancelled and simply keep access a while longer.
    @discardableResult
    func grantSaveOffer(reason: CancellationReason?) async -> Bool {
        guard isSaveOfferAvailable else { return false }
        let tier = SubscriptionService.shared.currentTier
        guard tier.grantsAccess else { return false }

        // Stack from the later of now and any existing retention expiry, so a
        // second grant can never shorten the first.
        let now = Date()
        let existing = SubscriptionService.shared.state.retentionExpiresAt ?? now
        let base = Swift.max(now, existing)
        guard let expiry = Calendar.current.date(
            byAdding: .day, value: Self.saveOfferDays, to: base
        ) else { return false }

        let granted = await patchState([
            "retentionTier": tier.rawValue,
            "retentionExpiresAt": Timestamp(date: expiry),
            "retentionGrantedAt": Timestamp(date: now),
            "retentionGrantCount": SubscriptionService.shared.state.retentionGrantCount + 1
        ])
        guard granted else { return false }

        AnalyticsService.log(.saveOfferAccepted, [
            .tier: tier.rawValue,
            .count: Self.saveOfferDays,
            .reason: reason?.rawValue ?? "unspecified"
        ])
        return true
    }

    // MARK: - Apple win-back offers

    // Resolves the best eligible win-back offer for a product, pairing the IDs
    // from renewal info with the offer details on the product. Returns nil
    // when nothing is configured in App Store Connect or the user isn't
    // eligible — every caller must degrade gracefully, because this stays
    // empty until those offers are actually set up.
    func bestWinBackOffer(
        for tier: SubscriptionTier,
        cycle: SubscriptionBillingCycle = .monthly
    ) -> (product: Product, offer: Product.SubscriptionOffer)? {
        guard !eligibleWinBackOfferIDs.isEmpty,
              let product = StoreKitClient.shared.product(for: tier, cycle: cycle),
              let subscription = product.subscription else { return nil }

        // eligibleWinBackOfferIDs is ordered best-first by the App Store, so
        // the first match wins.
        for id in eligibleWinBackOfferIDs {
            if let offer = subscription.winBackOffers.first(where: { $0.id == id }) {
                return (product, offer)
            }
        }
        return nil
    }

    // Buys a subscription with a win-back offer applied.
    func purchaseWinBack(
        product: Product,
        offer: Product.SubscriptionOffer
    ) async -> Bool {
        AnalyticsService.log(.winBackOfferAccepted, [.source: "in_app"])
        let success = await StoreKitClient.shared.purchase(
            product: product,
            winBackOffer: offer
        )
        if success { await refreshRenewalState() }
        return success
    }

    // MARK: - Exit survey

    // Records why someone left, in a top-level `cancellations` collection so
    // it's triageable in the Firebase console alongside `feedback`. Fire and
    // forget: never block the cancel flow on a write.
    func recordCancellation(reason: CancellationReason, note: String? = nil) async {
        AnalyticsService.log(.cancelReasonGiven, [.reason: reason.rawValue])

        let service = SubscriptionService.shared
        var payload: [String: Any] = [
            "reason": reason.rawValue,
            "tier": service.currentTier.rawValue,
            "submittedAt": FieldValue.serverTimestamp()
        ]
        if let uid = Auth.auth().currentUser?.uid { payload["userId"] = uid }
        if let note, !note.isEmpty { payload["note"] = String(note.prefix(2000)) }
        if let started = service.state.tierStartedAt { payload["tierStartedAt"] = started }
        if let productId = service.state.activeProductId { payload["productId"] = productId }

        _ = try? await Firestore.firestore()
            .collection("cancellations")
            .document()
            .setData(payload)
    }

    // MARK: - Throttles

    func noteCancellationIntent() async {
        await patchState(["cancellationIntentAt": Timestamp(date: Date())])
    }

    func snoozeWinBackBanner() async {
        AnalyticsService.log(.winBackBannerDismissed)
        await patchState(["winBackDismissedAt": Timestamp(date: Date())])
    }
}
