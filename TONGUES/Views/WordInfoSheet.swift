import SwiftUI

struct WordInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: GeneratedItem
    let deckLanguage: String
    let deckDialect: String
    // Parent deck's content kind ("Words", "Phrases", "Sentences"). Used
    // to swap the modal into its sentence variant — etymology link
    // suppressed, generate strip collapsed to "Sentence Studio".
    var contentType: String = "Words"
    // Firestore deck id needed to persist Sentence Studio saves. Nil for
    // call sites that don't support editing (no save button is exposed
    // in that case).
    var deckId: String? = nil
    // Bubbled up to DeckDetailView after Sentence Studio successfully
    // rewrites this item's text + translation. The parent updates its
    // local deck state so the items list reflects the new sentence
    // without a round trip back to Firestore.
    var onItemUpdated: ((GeneratedItem) -> Void)? = nil
    // Fired by the Add Phrase / Add Plurals / Add Synonyms / etc. chips
    // beneath the Generate label. The parent runs the Claude call,
    // inserts the returned items right under this word in the deck,
    // and persists. We dismiss as soon as the callback fires so the
    // user sees the new rows appear in place.
    var onAddRelated: ((RelationKind) -> Void)? = nil

    @State private var wordInfo: WordInfo?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            rootContent
                .toolbar(.hidden, for: .navigationBar)
        }
        .presentationBackground(.black)
        .task {
            await loadOrFetch()
        }
    }

    private var rootContent: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(item.word)
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.white)
                        .padding(.top, 40)

                    Divider()
                        .background(Color.white.opacity(0.25))

                    Text("WORD INFORMATION")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.55))

                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Loading word info…")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let info = wordInfo {
                        infoContent(info)
                    } else if let err = errorText {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }

                    Divider()
                        .background(Color.white.opacity(0.25))
                        .padding(.top, 8)

                    Text("Generate:")
                        .font(.custom("NeueHaasDisplay-Light", size: 17))
                        .foregroundStyle(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            if isPhraseOrSentence {
                                // Kept as a fallback for any call site
                                // that still presents the sheet for a
                                // phrase/sentence item. Direct
                                // sentence-studio routing now lives in
                                // DeckDetailView.
                                NavigationLink {
                                    SentenceStudioView(
                                        item: item,
                                        deckLanguage: deckLanguage,
                                        deckDialect: deckDialect,
                                        deckId: deckId,
                                        onSaved: { updated in
                                            onItemUpdated?(updated)
                                            dismiss()
                                        }
                                    )
                                } label: {
                                    generatePill("Sentence Studio")
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(TapGesture().onEnded { Haptics.light() })
                            } else {
                                relationChip("Add Phrase", kind: .phrases)
                                ForEach(inflectionPills, id: \.self) { label in
                                    if let kind = relationKind(for: label) {
                                        relationChip(label, kind: kind)
                                    }
                                }
                                relationChip("Add Synonyms", kind: .synonyms)
                                relationChip("Add Antonyms", kind: .antonyms)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 40)
            }

            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func infoContent(_ info: WordInfo) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            // Meaning + speak button (8pt right margin, vertically
            // centered against the whole Meaning block).
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Meaning:")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(info.meaning)
                        .font(.custom("NeueHaasDisplay-Light", size: 26))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                SpeakWaveformButton(
                    action: {
                        SpeechClient.shared.speak(
                            item.word,
                            language: item.language ?? deckLanguage,
                            allowForvo: true
                        )
                    },
                    font: .system(size: 22),
                    foregroundColor: .white
                )
                .padding(.trailing, 8)
            }

            // Parts of speech
            VStack(alignment: .leading, spacing: 10) {
                Text("Parts of Speech:")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 8) {
                    ForEach(info.partsOfSpeech, id: \.self) { pos in
                        Text(pos)
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            // Pronunciation
            labelValueRow(
                "Pronunciation:",
                value: info.pronunciation,
                valueFont: .custom("NeueHaasDisplay-Light", size: 14)
            )

            // Language
            labelValueRow("Language:", value: info.language)

            // Word Frequency
            labelValueRow("Word Frequency:", value: info.wordFrequency)

            // Pronunciation Difficulty
            labelValueRow(
                "Pronunciation Difficulty Level:",
                value: info.pronunciationDifficulty,
                valueFont: .custom("NeueHaasDisplay-Light", size: 14)
            )

            // View Etymology — only meaningful for single-token entries.
            // Phrases and sentences don't have a single etymological story,
            // so the link is hidden in those cases. `lexicalWord` strips a
            // leading definite article so gendered entries like "el perro"
            // or "der Hund" still surface the etymology of the noun itself.
            // `isPhraseOrSentence` also gates it explicitly, which catches
            // phrase / sentence items in CJK scripts where whitespace
            // isn't a reliable signal.
            if isSingleWord && !isPhraseOrSentence {
                HStack {
                    Spacer()
                    NavigationLink {
                        EtymologyDetailView(
                            word: lexicalWord,
                            sourceLanguage: item.language ?? deckLanguage
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Text("View Etymology")
                            Image(systemName: "arrow.right")
                        }
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { Haptics.light() })
                }
                .padding(.top, 8)
            }
        }
    }

    private func labelValueRow(
        _ label: String,
        value: String,
        valueFont: Font = .custom("NeueHaasDisplay-Light", size: 14)
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(valueFont)
                .foregroundStyle(.white)
        }
    }

    // Mirrors DeckResultsView.fourthRelationKind so the per-word sheet shows
    // the same Conjugations/Plurals/(none) treatment as the inline pills.
    private var inflectionPills: [String] {
        let pos = (wordInfo?.partsOfSpeech ?? item.partsOfSpeech ?? [])
            .map { $0.lowercased() }
        if pos.isEmpty { return ["Add Plurals"] }
        if pos.contains("verb") {
            return ["Add Conjugations"]
        }
        let inflecting: Set<String> = ["noun", "adjective", "determiner"]
        if pos.contains(where: { inflecting.contains($0) }) {
            return ["Add Plurals"]
        }
        return []
    }

    private func generatePill(_ title: String) -> some View {
        Text(title)
            .font(.custom("NeueHaasDisplay-Light", size: 15))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // Active chip — taps fire the parent's onAddRelated callback with
    // the matching RelationKind, then dismiss this sheet so the
    // newly-generated items can land underneath the source word on
    // the deck detail screen.
    private func relationChip(_ title: String, kind: RelationKind) -> some View {
        Button {
            Haptics.light()
            onAddRelated?(kind)
            dismiss()
        } label: {
            generatePill(title)
        }
        .buttonStyle(.plain)
    }

    // Maps inflection-pill labels back to their RelationKind. The
    // labels themselves come from `inflectionPills`, which currently
    // produces either "Add Plurals" or "Add Conjugations".
    private func relationKind(for label: String) -> RelationKind? {
        switch label {
        case "Add Plurals":      return .plurals
        case "Add Conjugations": return .conjugations
        default:                  return nil
        }
    }

    // Etymology is only meaningful for single-token entries. We treat any
    // item with internal whitespace as a phrase / sentence and hide the link.
    // Non-spacing scripts (CJK) are intentionally still surfaced; their
    // decomposition runs along character / radical lines rather than spaces.
    // `lexicalWord` first strips a leading definite article (the deck
    // generator prepends them on gendered nouns — "el perro", "der Hund",
    // "la maison", etc. — to surface grammatical gender) so single-noun
    // entries presented as "article + noun" still qualify.
    private var isSingleWord: Bool {
        lexicalWord.split(whereSeparator: { $0.isWhitespace }).count <= 1
    }

    // True for any phrase-, sentence-, or idiom-shaped item. The
    // per-item POS tag is authoritative — a Words deck can legitimately
    // contain a phrase or sentence (and vice versa), so we dispatch off
    // the tag attached to *this* item rather than the deck's
    // contentType. The contentType fallback only kicks in for legacy
    // items that predate the per-item POS field.
    private var isPhraseOrSentence: Bool {
        let pos = (wordInfo?.partsOfSpeech ?? item.partsOfSpeech ?? [])
            .map { $0.lowercased() }
        if !pos.isEmpty {
            let phraseLike: Set<String> = ["phrase", "sentence", "idiom"]
            return pos.contains(where: { phraseLike.contains($0) })
        }
        let lower = contentType.lowercased()
        return lower == "sentences" || lower == "phrases"
    }

    // The bare noun form of the entry — definite article (if recognized)
    // removed. Used both for the single-word gate above and as the word
    // we hand to the etymology generator, since "perro" has an
    // etymological story that "el perro" doesn't.
    private var lexicalWord: String {
        let trimmed = item.word.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              Self.leadingArticles.contains(parts[0].lowercased()) else {
            return trimmed
        }
        return parts[1]
    }

    // Definite articles the deck generator prepends to nouns (see
    // `buildDeckPrompt` in DeckGenerator). Kept lowercase for case-
    // insensitive matching against the first token of `item.word`.
    private static let leadingArticles: Set<String> = [
        "el", "la", "los", "las",          // Spanish
        "le", "les", "l'",                 // French (la covered above)
        "il", "lo", "i", "gli",            // Italian (la/le covered above)
        "o", "a", "os", "as",              // Portuguese
        "der", "die", "das",               // German nominative
        "den", "dem", "des",               // German other cases
        "de", "het", "een",                // Dutch
        "ο", "η", "το", "οι", "τα"         // Greek
    ]

    @MainActor
    private func loadOrFetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let cached = try await FirebaseDeckService.fetchWordInfo(
                word: item.word,
                language: deckLanguage
            ) {
                wordInfo = cached
                return
            }

            let generated = try await DeckGenerator.generateWordInfo(
                word: item.word,
                translation: item.translation,
                language: deckLanguage,
                dialect: deckDialect
            )
            wordInfo = generated
            try? await FirebaseDeckService.saveWordInfo(
                generated,
                word: item.word,
                language: deckLanguage
            )
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// In-modal etymology detail. Pushed onto the WordInfoSheet's NavigationStack
// so the back gesture and chevron pop us back to the word card rather than
// dismissing the whole sheet. Visual language matches the parent sheet —
// black background, white type at the same weights/sizes.
private struct EtymologyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let word: String
    let sourceLanguage: String

    @State private var etymology: Etymology?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(word)
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.white)
                        .padding(.top, 40)

                    if let etymology {
                        headerRow(etymology)
                    }

                    Divider()
                        .background(Color.white.opacity(0.25))

                    Text("ETYMOLOGY")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.55))

                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Tracing the roots…")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let etymology {
                        etymologyContent(etymology)
                    } else if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 40)
            }

            Button {
                Haptics.light()
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                    Text("Back")
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .padding(.top, 16)
            .padding(.leading, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadIfNeeded()
        }
    }

    private func headerRow(_ etymology: Etymology) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(etymology.pronunciation)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(etymology.partOfSpeech)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func etymologyContent(_ etymology: Etymology) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            // Hero — origin language + root form + the "aha" highlight.
            VStack(alignment: .leading, spacing: 14) {
                labelValueRow(
                    "Origin Language:",
                    value: etymology.summary.originLanguage
                )
                labelValueRow(
                    "Root Form:",
                    value: etymology.summary.rootForm,
                    valueFont: .custom("NeueHaasDisplay-Light", size: 26)
                )
                labelValueRow(
                    "Original Meaning:",
                    value: etymology.summary.originalMeaning
                )
                Text(etymology.summary.highlight)
                    .font(.custom("NeueHaasDisplay-Light", size: 17))
                    .foregroundStyle(.white)
                    .padding(.top, 6)
            }

            // Morphemes when the word decomposes; otherwise show lineage.
            if let morphemes = etymology.morphemes, !morphemes.isEmpty {
                morphemeSection(morphemes)
            }

            lineageSection(etymology.lineage)

            if let related = etymology.related, !related.isEmpty {
                relatedSection(related)
            }
        }
    }

    private func morphemeSection(_ morphemes: [Etymology.Morpheme]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Morphemes:")
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(morphemes) { morpheme in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(morpheme.surface)
                            .font(.custom("NeueHaasDisplay-Light", size: 20))
                            .foregroundStyle(.white)
                        Text(morpheme.type)
                            .font(.custom("NeueHaasDisplay-Light", size: 11))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 0)
                        Text(morpheme.originLanguage)
                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text(morpheme.gloss)
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private func lineageSection(_ lineage: [Etymology.LineageStep]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lineage:")
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 16) {
                ForEach(lineage.sorted(by: { $0.periodSort < $1.periodSort })) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle()
                            .fill((step.current ?? false) ? Color.white : Color.white.opacity(0.4))
                            .frame(width: 6, height: 6)
                            .offset(y: 2)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(step.form)
                                    .font(.custom("NeueHaasDisplay-Light", size: 20))
                                    .foregroundStyle(.white)
                                Text(step.language)
                                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer(minLength: 0)
                                Text(step.period)
                                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Text(step.meaning)
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
        }
    }

    private func relatedSection(_ related: [Etymology.Related]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Related:")
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.55))
            FlowLayout(spacing: 8) {
                ForEach(related) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.word)
                            .font(.custom("NeueHaasDisplay-Light", size: 15))
                            .foregroundStyle(.white)
                        Text(entry.gloss)
                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private func labelValueRow(
        _ label: String,
        value: String,
        valueFont: Font = .custom("NeueHaasDisplay-Light", size: 14)
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(valueFont)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }

    @MainActor
    private func loadIfNeeded() async {
        guard etymology == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            etymology = try await DeckGenerator.generateEtymology(
                word: word,
                sourceLanguage: sourceLanguage,
                explanationLanguage: Self.userExplanationLanguage
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    // Maps the device's preferred language code (e.g., "en", "fr", "zh-Hans")
    // to a human-readable English name we hand to the Claude prompt. Falls
    // back to English when no localized name is available.
    private static var userExplanationLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}

// Destination for the "Sentence Studio" pill on phrase / sentence items.
// Pushed onto the parent WordInfoSheet's NavigationStack so the standard
// push transition slides it in over the full sheet area, and the back
// gesture returns to the per-item info card.
//
// Layout mirrors the design spec: top bar (close, language tag, undo) →
// vertical history stack with faded prior versions above the bold
// active sentence → bottom edit panel with Structure / Style buttons +
// "Add Sentence to Deck" CTA. The transformation buttons currently
// append iteration markers into the local history so the UI is
// exercisable; routing them through Claude is a follow-up.
struct SentenceStudioView: View {
    @Environment(\.dismiss) private var dismiss
    let item: GeneratedItem
    let deckLanguage: String
    let deckDialect: String
    // Firestore deck id; nil disables the Save button.
    let deckId: String?
    // Fires after the user's `Save sentence` writes to Firestore. Hands
    // the updated `GeneratedItem` back up to the parent so the deck
    // list in DeckDetailView refreshes without a re-fetch.
    let onSaved: (GeneratedItem) -> Void

    @State private var history: [SentenceVersion] = []
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var transformError: String?
    @State private var showAddClauseSheet = false
    @State private var showChangeToneSheet = false
    @State private var showChangeTenseSheet = false
    @State private var showChangeLevelSheet = false

    fileprivate struct SentenceVersion: Identifiable, Hashable {
        let id = UUID()
        let text: String
        // English/native translation of `text`. Original entry pulls it
        // from the underlying GeneratedItem; each Claude transformation
        // returns a fresh translation alongside the rewritten foreign
        // sentence so the active card always shows them in lock-step.
        let translation: String
        // Short descriptor surfaced above the active version, e.g.
        // "Original", "Sentence Lengthened". Earlier versions render
        // with no descriptor — only the active one explains its origin.
        let action: String
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                sentenceColumn
                editPanel
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if history.isEmpty {
                history = [SentenceVersion(
                    text: item.word,
                    translation: item.translation,
                    action: "Original"
                )]
            }
        }
        .sheet(isPresented: $showAddClauseSheet) {
            AddClauseSheet { kind in
                showAddClauseSheet = false
                runClaudeTransformation(
                    .addClause(kind),
                    label: "\(kind.displayName) Added"
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChangeToneSheet) {
            ChangeToneSheet { kind in
                showChangeToneSheet = false
                runClaudeTransformation(
                    .changeTone(kind),
                    label: "Tone: \(kind.displayName)"
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChangeLevelSheet) {
            ChangeLevelSheet(levels: levels(for: deckLanguage)) { label in
                showChangeLevelSheet = false
                runClaudeTransformation(
                    .changeLevel(label: label),
                    label: "Level: \(label)"
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChangeTenseSheet) {
            ChangeTenseSheet { kind in
                showChangeTenseSheet = false
                runClaudeTransformation(
                    .changeTense(kind),
                    label: "Tense: \(kind.displayName)"
                )
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(shortLanguageLabel(deckLanguage).uppercased())
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))

            Spacer()

            Button {
                Haptics.light()
                if history.count > 1 {
                    history.removeLast()
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(history.count <= 1)
            .opacity(history.count <= 1 ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    private var sentenceColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(priorVersions) { version in
                        // Each older iteration retains its action label
                        // (what edit produced it) and its English
                        // translation, faded so the active sentence
                        // still reads as the current focus.
                        VStack(alignment: .leading, spacing: 6) {
                            if version.action != "Original" {
                                Text(version.action)
                                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                                    .foregroundStyle(.white.opacity(0.30))
                            }
                            Text(version.text)
                                .font(.custom("NeueHaasDisplay-Roman", size: 18))
                                .foregroundStyle(.white.opacity(0.22))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !version.translation.isEmpty {
                                Text(version.translation)
                                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                                    .foregroundStyle(.white.opacity(0.18))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .id(version.id)
                        // Each row fades + slides up gently from below
                        // when it transitions from active → prior on
                        // the next iteration.
                        .transition(
                            .opacity.combined(with: .move(edge: .bottom))
                        )
                    }

                    if let active = history.last {
                        VStack(alignment: .leading, spacing: 10) {
                            if history.count > 1 {
                                Text(active.action)
                                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Text(active.text)
                                .font(.custom("NeueHaasDisplay-Bold", size: 22))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(active.id)
                            if !active.translation.isEmpty {
                                Text(active.translation)
                                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        // Active sentence enters with the same gentle
                        // upward drift as the prior rows.
                        .transition(
                            .opacity.combined(with: .move(edge: .bottom))
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: history) { _, newValue in
                guard let last = newValue.last else { return }
                // `.smooth` is the slower, gentler easing curve added
                // in iOS 17 — slightly drawn-out at the start, settling
                // softly at the end — which lets the previous active
                // sentence drift upward into the prior-versions stack
                // while the new active fades in below it.
                withAnimation(.smooth(duration: 0.7)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var priorVersions: [SentenceVersion] {
        guard history.count > 1 else { return [] }
        return Array(history.dropLast())
    }

    private var editPanel: some View {
        // Horizontal padding lives on individual rows rather than the
        // outer container so the STRUCTURE / STYLE scrollers can bleed
        // all the way to the right edge — the trailing pill flows into
        // the screen edge as the user scrolls.
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text("EDIT")
                    .font(.custom("NeueHaasDisplay-Bold", size: 17))
                    .foregroundStyle(.white)
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(.leading, 20)

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("STRUCTURE")
                    .padding(.leading, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        studioButton(
                            systemImage: "arrow.right.and.line.vertical.and.arrow.left",
                            title: "Shorten Sentence"
                        ) {
                            runClaudeTransformation(.shorten, label: "Sentence Shortened")
                        }
                        studioButton(
                            systemImage: "arrow.left.and.right",
                            title: "Lengthen Sentence"
                        ) {
                            runClaudeTransformation(.lengthen, label: "Sentence Lengthened")
                        }
                        studioButton(
                            systemImage: "arrow.triangle.branch",
                            title: "Add Clause"
                        ) {
                            Haptics.light()
                            showAddClauseSheet = true
                        }
                    }
                    .padding(.leading, 20)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("STYLE")
                    .padding(.leading, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        studioButton(
                            systemImage: "face.smiling",
                            title: "Change Tone"
                        ) {
                            Haptics.light()
                            showChangeToneSheet = true
                        }
                        studioButton(
                            systemImage: "clock",
                            title: "Change Tense"
                        ) {
                            Haptics.light()
                            showChangeTenseSheet = true
                        }
                        studioButton(
                            systemImage: "chart.line.uptrend.xyaxis",
                            title: "Change Level"
                        ) {
                            Haptics.light()
                            showChangeLevelSheet = true
                        }
                    }
                    .padding(.leading, 20)
                }
            }

            Button {
                Haptics.medium()
                saveActiveSentence()
            } label: {
                HStack(spacing: 10) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18))
                    }
                    Text("Save sentence")
                        .font(.custom("NeueHaasDisplay-Light", size: 17))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass(.clear))
            .disabled(isSaving || deckId == nil)
            .opacity(deckId == nil ? 0.4 : 1)
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 24,
                    bottomLeading: 0,
                    bottomTrailing: 0,
                    topTrailing: 24
                )
            )
            .fill(Color.white.opacity(0.06))
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("NeueHaasDisplay-Light", size: 11))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func studioButton(
        systemImage: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                Text(title)
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .opacity(isProcessing ? 0.5 : 1)
    }

    // Real Claude-backed transformation (Shorten / Lengthen). Appends
    // the result as a new history entry so the user can stack edits or
    // undo with the toolbar back button.
    private func runClaudeTransformation(
        _ kind: DeckGenerator.SentenceTransformation,
        label: String
    ) {
        Haptics.light()
        guard !isProcessing else { return }
        guard let current = history.last?.text else { return }

        isProcessing = true
        transformError = nil
        Task {
            defer { isProcessing = false }
            do {
                let rewritten = try await DeckGenerator.transformSentence(
                    current,
                    transformation: kind,
                    language: deckLanguage,
                    dialect: deckDialect
                )
                guard !rewritten.foreign.isEmpty else { return }
                // `.smooth(duration:)` ties the append-time layout
                // animation to the same curve used by the scroll-to
                // call in `sentenceColumn`, so the new entry fades in
                // and the prior versions drift upward in one
                // continuous motion.
                withAnimation(.smooth(duration: 0.7)) {
                    history.append(SentenceVersion(
                        text: rewritten.foreign,
                        translation: rewritten.english,
                        action: label
                    ))
                }
            } catch {
                transformError = error.localizedDescription
            }
        }
    }

    // Placeholder for the buttons that don't yet have a Claude prompt
    // wired (Change Tone / Tense / Level). Appends a new version
    // reusing the current text + translation so the history UI still
    // grows during local testing.
    private func stubTransformation(_ label: String) {
        Haptics.light()
        guard let current = history.last else { return }
        withAnimation(.smooth(duration: 0.7)) {
            history.append(SentenceVersion(
                text: current.text,
                translation: current.translation,
                action: label
            ))
        }
    }

    // Persist the active iteration back into the parent deck. Replaces
    // the original item's `word` + `translation` in place — same id,
    // same `addedAt`, same FSRS schedule — then hands the updated
    // GeneratedItem to the parent so the deck list reflects the new
    // sentence and dismisses both Sentence Studio and the surrounding
    // WordInfoSheet via the `onSaved` callback chain.
    private func saveActiveSentence() {
        guard let active = history.last else { return }
        guard let deckId, !isSaving else { return }

        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await FirebaseDeckService.updateItem(
                    inDeck: deckId,
                    itemId: item.id,
                    word: active.text,
                    translation: active.translation
                )
                var updated = GeneratedItem(
                    word: active.text,
                    translation: active.translation,
                    transliteration: item.transliteration,
                    language: item.language,
                    kind: item.kind,
                    partsOfSpeech: item.partsOfSpeech,
                    addedAt: item.addedAt
                )
                updated.id = item.id
                Haptics.success()
                onSaved(updated)
            } catch {
                Haptics.error()
                transformError = error.localizedDescription
            }
        }
    }

    // "Chinese (Mandarin)" → "Mandarin" — matches the compaction used
    // elsewhere in the app for the language tag in the toolbar.
    private func shortLanguageLabel(_ language: String) -> String {
        if let open = language.firstIndex(of: "("),
           let close = language.firstIndex(of: ")"),
           open < close {
            return String(language[language.index(after: open)..<close])
        }
        return language
    }
}

// Presented when the user taps "Add Clause" inside Sentence Studio.
// White sheet with a title header and a vertical list of clause /
// phrase types. Each tap invokes `onSelect(kind)` and the parent
// dispatches the corresponding Claude prompt against the active
// sentence. Sheet detents allow the user to expand the picker if all
// nine options don't fit at .medium.
private struct AddClauseSheet: View {
    let onSelect: (DeckGenerator.ClauseKind) -> Void

    var body: some View {
        StudioOptionsSheet(
            title: "Add a Phrase or Clause",
            options: DeckGenerator.ClauseKind.allCases,
            label: { $0.displayName },
            onSelect: onSelect
        )
    }
}

// Presented when the user taps "Change Tone" inside Sentence Studio.
// Same layout as `AddClauseSheet` — only the title + option set differ.
private struct ChangeToneSheet: View {
    let onSelect: (DeckGenerator.ToneKind) -> Void

    var body: some View {
        StudioOptionsSheet(
            title: "Change Tone",
            options: DeckGenerator.ToneKind.allCases,
            label: { $0.displayName },
            onSelect: onSelect
        )
    }
}

// Reusable picker chrome behind the Sentence Studio sub-sheets. Header
// + vertical list of `plus.circle` rows, white background, same spacing
// + typography across every picker so future kinds drop in without
// duplicating layout code. `Hashable` is the only constraint so the
// dynamic Change Level picker (plain `[String]` from `levels(for:)`)
// works alongside the enum-backed ClauseKind / ToneKind pickers.
private struct StudioOptionsSheet<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 22))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                ForEach(options, id: \.self) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.black)
                            Text(label(option))
                                .font(.custom("NeueHaasDisplay-Light", size: 17))
                                .foregroundStyle(.black)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
// Change Level picker. Unlike Add Clause / Change Tone the option set
// is dynamic: each language has its own proficiency framework (HSK,
// JLPT, TOPIK, CEFR…) already encoded in `levels(for:)`, so the parent
// hands it in.
private struct ChangeLevelSheet: View {
    let levels: [String]
    let onSelect: (String) -> Void

    var body: some View {
        StudioOptionsSheet(
            title: "Change Level",
            options: levels,
            label: { $0 },
            onSelect: onSelect
        )
    }
}

// Change Tense picker. Different layout from the other Sentence Studio
// sub-sheets: chips grouped by time bucket (Present / Past / Future),
// each chip is one aspect (Simple / Continuous / Perfect / Perfect
// Continuous). Uses the existing `FlowLayout` so the four chips wrap
// gracefully on narrower devices.
private struct ChangeTenseSheet: View {
    let onSelect: (DeckGenerator.TenseKind) -> Void

    private let sections: [(title: String, kinds: [DeckGenerator.TenseKind])] = [
        ("Present", [
            .presentSimple, .presentContinuous,
            .presentPerfect, .presentPerfectContinuous
        ]),
        ("Past", [
            .pastSimple, .pastContinuous,
            .pastPerfect, .pastPerfectContinuous
        ]),
        ("Future", [
            .futureSimple, .futureContinuous,
            .futurePerfect, .futurePerfectContinuous
        ])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Change Tense")
                    .font(.custom("NeueHaasDisplay-Mediu", size: 22))
                    .foregroundStyle(.black)
                    .padding(.top, 16)

                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .font(.custom("NeueHaasDisplay-Roman", size: 17))
                            .foregroundStyle(.black)

                        FlowLayout(spacing: 8) {
                            ForEach(section.kinds) { kind in
                                Button {
                                    onSelect(kind)
                                } label: {
                                    Text(kind.aspectName)
                                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.black.opacity(0.3))
                                        )
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}


