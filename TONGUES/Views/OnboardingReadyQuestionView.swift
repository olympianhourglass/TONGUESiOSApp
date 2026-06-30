import SwiftUI

// Final onboarding screen before sign-in. Single Playfair line + a black
// pill button labeled "Yes" — visually consistent with the Next/Continue
// affordance used on every prior question screen. A small Haiku-generated
// summary line sits above the title so the user sees their own choices
// reflected back at them.
struct OnboardingReadyQuestionView: View {
    let state: OnboardingState
    let onNext: () -> Void

    @State private var summary: String = ""
    @State private var sampleDecks: [String] = []
    @State private var hasFetched = false
    @State private var isLoadingSummary = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Text("Ready to meet this version of you?")
                    .font(.custom("PlayfairDisplay-Regular", size: 32))
                    .tracking(-2.56)
                    .foregroundStyle(.black)

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                if !sampleDecks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your first decks")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        ForEach(sampleDecks, id: \.self) { title in
                            Text("· \(title)")
                                .font(.system(size: 14))
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // Yes only surfaces once the summary has come back from
            // Haiku — gives the page a moment to "settle" with the
            // user's reflection before committing. While we wait,
            // an inline ProgressView holds the slot so the layout
            // doesn't jump when Yes finally appears.
            if isLoadingSummary {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Putting it all together…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            } else {
                VStack(spacing: 10) {
                    Button {
                        Haptics.medium()
                        onNext()
                    } label: {
                        Text("Yes")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    // Free-trial tease. Lives right under the Yes
                    // button so the user sees it before they commit
                    // to sign-in. Pulls the trial length from
                    // SubscriptionTier so a future bump (1-day →
                    // 7-day) updates here automatically.
                    Text("Includes a \(SubscriptionTier.beginner.freeTrialLabel.lowercased()) free trial on every plan.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        guard !hasFetched else { return }
        hasFetched = true
        let answers = state.answers

        // Run both calls in parallel — each hits Haiku independently and
        // neither blocks the other.
        async let summaryTask = (try? await DeckGenerator.summarizeOnboarding(answers)) ?? ""
        async let decksTask = (try? await DeckGenerator.suggestSampleDecks(answers)) ?? []

        summary = await summaryTask
        sampleDecks = await decksTask
        // Persist into the flow state so the login step can auto-generate
        // these exact decks into the library after sign-up.
        state.sampleDecks = sampleDecks
        isLoadingSummary = false
    }
}
