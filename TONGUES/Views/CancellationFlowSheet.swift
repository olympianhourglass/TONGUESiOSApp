import SwiftUI

// The one honest interstitial between tapping "Manage subscription" and
// Apple's cancellation sheet.
//
// DESIGN RULES THIS FOLLOWS
//   • "Continue to cancel" is present on every step, at full weight, never
//     hidden behind a scroll or styled as the lesser option. Obstructing
//     cancellation is a guideline problem and reliably becomes a 1-star
//     review; the goal here is to be useful, not sticky.
//   • We ask WHY first, then respond to the actual answer. A free extension
//     offered to someone who's simply finished learning, or who hit a bug,
//     reads as tone-deaf — those answers get the feedback composer instead.
//   • Nothing is offered twice. The save offer is capped per account by
//     RetentionService.isSaveOfferAvailable.
struct CancellationFlowSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Proceeds to Apple's manage-subscription sheet.
    let onContinueToCancel: () -> Void
    // Opens the feedback composer.
    let onSendFeedback: () -> Void

    @State private var retention = RetentionService.shared
    @State private var subscription = SubscriptionService.shared
    @State private var step: Step = .reason
    @State private var reason: CancellationReason?
    @State private var isWorking = false
    @State private var savedDays: Int?

    private enum Step {
        case reason     // why are you leaving?
        case response   // our answer to that reason
        case saved      // the save offer was accepted
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .reason:   reasonStep
                case .response: responseStep
                case .saved:    savedStep
                }
            }
            .navigationTitle(step == .saved ? L("You're all set") : L("Before you go"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Close")) { dismiss() }
                        .disabled(isWorking)
                }
            }
            .onAppear {
                AnalyticsService.log(.cancelFlowOpened, [
                    .tier: subscription.currentTier.rawValue
                ])
                Task { await retention.noteCancellationIntent() }
            }
        }
    }

    // MARK: - Step 1: why

    private var reasonStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("What made you decide to cancel?"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 20))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("This goes straight to us — it's the fastest way to get something fixed."))
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(CancellationReason.allCases) { option in
                        Button {
                            Haptics.light()
                            reason = option
                            Task {
                                await retention.recordCancellation(reason: option)
                                withAnimation(.easeOut(duration: 0.2)) { step = .response }
                            }
                        } label: {
                            HStack {
                                Text(L(option.label))
                                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                                    .foregroundStyle(.black)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Always available, even before answering — no one is forced
                // through a survey to cancel.
                continueToCancelButton
                    .padding(.top, 4)
            }
            .padding(20)
        }
    }

    // MARK: - Step 2: our response to that reason

    private var responseStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L(headline))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 20))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L(message))
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // A: free extension — only for reasons where more time is a
                // genuine remedy (price, not-using-it), and only once ever.
                if showsSaveOffer {
                    primaryButton(
                        L("Keep it free for %d more days", RetentionService.saveOfferDays)
                    ) {
                        Task { await acceptSaveOffer() }
                    }
                }

                // B: downgrade — cheaper plan beats losing them entirely.
                if let cheaper = cheaperTier {
                    secondaryButton(
                        L("Switch to %@ instead", cheaper.displayName)
                    ) {
                        AnalyticsService.log(.downgradeAccepted, [.tier: cheaper.rawValue])
                        dismiss()
                        onContinueToCancel()   // Apple's sheet handles the plan change
                    }
                    .onAppear {
                        AnalyticsService.log(.downgradeOffered, [.tier: cheaper.rawValue])
                    }
                }

                // C: it's a product problem — route to feedback, don't discount.
                if reason?.wantsFeedback == true {
                    secondaryButton(L("Tell us what went wrong")) {
                        dismiss()
                        onSendFeedback()
                    }
                }

                continueToCancelButton
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .onAppear {
            if showsSaveOffer {
                AnalyticsService.log(.saveOfferShown, [
                    .reason: reason?.rawValue ?? "unspecified",
                    .count: RetentionService.saveOfferDays
                ])
            }
        }
    }

    // MARK: - Step 3: saved

    private var savedStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.black)
            Text(L("You've got %d more days", savedDays ?? RetentionService.saveOfferDays))
                .font(.custom("NeueHaasDisplay-Mediu", size: 20))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
            // Deliberately explicit: the App Store cancellation still stands.
            // Implying we reversed it would be a nasty surprise later.
            Text(L("Your subscription is still set to cancel — this just keeps your access going in the meantime. Resubscribe any time."))
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            Spacer()
            primaryButton(L("Done")) { dismiss() }
        }
        .padding(20)
    }

    // MARK: - Copy per reason

    private var headline: String {
        switch reason {
        case .tooExpensive:     return "Let's make the price work"
        case .notUsingIt:       return "Habits take a couple of weeks"
        case .missingFeature:   return "What's missing?"
        case .contentQuality:   return "That shouldn't have happened"
        case .technicalIssue:   return "Let's get that fixed"
        case .finishedLearning: return "Glad it helped"
        case .other, .none:     return "Thanks for telling us"
        }
    }

    private var message: String {
        switch reason {
        case .tooExpensive:
            return "We'd rather keep you learning than lose you over the price."
        case .notUsingIt:
            return "Most people need two or three sessions before it clicks. Here's more time, on us."
        case .missingFeature, .contentQuality, .technicalIssue:
            return "Tell us the specifics and we'll look at it properly — we read every note."
        case .finishedLearning:
            return "You can come back whenever you want to pick up a new language."
        case .other, .none:
            return "If there's more to it, we'd genuinely like to hear it."
        }
    }

    // MARK: - Eligibility

    private var showsSaveOffer: Bool {
        (reason?.isSaveableWithTime ?? false) && retention.isSaveOfferAvailable
    }

    // The next tier down, offered only when a cheaper real plan exists.
    private var cheaperTier: SubscriptionTier? {
        guard reason == .tooExpensive else { return nil }
        let current = subscription.currentTier
        return SubscriptionTier.purchasable
            .filter { $0.rank < current.rank }
            .max(by: { $0.rank < $1.rank })
    }

    // MARK: - Actions

    private func acceptSaveOffer() async {
        isWorking = true
        defer { isWorking = false }
        let ok = await retention.grantSaveOffer(reason: reason)
        if ok {
            Haptics.success()
            savedDays = RetentionService.saveOfferDays
            withAnimation(.easeOut(duration: 0.2)) { step = .saved }
        } else {
            // Grant failed (offline, or already used) — never pretend it
            // worked; fall through to the normal cancel path.
            Haptics.error()
            dismiss()
            onContinueToCancel()
        }
    }

    // MARK: - Buttons

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                }
            }
            .font(.custom("NeueHaasDisplay-Mediu", size: 17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.black)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .overlay(Capsule().stroke(Color(white: 0.85)))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    // Full-weight, always visible. This is the whole difference between a
    // retention flow and a dark pattern.
    private var continueToCancelButton: some View {
        Button {
            AnalyticsService.log(.cancelContinued, [
                .reason: reason?.rawValue ?? "unspecified",
                .tier: subscription.currentTier.rawValue
            ])
            if showsSaveOffer {
                AnalyticsService.log(.saveOfferDeclined, [
                    .reason: reason?.rawValue ?? "unspecified"
                ])
            }
            dismiss()
            onContinueToCancel()
        } label: {
            Text(L("Continue to cancel"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}
