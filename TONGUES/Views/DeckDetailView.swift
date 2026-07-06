import SwiftUI
import Charts

struct DeckDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deck: DeckDocument
    @State private var isPlaying = false
    @State private var isListening = false
    @State private var selectedItem: GeneratedItem?
    // Separate sheet binding for phrase/sentence items — tapping one
    // skips the WordInfoSheet intermediary and opens Sentence Studio
    // directly. Word-shaped items still flow through `selectedItem`
    // into WordInfoSheet.
    @State private var studioItem: GeneratedItem?
    @State private var showSessionToast = false
    @State private var isGeneratingMore = false
    @State private var generationError: String?
    @State private var showPromptInfo = false
    @State private var urgency: DeckUrgency?
    @State private var showDeleteConfirmation = false
    @State private var showReviewQueueInfo = false
    @State private var showRetentionInfo = false
    // Export flows: audio (settings sheet → generated .m4a) and CSV. Both
    // hand a file URL to the share sheet via `exportedFile`.
    @State private var showAudioExport = false
    @State private var exportedFile: ExportedFile?
    // "Merge into…" — copies this deck's items into another deck of the
    // same language + dialect. `mergeConfirmation` holds the target deck's
    // title for the post-merge confirmation alert.
    @State private var showMergeSheet = false
    @State private var mergeConfirmation: String?
    // "Rename" — edit the deck's title, with an AI-suggested refresh
    // drawn from the deck's current contents.
    @State private var showRenameSheet = false
    // Catches `SubscriptionError.capExceeded` from the audio cap
    // gate; surfaces via the shared cap alert + paywall.
    @State private var capError: SubscriptionError?
    // Tabbed split between the item list and the FSRS stats surface.
    // Swipe-driven via a horizontal drag gesture so the two tabs feel
    // like a single sliding plane rather than two disconnected views.
    @State private var selectedTab: DetailTab = .content
    // Per-card FSRS state used by the Stats tab to render the
    // forgetting curve + at-risk word list. Populated by
    // `loadUrgency` alongside the urgency snapshot — both surfaces
    // need the same underlying schedules so we fetch once.
    @State private var schedules: [String: CardSchedule] = [:]

    enum DetailTab: Hashable {
        case content
        case artifacts
        case stats
    }

    // Saved long-form generations (stories, conversations, songs, etc.)
    // surfaced in the Artifacts tab. Loaded on appear; refreshed when
    // the user dismisses GenerateContentSheet so a freshly-bookmarked
    // item shows up immediately without a navigation round-trip.
    @State private var artifacts: [Artifact] = []
    @State private var isLoadingArtifacts = false
    @State private var selectedArtifact: Artifact?
    @State private var pendingArtifactDeletion: Artifact?

    init(deck: DeckDocument) {
        self._deck = State(initialValue: deck)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                detailContent
            }
        }
        .background(Color(libraryHex: "F4F4F4").ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Haptics.light()
                        showRenameSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        Haptics.light()
                        showMergeSheet = true
                    } label: {
                        Label("Merge into", systemImage: "arrow.triangle.merge")
                    }
                    Button {
                        Haptics.light()
                        showAudioExport = true
                    } label: {
                        Label("Download as audio", systemImage: "waveform")
                    }
                    Button {
                        Haptics.light()
                        exportCSV()
                    } label: {
                        Label("Export as CSV", systemImage: "tablecells")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Haptics.medium()
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete deck", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.black)
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            DeckRenameSheet(deck: deck) { newTitle in
                showRenameSheet = false
                deck = deck.withTitle(newTitle)
            }
        }
        .sheet(isPresented: $showMergeSheet) {
            DeckMergeSheet(deck: deck) { targetTitle in
                showMergeSheet = false
                mergeConfirmation = targetTitle
            }
        }
        .alert("Merged", isPresented: mergeConfirmationBinding) {
            Button("OK") { mergeConfirmation = nil }
        } message: {
            Text("Added \(deck.items.count) \(deck.contentType.lowercased()) to \"\(mergeConfirmation ?? "")\".")
        }
        .sheet(isPresented: $showAudioExport) {
            DeckAudioExportSheet(deck: deck) { url in
                showAudioExport = false
                exportedFile = ExportedFile(url: url)
            }
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog(
            "Delete this deck?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteDeck() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Couldn't generate more", isPresented: errorAlertBinding) {
            Button("OK") { generationError = nil }
        } message: {
            Text(generationError ?? "")
        }
        .fullScreenCover(isPresented: $isPlaying) {
            SessionIntroView(
                deck: deck,
                urgency: urgency,
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
        .onChange(of: isPlaying) { _, nowPlaying in
            // Cover just dismissed — reviews may have been committed by the
            // FlashcardView's fire-and-forget save Task. Give it a beat to
            // finish writing schedules to Firestore, then re-query urgency
            // so the progress bar reflects the new state.
            guard !nowPlaying else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await loadUrgency()
            }
        }
        .fullScreenCover(isPresented: $isListening) {
            ListenSessionView(deck: deck)
        }
        .subscriptionCapAlert($capError)
        .sessionCompleteToast(isPresented: $showSessionToast)
        .sheet(item: $selectedItem) { item in
            WordInfoSheet(
                item: item,
                deckLanguage: item.language ?? deck.language,
                deckDialect: deck.dialect,
                contentType: deck.contentType,
                deckId: deck.id,
                onItemUpdated: { updated in
                    // Optimistic local replacement so the list reflects
                    // the Sentence Studio rewrite immediately — the
                    // backing Firestore write already happened inside
                    // SentenceStudioView.saveActiveSentence().
                    replaceLocalItem(updated)
                },
                onAddRelated: { kind in
                    Task { await addRelated(kind, to: item) }
                }
            )
        }
        .sheet(item: $studioItem) { item in
            NavigationStack {
                SentenceStudioView(
                    item: item,
                    deckLanguage: item.language ?? deck.language,
                    deckDialect: deck.dialect,
                    deckId: deck.id,
                    onSaved: { updated in
                        replaceLocalItem(updated)
                        studioItem = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showPromptInfo) {
            DeckPromptInfoSheet(deck: deck)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showReviewQueueInfo) {
            ReviewQueueInfoSheet(status: barLabel)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showRetentionInfo) {
            TargetRetentionInfoSheet(
                retention: deck.resolvedTargetRetention,
                onChange: { newValue in
                    Task { await updateRetention(newValue) }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedArtifact) { artifact in
            ArtifactReaderSheet(artifact: artifact)
        }
        .confirmationDialog(
            "Delete this artifact?",
            isPresented: Binding(
                get: { pendingArtifactDeletion != nil },
                set: { if !$0 { pendingArtifactDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingArtifactDeletion
        ) { artifact in
            Button("Delete", role: .destructive) {
                Task {
                    await deleteArtifact(artifact)
                    pendingArtifactDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingArtifactDeletion = nil
            }
        } message: { _ in
            Text("This can't be undone.")
        }
        .task(id: deck.id) {
            // Two independent loads kicked off in parallel so the
            // Stats and Artifacts tabs both populate without one
            // having to wait on the other's network call.
            async let urgencyLoad: Void = loadUrgency()
            async let artifactLoad: Void = loadArtifacts()
            _ = await (urgencyLoad, artifactLoad)
        }
        // Deck detail has a light backdrop, so force the status bar to dark
        // (black) content while it's on screen — it stays black even when
        // arriving from a dark tab (Study/Library). Released on pop and
        // while a full-screen study/listen cover (dark backdrop) is up so
        // those keep white content.
        .onAppear { updateForcedStatusBar() }
        .onDisappear { AppTabRouter.shared.forceDarkStatusBar = false }
        .onChange(of: isPlaying) { _, _ in updateForcedStatusBar() }
        .onChange(of: isListening) { _, _ in updateForcedStatusBar() }
    }

    private func updateForcedStatusBar() {
        AppTabRouter.shared.forceDarkStatusBar = !isPlaying && !isListening
    }

    // Mirrors the Study page's featured-card slot, but recolored to the
    // page-wide F4F4F4 background and bound to this deck's own cover so
    // the user sees the cardback they picked.
    private var headerSection: some View {
        HStack {
            Spacer()
            FeaturedCardImage(coverStyle: deck.resolvedCoverStyle)
                .scrollHeaderScale()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(deck.title)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(deck.language) \(deck.level)")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text("\(deck.items.count) \(deck.contentType.lowercased())")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button {
                        Haptics.light()
                        showPromptInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

                priorityBar

                tabBar
                    .padding(.top, 16)

                tabbedContent
                    // Lightweight horizontal swipe through the three
                    // tabs. Left-swipe advances Content → Artifacts →
                    // Stats. Right-swipe walks back the same path; a
                    // right-swipe at Content pops the view (mirrors
                    // the NavigationStack back-button). Vertical
                    // scroll is preserved by gating on
                    // horizontal > vertical travel and only acting on
                    // .onEnded.
                    .gesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                let dx = value.translation.width
                                guard abs(dx) > abs(value.translation.height) else { return }
                                if dx < -40 {
                                    switch selectedTab {
                                    case .content:
                                        Haptics.light()
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            selectedTab = .artifacts
                                        }
                                    case .artifacts:
                                        Haptics.light()
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            selectedTab = .stats
                                        }
                                    case .stats:
                                        break
                                    }
                                } else if dx > 40 {
                                    switch selectedTab {
                                    case .stats:
                                        Haptics.light()
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            selectedTab = .artifacts
                                        }
                                    case .artifacts:
                                        Haptics.light()
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            selectedTab = .content
                                        }
                                    case .content:
                                        Haptics.light()
                                        dismiss()
                                    }
                                }
                            }
                    )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
    }

    // Four vertical bars indicating how much of this deck is still
    // pending — brand-new cards plus reviewed cards that have come
    // due. The more bars filled, the more cards need attention now.
    // The bars themselves act as the button — tapping anywhere on the
    // group opens the explainer sheet with the current status.
    // Always renders — even before `loadUrgency` resolves — so the
    // indicator never disappears on a fresh-loaded deck. Pre-load it
    // shows all four bars filled (treated as 100% pending); once
    // urgency lands, the level redistributes with an eased animation.
    private var priorityBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                Haptics.light()
                showRetentionInfo = true
            } label: {
                Image("Calendar")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.light()
                showReviewQueueInfo = true
            } label: {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { idx in
                        Rectangle()
                            .fill(idx < priorityLevel ? Color.black : Color(white: 0.82))
                            .frame(width: 3, height: 18)
                    }
                }
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.25), value: priorityLevel)
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    Haptics.medium()
                    startAudio()
                } label: {
                    Image("Headphones")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 27, height: 27)
                        .frame(width: 43, height: 43)
                        .background(Color.black.opacity(0.04))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(deck.items.isEmpty)

                Button {
                    Haptics.medium()
                    isPlaying = true
                } label: {
                    Image("Play")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 27, height: 27)
                        .frame(width: 43, height: 43)
                        .background(Color.black)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(deck.items.isEmpty)
            }
        }
    }

    // Number of bars to fill (0–4) based on the share of the deck
    // still pending review — new cards plus due cards over total.
    // 0 bars means nothing pending ("Up to date"); 4 bars covers
    // brand-new decks and decks with a heavy backlog. Falls back to
    // 4 when urgency hasn't loaded yet so the indicator stays filled
    // instead of collapsing to empty.
    private var priorityLevel: Int {
        guard let urgency, urgency.totalCount > 0 else { return 4 }
        let pending = urgency.newCount + urgency.dueCount
        guard pending > 0 else { return 0 }
        let fraction = Double(pending) / Double(urgency.totalCount)
        return min(4, max(1, Int(ceil(fraction * 4))))
    }

    private var barLabel: String {
        guard let urgency else { return "New" }
        if urgency.dueCount > 0 { return "\(urgency.dueCount) due" }
        if urgency.newCount == urgency.totalCount { return "New" }
        return "Up to date"
    }

    // MARK: - Content / Stats tabs

    // Compact tab bar above the item list. Mirrors the underline-on-
    // active pattern used elsewhere (uppercase, gray inactive,
    // black active with a 2pt underline).
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "CONTENT", tab: .content)
            tabButton(title: "ARTIFACTS", tab: .artifacts)
            tabButton(title: "STATS", tab: .stats)
        }
    }

    private func tabButton(title: String, tab: DetailTab) -> some View {
        Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selectedTab == tab ? .black : Color.secondary)
                Rectangle()
                    .fill(selectedTab == tab ? Color.black : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabbedContent: some View {
        switch selectedTab {
        case .content:   contentTab
        case .artifacts: artifactsTab
        case .stats:     statsTab
        }
    }

    // Per-card list of the deck's items. Generate Artifact has moved
    // out to the Artifacts tab, so this tab is now purely the deck's
    // vocabulary.
    private var contentTab: some View {
        // Lazy so only near-visible rows are built. A plain VStack here
        // instantiated every row (each with a drag gesture, tap handlers,
        // and an animated waveform button) up front — the freeze on
        // landing and the sluggish scroll on large decks. LazyVStack lays
        // out identically for this full-width vertical list.
        LazyVStack(spacing: 0) {
            ForEach(deck.items) { item in
                SwipeToDeleteRow(onDelete: { deleteItem(item) }) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.word)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.black)
                            if let t = item.transliteration, !t.isEmpty {
                                Text(t)
                                    .font(.system(size: 13))
                                    .italic()
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.translation)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.light()
                            // Phrase/sentence items skip the
                            // intermediary word-detail sheet and
                            // go straight to Sentence Studio.
                            if isPhraseOrSentence(item) {
                                studioItem = item
                            } else {
                                selectedItem = item
                            }
                        }

                        SpeakWaveformButton {
                            SpeechClient.shared.speak(
                                item.word,
                                language: item.language ?? deck.language,
                                allowForvo: true
                            )
                        }
                    }
                    .padding(.vertical, 10)
                }
                Divider()
            }

            HStack {
                Spacer()
                Button {
                    Haptics.medium()
                    Task { await generateMore() }
                } label: {
                    HStack(spacing: 8) {
                        if isGeneratingMore {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(isGeneratingMore ? "Generating…" : "Generate More")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.black)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(
                        Capsule()
                            .stroke(Color(white: 0.85))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGeneratingMore)
                Spacer()
            }
            .padding(.top, 16)
        }
        .padding(.top, 8)
        .transition(.opacity)
    }

    // FSRS-driven stats surface. Three blocks, top to bottom:
    //   1. Summary tiles — average recall, count at risk, mean
    //      stability — derived from the schedules dict that
    //      `loadUrgency` already fetched.
    //   2. Forgetting curve — projects the deck's average
    //      retrievability across the next 30 days using each card's
    //      current stability (or the FSRS new-card baseline for
    //      never-reviewed items). Reads top-down: the steeper the
    //      drop, the sooner the user will start forgetting on average.
    //   3. At-risk word list — top 5 cards with the highest current
    //      forgetting risk. Tapping a row opens the same word /
    //      sentence sheets the Content tab uses.
    private var statsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            statsSummary
            forgettingCurveSection
            atRiskSection
        }
        .padding(.top, 16)
        .padding(.bottom, 32)
        .transition(.opacity)
    }

    // MARK: - Artifacts tab

    // Bookmarked long-form generations. The Generate Artifact row sits
    // up top so the user creates and reviews keepsakes in the same
    // place. Empty state nudges them to use it; otherwise it's a
    // vertical stack of tap-to-open cards, each one a saved Story /
    // Conversation / etc.
    @ViewBuilder
    private var artifactsTab: some View {
        VStack(spacing: 0) {
            GenerateRow(
                deck: deck,
                onSheetClosed: {
                    // Refetch artifacts after the sheet closes so a
                    // bookmark tap inside it surfaces a new row in the
                    // list without a navigation round-trip.
                    Task { await loadArtifacts() }
                }
            ) { newItem in
                // The Generate flow also lets the user save individual
                // words from the inline audit panel; keep that pathway
                // wired so a tapped-and-added word still lands in the
                // deck's items array immediately.
                deck = DeckDocument(
                    id: deck.id,
                    title: deck.title,
                    language: deck.language,
                    dialect: deck.dialect,
                    level: deck.level,
                    contentType: deck.contentType,
                    amount: deck.amount,
                    tones: deck.tones,
                    interests: deck.interests,
                    userPrompt: deck.userPrompt,
                    items: deck.items + [newItem],
                    languages: deck.languages,
                    coverStyle: deck.coverStyle,
                    targetRetention: deck.targetRetention,
                    createdAt: deck.createdAt
                )
            }
            .padding(.horizontal, -8)

            if isLoadingArtifacts && artifacts.isEmpty {
                loadingArtifactsState
            } else if artifacts.isEmpty {
                emptyArtifactsState
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(artifacts) { artifact in
                        artifactCard(artifact)
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(.bottom, 32)
        .transition(.opacity)
    }

    private var emptyArtifactsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.black.opacity(0.25))
            Text("No artifacts saved yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.black)
            Text("Open Generate, make a story, conversation, song, poem, news article, or joke — then tap the bookmark on the result to keep it here.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var loadingArtifactsState: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(.black.opacity(0.5))
            Spacer()
        }
        .padding(.vertical, 48)
    }

    private func artifactCard(_ artifact: Artifact) -> some View {
        Button {
            Haptics.light()
            selectedArtifact = artifact
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: artifactIcon(forKind: artifact.resolvedKind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                    Text(artifact.resolvedKind.rawValue.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.black)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(relativeDate(artifact.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                Text(artifact.title.isEmpty ? artifact.resolvedKind.rawValue : artifact.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(artifactPreview(artifact))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(white: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Haptics.medium()
                pendingArtifactDeletion = artifact
            } label: {
                Label("Delete artifact", systemImage: "trash")
            }
        }
    }

    // SF Symbols chosen to match each kind's mental model: book for
    // narrative, dual bubbles for dialogue, newspaper for journalism,
    // music note for songs, left-aligned text for poetry, smile for
    // jokes. Kept lightweight so the chip reads at a glance.
    private func artifactIcon(forKind kind: ContentGenerationKind) -> String {
        switch kind {
        case .story:        return "book"
        case .conversation: return "bubble.left.and.bubble.right"
        case .newsArticle:  return "newspaper"
        case .songs:        return "music.note"
        case .poems:        return "text.alignleft"
        case .jokes:        return "face.smiling"
        }
    }

    // Preview pulls from the foreign half so the user sees the actual
    // study material in the list — not the English crib, which would
    // make every card feel like reading their own language.
    private func artifactPreview(_ artifact: Artifact) -> String {
        let foreignBlock: String
        if let range = artifact.prose.range(of: "English:") {
            foreignBlock = String(artifact.prose[..<range.lowerBound])
        } else {
            foreignBlock = artifact.prose
        }
        return foreignBlock
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Artifact persistence

    private func loadArtifacts() async {
        guard let deckId = deck.id else { return }
        isLoadingArtifacts = true
        defer { isLoadingArtifacts = false }
        do {
            let fetched = try await FirebaseDeckArtifactService.fetch(forDeck: deckId)
            await MainActor.run { artifacts = fetched }
        } catch {
            print("Artifact fetch failed: \(error)")
        }
    }

    private func deleteArtifact(_ artifact: Artifact) async {
        do {
            try await FirebaseDeckArtifactService.delete(artifact)
            await MainActor.run {
                artifacts.removeAll { $0.id == artifact.id }
            }
        } catch {
            print("Artifact delete failed: \(error)")
        }
    }

    private var statsSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            statTile(
                label: "Avg recall",
                value: averageRecallText,
                accent: recallAccent
            )
            statTile(
                label: "At risk",
                value: "\(atRiskCount)",
                accent: atRiskCount > 0 ? .orange : .black
            )
            statTile(
                label: "Avg stability",
                value: averageStabilityText,
                accent: .black
            )
        }
    }

    private func statTile(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var forgettingCurveSection: some View {
        let curve = forgettingCurve
        VStack(alignment: .leading, spacing: 8) {
            Text("Forgetting curve")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
            Text("Average chance the deck is still remembered each day from today, projecting forward without further review.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if curve.isEmpty {
                Text("Review some cards to start the curve.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    // Target-retention reference line so the user can
                    // see when the deck dips below where the
                    // scheduler is trying to keep them.
                    RuleMark(y: .value("Target", deck.resolvedTargetRetention))
                        .foregroundStyle(.gray.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .topTrailing, alignment: .topTrailing) {
                            Text("Target \(Int(deck.resolvedTargetRetention * 100))%")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                    ForEach(curve) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Recall", point.recall)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.black)
                        AreaMark(
                            x: .value("Day", point.day),
                            y: .value("Recall", point.recall)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.black.opacity(0.12), .black.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
                .chartYScale(domain: 0.0...1.0)
                .chartYAxis {
                    AxisMarks(values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                        AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v * 100))%")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [0, 7, 14, 21, 30]) { value in
                        AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(v == 0 ? "Today" : "+\(v)d")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var atRiskSection: some View {
        let rows = atRiskRows
        VStack(alignment: .leading, spacing: 10) {
            Text("Most at risk")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
            Text("Cards with the highest forgetting risk right now. Review these first.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No cards at risk — keep up the good work.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button {
                            Haptics.light()
                            if isPhraseOrSentence(row.item) {
                                studioItem = row.item
                            } else {
                                selectedItem = row.item
                            }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.item.word)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .lineLimit(1)
                                    Text(row.item.translation)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                riskBadge(risk: row.risk)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func riskBadge(risk: Double) -> some View {
        let pct = Int((risk * 100).rounded())
        let tint: Color = risk > 0.6 ? .red : (risk > 0.3 ? .orange : .green)
        return Text("\(pct)%")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Stats derivations

    private var averageRecall: Double {
        guard !deck.items.isEmpty else { return 0 }
        let now = Date()
        let total = deck.items.reduce(0.0) { acc, item in
            let schedule = schedules[item.id.uuidString]
            return acc + (1.0 - FSRSScheduler.forgettingRisk(for: schedule, at: now))
        }
        return total / Double(deck.items.count)
    }

    private var averageRecallText: String {
        guard !deck.items.isEmpty else { return "—" }
        return "\(Int((averageRecall * 100).rounded()))%"
    }

    private var recallAccent: Color {
        let r = averageRecall
        if r >= 0.8 { return Color(red: 0.18, green: 0.55, blue: 0.30) }
        if r >= 0.6 { return .orange }
        return .red
    }

    private var atRiskCount: Int {
        let now = Date()
        return deck.items.reduce(0) { acc, item in
            let schedule = schedules[item.id.uuidString]
            return FSRSScheduler.forgettingRisk(for: schedule, at: now) >= 0.3 ? acc + 1 : acc
        }
    }

    private var averageStabilityText: String {
        let stabilities = schedules.values.compactMap { $0.stability }
        guard !stabilities.isEmpty else { return "—" }
        let avg = stabilities.reduce(0, +) / Double(stabilities.count)
        if avg < 1.0 { return "<1d" }
        return "\(Int(avg.rounded()))d"
    }

    // 31 samples (today + 30 days). For each day we average each
    // card's projected retrievability under its current stability so
    // the curve reflects what the *whole deck* tends to look like —
    // not just the worst card.
    private var forgettingCurve: [ForgettingPoint] {
        guard !deck.items.isEmpty else { return [] }
        let now = Date()
        let stabilities: [Double] = deck.items.map { item in
            if let s = schedules[item.id.uuidString]?.stability {
                return max(0.1, s)
            }
            // Never-reviewed cards sit at the FSRS baseline so the
            // curve doesn't lie about a deck that's all-new.
            return max(0.1, 1.0 / max(0.001, FSRSScheduler.newCardForgettingRisk) - 1.0)
        }
        let elapsedBaselines: [Double] = deck.items.map { item in
            guard let last = schedules[item.id.uuidString]?.lastReviewedAt else { return 0 }
            return max(0, now.timeIntervalSince(last) / 86_400)
        }
        return (0...30).map { day in
            let dayDouble = Double(day)
            let avg = zip(stabilities, elapsedBaselines).reduce(0.0) { acc, pair in
                let (s, baseline) = pair
                let r = FSRSScheduler.retrievability(
                    elapsedDays: baseline + dayDouble,
                    stability: s
                )
                return acc + r
            } / Double(deck.items.count)
            return ForgettingPoint(day: day, recall: avg)
        }
    }

    private var atRiskRows: [AtRiskRow] {
        let now = Date()
        return deck.items
            .map { item in
                AtRiskRow(
                    id: item.id,
                    item: item,
                    risk: FSRSScheduler.forgettingRisk(
                        for: schedules[item.id.uuidString],
                        at: now
                    )
                )
            }
            .filter { $0.risk >= 0.2 }
            .sorted { $0.risk > $1.risk }
            .prefix(5)
            .map { $0 }
    }

    struct ForgettingPoint: Identifiable {
        let day: Int
        let recall: Double
        var id: Int { day }
    }

    struct AtRiskRow: Identifiable {
        let id: UUID
        let item: GeneratedItem
        let risk: Double
    }

    private func loadUrgency() async {
        let cardIds = deck.items.map { $0.id.uuidString }
        let fetched = (try? await FirebaseDeckService.fetchSchedules(cardIds: cardIds)) ?? [:]
        schedules = fetched
        urgency = FSRSScheduler.urgency(for: deck, schedules: fetched, at: Date())
    }

    // Wraps the Headphones-button presentation so the audio-session
    // cap fires before ListenSessionView mounts. Pro + Max are
    // unlimited (Int.max), so for them this is a single async hop and
    // then-present. Beginner blocks at 50/month with the paywall.
    private func startAudio() {
        Task {
            do {
                try await SubscriptionService.shared.tryStartAudioSession()
                isListening = true
            } catch let error as SubscriptionError {
                capError = error
            } catch {
                isListening = true
            }
        }
    }

    private func deleteDeck() async {
        guard let id = deck.id else { return }
        do {
            try await FirebaseDeckService.deleteDeck(id: id)
            Haptics.success()
            dismiss()
        } catch {
            print("Failed to delete deck: \(error)")
        }
    }

    // Writes a basic native/foreign CSV to a temp file and opens the
    // share sheet so the user can save or send it.
    private func exportCSV() {
        do {
            let url = try DeckExporter.makeCSV(for: deck)
            exportedFile = ExportedFile(url: url)
        } catch {
            generationError = error.localizedDescription
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { generationError != nil },
            set: { if !$0 { generationError = nil } }
        )
    }

    private var mergeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { mergeConfirmation != nil },
            set: { if !$0 { mergeConfirmation = nil } }
        )
    }

    // Swipe-to-delete for a single word. Optimistically drops it from the
    // local list (animated) so the row disappears instantly, then removes
    // it in Firestore. On failure the item is restored and an error shown.
    private func deleteItem(_ item: GeneratedItem) {
        guard let deckId = deck.id else { return }
        let previous = deck
        Haptics.medium()
        withAnimation(.easeInOut(duration: 0.25)) {
            deck = deck.withItems(deck.items.filter { $0.id != item.id })
        }
        Task {
            do {
                try await FirebaseDeckService.removeItem(inDeck: deckId, itemId: item.id)
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) { deck = previous }
                    generationError = error.localizedDescription
                }
            }
        }
    }

    // Generates 5 more items using the same recipe (prompt + interests + tones
    // + level + content type + language) the deck was created with, persists
    // them to Firestore, and appends them locally so the list updates in place.
    private func generateMore() async {
        guard !isGeneratingMore else { return }
        isGeneratingMore = true
        defer { isGeneratingMore = false }

        do {
            // Feed every existing foreign word in as "words to avoid" so
            // Generate More never re-issues one the deck already has, and
            // fold the deck's actual content into the prompt so the new
            // items stay on the same theme as what's here — not just the
            // original one-line prompt.
            let existingForeign = deck.items.map { $0.word }
            let themedPrompt = generateMorePrompt()

            let result = try await DeckGenerator.generate(
                userPrompt: themedPrompt,
                interests: deck.interests,
                language: deck.language,
                dialect: deck.dialect,
                contentType: deck.contentType,
                amount: "5",
                level: deck.level,
                tones: deck.tones,
                knownWordsToAvoid: existingForeign
            )

            // Belt-and-suspenders de-dupe: drop any returned item whose
            // foreign word already exists in the deck (or repeats within
            // this batch), normalized case/whitespace-insensitively — so a
            // repeat can't slip through even if the model ignores the
            // avoid-list.
            var seen = Set(deck.items.map { normalizedWordKey($0.word) })
            let uniqueItems = result.items.filter { item in
                let key = normalizedWordKey(item.word)
                guard !key.isEmpty, !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            let newItems = uniqueItems.map { $0.withLanguage(deck.language) }

            guard !newItems.isEmpty else { return }

            if let deckId = deck.id {
                try await FirebaseDeckService.addItems(
                    toDeck: deckId,
                    items: uniqueItems,
                    sourceLanguage: deck.language
                )
            }

            deck = DeckDocument(
                id: deck.id,
                title: deck.title,
                language: deck.language,
                dialect: deck.dialect,
                level: deck.level,
                contentType: deck.contentType,
                amount: deck.amount,
                tones: deck.tones,
                interests: deck.interests,
                userPrompt: deck.userPrompt,
                items: deck.items + newItems,
                languages: deck.languages,
                coverStyle: deck.coverStyle,
                targetRetention: deck.targetRetention,
                createdAt: deck.createdAt
            )
        } catch {
            generationError = error.localizedDescription
        }
    }

    // Normalized key for repeat detection: trimmed + lowercased so trivial
    // case / whitespace differences still count as the same word.
    private func normalizedWordKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Builds the Generate More prompt from the deck's own subject matter:
    // the original prompt plus a sample of the English meanings already in
    // the deck, so new items track the combined theme rather than drifting.
    private func generateMorePrompt() -> String {
        let themeSample = deck.items
            .map { $0.translation }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(40)
            .joined(separator: ", ")
        var lines: [String] = []
        let base = deck.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { lines.append(base) }
        if !themeSample.isEmpty {
            lines.append(
                "Generate more \(deck.contentType.lowercased()) on the same theme and subject matter as this deck, which so far covers: \(themeSample). Stay within that theme and do not repeat any item already in the deck."
            )
        }
        return lines.joined(separator: "\n\n")
    }

    @MainActor
    private func updateRetention(_ newValue: Double) async {
        let previous = deck
        // Optimistic local update so the UI tracks the stepper without lag.
        deck = DeckDocument(
            id: deck.id,
            title: deck.title,
            language: deck.language,
            dialect: deck.dialect,
            level: deck.level,
            contentType: deck.contentType,
            amount: deck.amount,
            tones: deck.tones,
            interests: deck.interests,
            userPrompt: deck.userPrompt,
            items: deck.items,
            languages: deck.languages,
            coverStyle: deck.coverStyle,
            targetRetention: newValue,
            createdAt: deck.createdAt
        )
        guard let deckId = deck.id else { return }
        do {
            try await FirebaseDeckService.updateTargetRetention(
                deckId: deckId,
                retention: newValue
            )
        } catch {
            deck = previous
        }
    }

    // MARK: - Per-word relation generation

    // Mirrors WordInfoSheet/DeckResultsView's phrase/sentence detection
    // so an item that's clearly a phrase or full sentence routes to
    // Sentence Studio rather than the word-detail sheet.
    private func isPhraseOrSentence(_ item: GeneratedItem) -> Bool {
        let pos = (item.partsOfSpeech ?? []).map { $0.lowercased() }
        if !pos.isEmpty {
            let phraseLike: Set<String> = ["phrase", "sentence", "idiom"]
            return pos.contains(where: { phraseLike.contains($0) })
        }
        let kind = deck.contentType.lowercased()
        return kind == "sentences" || kind == "phrases"
    }

    // Replaces a single item in the local deck state. Used by both the
    // Sentence Studio save callback and the per-item relation flow.
    private func replaceLocalItem(_ updated: GeneratedItem) {
        let replaced = deck.items.map { existing in
            existing.id == updated.id ? updated : existing
        }
        deck = DeckDocument(
            id: deck.id,
            title: deck.title,
            language: deck.language,
            dialect: deck.dialect,
            level: deck.level,
            contentType: deck.contentType,
            amount: deck.amount,
            tones: deck.tones,
            interests: deck.interests,
            userPrompt: deck.userPrompt,
            items: replaced,
            languages: deck.languages,
            coverStyle: deck.coverStyle,
            targetRetention: deck.targetRetention,
            createdAt: deck.createdAt
        )
    }

    // Runs the same Claude call DeckResultsView uses for its inline
    // "Add Phrases / Add Synonyms / Add Plurals / Add Conjugations /
    // Add Antonyms" chips, but caps the result at 2 items and inserts
    // them right under the source word. Persists the updated ordering
    // back to Firestore.
    @MainActor
    private func addRelated(_ kind: RelationKind, to item: GeneratedItem) async {
        do {
            let newItems = try await DeckGenerator.generateRelated(
                relation: kind,
                source: item,
                language: deck.language,
                dialect: deck.dialect,
                level: deck.level,
                count: 2
            )
            let tagged = newItems.map { $0.withKind(kind.rawValue) }
            var updatedItems = deck.items
            if let idx = updatedItems.firstIndex(where: { $0.id == item.id }) {
                updatedItems.insert(contentsOf: tagged, at: idx + 1)
            } else {
                updatedItems.append(contentsOf: tagged)
            }
            // Update local state first so the rows pop into place as
            // soon as the call returns.
            deck = DeckDocument(
                id: deck.id,
                title: deck.title,
                language: deck.language,
                dialect: deck.dialect,
                level: deck.level,
                contentType: deck.contentType,
                amount: deck.amount,
                tones: deck.tones,
                interests: deck.interests,
                userPrompt: deck.userPrompt,
                items: updatedItems,
                languages: deck.languages,
                coverStyle: deck.coverStyle,
                targetRetention: deck.targetRetention,
                createdAt: deck.createdAt
            )
            if let deckId = deck.id {
                try await FirebaseDeckService.replaceItems(
                    inDeck: deckId,
                    items: updatedItems
                )
            }
            Haptics.success()
        } catch {
            generationError = error.localizedDescription
            Haptics.error()
        }
    }
}

// Subtle FSRS retention adjuster. Values clamp to the same five-step grid
// (80% – 98%) used in Anki — finer granularity isn't meaningful for users.
struct GenerateRow: View {
    let deck: DeckDocument
    // Fires when the GenerateContentSheet dismisses (any reason).
    // DeckDetailView uses it to refetch artifacts so a newly-bookmarked
    // result appears in the Artifacts tab without a navigation
    // round-trip. Declared before `onItemAdded` so the trailing
    // closure at the call site still resolves to `onItemAdded`.
    var onSheetClosed: () -> Void = {}
    // Bubbled up to DeckDetailView whenever the user adds a word from
    // the GenerateContentSheet's inline audit panel. GenerateRow can't
    // mutate `deck` itself (it's a let), so the parent's @State has to
    // be the one that updates.
    var onItemAdded: (GeneratedItem) -> Void = { _ in }
    @State private var activeKind: ContentGenerationKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generate Artifact")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ContentGenerationKind.allCases) { kind in
                        Button {
                            activeKind = kind
                        } label: {
                            Text(kind.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.black)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .overlay(
                                    Capsule()
                                        .stroke(Color(white: 0.85))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 12)
        .sheet(item: $activeKind, onDismiss: { onSheetClosed() }) { kind in
            GenerateContentSheet(kind: kind, deck: deck) { newItem in
                // Forward to DeckDetailView's @State — only the parent
                // can mutate the deck snapshot.
                onItemAdded(newItem)
            }
        }
    }
}

// Reusable speak/sound button. Each tap fires the action and bumps an internal
// counter, which retriggers a single quick play-through of the SF Symbol
// variable-color animation — the same wave-fill SwiftUI uses elsewhere.
struct SpeakWaveformButton: View {
    let action: () -> Void
    var font: Font = .system(size: 16)
    var foregroundColor: Color = .secondary
    var frameSize: CGFloat = 36

    @State private var playCount = 0

    var body: some View {
        Button {
            Haptics.light()
            playCount += 1
            action()
        } label: {
            Image(systemName: "waveform")
                .font(font)
                .foregroundStyle(foregroundColor)
                .symbolEffect(.variableColor.iterative.nonReversing, options: .speed(2), value: playCount)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DeckPromptInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Prompt") {
                        Text(deck.userPrompt.isEmpty ? "(none)" : deck.userPrompt)
                            .font(.system(size: 16))
                            .foregroundStyle(.black)
                    }

                    if !deck.interests.isEmpty {
                        section("Topics") {
                            Text(deck.interests.joined(separator: ", "))
                                .font(.system(size: 15))
                                .foregroundStyle(.black)
                        }
                    }

                    if !deck.tones.isEmpty {
                        section("Tone") {
                            Text(deck.tones.joined(separator: ", "))
                                .font(.system(size: 15))
                                .foregroundStyle(.black)
                        }
                    }

                    section("Settings") {
                        VStack(alignment: .leading, spacing: 6) {
                            settingRow("Language", "\(deck.language) (\(deck.dialect))")
                            settingRow("Level", deck.level)
                            settingRow("Content", deck.contentType)
                            settingRow("Original size", deck.amount)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Original Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.black)
                .multilineTextAlignment(.trailing)
        }
    }
}

// Shared scaffolding for the small in-context explainer sheets attached to
// info-buttons throughout DeckDetailView. Each instance just supplies a
// title and a body block — the NavigationStack, scroll, and Done button are
// identical to `DeckPromptInfoSheet`.
private struct InfoExplainerSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private func infoSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        content()
    }
}

private func infoBody(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 15))
        .foregroundStyle(.black)
        .fixedSize(horizontal: false, vertical: true)
}

struct ReviewQueueInfoSheet: View {
    let status: String

    var body: some View {
        InfoExplainerSheet(title: "Review queue") {
            infoSection("Status") {
                infoBody(status)
            }
            infoSection("The bars") {
                infoBody("Four vertical bars track how much of this deck still needs attention. Each bar represents roughly a quarter of your cards — bars fill as cards stack up that haven't been studied yet or have come due for another pass. Studying drains the bars as the scheduler pushes those cards further out.")
            }
            infoSection("\"New\"") {
                infoBody("\"New\" appears when you haven't reviewed any card in this deck yet. All four bars are filled because the entire deck is pending — tap Play to start a session and the bars retreat as you grade cards.")
            }
            infoSection("\"Up to date\"") {
                infoBody("\"Up to date\" appears when no cards are currently due and you've already studied every card at least once — all four bars sit empty. Come back later and bars will refill as cards reappear on their schedule.")
            }
            infoSection("Clearing the bars") {
                infoBody("Tap the Play button at the top of this deck to start a flashcard session. The bars update after each session as the scheduler reshuffles your cards.")
            }
        }
    }
}

struct TargetRetentionInfoSheet: View {
    let retention: Double
    let onChange: (Double) -> Void

    private let stops: [Double] = [0.80, 0.85, 0.90, 0.95, 0.98]

    private var currentIndex: Int {
        stops.enumerated().min(by: { abs($0.element - retention) < abs($1.element - retention) })?.offset ?? 2
    }

    private var percentLabel: String {
        "\(Int((stops[currentIndex] * 100).rounded()))%"
    }

    var body: some View {
        InfoExplainerSheet(title: "Target retention") {
            infoSection("Current") {
                HStack(alignment: .center) {
                    Text(percentLabel)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.black)
                        .monospacedDigit()
                    Spacer()
                    HStack(spacing: 0) {
                        stepperButton(systemImage: "minus") {
                            Haptics.light()
                            let next = max(0, currentIndex - 1)
                            onChange(stops[next])
                        }
                        .disabled(currentIndex == 0)
                        Divider().frame(height: 18)
                        stepperButton(systemImage: "plus") {
                            Haptics.light()
                            let next = min(stops.count - 1, currentIndex + 1)
                            onChange(stops[next])
                        }
                        .disabled(currentIndex == stops.count - 1)
                    }
                    .overlay(Capsule().stroke(Color(white: 0.85)))
                    .clipShape(Capsule())
                }
            }
            infoSection("What it means") {
                infoBody("Target retention is the probability you want to remember each card when it next comes up for review. At 90%, you're accepting that roughly 1 in 10 cards will be forgotten by the time they're reviewed — the scheduler aims for exactly that hit rate.")
            }
            infoSection("How it affects scheduling") {
                infoBody("Higher percentages tighten the schedule — cards return sooner so you forget fewer, but you'll study more often. Lower percentages stretch the intervals between reviews so you study less, at the cost of forgetting more cards along the way.")
            }
            infoSection("Range") {
                infoBody("Choose between 80% and 98%. 90% is the default and the value Anki recommends for most learners — a balanced trade-off between study load and retention.")
            }
            infoSection("When to change it") {
                infoBody("Nudge it up if too many cards feel unfamiliar when they reappear. Bring it down if you feel buried in daily reviews and can afford to forget a few more.")
            }
        }
    }

    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Reader for a saved Artifact. Mirrors GenerateContentSheet's
// Story / Line-by-line dual layout so reopening a saved item feels
// like the original result screen, minus the regenerate / save
// controls (which would be meaningless once the keep is committed).
private struct ArtifactReaderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: Artifact
    @State private var isInterleaved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("View", selection: $isInterleaved) {
                        Text("Story").tag(false)
                        Text("Line by line").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    contentBody
                        .padding(.horizontal)

                    if let prompt = artifact.userPrompt, !prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("You asked for")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(.secondary)
                            Text(prompt)
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.black)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(white: 0.96))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle(artifact.resolvedKind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if isInterleaved, !artifact.pairs.isEmpty {
            // Pairs from Claude are pre-aligned 1:1, so showing them
            // straight up is the cleanest line-by-line read.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(artifact.pairs.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pair.foreign)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                            .foregroundStyle(.black)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pair.english)
                            .font(.custom("NeueHaasDisplay-Light", size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            // Story mode (or a legacy artifact without aligned pairs):
            // render the raw prose so paragraph breaks survive.
            Text(artifact.prose)
                .font(.custom("NeueHaasDisplay-Light", size: 16))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Wraps a deck-list row with iOS-style swipe-to-delete. Swiping left
// reveals a red trash action; a short swipe snaps it open (tap the trash
// or tap the row to close), and a long swipe commits the delete outright.
// The gesture only engages on horizontal travel, so the parent's vertical
// ScrollView and tab-swipe keep working. Because it's an inner gesture, a
// swipe that starts on a row takes precedence over the tab-swipe.
private struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    // Settled position (0 = closed, -buttonWidth = open). Live drag is
    // layered on top via `dragTranslation`.
    @State private var settledOffset: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    private let buttonWidth: CGFloat = 76
    private let openSnap: CGFloat = 76
    // Past this much left-travel, releasing commits the delete instead of
    // just snapping open.
    private let commitThreshold: CGFloat = 200

    private var offset: CGFloat {
        // Clamp: never past-closed to the right, cap the rubber-band left.
        min(max(settledOffset + dragTranslation, -commitThreshold - 40), 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Trash action, revealed behind the sliding content.
            Button {
                commitDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .opacity(offset < -2 ? 1 : 0)

            content
                // Opaque page-matched background so the trash stays hidden
                // until the row slides.
                .background(Color(libraryHex: "F4F4F4"))
                .offset(x: offset)
                // When open, a tap anywhere on the row closes it rather
                // than falling through to the row's own tap handlers.
                .overlay {
                    if settledOffset < 0 {
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .highPriorityGesture(swipeGesture)
        }
        .clipped()
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($dragTranslation) { value, state, _ in
                // Only track clearly horizontal movement so vertical
                // scrolling passes through to the ScrollView untouched.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projected = settledOffset + value.translation.width
                if projected <= -commitThreshold {
                    commitDelete()
                } else if projected <= -openSnap / 2 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        settledOffset = -openSnap
                    }
                } else {
                    close()
                }
            }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            settledOffset = 0
        }
    }

    private func commitDelete() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            settledOffset = 0
        }
        onDelete()
    }
}
