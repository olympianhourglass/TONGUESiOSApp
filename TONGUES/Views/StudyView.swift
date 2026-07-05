import SwiftUI

struct StudyView: View {
    @State private var isCreateDeckPresented = false
    // Which Create New Deck tab to open on, and whether Direct should
    // start in Conversation mode — set by the long-press quick actions
    // and the app-icon Home Screen shortcuts.
    @State private var createDeckInitialPage = 0
    @State private var createDeckConversation = false
    @State private var quickActionRouter = QuickActionRouter.shared
    // Custom long-press quick-actions menu on the Create New Deck pill.
    @State private var showQuickActions = false
    // Global frames of each option chip, so a drag from the pill can
    // hit-test which option the finger is over.
    @State private var quickActionFrames: [CreateDeckQuickAction: CGRect] = [:]
    // The option currently under the dragging finger (drives highlight).
    @State private var highlightedQuickAction: CreateDeckQuickAction?
    // Set when a long-press opens the quick-actions menu, so the tap
    // that rides along with the finger lift doesn't also open the full
    // Create New Deck sheet. Auto-cleared shortly after the gesture ends.
    @State private var suppressNextCreateTap = false
    // First-run tutorial: a floating hand points new users at the
    // Create New Deck button. Shown once (persisted in AppStorage) when a
    // freshly-onboarded user lands here with an empty library.
    @State private var createButtonFrame: CGRect = .zero
    @State private var subscription = SubscriptionService.shared
    @State private var auth = AuthService.shared
    @State private var coach = FirstRunCoachController.shared
    @State private var seeder = OnboardingDeckSeeder.shared
    // True when the create-deck sheet was opened from the first-run coach
    // mark, so the sheet runs its own guided parameter/Generate tour.
    @State private var deckSheetTutorial = false
    @State private var vm = LibraryViewModel()
    @State private var path = NavigationPath()
    @State private var showSessionToast = false
    @State private var audioDeck: DeckDocument?
    @State private var showPaywall = false
    // Catches `SubscriptionError.capExceeded` from the audio cap
    // gate; surfaces it via the shared cap alert + paywall.
    @State private var capError: SubscriptionError?
    // Surfaces the Crown → PremiumActionSheet path. Re-enabled now
    // that the StoreKit-backed subscription flow is wired up.
    private let isCrownPaywallSurfaced = true

    // Single chokepoint for every "Start audio session" button on
    // this view. Checks the monthly audio cap, increments the
    // counter, and only then presents ListenSessionView. Surfaces
    // the cap alert (with an upgrade CTA) when the user is over
    // budget. Free + Beginner are capped; Pro + Max are Int.max.
    private func startAudio(_ deck: DeckDocument) {
        Task {
            do {
                try await SubscriptionService.shared.tryStartAudioSession()
                audioDeck = deck
            } catch let error as SubscriptionError {
                capError = error
            } catch {
                // Network/Firebase blip — fail open so audio still works.
                audioDeck = deck
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                            .background(Color.black)
                        bodySection
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                            .background(Color.white)
                    }
                }
                .scrollIndicators(.hidden)
                .background {
                    VStack(spacing: 0) {
                        Color.black
                        Color.white
                    }
                    .ignoresSafeArea()
                }
            }
            .navigationDestination(for: DeckDocument.self) { deck in
                DeckDetailView(deck: deck)
            }
            .navigationDestination(for: FlashcardSession.self) { session in
                SessionIntroView(
                    deck: session.deck,
                    urgency: session.deck.id.flatMap { vm.urgencies[$0] },
                    presentation: .pushed,
                    onSessionComplete: {
                        Task {
                            try? await Task.sleep(for: .seconds(0.4))
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                showSessionToast = true
                            }
                        }
                    }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                CreateNewDeckButton()
                    // Tap opens Create New Deck; a long-press opens the
                    // custom quick-actions menu. Attached here (not a
                    // Button + contextMenu) so there's no system preview
                    // border and we control the menu's placement.
                    .onTapGesture { handleCreateDeckTap() }
                    // Long-press opens the menu; keeping the finger down and
                    // dragging onto an option highlights it, and releasing
                    // over it fires that shortcut. Releasing in place leaves
                    // the menu up so the user can tap instead.
                    .gesture(pressDragQuickActionGesture)
                    // Track the button's on-screen frame so the first-run
                    // coach mark can spotlight + point at it precisely, and
                    // so the quick-actions menu can left-align to the pill.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { newValue in
                        createButtonFrame = newValue
                    }
                    .padding(.trailing, 16)
                // Visible button sits 8pt above the tab bar — the button's
                // 8pt invisible tap halo provides the remaining breathing
                // room, so no extra outer bottom padding is needed.
            }
            .overlay {
                if showQuickActions {
                    quickActionsMenuOverlay
                }
            }
            .fullScreenCover(isPresented: $isCreateDeckPresented) {
                CreateDeckSheet(
                    startTutorial: deckSheetTutorial,
                    initialPage: createDeckInitialPage,
                    initialDirectConversation: createDeckConversation
                ) {
                    isCreateDeckPresented = false
                    // First saved deck spends the free-deck grace; the
                    // next Create New Deck tap will hit the paywall.
                    Task {
                        await SubscriptionService.shared.markFreeDeckUsed()
                        await vm.loadDecks()
                    }
                }
            }
            .fullScreenCover(item: $audioDeck) { deck in
                ListenSessionView(deck: deck)
            }
            .sheet(isPresented: $showPaywall) {
                PremiumActionSheet()
            }
            .subscriptionCapAlert($capError)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await subscription.refresh()
                await vm.loadDecks()
                startCoachmarkIfJustLoggedIn()
                // Cold launch via an app-icon shortcut: the pending action
                // is already set by the time Study appears.
                if let action = quickActionRouter.pending {
                    consumeQuickAction(action)
                }
            }
            // Warm launch: the app-icon shortcut fires while Study is alive.
            .onChange(of: quickActionRouter.pending) { _, action in
                if let action { consumeQuickAction(action) }
            }
            // Catches the login flag flipping while Study is already alive
            // (e.g. ContentView routes here right after sign-in).
            .onChange(of: auth.didJustAuthenticate) { _, justAuthed in
                if justAuthed { startCoachmarkIfJustLoggedIn() }
            }
            // Reveal starter decks as the onboarding seeder saves each one,
            // and once more when it finishes.
            .onChange(of: seeder.seededCount) { _, _ in
                Task { await vm.loadDecks() }
            }
            .onChange(of: seeder.isSeeding) { _, _ in
                Task { await vm.loadDecks() }
            }
            .refreshable { await vm.loadDecks() }
            .sessionCompleteToast(isPresented: $showSessionToast)
        }
    }

    // MARK: Create New Deck entry

    // The Create New Deck button. Free users who've already spent their
    // one free deck get the paywall instead of the sheet; everyone else
    // opens the generator normally.
    private func handleCreateDeckTap() {
        // A tap that arrives on the heels of a long-press-drag (opening or
        // dismissing the quick-actions menu) is spurious — consume it so
        // the full sheet doesn't open behind the collapsing menu.
        if suppressNextCreateTap {
            suppressNextCreateTap = false
            return
        }
        openCreateDeck(page: 0, conversation: false)
    }

    // Opens the Create New Deck sheet on a specific tab, honoring the
    // free-deck paywall gate. Used by the plain tap (page 0), the
    // long-press quick actions, and the app-icon shortcuts.
    private func openCreateDeck(page: Int, conversation: Bool) {
        guard subscription.canCreateFreeDeck else {
            Haptics.medium()
            showPaywall = true
            return
        }
        deckSheetTutorial = false
        createDeckInitialPage = page
        createDeckConversation = conversation
        isCreateDeckPresented = true
    }

    private func openCreateDeck(_ action: CreateDeckQuickAction) {
        Haptics.light()
        openCreateDeck(page: action.page, conversation: action.startsConversation)
    }

    // MARK: Long-press quick-actions menu

    private func openQuickActions() {
        Haptics.medium()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            showQuickActions = true
        }
    }

    // Press-drag-release gesture: a long press opens the menu; if the user
    // keeps holding and drags onto an option, it highlights; releasing over
    // an option fires it. Releasing not over an option leaves the menu open
    // for a follow-up tap. A quick tap (never reaches 0.35s) falls through
    // to the separate .onTapGesture that opens Create New Deck.
    private var pressDragQuickActionGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !showQuickActions {
                        openQuickActions()
                        // The finger is still down; block the tap that
                        // will accompany its release from opening the sheet.
                        suppressNextCreateTap = true
                    }
                case .second(true, let drag):
                    guard let drag else { return }
                    let hit = quickAction(at: drag.location)
                    if hit != highlightedQuickAction {
                        if hit != nil { Haptics.light() }
                        highlightedQuickAction = hit
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                defer { highlightedQuickAction = nil }
                if case .second(_, let drag?) = value,
                   let action = quickAction(at: drag.location) {
                    // Released over an option → fire it (also collapses).
                    selectQuickAction(action)
                } else {
                    // Released anywhere else (empty space, or back over the
                    // pill) → cancel: collapse the menu rather than leaving
                    // it lingering. The tap-suppression flag keeps this
                    // release from opening the Create New Deck sheet.
                    withAnimation(.easeOut(duration: 0.18)) { showQuickActions = false }
                }
                // Clear the suppression just after the release so a tap
                // riding along with it is swallowed, while a later,
                // intentional tap on the pill still opens the sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    suppressNextCreateTap = false
                }
            }
    }

    // Which option chip (if any) contains the given global point.
    private func quickAction(at point: CGPoint) -> CreateDeckQuickAction? {
        quickActionFrames.first(where: { $0.value.contains(point) })?.key
    }

    private func selectQuickAction(_ action: CreateDeckQuickAction) {
        withAnimation(.easeOut(duration: 0.18)) { showQuickActions = false }
        openCreateDeck(action)
    }

    // Custom menu that floats above the pill. Options are left-aligned to
    // the pill's visible left edge (from `createButtonFrame`, offsetting the
    // pill's 8pt tap halo) and stack bottom→top as Direct, Conversation,
    // Camera. No system preview border on the pill.
    private var quickActionsMenuOverlay: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            // Visible pill edges = measured frame inset by the 8pt halo.
            let pillLeftX = createButtonFrame.minX + 8 - origin.x
            let pillTopY = createButtonFrame.minY + 8 - origin.y

            ZStack(alignment: .bottomLeading) {
                // Tap-catcher to dismiss.
                Color.black.opacity(0.06)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { showQuickActions = false }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    quickActionMenuButton(.camera, "Camera", "camera")
                    quickActionMenuButton(.conversation, "Conversation", "bubble.left.and.bubble.right")
                    quickActionMenuButton(.direct, "Direct", "character.bubble")
                }
                .padding(.leading, max(0, pillLeftX))
                // Sit 12pt above the pill's top edge.
                .padding(.bottom, max(0, proxy.size.height - pillTopY + 12))
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomLeading)))
            }
        }
    }

    private func quickActionMenuButton(
        _ action: CreateDeckQuickAction,
        _ title: String,
        _ icon: String
    ) -> some View {
        let isHighlighted = highlightedQuickAction == action
        return Button {
            selectQuickAction(action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
            }
            .foregroundStyle(isHighlighted ? .white : .black)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isHighlighted ? Color.black : Color.white,
                        in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isHighlighted ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
        }
        .buttonStyle(.plain)
        // Report the chip's on-screen frame so a drag from the pill can
        // hit-test whether the finger is over it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newValue in
            quickActionFrames[action] = newValue
        }
    }

    // Consumes an app-icon shortcut: clear it first so it fires once, then
    // open the sheet on the requested tab.
    private func consumeQuickAction(_ action: CreateDeckQuickAction) {
        quickActionRouter.pending = nil
        openCreateDeck(page: action.page, conversation: action.startsConversation)
    }

    // MARK: First-run coach mark

    // Run the tutorial whenever the user just completed an interactive
    // login/sign-up (every time, not only the first). The flag is never
    // set by launch-time session restore, so simply reopening the app
    // doesn't trigger it. Waits a beat for layout so the button frame is
    // measured, then hands the request to the root-level controller (so
    // the hand floats over the tab bar).
    private func startCoachmarkIfJustLoggedIn() {
        guard auth.didJustAuthenticate else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            // Re-check + consume atomically on the main actor: if .task and
            // onChange both fire, only the first survives this guard.
            guard auth.didJustAuthenticate, createButtonFrame != .zero else { return }
            auth.didJustAuthenticate = false
            coach.buttonFrame = createButtonFrame
            coach.onProceed = { dismissCoachmark(open: true) }
            coach.onSkip = { dismissCoachmark(open: false) }
            withAnimation(.easeInOut(duration: 0.3)) { coach.isPresented = true }
        }
    }

    // Tear down the first hand and, when the user tapped the spotlight,
    // open the Create New Deck sheet with the in-sheet tour enabled.
    private func dismissCoachmark(open: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { coach.isPresented = false }
        guard open else { return }
        deckSheetTutorial = true
        coach.runSheetTour = true   // reliable backstop for the sheet
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            isCreateDeckPresented = true
        }
    }

    struct FlashcardSession: Hashable {
        let deck: DeckDocument
    }

    /// Decks ordered by forgetting urgency: the deck whose cards are most likely to be
    /// forgotten now is first (featured), then High Priority, then Keep it Fresh at the
    /// bottom. Decks with no review history fall into the middle via the scheduler's
    /// `newCardForgettingRisk` baseline.
    private var decksByUrgency: [DeckDocument] {
        vm.decks.sorted { lhs, rhs in
            let l = lhs.id.flatMap { vm.urgencies[$0]?.score } ?? 0
            let r = rhs.id.flatMap { vm.urgencies[$0]?.score } ?? 0
            return l > r
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        if let featured = decksByUrgency.first {
            FeaturedDeckHeader(
                deck: featured,
                urgency: featured.id.flatMap { vm.urgencies[$0] },
                onBeginSession: {
                    Haptics.medium()
                    path.append(FlashcardSession(deck: featured))
                },
                onShowDetail: {
                    Haptics.light()
                    path.append(featured)
                },
                onCrownTap: isCrownPaywallSurfaced ? {
                    Haptics.light()
                    showPaywall = true
                } : nil
            )
        } else if seeder.isSeeding {
            // Brand-new user: starter decks are still generating, so show a
            // "setting up" state instead of the empty state.
            SeedingStudyHeader()
        } else {
            EmptyStudyHeader(
                onCrownTap: isCrownPaywallSurfaced ? {
                    Haptics.light()
                    showPaywall = true
                } : nil
            )
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        let others = Array(decksByUrgency.dropFirst())
        let highPriority = Array(others.prefix(4))
        let keepItFresh = Array(others.dropFirst(4))
        // Pulled straight from the VM's recency sort; intentionally
        // independent of the urgency split above so a freshly-created
        // deck appears here even if it's also in High Priority or the
        // featured slot.
        let recentlyAdded = vm.recentlyModifiedDecks

        VStack(alignment: .leading, spacing: 32) {
            if !recentlyAdded.isEmpty {
                DeckHScrollSection(
                    title: "Recently Added",
                    decks: recentlyAdded,
                    urgencies: vm.urgencies,
                    onTap: { deck in
                        Haptics.light()
                        path.append(deck)
                    },
                    onPlay: { deck in
                        Haptics.medium()
                        path.append(FlashcardSession(deck: deck))
                    },
                    onAudio: { deck in
                        Haptics.medium()
                        startAudio(deck)
                    }
                )
            }

            if !highPriority.isEmpty {
                DeckHScrollSection(
                    title: "High Priority",
                    decks: highPriority,
                    urgencies: vm.urgencies,
                    onTap: { deck in
                        Haptics.light()
                        path.append(deck)
                    },
                    onPlay: { deck in
                        Haptics.medium()
                        path.append(FlashcardSession(deck: deck))
                    },
                    onAudio: { deck in
                        Haptics.medium()
                        startAudio(deck)
                    }
                )
            }

            if !keepItFresh.isEmpty {
                DeckGridSection(
                    title: "Keep it Fresh",
                    decks: keepItFresh,
                    urgencies: vm.urgencies,
                    onTap: { deck in
                        Haptics.light()
                        path.append(deck)
                    },
                    onPlay: { deck in
                        Haptics.medium()
                        path.append(FlashcardSession(deck: deck))
                    },
                    onAudio: { deck in
                        Haptics.medium()
                        startAudio(deck)
                    }
                )
            }
        }
        .padding(.vertical, 24)
    }
}

// MARK: - Featured (black) header

struct FeaturedDeckHeader: View {
    let deck: DeckDocument
    var urgency: DeckUrgency? = nil
    let onBeginSession: () -> Void
    let onShowDetail: () -> Void
    // Optional so the parent can hide the Crown/paywall entry point
    // entirely by passing nil. Code path remains in place — flip the
    // call-site flag to surface it again.
    var onCrownTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row sits outside the detail-tap button so the Crown
            // can have its own action without competing with the outer
            // button's hit area. Hitting the rest of the featured card
            // still pushes the deck detail.
            HStack(alignment: .center) {
                Text("STUDY")
                    .font(.custom("PlayfairDisplay-Regular", size: 20))
                    .tracking(-1.6)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: true, vertical: false)
                    // Playfair's Y has serifs that fall outside
                    // the reported advance width — without this
                    // trailing buffer the right edge gets clipped.
                    .padding(.trailing, 4)
                Spacer()
                if let onCrownTap {
                    Button(action: onCrownTap) {
                        Image("Crown")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Button(action: onShowDetail) {
                VStack(alignment: .leading, spacing: 0) {
                    FeaturedCardImage(coverStyle: deck.resolvedCoverStyle)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)

                    HStack {
                        HStack(spacing: 3) {
                            Text(deck.language)
                                .foregroundStyle(.white)
                            Text(deck.level)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Text(deck.title)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text("\(deck.items.count) Items")
                            .foregroundStyle(.white)
                    }
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .padding(.horizontal, 8)
                    .padding(.top, 52)
                    .padding(.bottom, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 8)

            HStack {
                Text("Active")
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .foregroundStyle(.white)

                Spacer()

                Button(action: onBeginSession) {
                    HStack(spacing: 8) {
                        Text("Begin Session")
                            .font(.custom("NeueHaasDisplay-Light", size: 16))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 20)
        }
        .padding(.top, 12)
    }
}

struct FeaturedCardImage: View {
    var coverStyle: DeckCoverStyle = .gradient
    @State private var isVideoPlaying = false
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            DeckCoverFill(style: coverStyle, isPlaying: isVideoPlaying)
            Text("TONGUES")
                .font(.custom("PlayfairDisplay-Regular", size: 12))
                .tracking(-0.96)
                .foregroundStyle(coverStyle.labelColor)
                .padding(.top, 14)
                .padding(.leading, 16)
        }
        .frame(width: 220, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(coverStyle == .black ? 0.18 : 0), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .onLongPressGesture(minimumDuration: 0.3) {
            guard coverStyle.isVideo else { return }
            Haptics.medium()
            playbackTask?.cancel()
            isVideoPlaying = true
            playbackTask = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled {
                    await MainActor.run { isVideoPlaying = false }
                }
            }
        }
    }
}

// Shown on the Study tab for a freshly-onboarded user while their starter
// decks are being auto-generated. Mirrors EmptyStudyHeader's dark layout.
struct SeedingStudyHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("STUDY")
                .font(.custom("PlayfairDisplay-Regular", size: 20))
                .tracking(-1.6)
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Setting up your first decks…")
                        .font(.custom("NeueHaasDisplay-Light", size: 28))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("We're building a few starter decks from your interests. They'll appear here in a moment.")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 30)
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyStudyHeader: View {
    // Optional so the parent can hide the Crown/paywall entry point —
    // see `FeaturedDeckHeader.onCrownTap` note.
    var onCrownTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Text("STUDY")
                    .font(.custom("PlayfairDisplay-Regular", size: 20))
                    .tracking(-1.6)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 4)
                Spacer()
                if let onCrownTap {
                    Button(action: onCrownTap) {
                        Image("Crown")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("No decks yet")
                    .font(.custom("NeueHaasDisplay-Light", size: 28))
                    .foregroundStyle(.white)
                Text("Tap “Create new deck” below to start.")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 30)
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Body grid sections

struct DeckHScrollSection: View {
    let title: String
    let decks: [DeckDocument]
    var urgencies: [String: DeckUrgency] = [:]
    let onTap: (DeckDocument) -> Void
    let onPlay: (DeckDocument) -> Void
    var onAudio: (DeckDocument) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.custom("NeueHaasDisplay-Light", size: 22))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(decks) { deck in
                        DeckMiniCard(
                            deck: deck,
                            urgency: deck.id.flatMap { urgencies[$0] },
                            onTap: { onTap(deck) },
                            onPlay: { onPlay(deck) },
                            onAudio: { onAudio(deck) }
                        )
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

struct DeckGridSection: View {
    let title: String
    let decks: [DeckDocument]
    var urgencies: [String: DeckUrgency] = [:]
    let onTap: (DeckDocument) -> Void
    let onPlay: (DeckDocument) -> Void
    var onAudio: (DeckDocument) -> Void = { _ in }

    // Row spacing pattern. LazyVGrid only supports a single uniform
    // spacing, so we lay out the grid by hand to give every row gap
    // (including row 0 → row 1) the doubled breathing room.
    private let columnSpacing: CGFloat = 12
    private let rowGap: CGFloat = 24               // every row → next row

    // Chunk into pairs so each HStack renders one row of the two-column
    // grid. Last row may be a single deck — we pad with a clear cell so
    // the lone card stays in the leading column instead of stretching.
    private var deckRows: [[DeckDocument]] {
        stride(from: 0, to: decks.count, by: 2).map { idx in
            Array(decks[idx..<min(idx + 2, decks.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.custom("NeueHaasDisplay-Light", size: 22))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                ForEach(Array(deckRows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: columnSpacing) {
                        ForEach(row) { deck in
                            DeckMiniCard(
                                deck: deck,
                                urgency: deck.id.flatMap { urgencies[$0] },
                                onTap: { onTap(deck) },
                                onPlay: { onPlay(deck) },
                                onAudio: { onAudio(deck) }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        if row.count == 1 {
                            // Holds the trailing column open so a lone
                            // deck in the last row keeps its leading
                            // column alignment with the rows above.
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, topPadding(forRowIndex: rowIdx))
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func topPadding(forRowIndex rowIdx: Int) -> CGFloat {
        // First row sits flush under the section title; every row from
        // there on gets the doubled gap, so row 0 → row 1 also reads
        // as full breathing room — not a tight pair.
        rowIdx == 0 ? 0 : rowGap
    }
}

struct DeckMiniCard: View {
    let deck: DeckDocument
    var urgency: DeckUrgency? = nil
    let onTap: () -> Void
    let onPlay: () -> Void
    var onAudio: () -> Void = {}

    @State private var isVideoPlaying = false
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(deck.language)
                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                            .foregroundStyle(.black)
                        Text(deck.level)
                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    DeckCoverFill(style: deck.resolvedCoverStyle, isPlaying: isVideoPlaying)
                        .aspectRatio(90.0 / 53.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 2)
                        .scaleEffect(1.2 / (1.6 * 1.4))
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.3) {
                            guard deck.resolvedCoverStyle.isVideo else { return }
                            Haptics.medium()
                            playbackTask?.cancel()
                            isVideoPlaying = true
                            playbackTask = Task {
                                try? await Task.sleep(for: .seconds(3))
                                if !Task.isCancelled {
                                    await MainActor.run { isVideoPlaying = false }
                                }
                            }
                        }

                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deck.title)
                            .font(.custom("NeueHaasDisplay-Light", size: 16))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: onAudio) {
                            Image("Headphones")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .frame(width: 32, height: 32)
                                .background(Color.black.opacity(0.04))
                                .clipShape(Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: onPlay) {
                            Image("Play")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .frame(width: 32, height: 32)
                                .background(Color.black)
                                .clipShape(Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .background(Color.white)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .aspectRatio(200.0 / 244.0, contentMode: .fit)
            .background(Color(white: 0.94))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let count = "\(deck.items.count)"
        if let label = urgency?.statusLabel {
            return "\(count) · \(label)"
        }
        return count
    }
}

// MARK: - Floating create button (kept from previous implementation)

// Pure visual of the floating pill. Tap + long-press are attached by the
// parent (StudyView) so it can disambiguate a tap (open Create New Deck)
// from a long-press (custom quick-actions menu) without the system
// context-menu chrome/border.
struct CreateNewDeckButton: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
            Text("Create new deck")
                .font(.custom("NeueHaasDisplay-Light", size: 17))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .glassEffect(.regular.tint(.black).interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 8)
        .padding(8)
        .contentShape(.capsule)
    }
}
