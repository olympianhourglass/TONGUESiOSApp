import SwiftUI
import CoreLocation

// Placeholder Explore tab — content is hard-coded mock data for design
// review; nothing here touches the backend yet. Typography + spacing
// mirror StudyView so the two tabs feel like part of the same family.
// Exception: the "You might like these topics" row is fully wired to
// the user's onboarding interests + saved languages so each card is a
// one-tap deck preset.
struct ExploreView: View {
    // Language filter for the "You might like these topics" row. Empty
    // means "show all" — when the user picks one or more chips from the
    // top-right Language menu the topic row narrows to just those.
    @State private var languageFilter: Set<String> = []
    @State private var showLanguageFilter = false
    @State private var availableFilterLanguages: [String] = []
    @State private var showPaywall = false
    @State private var capError: SubscriptionError?
    @State private var topicPresets: [TopicPreset] = []
    @State private var activePreset: TopicPreset?

    // Cultural insight card content — drawn fresh on every Explore
    // appearance from a random destination the user picked.
    @State private var culturalInsightCountry: String?
    @State private var culturalInsightFact: String?
    @State private var isLoadingCulturalInsight = false

    // Public decks other users have made, restricted to the languages
    // the signed-in user has saved in their profile.
    @State private var publicDecks: [DeckDocument] = []
    @State private var hasFetchedPublicDecks = false
    // Stricter pass of the same query: only surfaces public decks that
    // match BOTH the user's saved language AND the dialect they
    // picked for that language. Renders between the destination and
    // adjacent sections so a Mexican-Spanish learner sees other
    // Mexican-Spanish (not Castilian) decks first.
    @State private var dialectMatchedDecks: [DeckDocument] = []
    @State private var hasFetchedDialectMatchedDecks = false
    @State private var locationManager = LocationManager()
    @State private var nearbyLanguages: [LanguagePreference] = []
    @State private var hasFetchedNearby = false
    @State private var addedNearbyLanguages: Set<String> = []

    // Destination-driven rows. Both rebuild whenever the user's saved
    // destinations change (onboarding or profile edits), keyed off
    // `destinationsKey` — a stable stringification used to compare lists.
    @State private var destinationLanguages: [LanguagePreference] = []
    @State private var adjacentLanguages: [LanguagePreference] = []
    @State private var lastDestinationsKey: String = ""

    // Curriculum surface: the most relevant active plan drives the
    // guided-plan strip; tapping it (or the create card) pushes PlanView.
    @State private var activePlan: CurriculumPlan?
    @State private var planPresented = false

    // Feature toggles. The Crown opens PremiumActionSheet now that
    // the subscription flow has landed (StoreKit 2 products + Firebase
    // mirror). The guided plan strip is surfaced again now that the
    // agentic curriculum pipeline is back in play.
    private let isCrownPaywallSurfaced = true
    private let isGuidedPlanSurfaced = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    languageFilterRow
                    if isGuidedPlanSurfaced {
                        guidedPlanStrip
                    }
                    culturalInsightCard
                    topicsSection
                    if !visibleDestinationLanguages.isEmpty {
                        destinationLanguagesSection
                            // 1.4× the standard 28pt section gap above the
                            // "Languages Based on Where You Want to Go"
                            // title (28 + 11.2 = 39.2).
                            .padding(.top, 11.2)
                    }
                    if !dialectMatchedDecks.isEmpty {
                        decksOthersHaveCreatedSection
                    }
                    if !visibleAdjacentLanguages.isEmpty {
                        adjacentLanguagesSection
                    }
                    if !visibleNearbyLanguages.isEmpty {
                        languagesNearYouSection
                    }
                    if !publicDecks.isEmpty {
                        publicDecksSection
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.white.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $planPresented) {
                PlanView()
            }
            .sheet(isPresented: $showPaywall) {
                PremiumActionSheet()
            }
            .subscriptionCapAlert($capError)
            .fullScreenCover(item: $activePreset) { preset in
                CreateDeckSheet(
                    preset: CreateDeckPreset(
                        language: preset.language,
                        level: preset.level,
                        topic: preset.topic
                    )
                ) {
                    activePreset = nil
                    Task { await SubscriptionService.shared.markFreeDeckUsed() }
                }
            }
            .task {
                await loadTopicPresets()
                locationManager.requestLocation()
                await loadDestinationLanguagesIfNeeded()
                await loadPublicDecksIfNeeded()
                await loadDialectMatchedDecksIfNeeded()
            }
            .onChange(of: locationManager.coordinate?.latitude) { _, _ in
                Task { await loadNearbyLanguages() }
            }
            // Re-check destinations every time the Explore tab becomes
            // visible. If the user edited destinations from the Profile
            // page (or finished onboarding mid-session), the key changes
            // and the two destination-driven rows refetch. The cultural
            // insight re-rolls on every appearance so the user sees a
            // fresh niche fact each time they open the tab.
            .onAppear {
                Task {
                    await loadDestinationLanguagesIfNeeded()
                    await loadCulturalInsight()
                }
                // Refresh the plan strip every time the tab shows so a
                // plan accepted in chat (or progress made in Study)
                // reflects without an app restart.
                Task { await loadCurriculum() }
            }
        }
    }

    // MARK: Guided plan strip

    // Count of FSRS-due cards across the library, shown in the strip's
    // subtitle. Loaded alongside the plan (one indexed range query).
    @State private var dueCardCount = 0

    private func loadCurriculum() async {
        async let dueTask: [CardSchedule]? = try? await FirebaseDeckService.fetchDueSchedules()
        let plans = (try? await FirebaseCurriculumService.fetchAll()) ?? []
        dueCardCount = (await dueTask)?.count ?? 0
        let candidate = plans
            .filter { $0.status == "active" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        if let candidate {
            // Deterministic gate check now; the (gated, at-most-weekly)
            // replan runs in the background so the strip never waits on
            // a model call.
            let outcome = await CurriculumReconciler.reconcile(plan: candidate)
            activePlan = outcome.plan
            let languageID = candidate.languageID
            Task.detached {
                await CurriculumReconciler.reconcileAndMaybeReplan(languageID: languageID)
            }
        } else {
            activePlan = plans.sorted { $0.updatedAt > $1.updatedAt }.first
        }
    }

    @ViewBuilder
    private var guidedPlanStrip: some View {
        Button {
            Haptics.light()
            planPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "map")
                        .font(.system(size: 11))
                    Text(activePlan == nil ? "GUIDED PLAN" : "TODAY")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                        .tracking(1.2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)

                if let plan = activePlan {
                    VStack(alignment: .leading, spacing: 4) {
                        if let unit = plan.activeUnit {
                            Text(unit.title)
                                .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                                .foregroundStyle(.black)
                            Text(todaySubtitle(plan: plan, unit: unit))
                                .font(.custom("NeueHaasDisplay-Light", size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Plan complete 🎉")
                                .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                                .foregroundStyle(.black)
                            Text(plan.goalStatement)
                                .font(.custom("NeueHaasDisplay-Light", size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get a guided plan")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                            .foregroundStyle(.black)
                        Text("Your tutor builds a unit-by-unit path from your goals and what you keep forgetting.")
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        // Halve the outer VStack's 28pt gap to the cultural-insight card
        // below (28 → 14) without touching every other section's spacing.
        .padding(.bottom, -14)
    }

    private func todaySubtitle(plan: CurriculumPlan, unit: CurriculumUnit) -> String {
        var parts: [String] = []
        if dueCardCount > 0 {
            parts.append("\(dueCardCount) cards due")
        }
        if let next = unit.plannedActivities.first(where: { $0.completedAt == nil }) {
            parts.append("Next: \(next.label)")
        }
        if parts.isEmpty {
            parts.append("Keep reviewing — \(Int((unit.masteryGate.matureFraction * 100).rounded()))% mastery unlocks the next unit")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("EXPLORE")
                .font(.custom("PlayfairDisplay-Regular", size: 20))
                .tracking(-1.6)
                .foregroundStyle(.black)
                // Playfair Display's trailing serifs extend past the
                // glyph's advance width; negative tracking + .fixedSize on
                // the HStack neighbors clip them. A small trailing
                // padding reserves room for the serif on the final E.
                .padding(.trailing, 4)
            Spacer()
            if isCrownPaywallSurfaced {
                Button {
                    Haptics.light()
                    showPaywall = true
                } label: {
                    Image("Crown")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color(red: 132 / 255, green: 102 / 255, blue: 52 / 255))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    // Top-right multi-select language filter. The label summarizes the
    // current selection ("All", a single language name, or "N selected").
    // Tapping opens a sheet of checkboxes scoped to the user's saved
    // languages, plus an "All" toggle that clears the filter.
    private var languageFilterRow: some View {
        HStack {
            Spacer()
            Button {
                Haptics.light()
                showLanguageFilter = true
            } label: {
                HStack(spacing: 6) {
                    Text("Language: \(filterLabel)")
                        .font(.custom("NeueHaasDisplay-Light", size: 15))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        // Negative bottom padding pulls the cultural-insight card 8pt
        // closer without touching the outer VStack's uniform 28pt spacing
        // (which still controls every other section's gap).
        .padding(.bottom, -8)
        .sheet(isPresented: $showLanguageFilter) {
            LanguageFilterSheet(
                languages: availableFilterLanguages,
                selection: $languageFilter
            )
            .presentationDetents([.medium])
        }
    }

    private var filterLabel: String {
        if languageFilter.isEmpty { return "All" }
        if languageFilter.count == 1, let only = languageFilter.first { return only }
        return "\(languageFilter.count) selected"
    }

    // MARK: Cultural Insight Card

    private var culturalInsightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CULTURAL INSIGHT")
                .font(.custom("NeueHaasDisplay-Mediu", size: 13))
                .foregroundStyle(.white)

            // Country sits between the title and the paragraph. Large
            // top padding pushes it away from the title; the VStack
            // wrapping it + the paragraph keeps a tight 6pt gap below
            // so the country reads as the paragraph's lead-in.
            VStack(alignment: .leading, spacing: 6) {
                if let country = culturalInsightCountry {
                    Text(country)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 18))
                        .foregroundStyle(.white)
                }

                Group {
                    if let fact = culturalInsightFact {
                        Text(fact)
                    } else if isLoadingCulturalInsight {
                        Text("Finding something interesting nearby…")
                    } else {
                        Text("Add a destination to your profile to see a cultural insight here.")
                    }
                }
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(height: 1)
                .padding(.top, 8)

            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    Task { await loadCulturalInsight() }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingCulturalInsight {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        }
                        Text("Get new insight")
                            .font(.custom("NeueHaasDisplay-Light", size: 14))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.glass(.clear))
                .disabled(isLoadingCulturalInsight)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
    }

    // MARK: Suggested Topics

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You might like these topics:")
                .font(.custom("NeueHaasDisplay-Light", size: 18))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(filteredTopicPresets) { preset in
                        topicCard(preset: preset)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }

    // Topic presets restricted to the chips the language filter allows.
    // Empty filter → return everything.
    private var filteredTopicPresets: [TopicPreset] {
        guard !languageFilter.isEmpty else { return topicPresets }
        return topicPresets.filter { languageFilter.contains($0.language) }
    }

    // Each suggestion row hides itself once the user has tapped Add on
    // every card in it. We track "added" by name in `addedNearbyLanguages`
    // (shared by all three rows since the underlying action is identical)
    // and filter each row's source list against it. When the resulting
    // list is empty, the parent body collapses the section entirely.
    private var visibleNearbyLanguages: [LanguagePreference] {
        nearbyLanguages.filter { !addedNearbyLanguages.contains($0.language) }
    }

    private var visibleDestinationLanguages: [LanguagePreference] {
        destinationLanguages.filter { !addedNearbyLanguages.contains($0.language) }
    }

    private var visibleAdjacentLanguages: [LanguagePreference] {
        adjacentLanguages.filter { !addedNearbyLanguages.contains($0.language) }
    }

    private func topicCard(preset: TopicPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Light-gray preview card
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Text(preset.languageDisplay)
                            .font(.custom("NeueHaasDisplay-Light", size: 15))
                            .foregroundStyle(.black)
                        Text(preset.level)
                            .font(.custom("NeueHaasDisplay-Light", size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image("Compass")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.black)
                }
                .padding(12)

                Spacer(minLength: 0)

                DeckCoverFill(style: preset.coverStyle)
                    .aspectRatio(90.0 / 53.0, contentMode: .fit)
                    .frame(width: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)

                Spacer(minLength: 0)
            }
            .frame(width: 220, height: 230)
            .background(Color(white: 0.94))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Title / count + add
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.topic)
                        .font(.custom("NeueHaasDisplay-Light", size: 22))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text("100 words")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Haptics.light()
                    activePreset = preset
                } label: {
                    addCircleButton(size: 32, plusSize: 14)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 220)
        }
    }

    @MainActor
    private func loadTopicPresets() async {
        // Only seed once per Explore mount. Each card is a fresh
        // random pick (interest × language × cover) so re-entering
        // the tab gives variety without breaking the in-session view.
        guard topicPresets.isEmpty else { return }
        guard let profile = try? await UserService.fetchProfile() else { return }

        let interests = profile.onboarding?.interests ?? []
        let languages = profile.onboarding?.languagePreferences ?? []
        guard !interests.isEmpty, !languages.isEmpty else { return }

        // Match up to five (interest, language) pairs without re-using the
        // same interest twice. Languages can repeat across cards when the
        // user has fewer languages than they have interests — that's fine,
        // each card's topic is still distinct.
        let shuffledInterests = interests.shuffled()
        var cards: [TopicPreset] = []
        for (index, interest) in shuffledInterests.prefix(5).enumerated() {
            let pref = languages[index % languages.count]
            cards.append(
                TopicPreset(
                    topic: interest,
                    language: pref.language,
                    level: pref.level,
                    coverStyle: DeckCoverStyle.allCases.randomElement() ?? .gradient
                )
            )
        }
        topicPresets = cards

        // Populate the top-right filter menu with the user's saved
        // languages (deduplicated, original order preserved). Only used
        // by the filter sheet — the topic row itself still receives the
        // full list and filters via `filteredTopicPresets`.
        var seen: Set<String> = []
        availableFilterLanguages = languages.compactMap { pref in
            guard !seen.contains(pref.language) else { return nil }
            seen.insert(pref.language)
            return pref.language
        }
    }

    // MARK: Decks Others Have Made

    // Mirrors the visual language of the "You might like these topics"
    // row exactly — same 220×230 light-gray preview, same title +
    // count + plus-button trailer — but the underlying data is a public
    // deck from another user. Plus opens the deck so the viewer can
    // explore it; future iteration can switch this to a "clone deck"
    // action once we have that flow.
    private var publicDecksSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Decks Others Have Made")
                .font(.custom("NeueHaasDisplay-Light", size: 18))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(publicDecks) { deck in
                        publicDeckCard(deck: deck)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }

    // Public decks where the language AND dialect both match one of
    // the user's saved (language, dialect) pairs. Surfaced between the
    // destination and adjacent rows so a Mexican-Spanish learner sees
    // other Mexican-Spanish content first instead of mixed dialects.
    // Card style is shared with `publicDecksSection` for consistency.
    private var decksOthersHaveCreatedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Decks Others Have Created")
                .font(.custom("NeueHaasDisplay-Light", size: 18))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(dialectMatchedDecks) { deck in
                        publicDeckCard(deck: deck)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }

    private func publicDeckCard(deck: DeckDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Text(shortLanguageLabel(deck.language))
                            .font(.custom("NeueHaasDisplay-Light", size: 15))
                            .foregroundStyle(.black)
                        Text(deck.level)
                            .font(.custom("NeueHaasDisplay-Light", size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image("Compass")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.black)
                }
                .padding(12)

                Spacer(minLength: 0)

                DeckCoverFill(style: deck.resolvedCoverStyle)
                    .aspectRatio(90.0 / 53.0, contentMode: .fit)
                    .frame(width: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)

                Spacer(minLength: 0)
            }
            .frame(width: 220, height: 230)
            .background(Color(white: 0.94))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title)
                        .font(.custom("NeueHaasDisplay-Light", size: 22))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text("\(deck.items.count)")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                addCircleButton(size: 32, plusSize: 14)
            }
            .frame(width: 220)
        }
    }

    // Compact "Mandarin" / "Cantonese" form for crowded card headers —
    // same logic as TopicPreset.languageDisplay but operating on a
    // raw string. Falls back to the original when there's no paren.
    private func shortLanguageLabel(_ language: String) -> String {
        if let open = language.firstIndex(of: "("),
           let close = language.firstIndex(of: ")"),
           open < close {
            return String(language[language.index(after: open)..<close])
        }
        return language
    }

    @MainActor
    private func loadPublicDecksIfNeeded() async {
        guard !hasFetchedPublicDecks else { return }
        hasFetchedPublicDecks = true
        guard let profile = try? await UserService.fetchProfile() else { return }
        let languages = (profile.onboarding?.languagePreferences ?? [])
            .map { canonicalLanguageName($0.language) }
        guard !languages.isEmpty else { return }
        do {
            publicDecks = try await FirebaseDeckService.fetchPublicDecks(
                languages: Array(Set(languages))
            )
        } catch {
            print("loadPublicDecksIfNeeded failed: \(error)")
            hasFetchedPublicDecks = false
        }
    }

    // Same Firestore query as `loadPublicDecksIfNeeded` (the existing
    // composite index already covers it), then narrowed client-side
    // to decks whose (language, dialect) pair matches one of the
    // user's saved language preferences. Firestore can't do an
    // efficient multi-field IN query across two columns, so the
    // dialect filter happens after the fetch — fine because the
    // upstream query is already capped at 20 results per language.
    private func loadDialectMatchedDecksIfNeeded() async {
        guard !hasFetchedDialectMatchedDecks else { return }
        hasFetchedDialectMatchedDecks = true
        guard let profile = try? await UserService.fetchProfile() else { return }
        let prefs = profile.onboarding?.languagePreferences ?? []
        guard !prefs.isEmpty else { return }

        // (canonical language, dialect) pairs the user actually picked.
        // Lowercased for case-insensitive comparison so a "MSA" deck
        // stored uppercase still matches a "msa" pref, etc.
        let matchKeys = Set(prefs.map {
            "\(canonicalLanguageName($0.language).lowercased())|\($0.dialect.lowercased())"
        })
        let languages = Array(Set(prefs.map { canonicalLanguageName($0.language) }))

        do {
            let candidates = try await FirebaseDeckService.fetchPublicDecks(
                languages: languages,
                limit: 40
            )
            dialectMatchedDecks = candidates.filter {
                let key = "\($0.language.lowercased())|\($0.dialect.lowercased())"
                return matchKeys.contains(key)
            }
        } catch {
            print("loadDialectMatchedDecksIfNeeded failed: \(error)")
            hasFetchedDialectMatchedDecks = false
        }
    }

    @MainActor
    private func loadCulturalInsight() async {
        guard let profile = try? await UserService.fetchProfile() else { return }
        let destinations = (profile.onboarding?.destinations ?? []).map { $0.name }
        guard !destinations.isEmpty else {
            culturalInsightCountry = nil
            culturalInsightFact = nil
            return
        }
        isLoadingCulturalInsight = true
        defer { isLoadingCulturalInsight = false }
        do {
            if let insight = try await DeckGenerator.suggestCulturalInsight(
                forDestinations: destinations
            ) {
                culturalInsightCountry = insight.location
                culturalInsightFact = insight.fact
            }
        } catch {
            print("loadCulturalInsight failed: \(error)")
        }
    }

    // MARK: Languages Based on Where You Are

    private var languagesNearYouSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Languages Based on Where You Are")
                .font(.custom("NeueHaasDisplay-Light", size: 18))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(visibleNearbyLanguages) { pref in
                        nearbyLanguageCard(pref: pref)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }

    // Card metrics scaled 1.6× down from the original 220×200 footprint
    // (≈138×125). Speaker + "Add Language" type each bumped +2pt over the
    // original scale-down so the secondary line stays legible. The action
    // row's top padding (14pt) is roughly half the visible gap that the
    // previous Spacer-based layout produced — i.e., the speakers→add
    // distance was halved per the latest design pass.
    private func nearbyLanguageCard(pref: LanguagePreference) -> some View {
        let speakers = totalSpeakers(for: pref.language)
        let isAdded = addedNearbyLanguages.contains(pref.language)
        return VStack(alignment: .leading, spacing: 6) {
            Text(pref.language)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            // Always render the speaker line so every card in a row is
            // the same height. `totalSpeakers` now always returns a
            // positive number (static table, else a 1M floor); the
            // non-breaking-space fallback is belt-and-suspenders so the
            // line still reserves its height in any edge case.
            Text({
                let s = formatSpeakers(speakers)
                return s.isEmpty ? "\u{00A0}" : s
            }())
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)

            HStack(alignment: .center) {
                Text(isAdded ? "Added" : "Add Language")
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(isAdded ? Color.secondary : Color.black)
                Spacer()
                Button {
                    Haptics.light()
                    Task { await addNearbyLanguage(pref) }
                } label: {
                    if isAdded {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.black)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    } else {
                        addCircleButton(size: 22, plusSize: 10)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isAdded)
            }
            .padding(.top, 14)
        }
        // Card sizes to its content with a fixed 8pt margin below the
        // plus button (per design pass: "8 px extending down from the
        // circle of the plus button"). Top/sides keep the original 10pt
        // padding; the bottom override drops the dead space that the
        // previous fixed 125pt height was producing.
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: 138, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: Languages Based on Where You Want to Go

    private var destinationLanguagesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Languages Based on Where You Want to Go")
                .font(.custom("NeueHaasDisplay-Light", size: 18))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(visibleDestinationLanguages) { pref in
                        nearbyLanguageCard(pref: pref)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Languages from Adjacent Countries

    private var adjacentLanguagesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Languages from Adjacent Countries")
                .font(.custom("NeueHaasDisplay-Light", size: 18))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(visibleAdjacentLanguages) { pref in
                        nearbyLanguageCard(pref: pref)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }

    // Re-fetches the destination-driven rows when the user's destination
    // list changes (or is loaded for the first time). Uses a stable
    // joined-string key so unchanged lists short-circuit and we don't
    // burn Haiku calls on every tab switch.
    @MainActor
    private func loadDestinationLanguagesIfNeeded() async {
        guard let profile = try? await UserService.fetchProfile() else { return }
        let destinations = (profile.onboarding?.destinations ?? []).map { $0.name }
        let key = destinations.joined(separator: "|")
        guard key != lastDestinationsKey else { return }
        lastDestinationsKey = key

        guard !destinations.isEmpty else {
            destinationLanguages = []
            adjacentLanguages = []
            return
        }

        // Filter both rows against the languages the user already studies
        // so the Add Language button doesn't surface duplicates.
        let existing = Set(
            (profile.onboarding?.languagePreferences ?? [])
                .map { $0.language.lowercased() }
        )

        // Fan both LLM calls out in parallel — each is a cheap Haiku
        // round-trip and they have no dependency on one another.
        async let primary = DeckGenerator.suggestLanguages(forDestinations: destinations)
        async let adjacent = DeckGenerator.suggestAdjacentLanguages(forDestinations: destinations)

        do {
            let (primaryResult, adjacentResult) = try await (primary, adjacent)
            let primaryNames = Set(primaryResult.map { $0.language.lowercased() })
            destinationLanguages = primaryResult.filter {
                !existing.contains($0.language.lowercased())
            }
            // Adjacent must skip both the user's existing languages and
            // anything already shown in the primary row — otherwise both
            // rows end up surfacing the same neighbor language.
            adjacentLanguages = adjacentResult.filter {
                let name = $0.language.lowercased()
                return !existing.contains(name) && !primaryNames.contains(name)
            }
        } catch {
            print("loadDestinationLanguagesIfNeeded failed: \(error)")
            // Roll the key back so the next visit retries instead of
            // permanently caching the failure.
            lastDestinationsKey = ""
        }
    }

    @MainActor
    private func loadNearbyLanguages() async {
        guard let coord = locationManager.coordinate, !hasFetchedNearby else { return }
        hasFetchedNearby = true
        do {
            let suggestions = try await DeckGenerator.suggestLanguages(
                forCoordinate: coord.latitude,
                longitude: coord.longitude
            )
            // Drop languages the user is already studying so the row only
            // surfaces languages they could actually add.
            let existing = Set(
                ((try? await UserService.fetchProfile())?.onboarding?.languagePreferences ?? [])
                    .map { $0.language.lowercased() }
            )
            nearbyLanguages = suggestions.filter {
                !existing.contains($0.language.lowercased())
            }
        } catch {
            print("loadNearbyLanguages failed: \(error)")
            hasFetchedNearby = false
        }
    }

    @MainActor
    private func addNearbyLanguage(_ pref: LanguagePreference) async {
        guard !addedNearbyLanguages.contains(pref.language) else { return }
        addedNearbyLanguages.insert(pref.language)
        do {
            try await UserService.addLanguagePreference(pref)
        } catch let error as SubscriptionError {
            // Roll back the optimistic UI flip so the chip re-arms.
            addedNearbyLanguages.remove(pref.language)
            capError = error
        } catch {
            addedNearbyLanguages.remove(pref.language)
            print("addNearbyLanguage failed: \(error)")
        }
    }

    // MARK: Shared bits

    private func addCircleButton(size: CGFloat, plusSize: CGFloat) -> some View {
        Image(systemName: "plus")
            .font(.system(size: plusSize, weight: .regular))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Color.black, lineWidth: 1)
            )
    }
}

// Multi-select language filter for the topic preset row. Renders as a
// checkbox list scoped to the user's saved language preferences plus an
// "All" toggle at the top — picking "All" clears the selection so the
// row falls back to its unfiltered state.
private struct LanguageFilterSheet: View {
    let languages: [String]
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(label: "All", isOn: selection.isEmpty) {
                        selection.removeAll()
                    }
                }
                Section("Your languages") {
                    ForEach(languages, id: \.self) { language in
                        row(label: language, isOn: selection.contains(language)) {
                            if selection.contains(language) {
                                selection.remove(language)
                            } else {
                                selection.insert(language)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter by language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(.black)
                }
            }
        }
    }

    private func row(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(.black)
                Spacer()
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.black : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// One preset card on the "You might like these topics" row. Composed
// from one of the user's onboarding interest chips paired with one of
// their saved language preferences, plus a randomized cardback. Tapping
// the card's plus opens CreateDeckSheet pre-filled with these fields.
private struct TopicPreset: Identifiable, Equatable {
    let id = UUID()
    let topic: String
    let language: String
    let level: String
    let coverStyle: DeckCoverStyle

    // Compact label for the card header. Trims the "Chinese (Mandarin)"
    // canonical form to "Mandarin" so the language + level still fit on
    // a single 220pt-wide preview card without truncating.
    var languageDisplay: String {
        if let open = language.firstIndex(of: "("),
           let close = language.firstIndex(of: ")"),
           open < close {
            let inside = language[language.index(after: open)..<close]
            return String(inside)
        }
        return language
    }
}
