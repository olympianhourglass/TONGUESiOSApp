import SwiftUI

struct LibraryView: View {
    @State private var vm = LibraryViewModel()
    @State private var showProfile = false
    @State private var headerHeight: CGFloat = 0
    @State private var scrollOffsetY: CGFloat = 0
    @State private var onboardingName: String?
    @State private var avatarImageData: Data?
    @State private var router = WidgetDeepLinkRouter.shared
    @State private var path = NavigationPath()

    @State private var sortOption: SortOption = .recent
    @State private var languageFilter: String?
    @State private var levelFilter: String?
    // Library is split into two horizontally-swipeable sections that sit
    // beneath the header and above the filters — mirroring the Deck Detail
    // page's Content/Artifacts/Stats tabs. Decks lists the user's decks;
    // Words flattens every item across all decks.
    @State private var section: LibrarySection = .decks
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
            case .recent:       return "Recently created"
            case .forgetting:   return "Likely to forget"
            case .alphabetical: return "Alphabetical"
            }
        }
    }

    enum LibrarySection: String, CaseIterable, Identifiable {
        case decks
        case words
        var id: String { rawValue }
        var title: String {
            switch self {
            case .decks: return "DECKS"
            case .words: return "WORDS"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    profileHeader
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
                scrollOffsetY = newValue
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
            .background {
                // Dark gradient tracks the header's on-screen bottom edge so
                // it stretches with overscroll and shrinks as the deck list
                // scrolls up over it. White fills everything below.
                VStack(spacing: 0) {
                    let bandHeight = max(0, headerHeight - scrollOffsetY)
                    // Radial gradient matching the audio (Listen) page —
                    // spreads from the top center through three warm stops.
                    // `endRadius` is anchored to the (stable) header height,
                    // NOT the live band height, so scrolling only *clips*
                    // the fixed gradient via the frame instead of rescaling
                    // the whole pattern each frame (which looked glitchy).
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 14/255, green: 12/255, blue: 12/255), location: 0.0),
                            .init(color: Color(red: 70/255, green: 61/255, blue: 58/255), location: 0.5),
                            .init(color: Color(red: 102/255, green: 102/255, blue: 102/255), location: 1.0)
                        ]),
                        center: .top,
                        startRadius: 0,
                        endRadius: max(1, headerHeight) * 1.3
                    )
                    .frame(height: bandHeight)
                    Color.white
                }
                .ignoresSafeArea()
            }
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
                async let decks: Void = vm.loadDecks()
                async let fetched = try? await UserService.fetchProfile()
                _ = await decks
                let profile = await fetched
                onboardingName = profile?.onboarding?.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                avatarImageData = profile?.avatarImage
                resolvePendingWidgetDeepLink()
            }
            .refreshable { await vm.loadDecks() }
            // Two triggers: the deckID arriving (warm app) and the deck
            // list finishing its initial load (cold launch from widget,
            // where the ID is already pending when this view appears).
            .onChange(of: router.pendingDeckID) { _, _ in
                resolvePendingWidgetDeepLink()
            }
            .onChange(of: vm.decks.count) { _, _ in
                resolvePendingWidgetDeepLink()
            }
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

    // MARK: Profile header (dark gradient)

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
                Text("Search decks, languages, words…")
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
                metricCard(label: "Preferred Language", value: mostPracticedLanguage)
                metricCard(label: "Streak", value: streakLabel)
                metricCard(label: "Longest Session", value: longestSessionLabel)
                metricCard(label: "Experience", value: experienceLabel)
            }

            HStack {
                Spacer()
                NavigationLink {
                    let topPracticed = vm.topPracticedDeckSummaries()
                    StatisticsView(
                        reviewsByLanguage: vm.reviewsByLanguage,
                        itemsLearned: vm.itemsTouched,
                        wordsInLibrary: vm.libraryItemCount(forContentType: "Words"),
                        phrasesInLibrary: vm.libraryItemCount(forContentType: "Phrases"),
                        sentencesInLibrary: vm.libraryItemCount(forContentType: "Sentences"),
                        cardsAddedThisWeek: vm.cardsAddedThisWeek,
                        cardsAddedThisMonth: vm.cardsAddedThisMonth,
                        practiceCountsByDay: vm.practiceCountsByDay,
                        topPracticedDecks: topPracticed.summaries,
                        topPracticedDecksSignature: topPracticed.signature,
                        totalXP: vm.totalXP,
                        preferredLearningMethod: vm.preferredLearningMethodLabel,
                        xpByDay: vm.xpByDay,
                        averageSessionSeconds: vm.averageSessionSeconds,
                        longestSessionSeconds: vm.longestSessionSeconds,
                        longestSessionLanguage: vm.longestSessionLanguage,
                        bestLearningTimeLabel: vm.bestLearningTimeLabel,
                        optimalLearningTimeLabel: vm.optimalLearningTimeLabel,
                        dailyStreak: vm.dailyStreak
                    )
                } label: {
                    HStack(spacing: 8) {
                        Text("View Statistics")
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
        vm.reviewsByLanguage.max { $0.value < $1.value }?.key ?? "—"
    }

    private var streakLabel: String {
        let days = vm.dailyStreak
        return "\(days) \(days == 1 ? "Day" : "Days")"
    }

    private var experienceLabel: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: vm.totalXP)) ?? "\(vm.totalXP)"
        return "\(number) XP"
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
        if hours == 0 { return "\(mins) min" }
        return String(format: "%d:%02d Hours", hours, mins)
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
        onboardingName = profile.onboarding?.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        avatarImageData = profile.avatarImage
    }

    private func metricCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text(value)
                .font(.custom("NeueHaasDisplay-Mediu", size: 22))
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
                ProgressView()
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if let error = vm.errorText, vm.decks.isEmpty {
                Text(error)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
            } else if vm.decks.isEmpty {
                Text("No decks yet — create one from the Study tab.")
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
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
                    }
                }
                // Horizontal swipe flips between Decks and Words, mirroring
                // the Deck Detail page. Vertical scroll is preserved by only
                // acting when horizontal travel dominates, and only on end.
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { value in
                            let dx = value.translation.width
                            guard abs(dx) > abs(value.translation.height) else { return }
                            if dx < -28, section == .decks {
                                Haptics.light()
                                withAnimation(.easeInOut(duration: 0.25)) { section = .words }
                            } else if dx > 28, section == .words {
                                Haptics.light()
                                withAnimation(.easeInOut(duration: 0.25)) { section = .decks }
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
        HStack(spacing: 28) {
            ForEach(LibrarySection.allCases) { item in
                sectionButton(item)
            }
            Spacer()
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Section content

    @ViewBuilder
    private var decksSection: some View {
        let decks = visibleDecks
        if decks.isEmpty {
            Text("No decks match this filter.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
        } else {
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
            }
        }
    }

    @ViewBuilder
    private var wordsSection: some View {
        let words = visibleWords
        if words.isEmpty {
            Text("No words match this filter.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
        } else {
            ForEach(words) { entry in
                LibraryWordRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.light()
                        path.append(entry.deck)
                    }
            }
        }
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
                title: "Level",
                options: availableLevels,
                selection: $levelFilter
            )
            Spacer(minLength: 0)
            if languageFilter != nil || levelFilter != nil {
                Button {
                    Haptics.light()
                    languageFilter = nil
                    levelFilter = nil
                } label: {
                    Text("Clear")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                        .underline()
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
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
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
                            Label(value, systemImage: "checkmark")
                        } else {
                            Text(value)
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
            Text(text)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
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

    // Single computed pipeline: apply filters first (since they're
    // cheaper than the urgency sort), then order. Falls back to
    // forgetting-score sort if scores aren't loaded yet for some
    // decks — score-of-zero floats them to the bottom rather than
    // crashing the comparator.
    private var visibleDecks: [DeckDocument] {
        let filtered = vm.decks.filter { deck in
            (languageFilter == nil || deck.language == languageFilter!)
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

    // Every item across all (filtered) decks, flattened and paired with
    // its parent deck so a tap routes to the containing deck. Defaults to
    // most-recently-added first, using the item's own `addedAt` when set
    // and falling back to the deck's `createdAt` for legacy items.
    private var visibleWords: [LibraryWordEntry] {
        let filtered = vm.decks.filter { deck in
            (languageFilter == nil || deck.language == languageFilter!)
                && (levelFilter == nil || deck.level == levelFilter!)
        }
        let entries = filtered.flatMap { deck in
            deck.items.map { LibraryWordEntry(deck: deck, item: $0) }
        }
        switch sortOption {
        case .alphabetical:
            return entries.sorted {
                $0.item.word.localizedCaseInsensitiveCompare($1.item.word) == .orderedAscending
            }
        case .recent, .forgetting:
            // Forgetting urgency is deck-level, so for the word list it
            // falls back to the recency ordering.
            return entries.sorted { ($0.addedDate) > ($1.addedDate) }
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
        HStack(alignment: .center, spacing: 16) {
            DeckCoverFill(style: deck.resolvedCoverStyle)
                .frame(width: 60, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(deck.title)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text("\(deck.language) | \(deck.level)")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// Row for the Library's Words section — the target word, its native
// translation, and the deck it lives in. Mirrors the word-result row used
// in LibrarySearchView for visual consistency.
private struct LibraryWordRow: View {
    let entry: LibraryWordEntry

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.word)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text(entry.item.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("in \(entry.deck.title)")
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
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
            head = "\(langs.joined(separator: ", ")) · \(countLabel)"
        } else {
            head = "\(deck.language) \(deck.level) · \(countLabel)"
        }
        if let label = urgency?.statusLabel {
            return "\(head) · \(label)"
        }
        return head
    }
}
