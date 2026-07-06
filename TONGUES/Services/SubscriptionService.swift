import Foundation
import FirebaseAuth
import FirebaseFirestore
import Observation

// Subscription state singleton. Fronts the Firestore doc at
// users/{uid}/subscription/state and exposes the resolved tier +
// current-month usage to the UI as an @Observable so progress
// rows and "X / Y left this month" hints refresh live without
// view-model plumbing.
//
// Service pattern mirrors AuthService (@MainActor @Observable
// .shared). Persistence reads/writes mirror XPService (defensive
// fetchState, single commit per mutation, merged setData).
@MainActor
@Observable
final class SubscriptionService {
    static let shared = SubscriptionService()

    // Live local copy of the user's state. UI binds against this.
    // Refreshed by `refresh()` on launch + after every mutation.
    private(set) var state: UserSubscriptionState = UserSubscriptionState()

    // Set to `true` while the initial fetch from Firestore is in flight
    // so views don't flash "0 / X used" before the real numbers land.
    private(set) var isLoading: Bool = false

    private init() {}

    // MARK: - Month key

    // Stable, locale-independent month key mirroring XPService's
    // dayKeyFormatter. yyyy-MM in the user's current timezone.
    private static let monthKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func monthKey(for date: Date) -> String {
        monthKeyFormatter.string(from: date)
    }

    var currentMonthKey: String {
        Self.monthKey(for: Date())
    }

    // Convenience for views.
    var currentTier: SubscriptionTier {
        state.resolvedTier
    }

    // True while the user may still open the Create New Deck flow without
    // hitting the paywall: any paid tier, or a free user who hasn't yet
    // spent their one free deck. Drives the Study tab's create button.
    var canCreateFreeDeck: Bool {
        currentTier != .free || !state.freeDeckUsed
    }

    // Consumes the free-deck grace. Called after a free user saves their
    // first deck; idempotent and a no-op for paid tiers.
    func markFreeDeckUsed() async {
        guard currentTier == .free, !state.freeDeckUsed else { return }
        state.freeDeckUsed = true
        do {
            try await commit()
        } catch {
            print("⚠️ SubscriptionService.markFreeDeckUsed failed: \(error)")
            await refresh()
        }
    }

    // MARK: - Firestore plumbing

    private static let db = Firestore.firestore()

    private static func docRef() throws -> DocumentReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw SubscriptionError.notAuthenticated
        }
        return db.collection("users")
            .document(uid)
            .collection("subscription")
            .document("state")
    }

    // Reads the user's subscription state. Missing doc → fresh empty
    // state (free tier). Decode failure → THROW (XPService pattern) so
    // we never silently overwrite a real doc with zeros on the next
    // commit when the schema evolves.
    static func fetchState() async throws -> UserSubscriptionState {
        let ref = try docRef()
        let snap = try await ref.getDocument()
        guard snap.exists else { return UserSubscriptionState() }
        return try snap.data(as: UserSubscriptionState.self)
    }

    // Pulls the latest state down from Firestore and republishes it.
    // Safe to call on app launch even before the user has signed in —
    // the auth check inside docRef throws, we swallow it, and the
    // local state stays at the default free tier until the next call
    // following a successful sign-in.
    func refresh() async {
        guard Auth.auth().currentUser != nil else {
            state = UserSubscriptionState()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            state = try await Self.fetchState()
        } catch {
            print("⚠️ SubscriptionService.refresh failed: \(error)")
        }
    }

    // MARK: - Cap arithmetic

    // Remaining quota in the given bucket for the current month under
    // the current tier. Negative results clamp to 0 — over-budget can
    // happen briefly if the user downgrades mid-month while sitting
    // above the lower tier's cap.
    func remaining(in bucket: SubscriptionBucket) -> Int {
        let cap = bucket.cap(for: currentTier)
        let used = state.usage(in: bucket, monthKey: currentMonthKey)
        return Swift.max(0, cap - used)
    }

    // Throws `.languageCapExceeded` when adding one more language
    // would exceed the tier's saved-language ceiling. Unlike monthly
    // buckets, this is a snapshot count, not a per-month counter — the
    // caller passes the user's current language total.
    func ensureLanguageSlotAvailable(currentCount: Int) async throws {
        let max = currentTier.maxLanguages
        if currentCount >= max {
            throw SubscriptionError.languageCapExceeded(tier: currentTier, max: max)
        }
    }

    // Convenience used by the listen-session call sites: refreshes
    // tier state, gates on the audio cap, and increments by 1. Wraps
    // the boilerplate that would otherwise have to live at every
    // ListenSessionView presentation point.
    func tryStartAudioSession() async throws {
        await refresh()
        try await ensureCapacity(in: .audioSessions, requested: 1)
        await consume(1, in: .audioSessions)
    }

    // Throws `.capExceeded` when `requested` is greater than the
    // remaining quota. Otherwise no-op. Generation call sites use this
    // pre-flight so the API call is never even fired when over budget.
    // Async so non-isolated callers (e.g. DeckGenerator) hop to the
    // MainActor cleanly via `try await`.
    func ensureCapacity(in bucket: SubscriptionBucket, requested: Int) async throws {
        // Free users get one full deck (generate + save) before the
        // paywall kicks in. The grace is consumed at save time
        // (markFreeDeckUsed), so every generation in that first deck
        // session passes regardless of the free tier's zero caps. Audio
        // sessions are excluded so the grace can't be spent on playback.
        if currentTier == .free, !state.freeDeckUsed, bucket != .audioSessions {
            return
        }

        let cap = bucket.cap(for: currentTier)
        let used = state.usage(in: bucket, monthKey: currentMonthKey)
        let remaining = Swift.max(0, cap - used)
        if requested > remaining {
            throw SubscriptionError.capExceeded(
                bucket: bucket,
                tier: currentTier,
                remaining: remaining,
                requested: requested
            )
        }
    }

    // MARK: - Consumption

    // Increments the in-memory + on-disk usage counters. Called on
    // successful generation/save. Mutation is local-first (so the UI
    // updates immediately) then merged into Firestore. We re-read on
    // failure to keep local in sync.
    func consume(_ amount: Int, in bucket: SubscriptionBucket) async {
        guard amount > 0 else { return }
        let monthKey = currentMonthKey

        switch bucket {
        case .words:         state.wordsByMonthKey[monthKey, default: 0] += amount
        case .sentences:     state.sentencesByMonthKey[monthKey, default: 0] += amount
        case .artifacts:     state.artifactsByMonthKey[monthKey, default: 0] += amount
        case .audioSessions: state.audioSessionsByMonthKey[monthKey, default: 0] += amount
        }

        do {
            let ref = try Self.docRef()
            try await ref.setData(from: state, merge: true)
        } catch {
            print("⚠️ SubscriptionService.consume failed: \(error)")
            await refresh()
        }
    }

    // MARK: - Entitlement application (called by StoreKitClient)

    // Writes the resolved tier through to Firestore. Idempotent: same
    // transactionId / productId → silent no-op so the StoreKit update
    // listener can fire repeatedly without churn.
    func applyEntitlement(
        tier: SubscriptionTier,
        productId: String?,
        transactionId: String?,
        verifiedAt: Date
    ) async {
        let alreadyApplied = state.tier == tier.rawValue
            && state.activeTransactionId == transactionId
            && state.activeProductId == productId
        if alreadyApplied {
            state.lastVerifiedAt = verifiedAt
            await commitLogging("applyEntitlement(noop)")
            return
        }

        state.tier = tier.rawValue
        state.activeProductId = productId
        state.activeTransactionId = transactionId
        state.lastVerifiedAt = verifiedAt
        if state.tierStartedAt == nil || tier == .free {
            state.tierStartedAt = tier == .free ? nil : verifiedAt
        } else if state.activeTransactionId != transactionId {
            state.tierStartedAt = verifiedAt
        }
        print("💳 SubscriptionService: applying tier=\(tier.rawValue) product=\(productId ?? "nil")")
        await commitLogging("applyEntitlement(\(tier.rawValue))")
    }

    // Wraps commit() so a Firestore write failure is surfaced rather than
    // swallowed by `try?`. A silent failure here is what leaves an upgraded
    // plan looking unchanged (the doc never advances), so it must be loud.
    private func commitLogging(_ context: String) async {
        do {
            try await commit()
        } catch {
            print("⚠️ SubscriptionService.commit failed [\(context)]: \(error)")
        }
    }

    // Drops the user back to the free tier. Used when StoreKit reports
    // no active entitlements (e.g. subscription expired, refund).
    func clearEntitlement(verifiedAt: Date) async {
        if state.tier == SubscriptionTier.free.rawValue
            && state.activeTransactionId == nil
            && state.activeProductId == nil {
            state.lastVerifiedAt = verifiedAt
            await commitLogging("clearEntitlement(noop)")
            return
        }
        state.tier = SubscriptionTier.free.rawValue
        state.activeProductId = nil
        state.activeTransactionId = nil
        state.tierStartedAt = nil
        state.lastVerifiedAt = verifiedAt
        await commitLogging("clearEntitlement")
    }

    private func commit() async throws {
        let ref = try Self.docRef()
        try await ref.setData(from: state, merge: true)
    }
}
