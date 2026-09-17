import SwiftUI

// A short, neutral "how's it going?" asked once, at a success moment, before
// we ever surface Apple's rating sheet.
//
// WHY THIS SITS IN FRONT OF requestReview()
//     Asking for a review blind sends delighted and frustrated users to the
//     same place — the public App Store listing. A frustrated user then has
//     exactly one outlet, and it's a 1-star review with no detail we can act
//     on. This asks first, then routes:
//       • positive → Apple's native rating sheet (the real review)
//       • negative → FeedbackSheet, so the complaint reaches us as text we
//         can actually fix, while the user feels heard
//
//     Deliberately neutral: both options are legitimate and equally weighted,
//     there's no reward for choosing either, and nothing here blocks anyone
//     from reviewing on the App Store whenever they like. We're offering a
//     better first stop, not filtering anybody out.
struct ReviewSentimentPrompt: View {
    @Environment(\.dismiss) private var dismiss

    // What earned this ask ("first_deck", "three_day_streak"). Reported with
    // every event so sentiment can be compared BY trigger — which is how
    // you learn whether a streak really does produce happier answers.
    var trigger: String = "unspecified"

    // Routed to Apple's native rating sheet.
    let onPositive: () -> Void
    // Routed to the feedback composer.
    let onNegative: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L("How's TONGUES so far?"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 22))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .padding(.top, 32)

            Text(L("We're a small team and we read everything."))
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 24)

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                // Filled = primary, but the copy stays honest rather than
                // fishing ("Loving it", not "Rate us 5 stars").
                Button {
                    Haptics.success()
                    AnalyticsService.log(.reviewPromptAnswered, [
                        .sentiment: "positive",
                        .source: trigger
                    ])
                    dismiss()
                    onPositive()
                } label: {
                    Text(L("I'm enjoying it"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    AnalyticsService.log(.reviewPromptAnswered, [
                        .sentiment: "negative",
                        .source: trigger
                    ])
                    dismiss()
                    onNegative()
                } label: {
                    Text(L("It could be better"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .overlay(Capsule().stroke(Color(white: 0.85)))
                }
                .buttonStyle(.plain)

                // An explicit third way out. Without it, dismissing feels like
                // it requires picking a side.
                Button {
                    AnalyticsService.log(.reviewPromptAnswered, [
                        .sentiment: "dismissed",
                        .source: trigger
                    ])
                    dismiss()
                } label: {
                    Text(L("Not now"))
                        .font(.custom("NeueHaasDisplay-Light", size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
        .onAppear { AnalyticsService.log(.reviewPromptShown, [.source: trigger]) }
    }
}
