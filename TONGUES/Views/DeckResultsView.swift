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
    // Set once the intro cascade has finished. After this, every row is
    // shown unconditionally — including words inserted later via "add
    // related" — so growing, reordering, or an interrupted cascade can
    // never leave rows stranded in the pre-reveal (invisible) state.
    @State private var introComplete: Bool = false
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
                    Text(L("Showing %d %@ for:", items.count, deck.contentType.lowercased()))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    Text(deck.title)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(2)

                    HStack {
                        Text("\(localizedLanguageName(deck.language)) \(L(deck.level))")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(ResultSort.allCases, id: \.self) { order in
                                Button(L(order.rawValue)) { sortOrder = order }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(L(sortOrder.rawValue))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(white: 0.85))
                            )
                        }
                    }
                    // 40pt total gap under the title: the VStack's 18pt
                    // spacing + 22pt here.
                    .padding(.top, 22)

                    Divider()

                    ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
                        // Rows are hidden only while the one-time intro
                        // cascade is still stepping through them. Once it's
                        // done — or for any row added afterward — the row is
                        // always visible, so the list can grow without
                        // stranding its tail behind an unadvanced counter.
                        let landed = introComplete || index < revealedCount
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

                HStack(spacing: 8) {
                    ActionCard(title: L("Regenerate"), systemImage: "arrow.2.circlepath", isPrimary: false) {
                        Haptics.light()
                        onRegenerate()
                    }
                    .disabled(isSaving)
                    ActionCard(
                        title: isSaving ? L("Saving…") : L("Create New Deck"),
                        systemImage: isSaving ? "arrow.up.circle" : "square.stack.3d.up",
                        isPrimary: false
                    ) {
                        Haptics.medium()
                        showCoverCustomization = true
                    }
                    .disabled(isSaving)
                    ActionCard(title: L("Add to Deck"), systemImage: "plus.circle", isPrimary: true) {
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
        .alert(L("Something went wrong"), isPresented: errorBinding) {
            Button(L("OK")) { actionError = nil }
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
        guard !didPlayIntro else {
            // Already ran once (possibly interrupted before finishing).
            // Guarantee nothing is left stuck invisible.
            introComplete = true
            return
        }
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
        // Cascade done: from here on every row (and any added later) is
        // shown unconditionally.
        introComplete = true
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
            // Words from the Generate results screen are sourced from Generate
            // (related-word additions here inherit the same, which is correct —
            // they were generated too). Won't overwrite an already-set source.
            items: items.map { $0.withSource(.generate) },
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
        // The part-of-speech-specific pill — Conjugations for verbs,
        // Plurals for nouns/adjectives/determiners — sits prominently
        // right after Add Phrases and before Add Synonyms.
        // "Add Similar Sounding Words" always sits last in the strip, followed
        // — for Chinese only — by "Add Similar-Looking Words" (形近字), which
        // only makes sense for the shared Han-character writing system.
        var relations: [RelationKind] = fourthRelationKind
            .map { [.phrases, $0, .synonyms, .antonyms, .similarSounding] }
            ?? [.phrases, .synonyms, .antonyms, .similarSounding]
        if isChineseLanguage(item.language ?? deckLanguage) {
            relations.append(.similarLooking)
        }
        return relations
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
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.black)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 9))
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
                            allowForvo: true,
                            pronunciation: item.transliteration
                        )
                    },
                    font: .system(size: 18)
                )
            }

            if isLoading {
                // Preview the rows about to arrive with shimmering skeletons
                // rather than a spinner, so the wait reads as "content is
                // materializing here" and lines up with where the generated
                // related items will insert.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        SkeletonResultRow()
                        if index < 2 { Divider() }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button(action: onRemove) {
                            ActionPill(text: L("Remove"), style: .remove)
                        }
                        .buttonStyle(.plain)

                        if supportsRelations {
                            ForEach(availableRelations) { kind in
                                Button {
                                    onAddRelated(kind)
                                } label: {
                                    ActionPill(text: L(kind.pillLabel), style: .add)
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

// A placeholder standing in for a `ResultRow` while related items load.
// Mirrors the real row's word / transliteration / translation stack and
// speaker button so the incoming content settles into the same footprint.
// Bar widths are varied per index to keep a set of placeholders from
// looking mechanically identical.
private struct SkeletonResultRow: View {
    private let fill = Color(white: 0.91)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 130, height: 16)   // word
                    bar(width: 66, height: 9)     // transliteration
                    bar(width: 168, height: 13)   // translation
                }
                Spacer()
                Circle()
                    .fill(fill)
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.vertical, 12)
        .modifier(SkeletonShimmer())
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .frame(width: width, height: height)
    }
}

// Sweeps a soft highlight left-to-right across its content, looping
// forever — the shimmer that signals a skeleton placeholder is loading.
private struct SkeletonShimmer: ViewModifier {
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
    // When true, colors are flipped for dark backgrounds (e.g. the
    // inverted Camera page): the primary card becomes white-on-black text,
    // the secondary card becomes an outlined white-on-dark chip.
    var inverted: Bool = false
    let action: () -> Void

    private var foreground: Color {
        if inverted { return isPrimary ? .black : .white }
        return isPrimary ? .white : .black
    }
    private var background: Color {
        if inverted { return isPrimary ? .white : .white.opacity(0.08) }
        return isPrimary ? .black : .white
    }
    private var border: Color {
        if inverted { return isPrimary ? .clear : .white.opacity(0.3) }
        return isPrimary ? .clear : Color(white: 0.88)
    }

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
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    sectionHeader(L("Prompt sent to Claude"))
                    Text(deck.promptSent)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    sectionHeader(L("Raw JSON response"))
                    Text(deck.rawJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(L("Generation Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
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

// Overlays the "where the audio came from" chip (ElevenLabs / Forvo / system
// voice) whenever `SpeechClient` emits a status, auto-clearing with it. Any
// screen that plays word audio can opt in with `.speechStatusToast()`.
extension View {
    func speechStatusToast(alignment: Alignment = .bottom) -> some View {
        modifier(SpeechStatusToastModifier(alignment: alignment))
    }
}

private struct SpeechStatusToastModifier: ViewModifier {
    let alignment: Alignment
    @State private var speech = SpeechClient.shared
    @State private var showAudit = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let message = speech.statusMessage {
                    // Tapping the chip opens the audit sheet for the last clip.
                    Button {
                        Haptics.light()
                        showAudit = true
                    } label: {
                        SpeechStatusToast(message: message)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(alignment == .top ? .top : .bottom, 16)
                    .transition(.move(edge: alignment == .top ? .top : .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: speech.statusMessage)
            .sheet(isPresented: $showAudit) {
                if let info = speech.lastSpoken {
                    AudioSourceSheet(info: info)
                        .presentationDetents([.height(info.engine == .elevenLabs ? 400 : 300)])
                        .presentationBackground(.black)
                        .presentationDragIndicator(.visible)
                }
            }
    }
}

// Black audit sheet opened by tapping the audio-source chip. Shows where the
// audio came from and, for an ElevenLabs clip, lets the user regenerate a
// fresh take (overwriting the cached version) when the voice-over is wrong.
struct AudioSourceSheet: View {
    let info: SpeechClient.SpokenAudioInfo
    @Environment(\.dismiss) private var dismiss
    @State private var isRegenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: engineIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(L("Audio source"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 20))
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Text(info.text)
                .font(.custom("NeueHaasDisplay-Light", size: 16))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                detailRow(icon: "waveform", label: L("Source"), value: engineLabel)
                if let lang = info.language, !lang.isEmpty {
                    Divider().overlay(Color.white.opacity(0.1))
                    detailRow(icon: "globe", label: L("Language"), value: localizedLanguageName(lang))
                }
                if let voice = info.voiceID {
                    Divider().overlay(Color.white.opacity(0.1))
                    detailRow(icon: "person.wave.2", label: L("Voice ID"), value: voice)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))

            actionButton(icon: "play.fill", title: L("Play again"), primary: false) {
                SpeechClient.shared.speak(info.text, language: info.language)
            }

            if info.engine == .elevenLabs {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: isRegenerating ? L("Regenerating…") : L("Regenerate voice"),
                    primary: true,
                    disabled: isRegenerating
                ) {
                    isRegenerating = true
                    Task {
                        await SpeechClient.shared.regenerateLastElevenLabs()
                        isRegenerating = false
                    }
                }
                Text(L("Creates a fresh take and replaces the cached audio. Uses one generation."))
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var engineLabel: String {
        switch info.engine {
        case .elevenLabs: return L("ElevenLabs — native voice")
        case .forvo:      return L("Forvo — native recording")
        case .apple:      return L("iOS system voice")
        }
    }

    private var engineIcon: String {
        switch info.engine {
        case .elevenLabs: return "waveform"
        case .forvo:      return "person.wave.2"
        case .apple:      return "iphone"
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 20)
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func actionButton(icon: String, title: String, primary: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.custom("NeueHaasDisplay-Mediu", size: 16))
                Spacer()
            }
            .foregroundStyle(primary ? .black : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(primary ? Color.white : Color.white.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
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
    case darkCherry
    case pleasant
    case mouths1
    case mouths2
    case peopleSpeaking
    case peopleSpeaking2
    case porcelain1
    case porcelain2
    case byzantine1
    case byzantine2
    case stillLife
    case chineseVillage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gradient:        return "Gradient"
        case .audioGradient:   return "Audio"
        case .black:           return "Black"
        case .white:           return "White"
        case .darkCherry:      return "Dark Cherry"
        case .pleasant:        return "Pleasant"
        case .mouths1:         return "Mouths"
        case .mouths2:         return "Mouths 2"
        case .peopleSpeaking:  return "Speakers"
        case .peopleSpeaking2: return "Speakers 2"
        case .porcelain1:      return "Porcelain"
        case .porcelain2:      return "Porcelain 2"
        case .byzantine1:      return "Byzantine"
        case .byzantine2:      return "Byzantine 2"
        case .stillLife:       return "Still Life"
        case .chineseVillage:  return "Chinese Village"
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
        case .chineseVillage:  return "ChineseVillage"
        case .gradient, .audioGradient, .black, .white,
             .darkCherry, .pleasant: return nil
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
        case .darkCherry:
            Color(libraryHex: "180805")
        case .pleasant:
            Color(libraryHex: "C6EFFF")
        case .mouths1, .mouths2, .peopleSpeaking, .peopleSpeaking2,
             .porcelain1, .porcelain2, .byzantine1, .byzantine2, .stillLife,
             .chineseVillage:
            // Solid backing while the video layer loads / mounts. The
            // first frame of the video covers this once ready.
            Color.black
        }
    }

    // Text color that reads against the swatch — used for the inline
    // "TONGUES" wordmark on the featured card.
    var labelColor: Color {
        switch self {
        // White + the light "Pleasant" blue take a dark wordmark; the dark
        // "Dark Cherry" reads with a white one.
        case .white, .pleasant: return .black
        case .gradient, .audioGradient, .black, .mouths1, .mouths2,
             .peopleSpeaking, .peopleSpeaking2, .porcelain1, .porcelain2,
             .byzantine1, .byzantine2, .stillLife, .chineseVillage,
             .darkCherry:
            return .white
        }
    }

    static func random() -> DeckCoverStyle {
        allCases.randomElement() ?? .gradient
    }
}

// Groups the cover styles into four swipeable categories shown in the
// customization sheet. Keeps the picker compact — one category's worth of
// swatches at a time — so the Save button stays above the fold.
enum DeckCoverCategory: String, CaseIterable, Identifiable {
    case colors = "Colors"
    case graphics = "Graphics"
    case art = "Art"
    case medieval = "Medieval"

    var id: String { rawValue }

    var styles: [DeckCoverStyle] {
        switch self {
        case .colors:   return [.gradient, .audioGradient, .black, .white, .darkCherry, .pleasant]
        case .graphics: return [.mouths1, .mouths2, .peopleSpeaking, .peopleSpeaking2]
        case .art:      return [.porcelain1, .porcelain2, .byzantine1, .byzantine2, .stillLife, .chineseVillage]
        // Not uploaded yet — renders a "coming soon" placeholder.
        case .medieval: return []
        }
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

    // Returns a copy with a new title. Used after a rename so the detail
    // view can reflect the change locally without a re-fetch (the fields
    // are all `let`, so we rebuild through the memberwise init).
    func withTitle(_ newTitle: String) -> DeckDocument {
        DeckDocument(
            id: id,
            title: newTitle,
            language: language,
            dialect: dialect,
            level: level,
            contentType: contentType,
            amount: amount,
            tones: tones,
            interests: interests,
            userPrompt: userPrompt,
            items: items,
            languages: languages,
            coverStyle: coverStyle,
            targetRetention: targetRetention,
            isPublic: isPublic,
            planUnitId: planUnitId,
            source: source,
            createdAt: createdAt
        )
    }

    // Returns a copy whose contentType is the canonical value (folds the
    // retired "Phrases" into "Sentences"). Applied on fetch so the whole
    // app — display labels, routing, widgets — treats old phrase decks as
    // sentences without a Firestore migration.
    func canonicalizingContentType() -> DeckDocument {
        let canonical = canonicalContentType(contentType)
        guard canonical != contentType else { return self }
        return DeckDocument(
            id: id,
            title: title,
            language: language,
            dialect: dialect,
            level: level,
            contentType: canonical,
            amount: amount,
            tones: tones,
            interests: interests,
            userPrompt: userPrompt,
            items: items,
            languages: languages,
            coverStyle: coverStyle,
            targetRetention: targetRetention,
            isPublic: isPublic,
            planUnitId: planUnitId,
            source: source,
            createdAt: createdAt
        )
    }

    // Returns a copy with a new items array. Used for optimistic local
    // updates (e.g. swipe-to-delete) so the list reflects the change
    // before Firestore confirms.
    func withItems(_ newItems: [GeneratedItem]) -> DeckDocument {
        DeckDocument(
            id: id,
            title: title,
            language: language,
            dialect: dialect,
            level: level,
            contentType: contentType,
            amount: amount,
            tones: tones,
            interests: interests,
            userPrompt: userPrompt,
            items: newItems,
            languages: languages,
            coverStyle: coverStyle,
            targetRetention: targetRetention,
            isPublic: isPublic,
            planUnitId: planUnitId,
            source: source,
            createdAt: createdAt
        )
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
    @State private var selectedCategory: DeckCoverCategory = .colors

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
            Text(L("PUBLIC"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 17.6))
                .foregroundStyle(.black.opacity(0.85))
            HStack(spacing: 16) {
                Button {
                    Haptics.light()
                    isPublic = true
                } label: {
                    Text(L("YES"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(isPublic ? .black : .black.opacity(0.35))
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    isPublic = false
                } label: {
                    Text(L("NO"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(isPublic ? .black.opacity(0.35) : .black)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Horizontal strip of category names above the swatch pager. Tapping
    // one animates the pager to that category; swiping the pager updates
    // the highlight in turn (both bind to `selectedCategory`).
    private var categoryTabs: some View {
        HStack(spacing: 18) {
            ForEach(DeckCoverCategory.allCases) { category in
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedCategory = category
                    }
                } label: {
                    Text(L(category.rawValue))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                        .foregroundStyle(selectedCategory == category ? .black : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // One page of the cover pager: a 3-column grid of that category's
    // swatches, or a "coming soon" placeholder for empty categories
    // (Medieval, whose art hasn't been uploaded yet).
    @ViewBuilder
    private func categoryPage(_ category: DeckCoverCategory) -> some View {
        if category.styles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                Text(L("Coming soon"))
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Top-aligned so 1- and 2-row categories both hug the top of
            // the fixed-height page instead of centering. The 24pt margin
            // lives here (not on the pager) so it shows at rest but the
            // swipe itself runs edge-to-edge.
            VStack {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(category.styles) { style in
                        DeckCoverSwatch(
                            style: style,
                            isSelected: selectedStyle == style
                        ) {
                            Haptics.light()
                            selectedStyle = style
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("TITLE"))
                            .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        TextField(L("Deck title"), text: $title, axis: .vertical)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 24))
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                        Divider()
                        Text("\(localizedLanguageName(language)) · \(L(level))")
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("COVER"))
                            .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)

                        categoryTabs

                        // Horizontally swipeable pager — one category of
                        // swatches per page. Fixed height keeps the sheet
                        // compact so Save stays above the fold.
                        //
                        // The pager runs full-bleed to the screen edges
                        // (negating the parent's 24pt margin) so the swipe
                        // travels edge-to-edge. Each page re-adds that 24pt
                        // margin internally, so at rest the swatches stay
                        // inset — and between two adjacent pages the two
                        // inner margins combine into a 48pt gap so card sets
                        // don't touch mid-swipe.
                        TabView(selection: $selectedCategory) {
                            ForEach(DeckCoverCategory.allCases) { category in
                                categoryPage(category)
                                    .tag(category)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 200)
                        .padding(.horizontal, -24)
                    }

                    visibilityRow

                    Button {
                        Haptics.medium()
                        let chosen = selectedStyle ?? .random()
                        let finalTitle = trimmedTitle.isEmpty ? initialTitle : trimmedTitle
                        onSave(finalTitle, chosen, isPublic)
                    } label: {
                        Text(L("Save deck"))
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
            .navigationTitle(L("New Deck"))
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
                Text(L(style.displayName))
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(isSelected ? .black : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

