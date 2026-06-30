import Foundation
import StoreKit
import Observation

// StoreKit 2 wrapper. Owns product loading, purchase flow, the
// long-running Transaction.updates listener, and mirroring the
// resolved entitlement through to Firebase via SubscriptionService.
//
// Pattern follows AuthService: @MainActor @Observable + .shared
// singleton. Views observe `currentTier` and `products` directly.
//
// NOTE: Server-side verification with Apple's /verifyReceipt endpoint
// is deferred to a future Cloud Function. Today, the in-app result of
// `VerificationResult.verified` is treated as authoritative for
// gating UI; spoof resistance for paid features lives behind a future
// server-side check.
@MainActor
@Observable
final class StoreKitClient {
    static let shared = StoreKitClient()

    // Keyed by (tier × cycle) so the paywall can show the price for
    // whichever billing cadence the user just toggled to.
    struct ProductKey: Hashable {
        let tier: SubscriptionTier
        let cycle: SubscriptionBillingCycle
    }

    private(set) var products: [ProductKey: Product] = [:]
    private(set) var currentTier: SubscriptionTier = .free
    private(set) var isPurchasing: Bool = false
    private(set) var isLoadingProducts: Bool = false
    private(set) var lastError: String? = nil

    private var updatesTask: Task<Void, Never>? = nil

    // Convenience for callers that just need the monthly product for
    // a tier (e.g. the cap-error alert's price hint).
    func product(for tier: SubscriptionTier, cycle: SubscriptionBillingCycle = .monthly) -> Product? {
        products[ProductKey(tier: tier, cycle: cycle)]
    }

    private init() {}

    // Called from TONGUESApp at launch. Spins up the long-running
    // transaction listener BEFORE any first await on entitlements so
    // an in-flight purchase that completes during launch isn't missed.
    func start() {
        if updatesTask == nil {
            updatesTask = Task.detached { [weak self] in
                for await update in Transaction.updates {
                    await self?.handle(update)
                }
            }
        }
        Task {
            await loadProducts()
            await syncEntitlements()
        }
    }

    // MARK: - Product loading

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: SubscriptionProduct.allIds)
            var map: [ProductKey: Product] = [:]
            for product in fetched {
                guard let tier = SubscriptionProduct.tier(forProductId: product.id),
                      let cycle = SubscriptionProduct.cycle(forProductId: product.id) else {
                    continue
                }
                map[ProductKey(tier: tier, cycle: cycle)] = product
            }
            self.products = map
        } catch {
            lastError = error.localizedDescription
            print("⚠️ StoreKitClient.loadProducts failed: \(error)")
        }
    }

    // MARK: - Purchase

    // Initiates a StoreKit purchase for the supplied tier. Handles
    // every Product.PurchaseResult branch and finishes the verified
    // transaction so it doesn't replay forever. Mirrors the resulting
    // entitlement to Firebase before returning.
    @discardableResult
    func purchase(
        _ tier: SubscriptionTier,
        cycle: SubscriptionBillingCycle = .monthly
    ) async -> Bool {
        guard let product = products[ProductKey(tier: tier, cycle: cycle)] else {
            lastError = "That tier isn't available right now."
            return false
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await applyTransaction(transaction)
                await transaction.finish()
                return true
            case .userCancelled:
                return false
            case .pending:
                // Ask-to-buy / parental approval — the transaction will
                // arrive later on Transaction.updates.
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            print("⚠️ StoreKitClient.purchase failed: \(error)")
            return false
        }
    }

    // MARK: - Entitlement sync

    // Walks the user's currently-active entitlements, picks the
    // highest tier, and writes it through to Firebase. Run on launch,
    // after every purchase, on every Transaction.updates event, and
    // when the user taps Restore Purchases.
    func syncEntitlements() async {
        var best: (tier: SubscriptionTier, txn: Transaction)? = nil
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result),
                  let tier = SubscriptionProduct.tier(forProductId: transaction.productID) else {
                continue
            }
            // Skip expired / revoked transactions — Transaction.currentEntitlements
            // also surfaces consumables we don't use, but we filter on
            // productID so they're naturally ignored.
            if let revoked = transaction.revocationDate, revoked <= Date() {
                continue
            }
            if let expires = transaction.expirationDate, expires <= Date() {
                continue
            }
            if best == nil || tier.rank > best!.tier.rank {
                best = (tier, transaction)
            }
        }

        let verifiedAt = Date()
        if let best {
            await SubscriptionService.shared.applyEntitlement(
                tier: best.tier,
                productId: best.txn.productID,
                transactionId: String(best.txn.id),
                verifiedAt: verifiedAt
            )
            currentTier = best.tier
        } else {
            await SubscriptionService.shared.clearEntitlement(verifiedAt: verifiedAt)
            currentTier = .free
        }
    }

    // Forces the App Store to refresh entitlements (e.g. user signed
    // into a new Apple ID with prior purchases). Called from the
    // Restore Purchases button.
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await syncEntitlements()
        } catch {
            lastError = error.localizedDescription
            print("⚠️ StoreKitClient.restorePurchases failed: \(error)")
        }
    }

    // MARK: - Transaction.updates handling

    private func handle(_ verification: VerificationResult<Transaction>) async {
        do {
            let transaction = try Self.checkVerified(verification)
            await applyTransaction(transaction)
            await transaction.finish()
        } catch {
            print("⚠️ StoreKitClient.handle unverified transaction: \(error)")
        }
    }

    private func applyTransaction(_ transaction: Transaction) async {
        // Defer to the full entitlement walk so a multi-product
        // user always lands on the highest active tier rather than
        // whatever the latest update happened to be.
        await syncEntitlements()
    }

    // MARK: - Verification

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    // Opens the system Manage Subscriptions sheet. Required hookup for
    // App Store compliance once a paid subscription is offered.
    func showManageSubscriptions() async {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first as? UIWindowScene else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
