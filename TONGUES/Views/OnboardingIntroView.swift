import SwiftUI

struct OnboardingIntroView: View {
    let onContinue: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                // Bitmap wordmark; tinted black for the white onboarding
                // background. Avoids the glyph-edge clipping the Text
                // version was prone to at this size.
                TonguesWordmark(size: 56)
                    .foregroundStyle(.black)

                Text("A modern way to learn a language —\nbuilt around the words you actually use.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            Spacer()

            VStack(spacing: 16) {
                Button {
                    Haptics.medium()
                    onContinue()
                } label: {
                    Text("Get Started")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    onSignIn()
                } label: {
                    Text("Sign In")
                        .font(.custom("NeueHaasDisplay-Roman", size: 15))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }
}
