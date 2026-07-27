import SwiftUI
import StoreKit

// In-app promo-code entry. The user types a code (e.g. TONGUESVIP) and
// SubscriptionService validates it against the in-app table, recording
// the grant to Firestore. `resolvedTier` then layers that grant over the
// StoreKit tier, so every gated feature unlocks immediately.
//
// A secondary link still exposes Apple's App Store offer-code redemption
// sheet for codes minted in App Store Connect, so both mechanisms live
// behind one entry point.
struct PromoCodeRedeemSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Fired after a successful redemption so the presenter (the paywall)
    // can dismiss itself and reveal the freshly-unlocked app.
    var onRedeemed: () -> Void = {}

    @State private var code: String = ""
    @State private var isRedeeming = false
    @State private var errorText: String?
    @State private var grantedTier: SubscriptionTier?
    @State private var showAppleOfferSheet = false

    private var trimmed: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let tier = grantedTier {
                successView(tier: tier)
            } else {
                entryView
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // App Store offer-code redemption. On success we re-sync the
        // StoreKit entitlement (the transaction listener would too, but
        // this makes the unlock feel instant) and dismiss.
        .offerCodeRedemption(isPresented: $showAppleOfferSheet) { result in
            if case .success = result {
                Task {
                    await StoreKitClient.shared.syncEntitlements()
                    await SubscriptionService.shared.refresh()
                    Haptics.success()
                    onRedeemed()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("Redeem a Code"))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
            Spacer()
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Entry

    private var entryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Enter your promo code to unlock full access."))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField(L("Enter code"), text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(.black)
                .padding(14)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .submitLabel(.go)
                .onChange(of: code) { _, _ in errorText = nil }
                .onSubmit { Task { await redeem() } }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Haptics.light()
                Task { await redeem() }
            } label: {
                HStack(spacing: 8) {
                    if isRedeeming { ProgressView().tint(.white) }
                    Text(isRedeeming ? L("Redeeming…") : L("Redeem"))
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(trimmed.isEmpty ? Color.black.opacity(0.35) : Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty || isRedeeming)

            Button {
                Haptics.light()
                showAppleOfferSheet = true
            } label: {
                Text(L("Have an App Store offer code?"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: - Success

    private func successView(tier: SubscriptionTier) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.18, green: 0.45, blue: 0.22))
                Text(L("You're on %@!", tier.displayName))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
            }
            Text(L("Full access is unlocked. Enjoy exploring TONGUES."))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Button {
                Haptics.light()
                onRedeemed()
                dismiss()
            } label: {
                Text(L("Done"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func redeem() async {
        guard !trimmed.isEmpty, !isRedeeming else { return }
        isRedeeming = true
        errorText = nil
        defer { isRedeeming = false }
        do {
            let tier = try await SubscriptionService.shared.redeemPromoCode(trimmed)
            Haptics.success()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                grantedTier = tier
            }
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }
}
