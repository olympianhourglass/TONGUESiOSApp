import SwiftUI

struct LibraryView: View {
    @State private var vm = LibraryViewModel()
    @State private var showProfile = false
    @State private var headerHeight: CGFloat = 0
    // Seeded synchronously from the on-device onboarding cache so the header
    // shows the real name on the very first frame instead of flashing the
    // "John Doe" placeholder while the Firestore profile loads.
    @State private var onboardingName: String? = UserService.cachedOnboarding()?.name?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    @State private var avatarImageData: Data?
    @State private var router = WidgetDeepLinkRouter.shared
    @State private var path = NavigationPath()

    @State private var sortOption: SortOption = .recent
    @State private var languageFilter: String?
    @State private var levelFilter: String?
    // Content-type filter: nil = All, "Words", or "Sentences" (the latter
    // also matches phrase decks). Applies to both the Decks and Content
    // sections.
    @State private var contentFilter: String?
    // Memoized Words list. Flattening every item across every deck +
    // sorting is expensive, so we compute it only when its inputs change
    // (decks / filters / sort) rather than on every scroll-driven body
    // re-render — which was tanking scroll performance on the Words tab.
    @State private var wordsToShow: [LibraryWordEntry] = []
    // Library is split into two horizontally-swipeable sections that sit
    // beneath the header and above the filters — mirroring the Deck Detail
    // page's Content/Artifacts/Stats tabs. Decks lists the user's decks;
    // Words flattens every item across all decks.
    @State private var section: LibrarySection = .decks
    // ARTIFACTS section. Saved long-form generations live under each deck
    // (users/{uid}/decks/{deckId}/artifacts), so the library view fetches
    // them per-deck concurrently the first time the user opens this section
    // and merges them into one recency-sorted list.
    @State private var artifacts: [Artifact] = []
    @State private var isLoadingArtifacts = false
    @State private var artifactsLoaded = false
    @State private var selectedArtifact: Artifact?
    // Search is hidden by default and revealed by an overscroll pull at
    // the top, appearing in the dark header. Tapping the revealed pill
    // opens the full-screen LibrarySearchView (Yelp-style) — the bar
    // itself isn't an inline filter.
    @State private var searchRevealed = false
    @State private var showSearch = false
    // Gate so the appear-time scroll-settle bounce can't auto-reveal the
    // pill. Armed a beat after the view appears; only then can a real
    // pull-down open search.
    @State private var searchArmed = false

    enum SortOption: String, CaseIterable, Identifiable {
        case recent
        case forgetting
        case alphabetical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent:       return L("Recently created")
            case .forgetting:   return L("Likely to forget")
            case .alphabetical: return L("Alphabetical")
            }
        }
    }

    enum LibrarySection: String, CaseIterable, Identifiable {
        case decks
        case words
        case artifacts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .decks: return L("DECKS")
            case .words: return L("CONTENT")
            case .artifacts: return L("ARTIFACTS")
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    profileHeader
                        // The scroll view extends under the status bar (see
                        // .ignoresSafeArea below) so the gradient can reach
                        // the very top edge. Pad the header's content back
                        // down by the status-bar height so the avatar/name
                        // still clear the status bar — the dark gradient fills
                        // that padded strip.
                        .padding(.top, statusBarInset)
                        // Stretchy, top-pinned dark header. The gradient's
                        // top sticks to the top of the scroll view and its
                        // bottom stays glued to the header's bottom edge, so
                        // it never slides away (no black sliding in) and the
                        // white "View Statistics" text is never cropped. It's
                        // driven by GeometryReader — not a per-frame @State
                        // write — so the lazy lists below don't churn while
                        // scrolling.
                        .background { headerBackground }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newValue in
                            headerHeight = newValue
                        }
                    deckList
                }
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                // NOTE: deliberately NOT storing the offset in @State —
                // doing so re-rendered the whole body on every scroll frame,
                // which churned the lazy lists and caused the jittery
                // "rows jump to the top" behavior. The header gradient below
                // is a fixed band that the white deck list scrolls over, so
                // it needs no live offset.
                // Pull-down past the top reveals the search pill;
                // scrolling back toward the top collapses it again.
                if searchArmed, newValue < -70, !searchRevealed {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        searchRevealed = true
                    }
                } else if newValue > 8, searchRevealed {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        searchRevealed = false
                    }
                }
            }
            // Let the scroll content run under the top safe area so the
            // header gradient reaches the very top edge (a ScrollView clips
            // its content to its bounds, which otherwise stop at the status
            // bar — leaving a white strip above the gradient).
            .ignoresSafeArea(.container, edges: .top)
            // Everything below the header (and any bottom overscroll) is
            // white. The header carries its own dark gradient as scroll
            // content, so there's no viewport-fixed band to fall out of sync
            // with the scrolling header.
            .background(Color.white.ignoresSafeArea())
            .navigationDestination(for: DeckDocument.self) { deck in
                DeckDetailView(deck: deck)
            }
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .fullScreenCover(isPresented: $showSearch) {
                LibrarySearchView(decks: vm.decks)
            }
            // Re-fetch the profile every time the Profile sheet closes so
            // name + avatar edits made inside it land back on the Library
            // header without requiring a full app reload.
            .onChange(of: showProfile) { _, isShown in
                if !isShown {
                    Task { await refreshHeaderProfile() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                // Arm pull-to-reveal after the initial layout settles so
                // the appear-time scroll bounce never auto-opens search.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    searchArmed = true
                }
                async let decks: Void = vm.refreshIfNeeded()
                async let fetched = try? await UserService.fetchProfile()
                _ = await decks
                let profile = await fetched
                // Only overwrite the cached-seed name when the fetch actually
                // returns one, so a slow/failed load never reverts to "John Doe".
                if let fetchedName = profile?.onboarding?.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !fetchedName.isEmpty {
                    onboardingName = fetchedName
                }
                avatarImageData = profile?.avatarImage
                resolvePendingWidgetDeepLink()
                recomputeWords()
            }
            .onAppear {
                // Returning to the Library tab (e.g. after a Study session)
                // re-aggregates the latest sessions so Preferred Language and
                // the favorite-topic inputs are current. Throttled so rapid
                // tab-switching doesn't refetch repeatedly.
                Task { await vm.refreshIfNeeded() }
            }
            .refreshable {
                await vm.loadDecks()
                // Force artifacts to refetch on next visit; refresh now if
                // that's the section currently on screen.
                artifactsLoaded = false
                if section == .artifacts { await loadArtifactsIfNeeded() }
            }
            .onChange(of: section) { _, newValue in
                if newValue == .artifacts {
                    Task { await loadArtifactsIfNeeded() }
                }
            }
            // Full-screen on Mac + iPad (a proper detail view), a sheet on iPhone.
            .adaptiveFullScreenOrSheet(item: $selectedArtifact) { artifact in
                ArtifactReaderSheet(
                    artifact: artifact,
                    deckLanguage: decksById[artifact.deckId]?.language ?? "",
                    deck: decksById[artifact.deckId],
                    onArtifactCreated: {
                        artifactsLoaded = false
                        Task { await loadArtifactsIfNeeded() }
                    }
                )
            }
            // Two triggers: the deckID arriving (warm app) and the deck
            // list finishing its initial load (cold launch from widget,
            // where the ID is already pending when this view appears).
            .onChange(of: router.pendingDeckID) { _, _ in
                resolvePendingWidgetDeepLink()
            }
            .onChange(of: vm.decks.count) { _, _ in
                resolvePendingWidgetDeepLink()
            }
            // Recompute the memoized Words list only when its inputs change
            // (not on scroll). vm.decks covers loads/edits/seeded decks.
            .onChange(of: vm.decks) { _, _ in recomputeWords() }
            .onChange(of: sortOption) { _, _ in recomputeWords() }
            .onChange(of: languageFilter) { _, _ in recomputeWords() }
            .onChange(of: contentFilter) { _, _ in recomputeWords() }
            .onChange(of: levelFilter) { _, _ in recomputeWords() }
        }
    }

    // Push the deck onto the navigation stack once both the pending ID
    // and the loaded decks are available. Clearing the router after
    // pushing prevents a second push if the user pops back.
    private func resolvePendingWidgetDeepLink() {
        guard let deckID = router.pendingDeckID,
              let deck = vm.decks.first(where: { $0.id == deckID }) else {
            return
        }
        path.append(deck)
        router.pendingDeckID = nil
    }

    // Height of the top safe area (status bar / Dynamic Island). Constant
    // per device+orientation, so reading it from the key window is stable
    // and involves no per-frame state. Used to pad the header content below
    // the status bar now that the scroll view draws under it.
    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }

    // MARK: Profile header (dark gradient)

    // Dark backdrop for the profile header, implemented as a stretchy,
    // top-pinned band. Reading the header's live offset within the scroll
    // view (minY) lets us keep:
    //   • the TOP edge pinned to the top of the scroll view (it never
    //     scrolls away — so no black slides into view), and
    //   • the BOTTOM edge glued to the header's bottom (so the white
    //     "View Statistics" text is always over dark — never cropped).
    // On a pull-down overscroll (minY > 0) the band simply grows taller,
    // giving the stretchy feel. A solid near-black region above the radial
    // (the radial's own top-stop color, invisible seam) covers the status
    // bar and any extra slack. GeometryReader recomputes only this
    // background — it writes no @State — so the lazy lists never churn.
    private var headerBackground: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .scrollView).minY
            // Distance from the scroll view's top down to the header's
            // bottom edge — the band's on-screen height at this moment.
            let fillHeight = max(1, headerHeight + minY)
            // Extra dark drawn ABOVE the pinned top to cover the status bar
            // and any pull-down slack; it never moves the bottom edge.
            let topExtra: CGFloat = 260
            VStack(spacing: 0) {
                Color(red: 14/255, green: 12/255, blue: 12/255)
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 14/255, green: 12/255, blue: 12/255), location: 0.0),
                        .init(color: Color(red: 70/255, green: 61/255, blue: 58/255), location: 0.5),
                        .init(color: Color(red: 102/255, green: 102/255, blue: 102/255), location: 1.0)
                    ]),
                    center: .top,
                    startRadius: 0,
                    endRadius: fillHeight * 1.3
                )
                .frame(height: fillHeight)
            }
            .frame(width: geo.size.width, height: fillHeight + topExtra)
            // Pin the top to the scroll view's top (and lift by topExtra so
            // the solid black fills the status bar). The bottom lands exactly
            // at the header's bottom edge regardless of scroll position.
            .offset(y: -minY - topExtra)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pull-to-reveal search lives at the very top of the dark
            // header. Collapsed to zero height until revealed, so it
            // never sits in the layout between header and list.
            headerSearchField
                .frame(height: searchRevealed ? 44 : 0)
                .opacity(searchRevealed ? 1 : 0)
                .padding(.bottom, searchRevealed ? 20 : 0)
                .clipped()

            headerContent
        }
        .padding(.horizontal, 8)
        .padding(.top, 32)
        .padding(.bottom, 16)
    }

    // The dark-surface search pill. It's a button, not an inline field:
    // tapping it opens the full-screen LibrarySearchView. Styled for the
    // gradient header (translucent white capsule, dimmed white label).
    private var headerSearchField: some View {
        Button {
            Haptics.light()
            showSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                Text(L("Search decks, languages, words…"))
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Tap target covers the avatar + name; the rest is placeholder.
            Button {
                Haptics.light()
                showProfile = true
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    profileAvatar
                    Text(displayName)
                        .font(.custom("NeueHaasDisplay-Bold", size: 15))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 2×2 metric grid — placeholder values for layout review.
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                metricCard(label: L("Preferred Language"), value: mostPracticedLanguage)
                metricCard(label: L("Streak"), value: streakLabel)
                metricCard(label: L("Longest Session"), value: longestSessionLabel)
                metricCard(label: L("Experience"), value: experienceLabel)
            }

            HStack {
                Spacer()
                NavigationLink {
                    let topPracticed = vm.favoriteTopicDeckSummaries()
                    StatisticsView(
                        languageBreakdown: vm.preferredLanguageBreakdown,
                        itemsLearned: vm.itemsTouched,
                        cardsEncountered: vm.totalCardsReviewed,
                        wordsInLibrary: vm.libraryItemCount(forContentType: "Words"),
                        sentencesInLibrary: vm.libraryItemCount(forContentType: "Sentences"),
                        cardsAddedThisWeek: vm.cardsAddedThisWeek,
                        cardsAddedThisMonth: vm.cardsAddedThisMonth,
                        practiceCountsByDay: vm.practiceCountsByDay,
                        topPracticedDecks: topPracticed.summaries,
                        topPracticedDecksSignature: topPracticed.signature,
                        totalXP: vm.totalXP,
                        preferredLearningMethod: vm.preferredLearningMethodLabel,
                        learningMethodShares: vm.learningMethodShares,
                        sourcingMethodShares: vm.sourcingMethodShares,
                        xpByDay: vm.xpByDay,
                        averageSessionSeconds: vm.averageSessionSeconds,
                        longestSessionSeconds: vm.longestSessionSeconds,
                        longestSessionLanguage: vm.longestSessionLanguage,
                        bestLearningTimeLabel: vm.bestLearningTimeLabel,
                        optimalLearningTimeLabel: vm.optimalLearningTimeLabel,
                        dailyStreak: vm.dailyStreak,
                        xpState: vm.xpState
                    )
                } label: {
                    HStack(spacing: 8) {
                        Text(L("View Statistics"))
                            .font(.custom("NeueHaasDisplay-Light", size: 16))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, -8)
        }
    }

    private var displayName: String {
        if let name = onboardingName, !name.isEmpty { return name }
        return "John Doe"
    }

    // Picks the language with the most flashcard reviews across the user's
    // saved study sessions. Falls back to an em-dash until any session has
    // been logged.
    private var mostPracticedLanguage: String {
        vm.mostPracticedLanguage
    }

    private var streakLabel: String {
        let days = vm.dailyStreak
        return "\(days) \(L(days == 1 ? "Day" : "Days"))"
    }

    private var experienceLabel: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: vm.totalXP)) ?? "\(vm.totalXP)"
        return L("%@ XP", number)
    }

    // Formats the longest meta-session as H:MM Hours when ≥ 1 hour, or
    // "X min" below that, so short-but-real sessions don't read as the
    // oddball "0:25 Hours".
    private var longestSessionLabel: String {
        let seconds = vm.longestSessionSeconds
        guard seconds > 0 else { return "—" }
        let totalMinutes = max(1, Int(seconds / 60))
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours == 0 { return L("%d min", mins) }
        return L("%d:%02d Hours", hours, mins)
    }

    private var profileAvatar: some View {
        Group {
            if let data = avatarImageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(white: 0.85))
                    Image(systemName: "person.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(white: 0.55))
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
    }

    @MainActor
    private func refreshHeaderProfile() async {
        guard let profile = try? await UserService.fetchProfile() else { return }
        if let fetchedName = profile.onboarding?.name?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fetchedName.isEmpty {
            onboardingName = fetchedName
        }
        avatarImageData = profile.avatarImage
    }

    private func metricCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text(value)
                .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(22)))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: Deck list (white)

    @ViewBuilder
    private var deckList: some View {
        VStack(spacing: 0) {
            if vm.isLoading && vm.decks.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        LibraryDeckRowSkeleton()
                        if index < 5 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .modifier(LibrarySkeletonShimmer())
                .padding(.top, 4)
            } else if let error = vm.errorText, vm.decks.isEmpty {
                Text(error)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
            } else if vm.decks.isEmpty {
                Text(L("No decks yet — create one from the Study tab."))
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
            } else {
                sectionBar
                sortFilterBar
                Group {
                    switch section {
                    case .decks: decksSection
                    case .words: wordsSection
                    case .artifacts: artifactsSection
                    }
                }
                // Horizontal swipe steps between sections (Decks → Content →
                // Artifacts), mirroring the Deck Detail page. Vertical scroll
                // is preserved by only acting when horizontal travel
                // dominates, and only on end.
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { value in
                            let dx = value.translation.width
                            guard abs(dx) > abs(value.translation.height) else { return }
                            let all = LibrarySection.allCases
                            guard let idx = all.firstIndex(of: section) else { return }
                            if dx < -28, idx < all.count - 1 {
                                Haptics.light()
                                withAnimation(.easeInOut(duration: 0.25)) { section = all[idx + 1] }
                            } else if dx > 28, idx > 0 {
                                Haptics.light()
                                withAnimation(.easeInOut(duration: 0.25)) { section = all[idx - 1] }
                            }
                        }
                )
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .background(Color.white)
    }

    // MARK: Section bar (Decks | Words)

    // Underline-on-active tab bar matching the Deck Detail page's
    // Content/Artifacts/Stats treatment.
    private var sectionBar: some View {
        HStack(spacing: 0) {
            ForEach(LibrarySection.allCases) { item in
                sectionButton(item)
            }
        }
        .padding(.horizontal, 8)
        // Gap between the header area and the section titles.
        .padding(.top, 20)
        // Doubled gap between the section titles and the filter options.
        .padding(.bottom, 16)
    }

    private func sectionButton(_ item: LibrarySection) -> some View {
        Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.25)) { section = item }
        } label: {
            VStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(section == item ? .black : Color.secondary)
                Rectangle()
                    .fill(section == item ? Color.black : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Section content

    @ViewBuilder
    private var decksSection: some View {
        let decks = visibleDecks
        if decks.isEmpty {
            Text(L("No decks match this filter."))
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
        } else {
            // Lazy so only on-screen rows are built.
            LazyVStack(spacing: 0) {
                ForEach(decks) { deck in
                    // Tap-driven navigation (instead of NavigationLink) so a
                    // horizontal swipe isn't swallowed as a row tap — it falls
                    // through to the section-switch drag gesture.
                    LibraryDeckRow(deck: deck)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.light()
                            path.append(deck)
                        }
                    // Thin divider between rows (not after the last), inset
                    // to the same 8pt margin as the row content.
                    if deck.id != decks.last?.id {
                        Divider()
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var wordsSection: some View {
        if wordsToShow.isEmpty {
            Text(L("No words match this filter."))
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
        } else {
            // Lazy + memoized: only visible rows render, and the list isn't
            // recomputed on every scroll frame.
            LazyVStack(spacing: 0) {
                ForEach(wordsToShow) { entry in
                    LibraryWordRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.light()
                            path.append(entry.deck)
                        }
                    // Thin divider between rows (not after the last), inset
                    // to the same 8pt margin as the row content.
                    if entry.id != wordsToShow.last?.id {
                        Divider()
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        if isLoadingArtifacts && artifacts.isEmpty {
            ProgressView()
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
        } else {
            let items = visibleArtifacts
            if items.isEmpty {
                Text(artifacts.isEmpty
                     ? L("No saved artifacts yet — generate one from a deck's Artifacts tab, then tap the bookmark to keep it.")
                     : L("No artifacts match this filter."))
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
            } else {
                let byId = decksById
                LazyVStack(spacing: 0) {
                    ForEach(items) { artifact in
                        LibraryArtifactRow(
                            artifact: artifact,
                            deckTitle: byId[artifact.deckId]?.title
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.light()
                            selectedArtifact = artifact
                        }
                        if artifact.id != items.last?.id {
                            Divider()
                                .padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
    }

    // Parent deck lookup for artifact rows/filtering (artifacts carry only
    // a `deckId`). Dedupes defensively so a stray duplicate id can't crash.
    private var decksById: [String: DeckDocument] {
        Dictionary(
            vm.decks.compactMap { deck in deck.id.map { ($0, deck) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // Artifacts honor the Language filter (mapped through the parent deck)
    // and the sort order. The Content/Level filters are word/sentence
    // concepts that don't apply to long-form artifacts, so they're ignored
    // here rather than silently emptying the list.
    private var visibleArtifacts: [Artifact] {
        let byId = decksById
        let filtered = artifacts.filter { artifact in
            guard let languageFilter else { return true }
            return byId[artifact.deckId]?.language == languageFilter
        }
        switch sortOption {
        case .alphabetical:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .recent, .forgetting:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // Fetches every deck's artifacts subcollection concurrently and merges
    // them, once per session (or after a pull-to-refresh resets the flag).
    // Reuses the per-deck query the Deck Detail page already relies on, so
    // no collection-group index is required.
    @MainActor
    private func loadArtifactsIfNeeded() async {
        guard !artifactsLoaded, !isLoadingArtifacts else { return }
        let deckIds = vm.decks.compactMap { $0.id }
        guard !deckIds.isEmpty else {
            artifactsLoaded = true
            return
        }
        isLoadingArtifacts = true
        defer { isLoadingArtifacts = false }
        let fetched = await withTaskGroup(of: [Artifact].self) { group -> [Artifact] in
            for id in deckIds {
                group.addTask {
                    (try? await FirebaseDeckArtifactService.fetch(forDeck: id)) ?? []
                }
            }
            var all: [Artifact] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
        artifacts = fetched.sorted { $0.createdAt > $1.createdAt }
        artifactsLoaded = true
    }

    // MARK: Sort + filter bar

    private var sortFilterBar: some View {
        HStack(spacing: 8) {
            sortMenu
            filterMenu(
                title: "Language",
                options: availableLanguages,
                selection: $languageFilter
            )
            filterMenu(
                title: "Content",
                options: ["Words", "Sentences"],
                selection: $contentFilter
            )
            filterMenu(
                title: "Level",
                options: availableLevels,
                selection: $levelFilter
            )
            Spacer(minLength: 0)
            if languageFilter != nil || levelFilter != nil || contentFilter != nil {
                Button {
                    Haptics.light()
                    languageFilter = nil
                    levelFilter = nil
                    contentFilter = nil
                } label: {
                    Text(L("Clear"))
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    Haptics.light()
                    sortOption = option
                } label: {
                    if sortOption == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            chipLabel(
                icon: "arrow.up.arrow.down",
                text: sortOption.label,
                isActive: false
            )
        }
    }

    private func filterMenu(
        title: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        Menu {
            Button {
                Haptics.light()
                selection.wrappedValue = nil
            } label: {
                if selection.wrappedValue == nil {
                    Label(L("All"), systemImage: "checkmark")
                } else {
                    Text(L("All"))
                }
            }
            if !options.isEmpty {
                Divider()
                ForEach(options, id: \.self) { value in
                    Button {
                        Haptics.light()
                        selection.wrappedValue = value
                    } label: {
                        if selection.wrappedValue == value {
                            Label(L(value), systemImage: "checkmark")
                        } else {
                            Text(L(value))
                        }
                    }
                }
            }
        } label: {
            chipLabel(
                icon: nil,
                text: selection.wrappedValue ?? title,
                isActive: selection.wrappedValue != nil
            )
        }
    }

    private func chipLabel(icon: String?, text: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            }
            Text(L(text))
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(isActive ? Color.white : Color.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(isActive ? Color.black : Color.clear)
        )
        .overlay(
            Capsule().stroke(
                Color.black.opacity(isActive ? 0 : 0.25),
                lineWidth: 1
            )
        )
    }

    private var availableLanguages: [String] {
        Array(Set(vm.decks.map { $0.language })).sorted()
    }

    private var availableLevels: [String] {
        Array(Set(vm.decks.map { $0.level })).sorted()
    }

    // Content-type match for the Content filter. "Words" matches word
    // decks; "Sentences" matches both sentence and phrase decks so nothing
    // is orphaned. nil (All) matches everything.
    private func matchesContentFilter(_ deck: DeckDocument) -> Bool {
        guard let contentFilter else { return true }
        switch contentFilter {
        case "Words":     return deck.contentType == "Words"
        case "Sentences": return deck.contentType == "Sentences" || deck.contentType == "Phrases"
        default:          return true
        }
    }

    // Single computed pipeline: apply filters first (since they're
    // cheaper than the urgency sort), then order. Falls back to
    // forgetting-score sort if scores aren't loaded yet for some
    // decks — score-of-zero floats them to the bottom rather than
    // crashing the comparator.
    private var visibleDecks: [DeckDocument] {
        let filtered = vm.decks.filter { deck in
            (languageFilter == nil || deck.language == languageFilter!)
                && matchesContentFilter(deck)
                && (levelFilter == nil || deck.level == levelFilter!)
        }
        switch sortOption {
        case .recent:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .forgetting:
            return filtered.sorted { lhs, rhs in
                let l = lhs.id.flatMap { vm.urgencies[$0]?.score } ?? 0
                let r = rhs.id.flatMap { vm.urgencies[$0]?.score } ?? 0
                return l > r
            }
        case .alphabetical:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    // Recomputes the memoized Words list (`wordsToShow`). Flattens every
    // item across all filtered decks, pairs each with its parent deck, and
    // sorts. Called only when the inputs change — NOT on every body render
    // — so scroll stays smooth. Defaults to most-recently-added first,
    // using the item's own `addedAt` when set and falling back to the
    // deck's `createdAt` for legacy items.
    private func recomputeWords() {
        let filtered = vm.decks.filter { deck in
            (languageFilter == nil || deck.language == languageFilter!)
                && matchesContentFilter(deck)
                && (levelFilter == nil || deck.level == levelFilter!)
        }
        let entries = filtered.flatMap { deck in
            deck.items.map { LibraryWordEntry(deck: deck, item: $0) }
        }
        switch sortOption {
        case .alphabetical:
            wordsToShow = entries.sorted {
                $0.item.word.localizedCaseInsensitiveCompare($1.item.word) == .orderedAscending
            }
        case .recent, .forgetting:
            // Forgetting urgency is deck-level, so for the word list it
            // falls back to the recency ordering.
            wordsToShow = entries.sorted { ($0.addedDate) > ($1.addedDate) }
        }
    }
}

// A single library item paired with its parent deck, used by the Words
// section so tapping a word routes to the deck that contains it.
struct LibraryWordEntry: Identifiable {
    let deck: DeckDocument
    let item: GeneratedItem
    var id: String { (deck.id ?? "") + "|" + item.id.uuidString }
    // Legacy items without their own timestamp inherit the deck's.
    var addedDate: Date { item.addedAt ?? deck.createdAt }
}

// New row used only by the library list — small cardback preview on the
// left, title + language/level subtitle in the middle, status pill on the
// trailing edge. `DeckRow` (below) stays intact for use by DeckPickerSheet.
private struct LibraryDeckRow: View {
    let deck: DeckDocument

    var body: some View {
        HStack(alignment: .center, spacing: MacLayout.s(16)) {
            DeckCoverFill(style: deck.resolvedCoverStyle)
                .frame(width: MacLayout.s(60), height: MacLayout.s(36))
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(deck.title)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text("\(localizedLanguageName(deck.language)) | \(L(deck.level))")
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, MacLayout.s(14))
        .contentShape(Rectangle())
    }
}

// Placeholder that mirrors `LibraryDeckRow`'s layout (cover thumbnail +
// title + subtitle) while decks load, shown under a shared shimmer sweep in
// place of a bare spinner.
private struct LibraryDeckRowSkeleton: View {
    private let fill = Color(white: 0.91)

    var body: some View {
        HStack(alignment: .center, spacing: MacLayout.s(16)) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill)
                .frame(width: MacLayout.s(60), height: MacLayout.s(36))

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(fill)
                    .frame(width: MacLayout.s(150), height: MacLayout.f(14))
                RoundedRectangle(cornerRadius: 4)
                    .fill(fill)
                    .frame(width: MacLayout.s(96), height: MacLayout.f(11))
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, MacLayout.s(14))
    }
}

// Sweeps a soft highlight left-to-right across its content, looping forever —
// the shimmer that signals skeleton placeholders are loading.
private struct LibrarySkeletonShimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.7), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: phase * geo.size.width)
                }
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// Row for the Library's Words section — the target word, its native
// translation, and the deck it lives in. Mirrors the word-result row used
// in LibrarySearchView for visual consistency.
private struct LibraryWordRow: View {
    let entry: LibraryWordEntry

    var body: some View {
        HStack(alignment: .center, spacing: MacLayout.s(16)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.word)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(15)))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text(entry.item.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("in \(entry.deck.title)")
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: MacLayout.f(12), weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, MacLayout.s(14))
        .contentShape(Rectangle())
    }
}

// Row for the Library's Artifacts section — a kind chip, the artifact's
// title, and the deck it was generated from. Tapping opens the same
// ArtifactReaderSheet used inside a deck's Artifacts tab.
private struct LibraryArtifactRow: View {
    let artifact: Artifact
    let deckTitle: String?

    var body: some View {
        HStack(alignment: .center, spacing: MacLayout.s(16)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: MacLayout.f(7), weight: .semibold))
                        .foregroundStyle(.black)
                    Text(L(artifact.resolvedKind.rawValue).uppercased())
                        .font(.custom("NeueHaasDisplay-Roman", size: MacLayout.f(7)))
                        .tracking(0.6)
                        .foregroundStyle(.black)
                }
                Text(artifact.title.isEmpty ? L(artifact.resolvedKind.rawValue) : artifact.title)
                    .font(.custom("NeueHaasDisplay-Roman", size: MacLayout.f(15)))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                if let deckTitle {
                    Text(L("in %@", deckTitle))
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: MacLayout.f(12), weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, MacLayout.s(14))
        .contentShape(Rectangle())
    }

    // Mirrors the icon mapping the Deck Detail page uses for its artifact
    // cards so a kind reads the same in both places.
    private var icon: String {
        switch artifact.resolvedKind {
        case .story:        return "book"
        case .conversation: return "bubble.left.and.bubble.right"
        case .newsArticle:  return "newspaper"
        case .songs:        return "music.note"
        case .poems:        return "text.alignleft"
        case .jokes:        return "face.smiling"
        }
    }
}

// Legacy row still used by DeckPickerSheet — unchanged so the picker UI
// remains exactly as it was.
struct DeckRow: View {
    let deck: DeckDocument
    var urgency: DeckUrgency? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(deck.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let langs = deck.allLanguages
        let countLabel = "\(deck.items.count) \(deck.contentType.lowercased())"
        let head: String
        if langs.count > 1 {
            head = "\(langs.map { localizedLanguageName($0) }.joined(separator: ", ")) · \(countLabel)"
        } else {
            head = "\(localizedLanguageName(deck.language)) \(L(deck.level)) · \(countLabel)"
        }
        if let label = urgency?.statusLabel {
            return "\(head) · \(L(label))"
        }
        return head
    }
}
