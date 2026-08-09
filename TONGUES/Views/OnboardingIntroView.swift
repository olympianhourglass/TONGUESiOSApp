import SwiftUI

struct OnboardingIntroView: View {
    let onContinue: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        ZStack {
            // Wordmark + tagline, left-aligned and vertically centered. The
            // wordmark uses the Statistics page's title typeface, white, and
            // sits 16pt from the leading edge.
            VStack(alignment: .leading, spacing: 12) {
                Text("TONGUES")
                    .font(.custom("NeueHaasDisplay-Light", size: 34))
                    .tracking(0)
                    .foregroundStyle(.white)

                Text(L("The infinite language learning application. Designed and engineered for travel and curiosity."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Actions pinned to the bottom — identical behavior to before.
            VStack {
                Spacer()
                VStack(spacing: 16) {
                    Button {
                        Haptics.medium()
                        onContinue()
                    } label: {
                        Text(L("Get Started"))
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
                        Text(L("Sign In"))
                            .font(.custom("NeueHaasDisplay-Roman", size: 15))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        // Full-bleed airport backdrop, mirrored horizontally so the scene
        // faces the other way. Applied as a background (not a ZStack child)
        // so the oversized scaledToFill image can't stretch the layout and
        // push the left-aligned wordmark off-screen — which was eating the
        // 16pt leading margin.
        .background {
            Image("FirstRunBackground")
                .resizable()
                .scaledToFill()
                .scaleEffect(x: -1, y: 1)
                .ignoresSafeArea()
        }
        .navigationBarBackButtonHidden(true)
        // White (light) status-bar content over the photo. Overrides the
        // onboarding flow's flow-wide dark setting while this page is up
        // (forceLight wins over forceDark), then releases it on the way out.
        .onAppear { AppTabRouter.shared.forceLightStatusBar = true }
        .onDisappear { AppTabRouter.shared.forceLightStatusBar = false }
    }
}
