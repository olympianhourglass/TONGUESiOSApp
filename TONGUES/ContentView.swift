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
    // Drives the first-run native-language picker + the app-wide UI language.
    @State private var localizer = Localizer.shared
    private var selectedTab: Binding<AppTab> {
        Binding(
            get: { tabRouter.current },
            set: { newValue in
                // Re-tapping the already-active Study tab (SwiftUI still calls
                // this setter with the same value for a custom binding) opens
                // Create New Deck, as if the user tapped the button itself.
                if newValue == .study, tabRouter.current == .study {
                    QuickActionRouter.shared.createDeckTick += 1
                }
                tabRouter.current = newValue
            }
        )
    }
    @AppStorage("hasCompletedOnboardingQuestions") private var hasCompletedOnboardingQuestions = false
    // Latches true the first time the startup chime finishes so subsequent
    // launches fall back to the silent splash + timer behavior.
    @AppStorage("hasPlayedStartupChime") private var hasPlayedStartupChime = false

    init() {
        #if targetEnvironment(macCatalyst)
        // Mac: the tabs render as a `.sidebarAdaptable` sidebar, which is
        // UITabBar-backed on Catalyst. Paint it as an OPAQUE BLACK panel with
        // white labels. Making it opaque is the key fix: a translucent sidebar
        // let the Study tab's black content show through and tint the glass,
        // which read as a strange color shift on the left edge. An opaque bar
        // can't reveal anything behind it, and black + white text matches the
        // Study header's palette.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black

        let itemAppearance = UITabBarItemAppearance()
        let dim = UIColor.white.withAlphaComponent(0.55)
        itemAppearance.normal.iconColor = dim
        itemAppearance.selected.iconColor = .white
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: dim]
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]

        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        #else
        // iPhone/iPad bottom tab bar: dimmed unselected icons, icons-only
        // (titles hidden via clear color).
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
        #endif
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

            // Splash waits until a native language has been chosen so the
            // black→white flip (into onboarding) only happens afterward.
            if isShowingSplash && localizer.hasChosen {
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

            // The very first screen on a fresh install: pick the app's
            // language before anything else renders. Sits on top of the
            // black splash layer, so the flip to white is deferred until
            // the user continues.
            if !localizer.hasChosen {
                LanguageSelectionView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .environment(\.locale, Locale(identifier: localizer.language.localeIdentifier))
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

    // Tab entry label. iPhone/iPad keep the icon-only bottom bar exactly as
    // before (the title branch isn't compiled there, and titles are hidden
    // by UITabBarItemAppearance regardless). On Mac Catalyst the TabView
    // renders as a sidebar via `.sidebarAdaptable`, so each row carries its
    // title next to the icon.
    private func tabItemLabel(icon: String, title: String) -> some View {
        #if targetEnvironment(macCatalyst)
        Label { Text(title) } icon: { tabIcon(icon) }
        #else
        tabIcon(icon)
        #endif
    }

    @ViewBuilder
    private var mainTabView: some View {
        #if targetEnvironment(macCatalyst)
        macSidebarLayout
        #else
        tabBarLayout
        #endif
    }

    // iPhone / iPad: the standard bottom tab bar (unchanged).
    private var tabBarLayout: some View {
        TabView(selection: selectedTab) {
            ExploreView()
                .tabItem { tabItemLabel(icon: "Compass", title: L("Explore")) }
                .tag(AppTab.explore)

            StudyView()
                .tabItem { tabItemLabel(icon: "PlusSquare", title: L("Study")) }
                .tag(AppTab.study)

            ChatView()
                .tabItem { tabItemLabel(icon: "Chat", title: L("Chat")) }
                .tag(AppTab.chat)

            LibraryView()
                .tabItem { tabItemLabel(icon: "Books", title: L("Library")) }
                .tag(AppTab.library)
        }
        .tint(.black)
    }

    #if targetEnvironment(macCatalyst)
    // Mac: a hand-built, guaranteed-solid-black sidebar. The system
    // `.sidebarAdaptable` sidebar uses a fixed translucent AppKit material
    // that can't be forced opaque, which let the Study tab's black bleed
    // through as a color shift and left labels hard to read. Drawing our own
    // sidebar sidesteps that entirely. Only the selected section is mounted,
    // so each tab keeps the exact lifecycle it has on iPhone (e.g. the Chat
    // mic starts/stops with its own appear/disappear rather than in the
    // background).
    private var macSidebarLayout: some View {
        HStack(spacing: 0) {
            macSidebar
            macSelectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Opaque black behind the whole window so no macOS window vibrancy
        // (from the hidden title bar) can show through as a translucent
        // region — the content panes paint their own white/black on top.
        .background(Color.black.ignoresSafeArea())
    }

    private var macSidebarItems: [(tab: AppTab, icon: String, title: String)] {
        [
            (.explore, "Compass", L("Explore")),
            (.study, "PlusSquare", L("Study")),
            (.chat, "Chat", L("Chat")),
            (.library, "Books", L("Library"))
        ]
    }

    private var macSidebar: some View {
        ZStack(alignment: .topLeading) {
            // Explicit opaque fill as the base layer — the most direct way to
            // guarantee the column paints solid black regardless of any window
            // material behind it.
            Rectangle()
                .fill(Color.black)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 2) {
                // Clear the window's traffic-light controls, which float over
                // the top-left of the (title-bar-less) window.
                Color.clear.frame(height: 28)
                ForEach(macSidebarItems, id: \.tab) { item in
                    macSidebarButton(tab: item.tab, icon: item.icon, title: item.title)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    private func macSidebarButton(tab: AppTab, icon: String, title: String) -> some View {
        let selected = tabRouter.current == tab
        return Button {
            tabRouter.current = tab
        } label: {
            HStack(spacing: 10) {
                tabIcon(icon)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                Text(title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.white.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var macSelectedContent: some View {
        switch tabRouter.current {
        case .explore: ExploreView()
        case .study:   StudyView()
        case .chat:    ChatView()
        case .library: LibraryView()
        }
    }
    #endif
}

// Mac (Catalyst) runs in a large window, so the phone-sized Study and
// Library layouts are grown into a richer, roughly-double-height
// composition — bigger hero, larger cards, wider multi-column grids —
// while preserving the design system's proportions. Dimensions scale a
// little more than type so text stays tasteful rather than cartoonish.
// On iPhone/iPad both helpers return the base value unchanged, so those
// layouts are byte-for-byte what they were.
enum MacLayout {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// Scale for structural dimensions — card sizes, image frames, padding.
    static func s(_ base: CGFloat) -> CGFloat { isMac ? base * 1.8 : base }

    /// Scale for type. Grown less than structure so headings/body don't
    /// balloon on the larger canvas.
    static func f(_ base: CGFloat) -> CGFloat { isMac ? base * 1.45 : base }
}

#Preview {
    ContentView()
}
