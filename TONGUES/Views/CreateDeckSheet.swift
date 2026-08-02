import SwiftUI

// Optional prefill for CreateDeckSheet. When non-nil, the sheet skips
// the random "draw 9 chips from onboarding" path and instead seeds the
// language/level + a single pre-selected topic chip. Used by the Explore
// tab's "You might like these topics" cards so tapping a preset opens
// the generator with everything already filled in.
struct CreateDeckPreset: Equatable {
    var language: String
    // Optional: when a preset carries the recommended dialect (e.g. Explore's
    // topic cards, seeded from the user's saved preference), the sheet opens on
    // that dialect instead of defaulting to the language's first one.
    var dialect: String? = nil
    var level: String
    var topic: String
}

// Navigation path for the generate flow: tap Generate pushes `.curating`,
// then a successful response pushes `.results` and the curating entry is
// silently removed from underneath so the back gesture skips it.
private enum GenerationRoute: Hashable {
    case curating
    case results(GeneratedDeck)
}

struct CreateDeckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CreateDeckViewModel()
    @State private var didApplyProfileDefaults = false
    // Presents the multi-select picker for attaching existing decks as
    // reference material for generation.
    @State private var showReferencePicker = false
    var preset: CreateDeckPreset? = nil
    // When true (first-run path from the Study tab coach mark), the sheet
    // runs a guided hand tour over the parameters + Generate button.
    var startTutorial: Bool = false
    // Opens the Direct tab straight in Conversation mode (the "Conversation"
    // quick action). The initial page itself is seeded into `currentPage`
    // via the custom init below.
    var initialDirectConversation: Bool = false
    let onComplete: () -> Void

    init(
        preset: CreateDeckPreset? = nil,
        startTutorial: Bool = false,
        initialPage: Int = 0,
        initialDirectConversation: Bool = false,
        onComplete: @escaping () -> Void
    ) {
        self.preset = preset
        self.startTutorial = startTutorial
        self.initialDirectConversation = initialDirectConversation
        self.onComplete = onComplete
        // Seed the paged TabView + its bottom toggle to the requested tab
        // (Camera / Direct) so a quick action lands there with no visible
        // swipe from page 0.
        _currentPage = State(initialValue: initialPage)
        _togglePosition = State(initialValue: initialPage)
    }

    // Coach-tour state: collected control frames, the control the tour is
    // currently focusing (drives scroll-to-reveal), and whether it's live.
    @State private var coachStore = CoachFrameStore()
    @State private var showTour = false
    @State private var tourStarted = false
    // Tour driver state. Lives here (a stable view) so the driving task
    // isn't torn down by the frame-anchor churn that re-creates the
    // overlay's coach-tour view on every layout pass.
    @State private var tourStepIndex = 0
    @State private var tourHandDip = false
    @State private var tourRipples: [UUID] = []
    // Hides the spotlight/hand while a scroll is in flight, so nothing
    // chases the moving content.
    @State private var tourHideContent = false
    // Captured from the form's scroll readers so the tour driver can
    // reveal each target directly (more reliable than routing through an
    // onChange observer, which wasn't scrolling the off-screen pills in).
    @State private var vScrollProxy: ScrollViewProxy?
    @State private var hScrollProxy: ScrollViewProxy?
    // FocusState drives the keyboard toolbar's Done button + the
    // background-tap dismiss. The TextField below binds to it.
    @FocusState private var isInterestFieldFocused: Bool
    // Hardware-keyboard page navigation (iPad/Mac): ← / → step through the
    // create pages. A focusable container receives the key presses; because a
    // focused text field consumes arrow keys first, typing in a field still
    // moves the cursor rather than flipping pages.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var pageNavigationFocused: Bool

    // Only offer arrow-key paging where a hardware keyboard is expected —
    // Mac Catalyst or an iPad in a regular-width layout. iPhone is untouched.
    private var supportsArrowTabNav: Bool {
        MacLayout.isMac || horizontalSizeClass == .regular
    }

    // Steps the paged TabView by `delta`, clamped to the available pages.
    // Returns `.handled` when it moves (consuming the key), or `.ignored` at
    // the ends or while a results screen is pushed, so nothing is swallowed.
    private func handleArrowTabNav(_ delta: Int) -> KeyPress.Result {
        guard supportsArrowTabNav, navPath.isEmpty else { return .ignored }
        let maxIndex = pageTitles.count - 1
        let target = min(maxIndex, max(0, currentPage + delta))
        guard target != currentPage else { return .ignored }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage = target
        }
        return .handled
    }
    // Drives the bottom page toggle + the TabView's horizontal
    // animation. Page 0 is the existing Generate form; pages 1-3 are
    // intentionally blank for now.
    @State private var currentPage: Int = 0
    // Bound to the toggle's `.scrollPosition(id:)`. Mirrors
    // currentPage in both directions so swiping the chip strip moves
    // the TabView and vice-versa.
    @State private var togglePosition: Int? = 0
    // Two-step generation nav stack: curating → results. Replaces the
    // older `isPresented: $vm.showResults` destination so we can show a
    // dedicated loading screen between the tap and the results.
    @State private var navPath: [GenerationRoute] = []
    // Drives CuratingView's soft exit (visual + audio fade) before the
    // path swap that pushes the results view in.
    @State private var isCurationFinishing: Bool = false

    var body: some View {
        NavigationStack(path: $navPath) {
            TabView(selection: $currentPage) {
                generateFormPage
                    .tag(0)
                CameraPage(
                    language: $vm.language,
                    dialect: $vm.dialect,
                    level: vm.level,
                    onAttributeTap: { vm.activeAttribute = $0 },
                    onSaved: {
                        Haptics.success()
                        onComplete()
                        dismiss()
                    }
                )
                .tag(1)
                DirectPage(
                    language: $vm.language,
                    dialect: $vm.dialect,
                    level: vm.level,
                    onAttributeTap: { vm.activeAttribute = $0 },
                    onSaved: {
                        Haptics.success()
                        onComplete()
                        dismiss()
                    },
                    startInConversation: initialDirectConversation
                )
                .tag(2)
                SongVideoLinkPage(
                    language: $vm.language,
                    dialect: $vm.dialect,
                    level: vm.level,
                    onSaved: {
                        Haptics.success()
                        onComplete()
                        dismiss()
                    }
                )
                .tag(3)
                LargeBodyTextPage(
                    language: $vm.language,
                    dialect: $vm.dialect,
                    level: vm.level,
                    onAttributeTap: { vm.activeAttribute = $0 },
                    onSaved: {
                        Haptics.success()
                        onComplete()
                        dismiss()
                    }
                )
                .tag(4)
                // Media page hidden for App Store submission — restore
                // by uncommenting this block and bumping the toggle's
                // ForEach range back to 0..<5 + adding "Media" to
                // pageTitles below.
                // comingSoonPage
                //     .tag(4)
            }
            // Native page-style horizontal swipe with spring snap.
            // `indexDisplayMode: .never` hides the system dots since
            // the custom toggle below is the source of truth.
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Full-bleed white backdrop behind the paged TabView — the same
            // technique the Study tab uses for its status bar. The backdrop
            // ignores the safe area so it fills the status-bar strip with the
            // page background color, turning the old white *clipping* bar into
            // a seamless continuation of the page. Crucially this is a
            // BACKGROUND layer, not `.ignoresSafeArea` on the TabView itself
            // (which blanks the non-initial pages), so paging stays intact.
            .background {
                // The Camera tab is inverted: black page, light chrome.
                (currentPage == 1 ? Color.black : Color.white).ignoresSafeArea()
            }
            // The nav bar carries no title/items (the close X is a custom
            // overlay), so hide it outright.
            .toolbar(.hidden, for: .navigationBar)
            // Custom close button (replaces the prior ToolbarItem). We
            // own positioning here so the X + its circular background
            // can sit exactly 8pt from the screen's leading edge —
            // tighter than the system nav-bar default. The X stays
            // dead-center inside its own circle because the circle
            // sizes from the Image's fixed frame, not from any outer
            // padding. Liquid Glass on the circle so it reads as a
            // native nav-style close button.
            .overlay(alignment: .topLeading) {
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(currentPage == 1 ? .white : .black)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .padding(.leading, 8)
                // Sit just below the top safe area, where a navigational
                // close button would normally live.
                .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom) {
                if isInterestFieldFocused {
                    // While typing, the tab + pinned bar give way to a single
                    // elegant Liquid Glass "Done" pill floating just above the
                    // keyboard, trailing-aligned.
                    HStack {
                        Spacer()
                        Button {
                            Haptics.light()
                            isInterestFieldFocused = false
                        } label: {
                            Text(L("Done"))
                                .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                } else {
                    VStack(spacing: 0) {
                        if currentPage == 0 {
                            // The Generate form's drop-downs + Generate button
                            // live in a pinned white bar above the page tab.
                            generateBottomBar
                        }
                        bottomPageToggle
                            .padding(.horizontal, 24)
                            // 44pt above the bottom safe area, matching the
                            // gap a tab bar would normally hold.
                            .padding(.bottom, 44)
                    }
                }
            }
            .navigationDestination(for: GenerationRoute.self) { route in
                destinationView(for: route)
            }
            // Hardware-keyboard paging (iPad/Mac): ← / → step between the
            // create pages. The focusable container receives the key presses;
            // a focused text field consumes arrows first, so typing still moves
            // the cursor. Focus effects are hidden so no ring appears.
            .focusable(supportsArrowTabNav)
            .focusEffectDisabled()
            .focused($pageNavigationFocused)
            .onKeyPress(.leftArrow) { handleArrowTabNav(-1) }
            .onKeyPress(.rightArrow) { handleArrowTabNav(1) }
            .onChange(of: isInterestFieldFocused) { _, focused in
                // When the interests field gives up the keyboard, hand focus
                // back to the pager so arrows resume flipping pages.
                if !focused, supportsArrowTabNav {
                    pageNavigationFocused = true
                }
            }
            // Single source for "we just landed on a page" — fires for
            // both tap-from-toggle and swipe-from-TabView so the haptic
            // feels identical on both gestures.
            .onChange(of: currentPage) { _, newValue in
                Haptics.light()
                // TabView-driven change (page swipe) needs to mirror
                // into the toggle's scroll position.
                if togglePosition != newValue {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        togglePosition = newValue
                    }
                }
                applyCreateStatusBar()
                // Keep arrow-key paging alive after a page change.
                if supportsArrowTabNav {
                    pageNavigationFocused = true
                }
            }
            .onChange(of: togglePosition) { _, newValue in
                // Toggle-driven change (swiping/tapping the chip
                // strip) drives the TabView via currentPage.
                if let newValue, currentPage != newValue {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage = newValue
                    }
                }
            }
            .onChange(of: navPath) { _, _ in applyCreateStatusBar() }
        }
        .onAppear {
            applyCreateStatusBar()
            // Take focus so the ← / → keys page immediately on iPad/Mac.
            if supportsArrowTabNav {
                pageNavigationFocused = true
            }
        }
        .onDisappear {
            AppTabRouter.shared.forceLightStatusBar = false
            AppTabRouter.shared.forceDarkStatusBar = false
        }
        .alert(L("Generation failed"), isPresented: errorAlertBinding) {
            Button(L("OK")) { vm.generationError = nil }
        } message: {
            Text(vm.generationError ?? "")
        }
        .subscriptionCapAlert(Binding(
            get: { vm.capError },
            set: { vm.capError = $0 }
        ))
        .sheet(item: $vm.activeAttribute) { attribute in
            Group {
                if attribute == .dialect {
                    DialectPickerSheet(
                        language: vm.language,
                        selection: bindingFor(attribute)
                    )
                } else {
                    AttributeOptionsSheet(
                        attribute: attribute,
                        options: vm.options(for: attribute),
                        selection: bindingFor(attribute)
                    )
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: vm.language) { _, _ in
            vm.handleLanguageChange()
        }
        .task {
            await applyProfileDefaultsIfNeeded()
        }
        // First-run path: drive the whole guided tour from here. This task
        // lives on the (stable) sheet, so the anchor-frame churn that
        // re-creates the overlay's tour view can't cancel it. Steps the
        // hand through every parameter to Generate.
        .task {
            // Either the passed flag OR the controller's reliable signal
            // arms the tour (the latter backstops @State propagation).
            let wantsTour = startTutorial || FirstRunCoachController.shared.runSheetTour
            guard wantsTour, !tourStarted else { return }
            FirstRunCoachController.shared.runSheetTour = false
            tourStarted = true
            await runDeckTour()
        }
        // Tour overlay at the SHEET ROOT (not the page) so the scrim covers
        // the full screen — attaching it to the page left the top/bottom
        // safe-area + toggle strips uncovered ("odd spacing"). Targets
        // report GLOBAL frames into coachStore; the safe-area-ignoring
        // GeometryReader has origin (0,0), so global == local here.
        .overlay {
            if showTour {
                GeometryReader { proxy in
                    let g = currentTourTargetRect
                    let local = g == .zero
                        ? CGRect.zero
                        : CGRect(x: g.minX - proxy.frame(in: .global).minX,
                                 y: g.minY - proxy.frame(in: .global).minY,
                                 width: g.width, height: g.height)
                    CreateDeckCoachTour(
                        step: currentTourStep,
                        targetRect: local,
                        containerSize: proxy.size,
                        handDip: tourHandDip,
                        ripples: tourRipples,
                        hideContent: tourHideContent,
                        onSkip: { showTour = false }
                    )
                }
                .ignoresSafeArea()
            }
        }
    }

    // Advances the in-sheet coach tour: reveal each control, glide + tap
    // the hand with a ripple, then move on. Sleeps return false on
    // cancellation (sheet dismissed) so the loop bails cleanly.
    private func runDeckTour() async {
        // Let the sheet finish presenting + the static pill frames + viewport
        // get measured.
        guard await tourSleep(600) else { return }
        // Dim appears immediately; the spotlight stays hidden until the
        // first target has been scrolled into place.
        tourHideContent = true
        withAnimation(.easeInOut(duration: 0.3)) { showTour = true }
        guard await tourSleep(250) else { return }

        // One row, one element at a time: scroll to it, then point + tap.
        for index in tourSteps.indices {
            let target = tourSteps[index].target

            // Hide the spotlight while we scroll this target into view, so
            // nothing chases the moving content.
            withAnimation(.easeInOut(duration: 0.2)) { tourHideContent = true }
            guard await tourSleep(200) else { return }
            scrollToTarget(target)
            // Wait out the scroll + the offset/viewport reports so the
            // computed on-screen frame is stable.
            guard await tourSleep(700) else { return }

            // Point at the now-stable target, then reveal.
            tourStepIndex = index
            withAnimation(.easeInOut(duration: 0.3)) { tourHideContent = false }
            guard await tourSleep(400) else { return }

            for _ in 0..<2 {
                spawnTourRipple()
                Haptics.light()
                withAnimation(.easeIn(duration: 0.16)) { tourHandDip = true }
                guard await tourSleep(220) else { return }
                withAnimation(.easeOut(duration: 0.3)) { tourHandDip = false }
                guard await tourSleep(650) else { return }
            }
        }

        guard await tourSleep(400) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { showTour = false }
    }

    // Scrolls the given target into view: the attribute pill horizontally
    // (and keeps the strip vertically centered), or the Generate button.
    private func scrollToTarget(_ target: CoachTarget) {
        withAnimation(.easeInOut(duration: 0.45)) {
            if let attr = target.deckAttribute {
                vScrollProxy?.scrollTo("coach.attributes", anchor: .center)
                hScrollProxy?.scrollTo(attr, anchor: .center)
            } else {
                vScrollProxy?.scrollTo("coach.generate", anchor: .center)
            }
        }
    }

    private func tourSleep(_ ms: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(ms))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func spawnTourRipple() {
        let id = UUID()
        tourRipples.append(id)
        Task {
            try? await Task.sleep(for: .milliseconds(950))
            tourRipples.removeAll { $0 == id }
        }
    }

    // The step currently being highlighted + its on-screen frame.
    private var currentTourStep: CreateDeckTourStep? {
        guard tourStepIndex >= 0, tourStepIndex < tourSteps.count else { return nil }
        return tourSteps[tourStepIndex]
    }
    // On-screen global frame of the currently-highlighted control (.zero
    // until measured). Pills are computed from their static content
    // position + the live scroll offset; Generate uses its measured frame.
    private var currentTourTargetRect: CGRect {
        guard let step = currentTourStep else { return .zero }
        return coachStore.globalFrame(for: step.target)
    }

    // MARK: - Pages

    // Page 0: the original Generate form. Untouched apart from being
    // wrapped here as a TabView page.
    private var generateFormPage: some View {
        ScrollViewReader { vProxy in
        ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    TextField(
                        L("Enter what you're interested in…"),
                        text: $vm.interestPrompt,
                        axis: .vertical
                    )
                    .font(.custom("NeueHaasDisplay-Light", size: 28))
                    .foregroundStyle(.primary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isInterestFieldFocused)
                    .padding(.top, 8)
                    // Extra breathing room below the title so it floats in
                    // the white top area, matching the design comp.
                    .padding(.bottom, 20)

                    // Two-row horizontal-scrolling chip strip. Each row
                    // is its own HStack with a uniform 8pt spacing so
                    // the gap between adjacent chips on a row is always
                    // exactly 8pt — independent of the other row's
                    // chip widths (the previous LazyHGrid layout pinned
                    // columns to the widest chip in each pair, which
                    // produced the inconsistent visual gaps that the
                    // latest design pass called out). Each row scrolls
                    // together inside the parent horizontal ScrollView.
                    // No horizontal padding override here — the strip
                    // inherits the parent VStack's 8pt inset so the
                    // first chip on each row left-aligns with the
                    // "Language" label that sits in the AttributesRow
                    // immediately below.
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(interestRowChips(rowIndex: 0), id: \.self) { interest in
                                    InterestChip(
                                        title: interest,
                                        isSelected: vm.selectedInterests.contains(interest)
                                    ) {
                                        vm.toggleInterest(interest)
                                    }
                                }
                            }
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(interestRowChips(rowIndex: 1), id: \.self) { interest in
                                    InterestChip(
                                        title: interest,
                                        isSelected: vm.selectedInterests.contains(interest)
                                    ) {
                                        vm.toggleInterest(interest)
                                    }
                                }
                            }
                        }
                    }
                    .scrollClipDisabled()

                    HStack(spacing: 12) {
                        ToneLabel(title: L("Casual"), isSelected: vm.selectedTones.contains("Casual")) {
                            vm.toggleTone("Casual")
                        }
                        ToneLabel(title: L("Formal"), isSelected: vm.selectedTones.contains("Formal")) {
                            vm.toggleTone("Formal")
                        }
                    }
                    .padding(.top, 8)
                }
                // Clears the 44pt-tall custom close button overlay
                // (36pt circle + 8pt top inset) and adds the generous white
                // top area from the design comp so the title floats.
                .padding(.top, 96)
                .padding(.horizontal, 8)
                // Breathing room before the pinned bottom bar takes over.
                .padding(.bottom, 24)
            }
            // Subtle white→light-gray gradient behind the scrolling content.
            // The pinned bottom bar (attribute pills + Generate) is solid
            // white, so it reads as "interrupting" this gradient.
            .background(
                LinearGradient(
                    colors: [Color.white, Color(white: 0.93)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            // Drag-to-dismiss the keyboard inside the scroll view —
            // standard iOS Mail/Notes behavior. Combined with the
            // toolbar Done button this gives the user three ways out:
            // scroll, tap Done, or tap outside the field.
            .scrollDismissesKeyboard(.interactively)
            // Tap-anywhere-outside-the-field. Attached to the scroll
            // view's background area so it doesn't intercept taps on
            // the chips / attribute pills / Generate button.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isInterestFieldFocused = false }
            )
            .onAppear { vScrollProxy = vProxy }
        }
        .sheet(isPresented: $showReferencePicker) {
            DeckReferencePickerSheet(initiallySelected: vm.referencedDecks) { chosen in
                vm.referencedDecks = chosen
            }
        }
    }

    // "Reference decks" affordance: attached decks show as removable
    // chips, followed by an add pill that opens the multi-select picker.
    // Feeds vm.referencedDecks into the generation prompt. Rendered inline
    // (no own ScrollView) so it trails the attribute pills inside the
    // bottom strip's single horizontal scroll.
    private var referenceDeckPills: some View {
        HStack(spacing: 10) {
            ForEach(vm.referencedDecks) { deck in
                HStack(spacing: 6) {
                    Text(deck.title)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Button {
                        Haptics.light()
                        vm.referencedDecks.removeAll { $0.id == deck.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black))
            }

            Button {
                Haptics.light()
                isInterestFieldFocused = false
                showReferencePicker = true
            } label: {
                // Same glass-capsule style as the attribute drop-down pills,
                // no icon.
                Text(L(vm.referencedDecks.isEmpty ? "Reference a deck" : "Add"))
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    // Display names for each page. Page 0 ("Generate") is the existing
    // form; 1-3 are placeholders shown only as titles for now. "Media"
    // is hidden for App Store submission — re-add as the 5th entry to
    // restore.
    private let pageTitles = ["Generate", "Camera", "Direct", "Song or Video Link", "Large Body Text"]

    // Placeholder for Media (page 4). Same centered "Coming Soon" look
    // the original blank-page helper used.
    private var comingSoonPage: some View {
        VStack {
            Spacer()
            Text(L("Coming Soon"))
                .font(.custom("NeueHaasDisplay-Light", size: 20))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Pages 1-3 — intentionally blank for now; their content lives in
    // the toggle's spec but hasn't been built yet.
    private func blankPage(index: Int) -> some View {
        VStack {
            Spacer()
            Text(L(pageTitles[index]))
                .font(.custom("NeueHaasDisplay-Light", size: 20))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom controls

    // Pinned white bar for the Generate form: the attribute drop-downs in
    // a horizontally-scrolling glass-pill strip, then the black Generate
    // button. Sits on solid white so it "interrupts" the scroll area's
    // subtle gradient, matching the design comp.
    private var generateBottomBar: some View {
        VStack(spacing: 16) {
            ScrollViewReader { hProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 10) {
                        AttributesRow(
                            language: vm.language,
                            dialect: vm.dialect,
                            content: vm.contentType,
                            amount: vm.amount,
                            level: vm.level,
                            onTap: { vm.activeAttribute = $0 },
                            coachStore: coachStore
                        )
                        // Reference-deck chips + pill trail after the Level
                        // pill in the same horizontal strip.
                        referenceDeckPills
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
                .onAppear { hScrollProxy = hProxy }
                // Track the strip's viewport (global) + live offset so the
                // tour computes each pill's on-screen frame deterministically.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newValue in
                    coachStore.hViewport = newValue
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, newValue in
                    coachStore.hOffsetX = newValue
                }
            }
            .id("coach.attributes")

            Button {
                Haptics.medium()
                runGeneration()
            } label: {
                ZStack {
                    Text(L("Generate"))
                        .font(.custom("NeueHaasDisplay-Light", size: 22))
                        .foregroundStyle(.white)
                        .opacity(vm.isGenerating ? 0 : 1)
                    if vm.isGenerating {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(Color.black)
                .clipShape(Capsule())
                .coachAnchor(.generate, store: coachStore)
            }
            .buttonStyle(.plain)
            .disabled(vm.isGenerating)
            .padding(.horizontal, 20)
            .id("coach.generate")
        }
        .padding(.top, 12)
        // ~40pt gap between the Generate button and the page tab below it,
        // which shifts the whole bar (and the scroll content above) upward.
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .background(Color.white)
    }

    // 4-item page toggle, pinned 44pt above the bottom safe area.
    // Borrows the swipe-snap pattern from the flashcard language
    // picker: horizontal ScrollView + `.scrollPosition(id:)` so the
    // user can flick the strip and a chip snaps to the leading edge,
    // OR tap a chip directly. Liquid Glass capsule wraps the whole
    // strip. Haptics fire from the shared onChange in the body.
    private var bottomPageToggle: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(0..<5, id: \.self) { idx in
                        Button {
                            // Mirrors the flashcard tap pattern.
                            // Writing to the bound scrollPosition id
                            // triggers an animated snap to that chip.
                            withAnimation(.easeInOut(duration: 0.3)) {
                                togglePosition = idx
                            }
                        } label: {
                            Text(L(pageTitles[idx]))
                                .font(.system(size: 15, weight: currentPage == idx ? .semibold : .regular))
                                // White chips on the inverted Camera tab.
                                .foregroundStyle((currentPage == 1 ? Color.white : Color.black).opacity(currentPage == idx ? 1 : 0.4))
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(idx)
                    }
                    // Trailing spacer so even the last chip can land
                    // at the leading edge of the strip.
                    Color.clear
                        .frame(width: max(0, proxy.size.width - 120), height: 1)
                }
                .padding(.leading, 20)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $togglePosition, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // Seeds Language / Dialect / Level and Interests from the user's
    // saved onboarding answers so opening Create New lands on the
    // language they care most about (instead of "Arabic · MSA · A1")
    // and shows interest chips drawn from their own Q8 selections
    // (instead of the legacy medical sample list). Runs once per sheet
    // lifetime; never overwrites a value the user picked.
    // Tracks what the last seeding pass wrote so a later Firestore
    // reconcile can tell whether the user has since changed a field by
    // hand (and must not be overwritten).
    private struct AttributeSeed {
        var language: String?
        var seededInterests = false
    }

    @MainActor
    private func applyProfileDefaultsIfNeeded() async {
        guard !didApplyProfileDefaults else { return }
        didApplyProfileDefaults = true

        // Preset prefill (Explore tab "You might like these topics"):
        // overrides the random-9-chip draw and the first-language default
        // with an explicit topic + language + level. The topic is pinned
        // as the only selected chip; any additional onboarding chips fill
        // the rest of the row so the user can still expand the selection.
        if let preset {
            // Language/level come from the preset synchronously, so there's
            // no cold-start flash here. Fill extra interest chips from the
            // cache instantly; only hit the network if the cache is empty.
            let cachedInterests = UserService.cachedOnboarding()?.interests
            applyPreset(preset, interests: cachedInterests)
            if cachedInterests == nil {
                let profile = try? await UserService.fetchProfile()
                applyPreset(preset, interests: profile?.onboarding?.interests)
            }
            return
        }

        // Seed instantly from the on-device cache so the AttributesRow
        // shows the user's real language immediately instead of flashing
        // the generic "Arabic · MSA · A1" default while Firestore loads.
        let seed = applyOnboardingDefaults(UserService.cachedOnboarding(), previousSeed: nil)

        // Reconcile with the authoritative Firestore copy when it lands.
        // Fields the user has since changed by hand are left alone.
        let profile = try? await UserService.fetchProfile()
        _ = applyOnboardingDefaults(profile?.onboarding, previousSeed: seed)
    }

    @MainActor
    private func applyPreset(_ preset: CreateDeckPreset, interests: [String]?) {
        let canonical = canonicalLanguageName(preset.language)
        vm.language = canonical
        // Honor the preset's dialect (snapped to a canonical option) when it
        // carries one; otherwise fall back to the language's first dialect.
        if let presetDialect = preset.dialect {
            vm.dialect = canonicalDialectName(for: canonical, dialect: presetDialect)
        } else {
            vm.dialect = dialects(for: canonical).first ?? vm.dialect
        }
        let validLevels = levels(for: canonical)
        vm.level = validLevels.contains(preset.level) ? preset.level : (validLevels.first ?? vm.level)

        var options: [String] = [preset.topic]
        if let interests {
            for interest in interests.shuffled() where interest != preset.topic && options.count < 9 {
                options.append(interest)
            }
        }
        vm.interestOptions = options
        vm.selectedInterests = [preset.topic]
    }

    // Applies language / dialect / level / interest defaults from an
    // onboarding-answers source. `previousSeed` is nil on the first
    // (cache) pass and carries the cache result on the second (network)
    // pass so we only overwrite fields the user hasn't touched. Returns
    // what it seeded so the caller can thread it into the next pass.
    @MainActor
    @discardableResult
    private func applyOnboardingDefaults(
        _ answers: OnboardingAnswers?,
        previousSeed: AttributeSeed?
    ) -> AttributeSeed {
        var seed = AttributeSeed()
        guard let answers else { return previousSeed ?? seed }

        // Interest chips — random 9 from the user's onboarding picks.
        // Seed once (cache pass); the network pass leaves them be so the
        // chips don't visibly reshuffle a beat after the sheet opens. Only
        // seed while the user hasn't selected any, so an in-progress
        // selection is never wiped.
        let alreadySeededInterests = previousSeed?.seededInterests == true
        if alreadySeededInterests {
            seed.seededInterests = true
        } else if let interests = answers.interests, !interests.isEmpty, vm.selectedInterests.isEmpty {
            vm.interestOptions = Array(interests.shuffled().prefix(9))
            vm.selectedInterests = []
            seed.seededInterests = true
        }

        guard let pref = answers.languagePreferences?.first else {
            seed.language = previousSeed?.language
            return seed
        }
        // Normalize Claude-style shorthand ("Mandarin" → "Chinese (Mandarin)")
        // so the AttributesRow shows it and the dialect/level pickers find
        // matching options.
        let canonical = canonicalLanguageName(pref.language)
        // Only overwrite the language if the user hasn't changed it away
        // from what the previous pass seeded (on the first pass there's no
        // prior seed, so we always apply).
        let mayOverwrite = previousSeed == nil || vm.language == previousSeed?.language
        guard mayOverwrite else {
            seed.language = previousSeed?.language
            return seed
        }
        vm.language = canonical
        // Snap dialect / level to options valid for that language; falls
        // back to the user's onboarding choice when it's already valid.
        let validDialects = dialects(for: canonical)
        vm.dialect = validDialects.contains(pref.dialect) ? pref.dialect : (validDialects.first ?? vm.dialect)
        let validLevels = levels(for: canonical)
        vm.level = validLevels.contains(pref.level) ? pref.level : (validLevels.first ?? vm.level)
        seed.language = canonical
        return seed
    }

    // Split out of the navigationDestination closure to keep the
    // Swift type-checker out of timeout territory in body — the inline
    // switch over CuratingView/DeckResultsView with their closures
    // was tipping the compiler over.
    @ViewBuilder
    private func destinationView(for route: GenerationRoute) -> some View {
        switch route {
        case .curating:
            CuratingView(
                onCancel: {
                    if navPath.last == .curating {
                        navPath.removeLast()
                    }
                },
                isFinishing: $isCurationFinishing
            )
        case .results(let deck):
            DeckResultsView(
                deck: deck,
                onComplete: onComplete,
                onRegenerate: {
                    // Same prompt parameters still live in `vm`
                    // (interestPrompt, language, dialect, level,
                    // contentType, amount, tones, interests) —
                    // re-running runGeneration replays the same query
                    // and replaces .results with a fresh curating →
                    // results pass.
                    runGeneration(replacingStack: true)
                }
            )
        }
    }

    // Drives the curating → results pipeline. Shared by both the
    // Generate button on the form and the Regenerate button on the
    // results screen. When `replacingStack` is true (the regenerate
    // case) we reset the nav stack to a single .curating entry so the
    // user can't swipe back to the stale results behind it; the form
    // case appends because the stack is empty at that point.
    private func runGeneration(replacingStack: Bool = false) {
        if replacingStack {
            navPath = [.curating]
        } else {
            navPath.append(.curating)
        }
        Task {
            await vm.generate()
            // Guard on `.curating` being the current top: if the user
            // already cancelled out of the curating screen, silently
            // drop the result instead of bouncing them into Results.
            guard navPath.last == .curating else { return }

            if let deck = vm.generatedDeck {
                // A deck was actually generated in this language, so it now
                // qualifies for the picker's "Recently Used" section.
                RecentAttributeStore.recordLanguage(vm.language)
                // Soft hand-off: signal CuratingView to fade visuals +
                // audio, give it a beat to do so, then swap
                // [.curating] → [.results] in one mutation so the
                // NavigationStack push is single (no flicker from a
                // later restructure).
                isCurationFinishing = true
                // Matches `CuratingView.fadeDuration` (0.5s) so the
                // audio fade can taper fully past hearing before the
                // view unmounts and the player stops.
                try? await Task.sleep(for: .milliseconds(500))
                navPath = [.results(deck)]
                isCurationFinishing = false
            } else {
                // Generation failed — pop curating so the error alert
                // lands on whichever surface the user came from.
                if navPath.last == .curating {
                    navPath.removeLast()
                }
            }
        }
    }

    // Drives the status bar across the Create-New flow: white (light)
    // content over the black surfaces (the Camera tab and the black
    // Curating screen), black (dark) content over the white surfaces
    // (the Generate/other forms and the white Results screen).
    private func applyCreateStatusBar() {
        let wantsLight: Bool
        switch navPath.last {
        case .curating: wantsLight = true          // black immersive screen
        case .results:  wantsLight = false         // white results screen
        case .none:     wantsLight = (currentPage == 1)  // black Camera tab vs white forms
        }
        AppTabRouter.shared.forceLightStatusBar = wantsLight
        AppTabRouter.shared.forceDarkStatusBar = !wantsLight
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { vm.generationError != nil },
            set: { if !$0 { vm.generationError = nil } }
        )
    }

    // Splits the chip options into a top row (even indices) and a
    // bottom row (odd indices). Splitting by index rather than by
    // half-and-half keeps the two rows balanced in chip count even when
    // the option list has an odd length.
    private func interestRowChips(rowIndex: Int) -> [String] {
        vm.interestOptions.enumerated()
            .filter { $0.offset % 2 == rowIndex }
            .map { $0.element }
    }

    // Ordered walkthrough for the first-run coach tour.
    private var tourSteps: [CreateDeckTourStep] {
        [
            .init(target: .language, caption: L("Choose the language you're learning")),
            .init(target: .dialect, caption: L("Pick a dialect or regional variety")),
            .init(target: .content, caption: L("Words or full sentences — your call")),
            .init(target: .amount, caption: L("Set how many cards to generate")),
            .init(target: .level, caption: L("Match it to your proficiency level")),
            .init(target: .generate, caption: L("Tap Generate, and your deck is ready"))
        ]
    }

    private func bindingFor(_ attribute: DeckAttribute) -> Binding<String> {
        switch attribute {
        case .language: return $vm.language
        case .dialect:  return $vm.dialect
        case .content:  return $vm.contentType
        case .amount:   return $vm.amount
        case .level:    return $vm.level
        }
    }

}
