import SwiftUI

struct ContentView: View {
    // Bridges through the shared AppTabRouter so TONGUESApp can read
    // the active tab when deciding the window's status-bar color
    // scheme. Reads + writes the same source of truth.
    @State private var tabRouter = AppTabRouter.shared
    @State private var isShowingSplash = true
    @State private var auth = AuthService.shared
    @State private var router = WidgetDeepLinkRouter.shared
    @State private var quickActionRouter = QuickActionRouter.shared
    // First-run "tap Create New Deck" coach mark. Rendered here, above the
    // TabView, so the hand floats over the tab bar rather than being
    // clipped beneath it inside the Study tab.
    @State private var coach = FirstRunCoachController.shared
    private var selectedTab: Binding<AppTab> {
        Binding(get: { tabRouter.current }, set: { tabRouter.current = $0 })
    }
    @AppStorage("hasCompletedOnboardingQuestions") private var hasCompletedOnboardingQuestions = false
    // Latches true the first time the startup chime finishes so subsequent
    // launches fall back to the silent splash + timer behavior.
    @AppStorage("hasPlayedStartupChime") private var hasPlayedStartupChime = false

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()

        let itemAppearance = UITabBarItemAppearance()
        let unselected = UIColor.black.withAlphaComponent(0.3)
        itemAppearance.normal.iconColor = unselected
        itemAppearance.selected.iconColor = .black

        // No tab-bar titles — icons only. Hide any residual label the
        // system might vend so nothing shows beneath the icon and it
        // sits vertically centered in the bar.
        let hiddenTitle: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]
        itemAppearance.normal.titleTextAttributes = hiddenTitle
        itemAppearance.selected.titleTextAttributes = hiddenTitle

        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        ZStack {
            if auth.isAuthenticated && hasCompletedOnboardingQuestions {
                mainTabView
                    .xpToastOverlay()
            } else {
                OnboardingFlow {
                    hasCompletedOnboardingQuestions = true
                }
            }

            if coach.isPresented {
                firstRunCoachLayer
            }

            if isShowingSplash {
                SplashView(
                    isFirstLaunch: !hasPlayedStartupChime,
                    onChimeFinished: {
                        // Latch the flag so this only ever fires once, then
                        // hand off to the onboarding flow by hiding the
                        // splash. The OnboardingFlow vs. mainTabView gate
                        // sitting below already routes correctly.
                        hasPlayedStartupChime = true
                        withAnimation(.easeOut(duration: 0.4)) {
                            isShowingSplash = false
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .task {
            // First launch: the SplashView's chime callback dismisses the
            // splash when audio + haptics finish, so we skip the legacy
            // 1.5s timer to avoid racing it.
            guard hasPlayedStartupChime else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.4)) {
                isShowingSplash = false
            }
        }
        .onChange(of: router.pendingDeckID) { _, newValue in
            // Widget tap → flip to the Library tab so its
            // navigation stack can push DeckDetailView.
            if newValue != nil { tabRouter.current = .library }
        }
        // App-icon quick action → flip to the Study tab so StudyView is
        // on-screen to consume the pending action and open Create New Deck.
        .onChange(of: quickActionRouter.pending) { _, newValue in
            if newValue != nil { tabRouter.current = .study }
        }
        .onAppear {
            // Cold launch via a shortcut: the pending action may already be
            // set before this appears.
            if quickActionRouter.pending != nil { tabRouter.current = .study }
        }
        // Status bar override is installed via runtime class-swap on
        // the window's UIHostingController; see StatusBarStyleSwap.
        // The didSet on AppTabRouter.current fires it on every tab
        // change. We additionally call applyStatusBarStyle on every
        // appearance + after the splash dismisses + after auth /
        // onboarding lands, because the hosting controller can be
        // (re)created at any of those moments and the swap has to
        // run against the new instance.
        .onChange(of: tabRouter.current) { _, _ in
            tabRouter.applyStatusBarStyle()
        }
        .onChange(of: isShowingSplash) { _, _ in
            tabRouter.applyStatusBarStyle()
        }
        .onChange(of: auth.isAuthenticated) { _, _ in
            tabRouter.applyStatusBarStyle()
        }
        // A fresh interactive login/sign-up routes to the Study tab so the
        // first-run coach tour can start there. Session restore on launch
        // doesn't set this flag, so just opening the app never triggers it.
        .onChange(of: auth.didJustAuthenticate) { _, justAuthed in
            if justAuthed { tabRouter.current = .study }
        }
        .onChange(of: hasCompletedOnboardingQuestions) { _, _ in
            tabRouter.applyStatusBarStyle()
        }
        .onAppear { tabRouter.applyStatusBarStyle() }
    }

    // Converts the Study tab's globally-measured button frame into this
    // root overlay's local space (the GeometryReader ignores safe area, so
    // local == global) and hands it to the coach mark.
    private var firstRunCoachLayer: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let f = coach.buttonFrame
            let local = CGRect(
                x: f.minX - origin.x,
                y: f.minY - origin.y,
                width: f.width,
                height: f.height
            )
            CreateDeckCoachmark(
                target: local,
                containerSize: proxy.size,
                onProceed: { coach.onProceed() },
                onSkip: { coach.onSkip() }
            )
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    // Tab-bar icons rendered 20% smaller than the system default (~25pt →
    // 20pt) so there's more apparent vertical breathing room between each
    // icon and its label. Template rendering preserves the tab bar's
    // selected/unselected tint from UITabBarItemAppearance.
    private func tabIcon(_ name: String) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
    }

    private var mainTabView: some View {
        TabView(selection: selectedTab) {
            ExploreView()
                .tabItem { tabIcon("Compass") }
                .tag(AppTab.explore)

            StudyView()
                .tabItem { tabIcon("PlusSquare") }
                .tag(AppTab.study)

            ChatView()
                .tabItem { tabIcon("Chat") }
                .tag(AppTab.chat)

            LibraryView()
                .tabItem { tabIcon("Books") }
                .tag(AppTab.library)
        }
        .tint(.black)
    }
}

#Preview {
    ContentView()
}
