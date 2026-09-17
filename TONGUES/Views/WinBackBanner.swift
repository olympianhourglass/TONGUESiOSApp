import SwiftUI
import StoreKit

// Shown while a cancellation is pending but access hasn't lapsed yet.
//
// WHY THIS IS THE IMPORTANT HALF
//     Most people cancel from iOS Settings, not from inside the app, so the
//     cancellation interstitial never gets a chance to run for them. This
//     banner is driven purely by StoreKit's renewal state
//     (`willAutoRenew == false`), so it reaches everyone regardless of where
//     they cancelled — and it has the remaining paid days to work with.
//
//     It's dismissible and the dismissal sticks for several days
//     (RetentionService.shouldShowWinBackBanner), so it informs rather than
//     nags. The honest framing matters too: the user DID cancel, and the
//     banner says so rather than pretending otherwise.
struct WinBackBanner: View {
    @State private var retention = RetentionService.shared
    @State private var subscription = SubscriptionService.shared
    @State private var isWorking = false

    // Opens the paywall so they can resubscribe at full price when no
    // win-back offer is configured/eligible.
    let onResubscribe: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(L(subtitle))
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await act() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(.black).controlSize(.small)
                    } else {
                        Text(L(ctaLabel))
                            .font(.custom("NeueHaasDisplay-Mediu", size: 13))
                            .foregroundStyle(.black)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Button {
                Haptics.light()
                Task { await retention.snoozeWinBackBanner() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .onAppear {
            AnalyticsService.log(.winBackBannerShown, [
                .tier: subscription.currentTier.rawValue,
                .count: retention.daysUntilExpiry ?? -1
            ])
            if winBackOffer != nil {
                AnalyticsService.log(.winBackOfferShown, [.source: "banner"])
            }
        }
    }

    // MARK: - Copy

    private var title: String {
        guard let days = retention.daysUntilExpiry else {
            return "Your plan is set to cancel"
        }
        switch days {
        case 0:  return "Your plan ends today"
        case 1:  return "Your plan ends tomorrow"
        default: return "Your plan ends in \(days) days"
        }
    }

    private var subtitle: String {
        // An Apple win-back offer beats a plain "resubscribe" pitch, so lead
        // with it whenever one is actually available.
        if winBackOffer != nil { return "There's an offer waiting for you" }
        if retention.isSaveOfferAvailable { return "Keep your decks and streak going" }
        return "Your decks and progress stay saved"
    }

    private var ctaLabel: String {
        winBackOffer != nil ? "See offer" : "Keep it"
    }

    // MARK: - Offer resolution

    // Apple's win-back offer, if one is configured in App Store Connect AND
    // this Apple ID is eligible. Nil is the normal case until those offers
    // exist, so every path below degrades gracefully.
    private var winBackOffer: (product: Product, offer: Product.SubscriptionOffer)? {
        retention.bestWinBackOffer(for: subscription.currentTier)
    }

    private func act() async {
        isWorking = true
        defer { isWorking = false }
        Haptics.medium()

        // 1. Apple win-back offer — the real discount, handled by StoreKit.
        if let (product, offer) = winBackOffer {
            _ = await retention.purchaseWinBack(product: product, offer: offer)
            return
        }
        // 2. Our own extension, if they haven't used it.
        if retention.isSaveOfferAvailable {
            if await retention.grantSaveOffer(reason: nil) {
                Haptics.success()
                return
            }
        }
        // 3. Nothing to give — send them to the paywall to resubscribe.
        onResubscribe()
    }
}
