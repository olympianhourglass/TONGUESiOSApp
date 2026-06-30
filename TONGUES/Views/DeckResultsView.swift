import SwiftUI
import AVFoundation

struct DeckResultsView: View {
    let deck: GeneratedDeck
    let onComplete: () -> Void
    // Fired by the Regenerate action card. Parent owns the actual
    // generation pipeline (it has the VM + nav stack), so this view
    // just signals intent.
    var onRegenerate: () -> Void = {}
    @State private var items: [GeneratedItem]
    @State private var loadingIds: Set<UUID> = []
    @State private var sortOrder: ResultSort = .original
    @State private var showInfo = false
    @State private var isSaving = false
    @State private var showAddToDeck = false
    @State private var showCoverCustomization = false
    @State private var actionError: String?
    @State private var speech = SpeechClient.shared
    // How many of the rows have animated into place from the bottom.
    // Drives the staggered spring-up intro that runs once on first
    // appearance. Sort changes don't replay it.
    @State private var revealedCount: Int = 0
    @State private var didPlayIntro: Bool = false
    // Holds the success chime through the cascade so we can stop it on
    // teardown if the user pops back before it finishes.
    @State private var introChime: AVAudioPlayer?

    init(
        deck: GeneratedDeck,
        onComplete: @escaping () -> Void,
        onRegenerate: @escaping () -> Void = {}
    ) {
        self.deck = deck
        self.onComplete = onComplete
        self.onRegenerate = onRegenerate
        self._items = State(initialValue: deck.items)
    }

    enum ResultSort: String, CaseIterable {
        case alphabetized = "Alphabetized"
        case original = "Original"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Showing \(items.count) \(deck.contentType.lowercased()) for:")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    Text(deck.title)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(2)

                    HStack {
                        Text("\(deck.language) \(deck.level)")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(ResultSort.allCases, id: \.self) { order in
                                Button(order.rawValue) { sortOrder = order }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(sortOrder.rawValue)
                                    .foregroundStyle(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(white: 0.85))
                            )
                        }
                    }

                    Divider()

                    ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
                        let landed = index < revealedCount
                        VStack(spacing: 0) {
                            ResultRow(
                                item: item,
                                deckLanguage: deck.language,
                                contentType: deck.contentType,
                                isLoading: loadingIds.contains(item.id),
                                onRemove: {
                                    Haptics.light()
                                    remove(item)
                                },
                                onAddRelated: { kind in
                                    Haptics.light()
                                    Task { await addRelated(kind, to: item) }
                                }
                            )
                            Divider()
                        }
                        // Pre-intro: parked ~50pt below with zero
                        // opacity. The spring inside `playIntroIfNeeded`
                        // pulls the row up to its final position with
                        // a soft bounce.
                        .offset(y: landed ? 0 : 50)
                        .opacity(landed ? 1 : 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }

            VStack(spacing: 16) {
                if let message = speech.statusMessage {
                    SpeechStatusToast(message: message)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 12) {
                    ActionCard(title: "Regenerate", systemImage: "arrow.2.circlepath", isPrimary: false) {
                        Haptics.light()
                        onRegenerate()
                    }
                    .disabled(isSaving)
                    ActionCard(
                        title: isSaving ? "Saving…" : "Create New Deck",
                        systemImage: isSaving ? "arrow.up.circle" : "square.stack.3d.up",
                        isPrimary: false
                    ) {
                        Haptics.medium()
                        showCoverCustomization = true
                    }
                    .disabled(isSaving)
                    ActionCard(title: "Add to Deck", systemImage: "plus.circle", isPrimary: true) {
                        Haptics.medium()
                        showAddToDeck = true
                    }
                    .disabled(isSaving)
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
            .padding(.top, 8)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: speech.statusMessage)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.black)
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            PromptInfoSheet(deck: deck)
        }
        .sheet(isPresented: $showAddToDeck) {
            DeckPickerSheet(
                itemsToAdd: items,
                sourceLanguage: deck.language,
                sourceDialect: deck.dialect,
                onAdded: onComplete
            )
        }
        .sheet(isPresented: $showCoverCustomization) {
            DeckCoverCustomizationSheet(
                initialTitle: deck.title,
                language: deck.language,
                level: deck.level
            ) { newTitle, chosenStyle, isPublic in
                showCoverCustomization = false
                Task {
                    await saveAsNewDeck(title: newTitle, style: chosenStyle, isPublic: isPublic)
                }
            }
            .presentationDetents([.fraction(0.8), .large])
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task { await playIntroIfNeeded() }
    }

    // Walks `revealedCount` from 0 → items.count, letting each row
    // spring up with a small delay so the list cascades top-down.
    // Latches `didPlayIntro` so re-entering the view (e.g. after a
    // sheet dismiss) doesn't replay it.
    //
    // Synced to the cascade:
    //   • `tonguessuccess.mp3` plays as the first row lands.
    //   • A warm crescendo haptic pulses underneath — soft taps as the
    //     first rows arrive, building to a medium impact mid-cascade,
    //     then a notification-style success pulse on the last row.
    @MainActor
    private func playIntroIfNeeded() async {
        guard !didPlayIntro else { return }
        didPlayIntro = true
        // Prime the chime before the cascade so `play()` starts
        // instantly rather than spending its first ~20ms on disk +
        // codec init while the first row is already landing.
        prepareIntroChime()
        // Wait for the navigation push to fully slide the page in before
        // starting the cascade. Without this, rows are already springing
        // up while the whole screen is still translating from the right
        // and the two motions read as a single muddy animation.
        try? await Task.sleep(for: .milliseconds(400))

        // First row lands now — fire the chime + opening haptic on the
        // same frame so audio, haptic, and visual all hit together.
        introChime?.play()
        Haptics.light()

        let count = items.count
        // Two breakpoints scaled to the deck length so the crescendo
        // reads the same whether there are 5 items or 30. Roughly: the
        // softer ramp covers the front third; the medium impact lands
        // around the middle; the success pulse fires on the final row.
        let mediumIndex = max(1, count / 2)
        for index in 0..<count {
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) {
                revealedCount = index + 1
            }
            if index == mediumIndex {
                Haptics.medium()
            } else if index == count - 1 {
                Haptics.success()
            } else if index < mediumIndex, index % 2 == 0 {
                // Soft taps every other row through the front third
                // so the build feels continuous, not punctuated.
                Haptics.light()
            }
        }
    }

    // Lazily loads the success chime, re-asserts the playback audio
    // session (the chat tab's mic flow may have repurposed it), and
    // calls `prepareToPlay` so the actual `play()` on intro start is
    // jitter-free. Errors fall through silently — the cascade still
    // runs without audio if anything goes wrong.
    @MainActor
    private func prepareIntroChime() {
        guard introChime == nil,
              let url = Bundle.main.url(forResource: "tonguessuccess", withExtension: "mp3") else {
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            introChime = player
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private var currentDeck: GeneratedDeck {
        GeneratedDeck(
            id: deck.id,
            title: deck.title,
            items: items,
            language: deck.language,
            dialect: deck.dialect,
            level: deck.level,
            contentType: deck.contentType,
            amount: deck.amount,
            tones: deck.tones,
            interests: deck.interests,
            userPrompt: deck.userPrompt,
            promptSent: deck.promptSent,
            rawJSON: deck.rawJSON
        )
    }

    @MainActor
    private func saveAsNewDeck(title: String, style: DeckCoverStyle, isPublic: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await FirebaseDeckService.saveDeck(
                currentDeck,
                title: title,
                coverStyle: style.rawValue,
                isPublic: isPublic
            )
            Haptics.success()
            onComplete()
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
        }
    }

    private func remove(_ item: GeneratedItem) {
        items.removeAll { $0.id == item.id }
    }

    @MainActor
    private func addRelated(_ kind: RelationKind, to item: GeneratedItem) async {
        loadingIds.insert(item.id)
        defer { loadingIds.remove(item.id) }
        do {
            let newItems = try await DeckGenerator.generateRelated(
                relation: kind,
                source: item,
                language: deck.language,
                dialect: deck.dialect,
                level: deck.level
            )
            // Tag each inserted item with the relation kind so downstream
            // controls (e.g. the relation pills) can suppress themselves on
            // items that aren't word-shaped (phrases, sentences).
            let tagged = newItems.map { $0.withKind(kind.rawValue) }
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items.insert(contentsOf: tagged, at: idx + 1)
            } else {
                items.append(contentsOf: tagged)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var sortedItems: [GeneratedItem] {
        switch sortOrder {
        case .alphabetized:
            return items.sorted {
                $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
            }
        case .original:
            return items
        }
    }
}

struct ResultRow: View {
    let item: GeneratedItem
    let deckLanguage: String
    // "Words", "Phrases", "Sentences" — relation pills (synonyms etc.)
    // only make sense at the word level.
    let contentType: String
    let isLoading: Bool
    let onRemove: () -> Void
    let onAddRelated: (RelationKind) -> Void

    // Show relation pills only when this row is word-shaped:
    // 1. The deck itself must be "Words" (Phrases/Sentences decks never get
    //    relation pills).
    // 2. If the item was added via Add Phrases (kind == "phrases"), suppress
    //    pills — even if the deck is a Words deck. Tag-based check works for
    //    CJK languages that don't use whitespace between words.
    // 3. Prefer the explicit `partsOfSpeech` classification when present —
    //    a French/Spanish/Italian/German noun like "le chien" / "la casa"
    //    legitimately contains whitespace because of its article prefix,
    //    so the whitespace heuristic alone would wrongly suppress its
    //    relation pills.
    // 4. As a backstop for items without a POS tag (legacy data), treat
    //    multi-token surface forms as phrases.
    private var supportsRelations: Bool {
        guard contentType.lowercased() == "words" else { return false }
        if item.kind == RelationKind.phrases.rawValue { return false }

        if let pos = item.partsOfSpeech, !pos.isEmpty {
            // Authoritative classification — only hide relations when Claude
            // actually labelled the item as phrase-like.
            let lowered = pos.map { $0.lowercased() }
            let phraseLike: Set<String> = ["phrase", "sentence", "idiom"]
            return !lowered.contains(where: { phraseLike.contains($0) })
        }

        // Backstop for items predating the partsOfSpeech field.
        let trimmed = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(where: { $0.isWhitespace }) { return false }
        return true
    }

    // Which relation pills make sense for this part of speech. Synonyms,
    // antonyms, and phrases apply to almost every word class. The fourth
    // pill switches between Plurals (number inflections — for nouns,
    // adjectives, determiners) and Cases (conjugations / declensions — for
    // verbs, adverbs, pronouns). Closed-class words with no useful
    // inflections (prepositions, conjunctions, interjections) skip the
    // fourth pill entirely.
    private var availableRelations: [RelationKind] {
        var pills: [RelationKind] = [.synonyms, .antonyms, .phrases]
        if let fourth = fourthRelationKind {
            pills.append(fourth)
        }
        return pills
    }

    private var fourthRelationKind: RelationKind? {
        let pos = (item.partsOfSpeech ?? []).map { $0.lowercased() }
        if pos.isEmpty { return .plurals }  // Backstop for legacy items pre-POS field

        // Verbs get Add Conjugations — the umbrella grammatical term for all
        // tense/person/mood/voice variants of a verb. Other word classes get
        // either Plurals or nothing (closed-class words don't inflect).
        if pos.contains("verb") {
            return .conjugations
        }
        let inflecting: Set<String> = ["noun", "adjective", "determiner"]
        if pos.contains(where: { inflecting.contains($0) }) {
            return .plurals
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.word)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 13))
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    Text(item.translation)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SpeakWaveformButton(
                    action: {
                        SpeechClient.shared.speak(
                            item.word,
                            language: item.language ?? deckLanguage,
                            allowForvo: true
                        )
                    },
                    font: .system(size: 18)
                )
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Adding…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button(action: onRemove) {
                            ActionPill(text: "Remove", style: .remove)
                        }
                        .buttonStyle(.plain)

                        if supportsRelations {
                            ForEach(availableRelations) { kind in
                                Button {
                                    onAddRelated(kind)
                                } label: {
                                    ActionPill(text: kind.pillLabel, style: .add)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(.vertical, 12)
    }
}

struct ActionPill: View {
    enum Style { case remove, add }
    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch style {
        case .remove: return Color(red: 1.0, green: 0.92, blue: 0.92)
        case .add:    return Color(red: 0.88, green: 0.97, blue: 0.88)
        }
    }

    private var foreground: Color {
        switch style {
        case .remove: return Color(red: 0.6, green: 0.2, blue: 0.2)
        case .add:    return Color(red: 0.18, green: 0.45, blue: 0.22)
        }
    }
}

struct ActionCard: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isPrimary ? .white : .black)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(isPrimary ? Color.black : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isPrimary ? Color.clear : Color(white: 0.88), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct PromptInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deck: GeneratedDeck

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader("Prompt sent to Claude")
                    Text(deck.promptSent)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    sectionHeader("Raw JSON response")
                    Text(deck.rawJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Generation Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }
}

struct SpeechStatusToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.88), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
    }
}

// MARK: - Deck cover style

// Visual styles available for a deck's cover swatch. Kept to the palette
// already shown on the Study screen (featured gradient + black + white) so
// the customization step doesn't introduce colors not seen elsewhere.
enum DeckCoverStyle: String, CaseIterable, Identifiable, Codable {
    case gradient
    case audioGradient
    case black
    case white
    case mouths1
    case mouths2
    case peopleSpeaking
    case peopleSpeaking2
    case porcelain1
    case porcelain2
    case byzantine1
    case byzantine2
    case stillLife

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gradient:        return "Gradient"
        case .audioGradient:   return "Audio"
        case .black:           return "Black"
        case .white:           return "White"
        case .mouths1:         return "Mouths"
        case .mouths2:         return "Mouths 2"
        case .peopleSpeaking:  return "Speakers"
        case .peopleSpeaking2: return "Speakers 2"
        case .porcelain1:      return "Porcelain"
        case .porcelain2:      return "Porcelain 2"
        case .byzantine1:      return "Byzantine"
        case .byzantine2:      return "Byzantine 2"
        case .stillLife:       return "Still Life"
        }
    }

    // Bundled mp4 resource name for video-style cardbacks. `nil` for the
    // static color/gradient styles.
    var videoResourceName: String? {
        switch self {
        case .mouths1:         return "Mouths1"
        case .mouths2:         return "Mouths2"
        case .peopleSpeaking:  return "PeopleSpeaking"
        case .peopleSpeaking2: return "PeopleSpeaking2"
        case .porcelain1:      return "Porcelain1"
        case .porcelain2:      return "Porcelain2"
        case .byzantine1:      return "Byzantine1"
        case .byzantine2:      return "Byzantine2"
        case .stillLife:       return "StillLife"
        case .gradient, .audioGradient, .black, .white: return nil
        }
    }

    var isVideo: Bool { videoResourceName != nil }

    @ViewBuilder
    func fill() -> some View {
        switch self {
        case .gradient:
            LinearGradient(
                colors: [
                    Color(red: 0.78, green: 0.22, blue: 0.20),
                    Color(red: 0.95, green: 0.78, blue: 0.78),
                    Color(red: 0.93, green: 0.88, blue: 0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .audioGradient:
            // Same near-black → steel-blue → warm off-white radial spread
            // used as the background of `ListenSessionView`. Anchored to the
            // top with an oversized end radius so only the central slice of
            // the gradient is visible — the static (non-breathing) version
            // of the live audio backdrop.
            GeometryReader { geo in
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 10/255, green: 10/255, blue: 10/255), location: 0.0),
                        .init(color: Color(red: 83/255, green: 104/255, blue: 120/255), location: 0.167),
                        .init(color: Color(red: 229/255, green: 228/255, blue: 226/255), location: 0.5)
                    ]),
                    center: .top,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 2
                )
            }
        case .black:
            Color.black
        case .white:
            Color.white
        case .mouths1, .mouths2, .peopleSpeaking, .peopleSpeaking2,
             .porcelain1, .porcelain2, .byzantine1, .byzantine2, .stillLife:
            // Solid backing while the video layer loads / mounts. The
            // first frame of the video covers this once ready.
            Color.black
        }
    }

    // Text color that reads against the swatch — used for the inline
    // "TONGUES" wordmark on the featured card.
    var labelColor: Color {
        switch self {
        case .white: return .black
        case .gradient, .audioGradient, .black, .mouths1, .mouths2,
             .peopleSpeaking, .peopleSpeaking2, .porcelain1, .porcelain2,
             .byzantine1, .byzantine2, .stillLife:
            return .white
        }
    }

    static func random() -> DeckCoverStyle {
        allCases.randomElement() ?? .gradient
    }
}

// Renders the deck cardback. For static styles it's just the fill; for
// video styles it shows a cached first-frame thumbnail as a poster while
// idle, and mounts a real `AVPlayer` only while `isPlaying` is true.
//
// Why the swap: a previous version mounted one `AVPlayer` per visible
// mini-card, which exhausted memory on the Study page (4+ video decks
// visible at once) and triggered iOS jetsam SIGKILLs. The thumbnail is
// extracted exactly once per resource via `CardbackThumbnailCache`.
struct DeckCoverFill: View {
    let style: DeckCoverStyle
    var isPlaying: Bool = false
    @State private var poster: UIImage?

    var body: some View {
        // Anchor sizing to `style.fill()` so the cardback always matches the
        // outer aspect ratio. Putting the poster/video in an overlay (instead
        // of as siblings in a ZStack) prevents the poster's natural aspect
        // from inflating the container — without this, video cardbacks
        // appeared too tall on mount and snapped down once the player took
        // over from the poster.
        style.fill()
            .overlay {
                if let resource = style.videoResourceName {
                    // Poster stays in the stack the whole time so it can
                    // "show through" the transparent AVPlayerLayer during
                    // the brief window between mount and first decoded
                    // frame — eliminating the black flash on play. The
                    // poster IS the video's first frame (extracted via
                    // CardbackThumbnailCache), so the handoff is seamless.
                    ZStack {
                        if let poster {
                            Image(uiImage: poster)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                        if isPlaying {
                            CardbackVideoView(resourceName: resource, isPlaying: true)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .clipped()
        .task(id: style.videoResourceName) {
            guard let resource = style.videoResourceName else { return }
            if poster == nil {
                poster = CardbackThumbnailCache.image(for: resource)
            }
            if poster == nil {
                await CardbackThumbnailCache.prepare(for: resource)
                poster = CardbackThumbnailCache.image(for: resource)
            }
        }
    }
}

extension DeckDocument {
    // Resolves the cover style for this deck. Honors the stored value when
    // present; for legacy decks saved before this field existed, picks a
    // deterministic style from `id`/`title` so it stays stable across loads
    // without requiring a Firestore migration.
    var resolvedCoverStyle: DeckCoverStyle {
        if let raw = coverStyle, let style = DeckCoverStyle(rawValue: raw) {
            return style
        }
        // Pool is intentionally fixed to the original three styles. Legacy
        // decks (saved before `coverStyle` existed) were assigned a style by
        // hashing into this list, so the list must not change when new
        // cases are added to the enum — otherwise the same deck would
        // render a different style after each update.
        let pool: [DeckCoverStyle] = [.gradient, .black, .white]
        let key = id ?? title
        let hash = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return pool[hash % pool.count]
    }
}

struct DeckCoverCustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialTitle: String
    let language: String
    let level: String
    let onSave: (_ title: String, _ style: DeckCoverStyle, _ isPublic: Bool) -> Void

    @State private var title: String
    @State private var selectedStyle: DeckCoverStyle?
    @State private var isPublic: Bool = false

    init(
        initialTitle: String,
        language: String,
        level: String,
        onSave: @escaping (String, DeckCoverStyle, Bool) -> Void
    ) {
        self.initialTitle = initialTitle
        self.language = language
        self.level = level
        self.onSave = onSave
        self._title = State(initialValue: initialTitle)
        self._selectedStyle = State(initialValue: nil)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Text-based YES/NO selector matching the audio session's options menu —
    // the selected side is full-opacity black, the other dims to 35% so the
    // pair reads as a single toggle without a control chrome.
    private var visibilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PUBLIC")
                .font(.custom("NeueHaasDisplay-Mediu", size: 17.6))
                .foregroundStyle(.black.opacity(0.85))
            HStack(spacing: 16) {
                Button {
                    Haptics.light()
                    isPublic = true
                } label: {
                    Text("YES")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(isPublic ? .black : .black.opacity(0.35))
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    isPublic = false
                } label: {
                    Text("NO")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(isPublic ? .black.opacity(0.35) : .black)
                }
                .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TITLE")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        TextField("Deck title", text: $title, axis: .vertical)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 24))
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                        Divider()
                        Text("\(language) · \(level)")
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("COVER")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ],
                            spacing: 12
                        ) {
                            ForEach(DeckCoverStyle.allCases) { style in
                                DeckCoverSwatch(
                                    style: style,
                                    isSelected: selectedStyle == style
                                ) {
                                    Haptics.light()
                                    selectedStyle = style
                                }
                            }
                        }
                    }

                    visibilityRow

                    Button {
                        Haptics.medium()
                        let chosen = selectedStyle ?? .random()
                        let finalTitle = trimmedTitle.isEmpty ? initialTitle : trimmedTitle
                        onSave(finalTitle, chosen, isPublic)
                    } label: {
                        Text("Save deck")
                            .font(.custom("PlayfairDisplay-Regular", size: 20))
                            .tracking(-1.2)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.black)
                    }
                }
            }
        }
    }
}

private struct DeckCoverSwatch: View {
    let style: DeckCoverStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                DeckCoverFill(style: style)
                    .aspectRatio(90.0 / 53.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.black, lineWidth: isSelected ? 2 : 0)
                            .padding(-2)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                Text(style.displayName)
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(isSelected ? .black : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

