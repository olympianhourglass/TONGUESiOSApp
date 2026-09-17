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
    // Drives the hard paywall. There is no free tier, so the app is only
    // reachable with an active trial, subscription, or promo grant.
    @State private var subscription = SubscriptionService.shared
    // False until StoreKit + Firestore have both been consulted, so a cold
    // launch never flashes the paywall at a paying subscriber.
    @State private var didResolveEntitlement = false
    // Churn detection + the win-back banner shown during the grace window.
    @State private var retention = RetentionService.shared
    @State private var showWinBackPaywall = false
    // Hosts the audio listening session at the app root so it survives a
    // pull-down into the floating mini-bar above the tab bar (Apple Music-style)
    // and keeps playing across tab switches.
    @State private var listenHost = ListenSessionHost.shared
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
                // Only log real tab CHANGES — SwiftUI calls this setter with
                // the same value on a re-tap, which would double-count.
                if newValue != tabRouter.current {
                    AnalyticsService.log(.tabSelected, [.tab: newValue.analyticsName])
                }
                tabRouter.current = newValue
            }
        )
    }
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboardingQuestions") private var hasCompletedOnboardingQuestions = false
    // Latched true while the onboarding flow is on screen so that signing in
    // mid-flow (which flips `auth.isAuthenticated` true) doesn't rip the flow
    // out from under the user before they reach the slideshow/paywall. Only the
    // flow's own completion clears it. A returning user who's already signed in
    // at launch never mounts the flow, so this stays false and they go straight
    // to the app.
    @State private var onboardingInProgress = false
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
        // iPhone/iPad bottom tab bar: light material, dimmed black icons,
        // icons-only. Owned by TabBarChrome so black-backdrop screens (e.g.
        // StatisticsView) can swap the live bar to a dark variant on appear.
        TabBarChrome.installDefault()
        #endif
    }

    var body: some View {
        ZStack {
            if auth.isAuthenticated && hasCompletedOnboardingQuestions && !onboardingInProgress {
                mainTabView
                    .xpToastOverlay()
            } else {
                OnboardingFlow {
                    hasCompletedOnboardingQuestions = true
                    onboardingInProgress = false
                }
                // Mark the flow as in progress once it mounts, so an auth flip
                // partway through (Apple sign-in) keeps it on screen through the
                // slideshow instead of jumping to the app.
                .onAppear { onboardingInProgress = true }
            }

            // The listening session lives above the tab bar so its full-screen
            // player covers the bar when expanded, and its mini-bar floats over
            // the bar when collapsed. Kept mounted for the whole session so the
            // audio never stops on a pull-down. `.id` restarts it when a
            // different deck is presented.
            if let deck = listenHost.deck {
                ListenSessionView(deck: deck)
                    .id(deck.id)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }

            // Hard lock. There is no free tier, so a returning user whose
            // trial or subscription has lapsed (and anyone from before the
            // free tier was retired) lands straight back on the paywall.
            // Their decks and progress are untouched — the moment an
            // entitlement lands, `hasAccess` flips and the app reappears.
            // Gated on `didResolveEntitlement` so we never flash the paywall
            // while StoreKit is still verifying on a cold launch.
            if auth.isAuthenticated,
               hasCompletedOnboardingQuestions,
               !onboardingInProgress,
               didResolveEntitlement,
               !subscription.hasAccess {
                PremiumActionSheet(isMandatory: true)
                    .transition(.opacity)
                    .zIndex(2)
                    // Distinct from paywall_viewed: this is specifically a
                    // returning user being locked OUT, i.e. involuntary churn
                    // meeting the wall rather than a first-run funnel step.
                    .onAppear {
                        AnalyticsService.log(.paywallLockShown, [
                            .tier: subscription.currentTier.rawValue
                        ])
                    }
            }

            // Pending cancellation, access not yet lapsed. Driven by StoreKit's
            // renewal state, so it reaches the majority who cancel from iOS
            // Settings and never open our own cancel flow. Sits above the tab
            // bar, below the audio mini-player, and is dismissible for days.
            if auth.isAuthenticated,
               hasCompletedOnboardingQuestions,
               !onboardingInProgress,
               retention.shouldShowWinBackBanner {
                VStack {
                    Spacer()
                    WinBackBanner(onResubscribe: { showWinBackPaywall = true })
                        .padding(.bottom, 96)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
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
        .sheet(isPresented: $showWinBackPaywall) {
            PremiumActionSheet()
        }
        // Resolve the entitlement before the lock gate is allowed to judge.
        // Re-runs whenever auth flips so signing in/out re-evaluates access.
        .task(id: auth.isAuthenticated) {
            guard auth.isAuthenticated else {
                didResolveEntitlement = false
                return
            }
            await subscription.refresh()
            // Let the StoreKit entitlement sync land too — it writes through
            // to the same state, so a valid receipt unlocks without a relaunch.
            await StoreKitClient.shared.syncEntitlements()
            didResolveEntitlement = true
            // Learn whether a cancellation is pending. Products must be loaded
            // first, which syncEntitlements above guarantees.
            await retention.refreshRenewalState()
            // Stamp the segmentation properties now that tier + trial state
            // are known, so every subsequent event is segmentable.
            AnalyticsService.refreshUserProperties(
                profile: try? await UserService.fetchProfile()
            )
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
        .onChange(of: tabRouter.current) { _, newTab in
            // Chat owns the audio route (mic + spoken replies), so a listening
            // session can't coexist there: entering Chat stops the playlist and
            // dismisses the mini-bar, letting the chat interface take over.
            if newTab == .chat, listenHost.deck != nil {
                listenHost.end()
            }
            tabRouter.applyStatusBarStyle()
        }
        .onChange(of: isShowingSplash) { _, _ in
            tabRouter.applyStatusBarStyle()
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthed in
            // Push the interface language chosen on the pre-sign-in first-run
            // picker up to Firestore now that there's a user to attach it to.
            if isAuthed { localizer.syncToFirestore() }
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
        // Streak reminders. On foreground we (re)request permission the first
        // time and always reschedule so a day rollover or an out-of-app change
        // is reflected; on background we reschedule to capture the latest
        // "studied today" state. We only prompt for permission once the user
        // is past onboarding so the system alert never lands on the splash /
        // language picker.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A cancellation may have happened in iOS Settings while we
                // were backgrounded — re-read the renewal state on return.
                if auth.isAuthenticated {
                    Task { await retention.refreshRenewalState() }
                }
                if auth.isAuthenticated && hasCompletedOnboardingQuestions {
                    Task { await StreakReminderService.shared.requestAuthorizationIfNeeded() }
                }
            case .background:
                Task { await StreakReminderService.shared.reschedule() }
            default:
                break
            }
        }
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

    // Maps a tab's base (outline) icon name to the variant shown while that tab
    // is selected. Explore and Library use bold outline variants; Study and Chat
    // use their filled variants. (All selected variants are normalized to the
    // same 32pt artboard as the outline icons so they render at a matching size.)
    private func selectedIcon(_ name: String) -> String {
        switch name {
        case "Compass":    return "CompassRoseBold"
        case "PlusSquare": return "PlusSquare_fill"
        case "Chat":       return "Chat_fill"
        case "Books":      return "BooksBold"
        default:           return name
        }
    }

    // Tab entry label. iPhone/iPad keep the icon-only bottom bar exactly as
    // before (the title branch isn't compiled there, and titles are hidden
    // by UITabBarItemAppearance regardless). On Mac Catalyst the TabView
    // renders as a sidebar via `.sidebarAdaptable`, so each row carries its
    // title next to the icon. The selected tab swaps in the filled icon
    // variant; reading `tabRouter.current` here keeps the swap reactive.
    private func tabItemLabel(icon: String, title: String, tab: AppTab) -> some View {
        let name = tabRouter.current == tab ? selectedIcon(icon) : icon
        #if targetEnvironment(macCatalyst)
        return Label { Text(title) } icon: { tabIcon(name) }
        #else
        return tabIcon(name)
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
                .trackScreen("Explore")
                .tabItem { tabItemLabel(icon: "Compass", title: L("Explore"), tab: .explore) }
                .tag(AppTab.explore)

            StudyView()
                .trackScreen("Study")
                .tabItem { tabItemLabel(icon: "PlusSquare", title: L("Study"), tab: .study) }
                .tag(AppTab.study)

            ChatView()
                .trackScreen("Chat")
                .tabItem { tabItemLabel(icon: "Chat", title: L("Chat"), tab: .chat) }
                .tag(AppTab.chat)

            LibraryView()
                .trackScreen("Library")
                .tabItem { tabItemLabel(icon: "Books", title: L("Library"), tab: .library) }
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
                tabIcon(selected ? selectedIcon(icon) : icon)
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
