import SwiftUI
import AVFoundation

struct GenerateContentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ContentGenerationKind
    let deck: DeckDocument
    // Fires when the user adds a word from the inline audit panel.
    // The parent (DeckDetailView) listens so it can append the item
    // to its local @State deck snapshot — without this, the word IS
    // saved to Firestore but the deck's in-memory items array stays
    // stale and the new card doesn't show up until a full reload.
    var onItemAdded: (GeneratedItem) -> Void = { _ in }
    // Fires once the sheet produces a finished result (content on screen,
    // artifact auto-saved). A curriculum "content" activity uses this to
    // stamp itself complete. Default nil — every existing call site is
    // unaffected.
    var onComplete: (() -> Void)? = nil

    @State private var additionalDetails: String = ""
    // Last-second "flavor" dials (vibe, voice, register, …) chosen on the input
    // screen for Story / Conversation / News Article. Woven into the generation
    // prompt and reused on Regenerate.
    @State private var flavor = ArtifactFlavor()
    @State private var phase: Phase = .input
    @State private var generatedContent: String = ""
    // Aligned sentence pairs straight from Claude. When non-empty,
    // the Line-by-line view uses these directly (perfect 1:1 alignment);
    // when empty (e.g. legacy fallback path) the view falls back to
    // sentence-splitting heuristics over `foreignContext` / `englishContext`.
    @State private var generatedPairs: [SentencePair] = []
    @State private var errorText: String?
    @State private var selectedWord: String?
    @State private var alignedNativeTokens: [String] = []
    @State private var pendingEnglishHighlight: String?
    @State private var isResolvingForeignWord = false
    @State private var speech = SpeechClient.shared
    @State private var readAloudPlayCount = 0
    // Completion chime played once the artifact finishes generating,
    // mirroring the deck-results success chime. Lazily loaded, primed for
    // jitter-free playback.
    @State private var completionPlayer: AVAudioPlayer?
    // Subtle repeating haptic that runs only while the skeleton loader is on
    // screen, so the wait has a gentle pulse under it. Torn down the moment
    // generation ends. No-ops on devices without a haptic engine (iPad/Mac).
    @State private var generatingHapticTimer: Timer?
    // Picker state for the result view. False = "Story" (the existing
    // foreign-block-then-English-block layout). True = "Line by line"
    // (sentence-pair interleave).
    @State private var isInterleaved = false
    // Eye toggle: reveals the Latin-script pronunciation (pinyin / romaji /
    // etc.) of the foreign text. Only offered for the non-Latin scripts the
    // generator produces a transliteration for.
    @State private var revealPronunciation = false
    // Save-to-Artifacts state. `didSaveArtifact` flips to true after
    // a successful write so the toolbar bookmark fills in and the
    // button disables — no double-saves, and the user gets visible
    // confirmation that the keep landed.
    @State private var isSavingArtifact = false
    @State private var didSaveArtifact = false
    // Guards the one-time "artifact generated" XP award, granted when the
    // sheet closes after a successful generation.
    @State private var awardedGenerationXP = false
    // Surfaced by `.subscriptionCapAlert` when generate or save
    // throws SubscriptionError.capExceeded.
    @State private var capError: SubscriptionError?

    // Reading-comprehension questions generated for the current content
    // (story / conversation / news article only). They live below the
    // Read-aloud/Regenerate row and are shared by both the Story and
    // Line-by-line tabs, since they sit outside the tab switch.
    @State private var comprehensionPhase: ComprehensionPhase = .idle
    @State private var comprehensionQuestions: [ComprehensionQuestion] = []
    @State private var comprehensionError: String?
    // Questions already credited with XP, so re-tapping (or re-render)
    // never double-awards. Streak is credited at most once per content
    // via `didRegisterComprehensionStreak`.
    @State private var awardedQuestionIDs: Set<UUID> = []
    @State private var didRegisterComprehensionStreak = false
    // Counts one "comprehension" learning-method session the first time the
    // learner answers a question for this artifact. Reset on regenerate.
    @State private var didCountComprehensionSession = false

    // Parallel-columns Story view (iPad/Mac only). The first tab renders the
    // target and native text side by side, plus any number of extra translation
    // columns the reader adds. The whole strip scrolls horizontally so columns
    // keep a fixed width no matter how many are added.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // One added translation column: its language + dialect and the per-pair
    // translations (aligned 1:1 with `interleavedPairs()`).
    struct ExtraColumn: Identifiable {
        let id = UUID()
        var language: String
        var dialect: String
        var translations: [String] = []
        var isTranslating: Bool = false
        var error: String?
    }
    @State private var extraColumns: [ExtraColumn] = []
    // Fixed on-screen width for every column, so adding more scrolls rather
    // than shrinks.
    private let storyColumnWidth: CGFloat = 340

    // Language picker state. `editingColumnID` is nil when adding a new column,
    // or the id of the column being re-selected. Draft values are committed
    // only on "Done".
    @State private var thirdPickerPresented = false
    @State private var editingColumnID: UUID?
    @State private var draftThirdLanguage: String = ""
    @State private var draftThirdDialect: String = ""
    // Cross-language word mapping shown as a callout above the columns when a
    // word is tapped. Drives the per-column highlights too.
    @State private var wordMapping: DeckGenerator.WordMap?

    // Columns are only offered where there's horizontal room: Mac Catalyst,
    // or an iPad in a regular-width layout. iPhone (and iPad slide-over) keep
    // the existing stacked Story layout untouched.
    private var useColumns: Bool {
        MacLayout.isMac || horizontalSizeClass == .regular
    }

    enum Phase {
        case input, generating, result
    }

    enum ComprehensionPhase {
        case idle, loading, loaded, failed
    }

    private var nativeHighlightWords: Set<String> {
        var set = Set(alignedNativeTokens.map { $0.lowercased() })
        if let hint = pendingEnglishHighlight {
            set.insert(hint.lowercased())
        }
        return set
    }

    private var englishContext: String {
        // The DeckGenerator prompt asks Claude to append a line starting with "English:".
        // Pull that text out so we can ask Claude to align the tapped foreign word to a
        // token inside it.
        if let range = generatedContent.range(of: "English:") {
            return generatedContent[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // True when the target language uses a script we generate a pronunciation
    // for AND the current content actually carries transliterations. Gates
    // whether the eye toggle appears at all.
    private var pronunciationAvailable: Bool {
        DeckGenerator.needsPronunciationAid(deck.language)
            && generatedPairs.contains {
                ($0.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }
    }

    private var foreignContext: String {
        if let range = generatedContent.range(of: "English:") {
            return generatedContent[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return generatedContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            phaseView
                .navigationTitle(L("Generate %@", L(kind.rawValue)))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L("Cancel")) { dismiss() }
                            .disabled(phase == .generating)
                    }
                    if phase == .result {
                        // No Save button — generated artifacts are auto-saved
                        // to the deck's collection the moment they're created.
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L("Done")) { dismiss() }
                        }
                    }
                }
        }
        // Kill any in-flight speech when the sheet is torn down so the
        // "Read aloud" playback (and any per-word pronunciation taps)
        // don't keep going after the user dismisses. Mirrors the
        // same stop-on-disappear hook ListenSessionView uses.
        .onDisappear {
            SpeechClient.shared.stop()
            stopGeneratingHaptics()
            completionPlayer?.stop()
            // Reward generating (and reading) the artifact, once, on close —
            // only if a generation actually happened.
            if phase == .result, !awardedGenerationXP {
                awardedGenerationXP = true
                let artifactKind = kind.rawValue
                let artifactVibe = flavor.option(for: .vibe)
                Task {
                    if let grants = try? await XPService.awardArtifactGenerated(kind: artifactKind, vibe: artifactVibe),
                       !grants.isEmpty {
                        await MainActor.run { XPToastCenter.shared.enqueue(grants) }
                    }
                }
            }
        }
        .subscriptionCapAlert($capError)
    }

    // Writes the current result (prose + sentence alignment) to the
    // deck's artifacts subcollection so the user can revisit it from
    // the Artifacts tab. Idempotent via `didSaveArtifact` so a quick
    // double-tap doesn't produce two records.
    private func saveAsArtifact() async {
        guard let deckId = deck.id,
              !generatedContent.isEmpty,
              !isSavingArtifact,
              !didSaveArtifact else { return }
        isSavingArtifact = true
        defer { isSavingArtifact = false }

        let trimmedDetails = additionalDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let artifact = Artifact(
            id: nil,
            deckId: deckId,
            kind: kind.rawValue,
            title: Artifact.deriveTitle(fromProse: generatedContent),
            prose: generatedContent,
            pairs: generatedPairs,
            userPrompt: trimmedDetails.isEmpty ? nil : trimmedDetails,
            createdAt: Date(),
            questions: comprehensionQuestions.isEmpty ? nil : comprehensionQuestions
        )
        do {
            _ = try await FirebaseDeckArtifactService.save(artifact)
            await MainActor.run {
                didSaveArtifact = true
                Haptics.success()
            }
        } catch let error as SubscriptionError {
            await MainActor.run {
                capError = error
            }
        } catch {
            await MainActor.run {
                errorText = L("Couldn't save artifact: %@", error.localizedDescription)
            }
        }
    }

    // Maps the AVSpeechSynthesizer NSRange (which is into the trimmed
    // `foreignContext` we pass to speak) onto the displayed `generatedContent`
    // by shifting it past any leading whitespace.
    private var spokenRangeInDisplayedText: NSRange? {
        guard let range = speech.currentSpokenWordRange else { return nil }
        let leadingWhitespaceCount = generatedContent
            .prefix { $0.isWhitespace || $0.isNewline }
            .utf16.count
        return NSRange(
            location: range.location + leadingWhitespaceCount,
            length: range.length
        )
    }

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .input:      inputView
        case .generating: generatingView
        case .result:     resultView
        }
    }

    private var inputView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Add any additional details (optional)"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField(
                        kind.placeholder,
                        text: $additionalDetails,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                    if kind.supportsFlavor {
                        flavorDialsSection
                    }

                    Text(deckContextLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let err = errorText {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Button {
                Task { await generate() }
            } label: {
                Text(L("Generate"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Flavor dials

    // Optional last-second style dials, laid out as label + dropdown rows in the
    // same spirit as the deck's language / dialect / level pickers. Only shown
    // for the narrative kinds (Story / Conversation / News Article).
    private var flavorDialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Style (optional)"))
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            ForEach(ArtifactDial.dials(for: kind)) { dial in
                flavorDialRow(dial)
            }
        }
        .padding(.top, 4)
    }

    private func flavorDialRow(_ dial: ArtifactDial) -> some View {
        HStack {
            Text(L(dial.title))
                .font(.system(size: 14))
                .foregroundStyle(.black)
            Spacer(minLength: 12)
            Menu {
                Picker(L(dial.title), selection: flavorBinding(dial)) {
                    Text(L("Any")).tag("")
                    ForEach(dial.options, id: \.self) { option in
                        Text(L(option)).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(flavor.option(for: dial).map { L($0) } ?? L("Any"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(flavor.option(for: dial) == nil ? Color.secondary : Color.black)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(Capsule().stroke(Color(white: 0.85), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func flavorBinding(_ dial: ArtifactDial) -> Binding<String> {
        Binding(
            get: { flavor.option(for: dial) ?? "" },
            set: { newValue in
                Haptics.light()
                flavor.set(newValue.isEmpty ? nil : newValue, for: dial)
            }
        )
    }

    // Placeholder paragraphs that mirror the prose about to appear, with a
    // looping shimmer, so the wait reads as "text is materializing here"
    // rather than a bare spinner.
    private var generatingView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L("Generating %@…", L(kind.rawValue).lowercased()))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    skeletonBar(width: nil)
                    skeletonBar(width: nil)
                    skeletonBar(width: 240)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(GeneratingShimmer())
        .onAppear { startGeneratingHaptics() }
        .onDisappear { stopGeneratingHaptics() }
    }

    // A soft tap on entry, then a gentle light pulse every ~1.2s while the
    // skeleton loader animates — subtle background feedback for the wait.
    private func startGeneratingHaptics() {
        stopGeneratingHaptics()
        Haptics.light()
        generatingHapticTimer = Timer.scheduledTimer(
            withTimeInterval: 1.2,
            repeats: true
        ) { _ in
            Haptics.light()
        }
    }

    private func stopGeneratingHaptics() {
        generatingHapticTimer?.invalidate()
        generatingHapticTimer = nil
    }

    // Plays the artifact-complete chime and fires the success haptic —
    // the same "you're done" beat the deck-results cascade uses. Re-asserts
    // the playback session (the chat mic flow may have repurposed it) and
    // primes the player on first use. Fails silently if anything is missing.
    @MainActor
    private func playCompletionFeedback() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        if completionPlayer == nil,
           let url = Bundle.main.url(forResource: "TonguesArtifactComplete", withExtension: "mp3") {
            completionPlayer = try? AVAudioPlayer(contentsOf: url)
            completionPlayer?.prepareToPlay()
        }
        completionPlayer?.currentTime = 0
        completionPlayer?.play()
        Haptics.success()
    }

    @ViewBuilder
    private func skeletonBar(width: CGFloat?) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(white: 0.90))
            .frame(width: width, height: 13)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var resultView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(L("Format"), selection: $isInterleaved) {
                        Text(L("Story")).tag(false)
                        Text(L("Line by line")).tag(true)
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .top, spacing: 10) {
                        Text(L("Tap any word to look it up or add it to this deck."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if pronunciationAvailable {
                            Button {
                                Haptics.light()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    revealPronunciation.toggle()
                                }
                            } label: {
                                Image(systemName: revealPronunciation ? "eye.fill" : "eye")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(revealPronunciation ? .black : Color(white: 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(revealPronunciation ? L("Hide pronunciation") : L("Show pronunciation"))
                        }
                    }

                    if isInterleaved {
                        interleavedContent
                    } else if useColumns {
                        storyColumns
                    } else if revealPronunciation, pronunciationAvailable {
                        storyWithPronunciation
                    } else {
                        TappableContentText(
                            text: generatedContent,
                            highlightedWord: selectedWord,
                            highlightedNativeWords: nativeHighlightWords,
                            spokenRange: spokenRangeInDisplayedText,
                            onWordTapped: { word, kind in
                                Haptics.light()
                                handleWordTap(word: word, kind: kind)
                            }
                        )
                    }

                    HStack(spacing: 8) {
                        Button {
                            Haptics.light()
                            // Toggle: tap while playing stops the
                            // current run; tap when idle starts a
                            // fresh read-through. SpeechClient doesn't
                            // expose true pause/resume, so this is the
                            // interim play/stop behavior.
                            if speech.isSpeaking {
                                SpeechClient.shared.stop()
                            } else {
                                readAloudPlayCount += 1
                                SpeechClient.shared.speak(
                                    foreignContext,
                                    language: deck.language,
                                    highlightPassage: true
                                )
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: speech.isSpeaking ? "stop.fill" : "waveform")
                                    .symbolEffect(.variableColor.iterative.nonReversing, options: .speed(2), value: readAloudPlayCount)
                                Text(speech.isSpeaking ? L("Stop") : L("Read aloud"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(.black)
                            .overlay(Capsule().stroke(Color(white: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .disabled(foreignContext.isEmpty)

                        Button {
                            Task {
                                await generate()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.2.circlepath")
                                Text(L("Regenerate"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(.black)
                            .overlay(Capsule().stroke(Color(white: 0.85)))
                        }
                        .buttonStyle(.plain)
                    }

                    if kind.supportsComprehension {
                        Divider()
                            .padding(.top, 4)
                        comprehensionSection
                    }
                }
                .padding(20)
            }

            if let word = selectedWord {
                WordAuditPanel(
                    word: word,
                    deck: deck,
                    englishContext: englishContext,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            selectedWord = nil
                            alignedNativeTokens = []
                            pendingEnglishHighlight = nil
                            isResolvingForeignWord = false
                            wordMapping = nil
                        }
                    },
                    onAlignedTokensLoaded: { tokens in
                        withAnimation(.easeOut(duration: 0.18)) {
                            alignedNativeTokens = tokens
                            if !tokens.isEmpty {
                                pendingEnglishHighlight = nil
                            }
                        }
                    },
                    onItemAdded: { item in
                        onItemAdded(item)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isResolvingForeignWord {
                ResolvingForeignWordPanel(
                    englishWord: pendingEnglishHighlight ?? "",
                    onClose: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isResolvingForeignWord = false
                            pendingEnglishHighlight = nil
                            wordMapping = nil
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $thirdPickerPresented) {
            ThirdLanguagePickerSheet(
                selectedLanguage: $draftThirdLanguage,
                selectedDialect: $draftThirdDialect,
                onConfirm: {
                    thirdPickerPresented = false
                    commitLanguagePicker()
                }
            )
        }
    }

    // MARK: - Story columns (iPad / Mac)

    // First-tab parallel layout: target language and native language side by
    // side, plus an optional third column the reader can translate into. Each
    // cell is word-tappable and drives the same add-to-deck flow (WordAuditPanel)
    // as the stacked iPhone layout, with a tri-lingual mapping callout on top.
    @ViewBuilder
    private var storyColumns: some View {
        let pairs = interleavedPairs()
        // target + native + each extra + the trailing "add" column
        let totalColumns = 2 + extraColumns.count + 1
        VStack(alignment: .leading, spacing: 14) {
            mappingCallout

            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        columnHeader(localizedLanguageName(deck.language))
                            .frame(width: storyColumnWidth, alignment: .leading)
                        columnHeader(localizedLanguageName(AppLanguage.currentNative.englishName))
                            .frame(width: storyColumnWidth, alignment: .leading)
                        ForEach(Array(extraColumns.enumerated()), id: \.element.id) { i, col in
                            extraColumnHeader(col, index: i)
                                .frame(width: storyColumnWidth, alignment: .leading)
                        }
                        addColumnHeader
                            .frame(width: storyColumnWidth, alignment: .leading)
                    }
                    Divider()
                        .gridCellColumns(totalColumns)
                    ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                        GridRow {
                            foreignColumnCell(pair, spokenRange: spokenRange(forPairIndex: index))
                                .frame(width: storyColumnWidth, alignment: .leading)
                            nativeColumnCell(pair)
                                .frame(width: storyColumnWidth, alignment: .leading)
                            ForEach(Array(extraColumns.enumerated()), id: \.element.id) { i, col in
                                extraColumnCell(column: col, columnIndex: i, rowIndex: index)
                                    .frame(width: storyColumnWidth, alignment: .leading)
                            }
                            addColumnCell(rowIndex: index)
                                .frame(width: storyColumnWidth, alignment: .leading)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Header for an added translation column: the language name (tapping
    // re-opens the picker to change it), its dialect beneath, and a small ×
    // to remove the column.
    private func extraColumnHeader(_ col: ExtraColumn, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    Haptics.light()
                    openLanguagePicker(editing: col)
                } label: {
                    HStack(spacing: 4) {
                        Text(localizedLanguageName(col.language).uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.5)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    Haptics.light()
                    removeColumn(col.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(white: 0.6))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !col.dialect.isEmpty, col.dialect != "Standard" {
                Text(col.dialect)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Header above the trailing "add" column. A plain "Translation" title
    // before the first extra column exists; blank once there are extras (the
    // gray box below already reads as "add another").
    private var addColumnHeader: some View {
        columnHeader(extraColumns.isEmpty ? L("Translation") : " ")
    }

    // Call to action for the trailing "add" column: a very light gray panel
    // that opens the language picker to add another translation column. It
    // occupies the space that column's translations will fill once chosen.
    private var addLanguageBox: some View {
        Button {
            Haptics.light()
            openLanguagePicker(editing: nil)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(white: 0.62))
                Text(L("Add language"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.42))
                Text(L("Translate this text into another language"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 140)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.96))
            )
        }
        .buttonStyle(.plain)
    }

    // Seeds the picker draft — from the column being edited, or a sensible
    // default (the first language not already on screen) when adding — then
    // presents the picker.
    private func openLanguagePicker(editing col: ExtraColumn?) {
        if let col {
            editingColumnID = col.id
            draftThirdLanguage = col.language
            draftThirdDialect = col.dialect
        } else {
            editingColumnID = nil
            let used = Set(extraColumns.map(\.language) + [deck.language])
            let opts = DeckAttribute.language.options
            draftThirdLanguage = opts.first(where: { !used.contains($0) })
                ?? opts.first(where: { $0 != deck.language })
                ?? (opts.first ?? "")
            draftThirdDialect = dialects(for: draftThirdLanguage).first ?? "Standard"
        }
        thirdPickerPresented = true
    }

    // Applies the picker result: updates the edited column (and re-translates)
    // or appends a new column, kicking off its translation.
    private func commitLanguagePicker() {
        let lang = draftThirdLanguage
        let dialect = draftThirdDialect
        guard !lang.isEmpty else { return }
        // Feed the shared recents list so a language chosen here surfaces under
        // "Recently Used" everywhere the language picker appears.
        RecentAttributeStore.recordLanguage(lang)
        let affectedID: UUID
        if let editID = editingColumnID,
           let idx = extraColumns.firstIndex(where: { $0.id == editID }) {
            extraColumns[idx].language = lang
            extraColumns[idx].dialect = dialect
            extraColumns[idx].translations = []
            extraColumns[idx].error = nil
            affectedID = editID
        } else {
            let col = ExtraColumn(language: lang, dialect: dialect)
            extraColumns.append(col)
            affectedID = col.id
        }
        editingColumnID = nil
        Task { await translateColumn(affectedID) }
    }

    private func removeColumn(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.18)) {
            extraColumns.removeAll { $0.id == id }
            wordMapping = nil
        }
    }

    @ViewBuilder
    private func foreignColumnCell(_ pair: SentencePair, spokenRange: NSRange? = nil) -> some View {
        let translit = pair.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
        if revealPronunciation,
           DeckGenerator.isChinese(deck.language),
           let translit, !translit.isEmpty,
           let tokens = RubyPinyinAligner.align(foreign: pair.foreign, pinyin: translit) {
            RubyPinyinLine(tokens: tokens, highlightPhrases: foreignHighlightPhrases, spokenRange: spokenRange) { word in
                handleColumnTap(word: word, column: .target)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                TappableContentText(
                    text: pair.foreign,
                    highlightedWord: selectedWord,
                    highlightedNativeWords: [],
                    spokenRange: spokenRange,
                    highlightPhrases: foreignHighlightPhrases,
                    onWordTapped: { word, _ in
                        handleColumnTap(word: word, column: .target)
                    }
                )
                if revealPronunciation, let translit, !translit.isEmpty {
                    Text(translit)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func nativeColumnCell(_ pair: SentencePair) -> some View {
        TappableContentText(
            text: pair.english,
            highlightedWord: nil,
            highlightedNativeWords: [],
            highlightPhrases: mappingPhrases(wordMapping?.native),
            onWordTapped: { word, _ in
                handleColumnTap(word: word, column: .native)
            }
        )
    }

    // One row of an added translation column. Shows a skeleton bar while the
    // column is translating, its (row 0) error if any, otherwise the tappable
    // translated sentence — wired to the same mapping + add-to-deck flow.
    @ViewBuilder
    private func extraColumnCell(column col: ExtraColumn, columnIndex: Int, rowIndex: Int) -> some View {
        if col.isTranslating {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.92))
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let err = col.error, rowIndex == 0 {
            Text(err)
                .font(.system(size: 12))
                .foregroundStyle(.red)
        } else if rowIndex < col.translations.count, !col.translations[rowIndex].isEmpty {
            TappableContentText(
                text: col.translations[rowIndex],
                highlightedWord: nil,
                highlightedNativeWords: [],
                highlightPhrases: mappingPhrases(extraMappingWord(columnIndex)),
                onWordTapped: { word, _ in
                    handleColumnTap(word: word, column: .extra(columnIndex))
                }
            )
        } else {
            Color.clear.frame(height: 1)
        }
    }

    // The trailing "add" column body: the gray call-to-action box at the top
    // (first row), empty beneath.
    @ViewBuilder
    private func addColumnCell(rowIndex: Int) -> some View {
        if rowIndex == 0 {
            addLanguageBox
        } else {
            Color.clear.frame(height: 1)
        }
    }

    // The mapped word for extra column `index`, if the current mapping covers it.
    private func extraMappingWord(_ index: Int) -> String? {
        guard let extras = wordMapping?.extras, index < extras.count else { return nil }
        return extras[index]
    }

    // Mapping card shown above the columns after a word tap — the tapped
    // meaning rendered across the target, native, and every extra language.
    @ViewBuilder
    private var mappingCallout: some View {
        if let map = wordMapping {
            VStack(alignment: .leading, spacing: 8) {
                mappingRow(localizedLanguageName(deck.language), map.foreign)
                mappingRow(localizedLanguageName(AppLanguage.currentNative.englishName), map.native)
                ForEach(Array(extraColumns.enumerated()), id: \.element.id) { i, col in
                    let word = i < map.extras.count ? map.extras[i] : ""
                    if !word.isEmpty {
                        mappingRow(localizedLanguageName(col.language), word)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.04))
            )
        }
    }

    private func mappingRow(_ language: String, _ word: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(language.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(word.isEmpty ? "—" : word)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Wraps a mapped phrase for the phrase-highlight path in TappableContentText.
    // Keeping the phrase whole (rather than splitting into tokens) is what lets
    // multi-character CJK words and multi-word phrases highlight as one span.
    private func mappingPhrases(_ phrase: String?) -> [String] {
        guard let phrase = phrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty else { return [] }
        return [phrase]
    }

    // Phrases to highlight in the target column: the mapped foreign word plus
    // the currently selected word (instant feedback before the mapping resolves,
    // and the source of truth when the target column itself was tapped). Shared
    // by the plain and pinyin (ruby) renderings so both highlight identically.
    private var foreignHighlightPhrases: [String] {
        var phrases = mappingPhrases(wordMapping?.foreign)
        if let selected = selectedWord?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            phrases.append(selected)
        }
        return phrases
    }

    // Translates every foreign sentence into the given column's language,
    // preserving alignment with the pairs. Re-run when the column's language
    // changes or the artifact is regenerated. Looked up by id throughout so a
    // concurrent add/remove can't write into the wrong slot.
    @MainActor
    private func translateColumn(_ id: UUID) async {
        let pairs = interleavedPairs()
        guard !pairs.isEmpty,
              let start = extraColumns.firstIndex(where: { $0.id == id }) else { return }
        let lang = extraColumns[start].language
        let dialect = extraColumns[start].dialect
        extraColumns[start].isTranslating = true
        extraColumns[start].error = nil
        do {
            let translations = try await DeckGenerator.translatePairs(
                pairs.map(\.foreign),
                from: deck.language,
                to: lang,
                dialect: dialect
            )
            if let idx = extraColumns.firstIndex(where: { $0.id == id }) {
                extraColumns[idx].translations = translations
                extraColumns[idx].isTranslating = false
            }
        } catch {
            if let idx = extraColumns.firstIndex(where: { $0.id == id }) {
                extraColumns[idx].error = L("Couldn't translate: %@", error.localizedDescription)
                extraColumns[idx].translations = []
                extraColumns[idx].isTranslating = false
            }
        }
    }

    private enum StoryColumn: Equatable {
        case target, native, extra(Int)
        var role: String {
            switch self {
            case .target: return "target"
            case .native: return "native"
            case .extra(let i): return "extra:\(i)"
            }
        }
    }

    // Column word-tap handler. The target column's word IS the foreign word,
    // so the add-to-deck panel opens immediately; every other column resolves
    // the corresponding foreign word first (via the same mapping call that
    // feeds the all-languages callout + per-column highlights).
    private func handleColumnTap(word: String, column: StoryColumn) {
        Haptics.light()
        let isTarget = (column == .target)
        withAnimation(.easeOut(duration: 0.18)) {
            wordMapping = nil
            alignedNativeTokens = []
            if isTarget {
                selectedWord = word
                pendingEnglishHighlight = nil
                isResolvingForeignWord = false
            } else {
                selectedWord = nil
                pendingEnglishHighlight = word
                isResolvingForeignWord = true
            }
        }
        let foreignPassage = pairsForeignPassage
        let nativePassage = pairsNativePassage
        let extraLangs = extraColumns.map(\.language)
        let extraPassages = extraColumns.map { $0.translations.joined(separator: " ") }
        let role = column.role
        Task { @MainActor [deck, foreignPassage, nativePassage, extraLangs, extraPassages, role] in
            let map = try? await DeckGenerator.mapWordAcrossLanguages(
                tappedWord: word,
                tappedColumn: role,
                foreignPassage: foreignPassage,
                foreignLanguage: deck.language,
                nativePassage: nativePassage,
                extraLanguages: extraLangs,
                extraPassages: extraPassages
            )
            withAnimation(.easeOut(duration: 0.18)) {
                wordMapping = map
                if let foreign = map?.foreign, !foreign.isEmpty {
                    if isTarget {
                        // A tap in a CJK column yields a single character; expand
                        // it to the full word it belongs to so the target word
                        // highlights fully and add-to-deck saves the whole word,
                        // not one character. Leave ordinary whole-word taps as-is.
                        if word.count == 1, word.first?.isCJKIdeograph == true {
                            selectedWord = foreign
                        }
                    } else {
                        selectedWord = foreign
                    }
                }
                if !isTarget {
                    isResolvingForeignWord = false
                }
            }
        }
    }

    // Passages built straight from the aligned pairs (robust regardless of the
    // native-language marker used in the flat prose).
    private var pairsForeignPassage: String {
        interleavedPairs().map(\.foreign).joined(separator: " ")
    }

    private var pairsNativePassage: String {
        interleavedPairs().map(\.english).joined(separator: " ")
    }

    // Per-pair spoken-word range for the Story columns' foreign cells, so the
    // Read-aloud highlight tracks the word being spoken. Reuses the same
    // pair-relative mapping the Line-by-line view uses; nil for every pair
    // except the one currently being read.
    private func spokenRange(forPairIndex index: Int) -> NSRange? {
        guard let highlight = spokenPairHighlight, highlight.pairIndex == index else {
            return nil
        }
        return highlight.range
    }

    // MARK: Pronunciation rendering

    // Renders one foreign sentence with its pronunciation directly beneath
    // it. For Chinese (when the pinyin is syllable-separated and lines up
    // 1:1 with the characters) it stacks each syllable centered under its
    // character, ruby-style; otherwise it falls back to the tappable
    // foreign line with the romanization on the line below. Used by both
    // the Story reveal and the Line-by-line view so they stay consistent.
    @ViewBuilder
    private func foreignWithPinyin(_ pair: SentencePair, spokenRange: NSRange? = nil) -> some View {
        let translit = pair.transliteration?.trimmingCharacters(in: .whitespacesAndNewlines)
        if revealPronunciation,
           DeckGenerator.isChinese(deck.language),
           let translit, !translit.isEmpty,
           let tokens = RubyPinyinAligner.align(foreign: pair.foreign, pinyin: translit) {
            RubyPinyinLine(tokens: tokens, spokenRange: spokenRange) { word in
                Haptics.light()
                handleWordTap(word: word, kind: .foreign)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                TappableContentText(
                    text: pair.foreign,
                    highlightedWord: selectedWord,
                    highlightedNativeWords: nativeHighlightWords,
                    spokenRange: spokenRange,
                    onWordTapped: { word, kind in
                        Haptics.light()
                        handleWordTap(word: word, kind: kind)
                    }
                )
                if revealPronunciation, let translit, !translit.isEmpty {
                    Text(translit)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Story mode with pinyin revealed: each foreign sentence gets its
    // pronunciation beneath it (line-by-line, not a trailing paragraph),
    // then the whole native translation follows as one block.
    private var storyWithPronunciation: some View {
        let pairs = interleavedPairs()
        let highlight = spokenPairHighlight
        let native = pairs.map(\.english).filter { !$0.isEmpty }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    if !pair.foreign.isEmpty {
                        // Pipe the read-aloud highlight only to the pair
                        // currently being spoken (same mapping the other views
                        // use), so pinyin mode highlights like plain text.
                        foreignWithPinyin(
                            pair,
                            spokenRange: highlight?.pairIndex == index ? highlight?.range : nil
                        )
                    }
                }
            }
            if !native.isEmpty {
                Text(native)
                    .font(.system(size: 15).italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Line-by-line interleave

    // Renders sentence pairs as alternating foreign + English rows.
    // Tight within-pair spacing + larger between-pair spacing gives the
    // visual rhythm of true line-by-line: one foreign line, one English
    // line, breath, next pair. English uses italic + secondary color so
    // the eye can distinguish the translation line from the source even
    // when the foreign line wraps onto multiple typographic lines.
    private var interleavedContent: some View {
        let pairs = interleavedPairs()
        let highlight = spokenPairHighlight
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                VStack(alignment: .leading, spacing: 2) {
                    if !pair.foreign.isEmpty {
                        // Pipe the spoken-word highlight only to the pair the
                        // speech engine is currently reading.
                        foreignWithPinyin(
                            pair,
                            spokenRange: highlight?.pairIndex == index ? highlight?.range : nil
                        )
                    }
                    if !pair.english.isEmpty {
                        Text(pair.english)
                            .font(.system(size: 14).italic())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Reading comprehension

    // The comprehension block that sits below the Read-aloud/Regenerate row.
    // Because it lives outside the Story/Line-by-line `if isInterleaved`
    // switch, the same questions (and their answer state) show identically
    // in both tabs — switching tabs never resets or changes them.
    @ViewBuilder
    private var comprehensionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                Text(L("Check your understanding"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.black)

            switch comprehensionPhase {
            case .idle, .loading:
                ComprehensionLoadingView()
            case .loaded:
                ForEach(Array(comprehensionQuestions.enumerated()), id: \.element.id) { index, question in
                    ComprehensionQuestionCard(
                        index: index,
                        question: question,
                        onFirstAttempt: { correct in handleFirstAttempt(question, correct: correct) },
                        onSolved: { Task { await registerComprehensionStreakIfNeeded() } }
                    )
                }
            case .failed:
                VStack(alignment: .leading, spacing: 10) {
                    Text(comprehensionError ?? L("Couldn't load questions."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button {
                        Haptics.light()
                        Task { await loadComprehensionQuestions() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text(L("Try again"))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .foregroundStyle(.black)
                        .overlay(Capsule().stroke(Color(white: 0.85)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    // Generates (or regenerates) the comprehension questions from the
    // current content. Reads the pairs straight off state so the retry
    // button and the initial post-generate call share one path.
    @MainActor
    private func loadComprehensionQuestions() async {
        guard kind.supportsComprehension, !generatedPairs.isEmpty else { return }
        comprehensionPhase = .loading
        comprehensionError = nil
        let content = GeneratedContent(prose: generatedContent, pairs: generatedPairs)
        do {
            let questions = try await DeckGenerator.generateComprehensionQuestions(
                kind: kind,
                deck: deck,
                content: content
            )
            comprehensionQuestions = questions
            comprehensionPhase = questions.isEmpty ? .failed : .loaded
            if questions.isEmpty {
                comprehensionError = L("Couldn't load questions.")
            }
        } catch {
            comprehensionError = error.localizedDescription
            comprehensionPhase = .failed
        }
    }

    private func handleFirstAttempt(_ question: ComprehensionQuestion, correct: Bool) {
        // Count one "comprehension" learning-method session per artifact, the
        // first time the learner answers any of its questions — plus a flat
        // time estimate for the time-weighted preferred-language score.
        if !didCountComprehensionSession {
            didCountComprehensionSession = true
            let lang = deck.language
            Task { try? await XPService.recordComprehensionSession(language: lang, seconds: 60) }
        }
        // One award per question, on the first attempt only: 10 XP for a
        // correct first try, 5 XP for a wrong first guess. Later taps on the
        // same question earn nothing.
        guard !awardedQuestionIDs.contains(question.id) else { return }
        awardedQuestionIDs.insert(question.id)
        Task {
            let grants = correct
                ? (try? await XPService.awardComprehensionFirstTryCorrect())
                : (try? await XPService.awardComprehensionGuess())
            if let grants, !grants.isEmpty {
                await MainActor.run { XPToastCenter.shared.enqueue(grants) }
            }
        }
    }

    // Saves a lightweight study session (once per content) so the day is
    // registered in the streak walk. The streak reads
    // `practiceCountsByDay`, which is derived from StudySession records —
    // XP alone doesn't feed it, so we mirror how FlashcardView records a
    // session, just with a single-review count.
    @MainActor
    private func registerComprehensionStreakIfNeeded() async {
        guard !didRegisterComprehensionStreak, let deckId = deck.id else { return }
        didRegisterComprehensionStreak = true
        _ = try? await FirebaseDeckService.recordStreakActivity(
            deckId: deckId,
            deckTitle: deck.title,
            language: deck.language
        )
    }

    // Maps the speech engine's spoken-word range (which is relative to
    // the concatenated foreignContext we pass to `speak`) back to the
    // pair that contains it, plus the range within that pair's text.
    // Only used in Line-by-line mode; Story mode keeps using the
    // existing `spokenRangeInDisplayedText` for the full-text overlay.
    private var spokenPairHighlight: (pairIndex: Int, range: NSRange)? {
        guard !generatedPairs.isEmpty,
              let global = speech.currentSpokenWordRange else { return nil }
        // Match how foreignContext is constructed:
        // pairs.map(\.foreign).joined(separator: " ") then trimmed.
        // Trim doesn't touch internal joins, so per-pair offsets line
        // up as long as no pair's foreign starts/ends with whitespace.
        var offset = 0
        for (idx, pair) in generatedPairs.enumerated() {
            let pairLength = pair.foreign.utf16.count
            let pairEnd = offset + pairLength
            if global.location >= offset && global.location < pairEnd {
                let localStart = global.location - offset
                let localLength = min(global.length, pairLength - localStart)
                return (idx, NSRange(location: localStart, length: max(0, localLength)))
            }
            offset = pairEnd + 1   // +1 for the " " separator between pairs
        }
        return nil
    }

    // Source-of-truth pair list: prefer the LLM-aligned pairs (perfect
    // 1:1) when the new JSON-based response delivered them. Fall back
    // to sentence-splitting the prose only when pairs are missing
    // (legacy responses or a malformed response that somehow still
    // produced a prose string).
    private func interleavedPairs() -> [SentencePair] {
        if !generatedPairs.isEmpty {
            return generatedPairs
        }
        let foreignSentences = sentences(in: foreignContext)
        let englishSentences = sentences(in: englishContext)
        let count = max(foreignSentences.count, englishSentences.count)
        var pairs: [SentencePair] = []
        for i in 0..<count {
            let f = i < foreignSentences.count ? foreignSentences[i] : ""
            let e = i < englishSentences.count ? englishSentences[i] : ""
            pairs.append(SentencePair(foreign: f, english: e))
        }
        return pairs
    }

    // Locale-aware sentence split via Foundation. Respects CJK
    // punctuation (。 ! ?) as well as Latin (. ! ?) and any line breaks
    // the model inserted (which matters for songs/poems where each
    // verse line is its own unit).
    private func sentences(in text: String) -> [String] {
        var result: [String] = []
        // First respect explicit line breaks — the prompt asks the
        // model to preserve them for songs and poems.
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            var lineSentences: [String] = []
            line.enumerateSubstrings(
                in: line.startIndex..<line.endIndex,
                options: .bySentences
            ) { substring, _, _, _ in
                if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty {
                    lineSentences.append(s)
                }
            }
            if lineSentences.isEmpty {
                result.append(line)
            } else {
                result.append(contentsOf: lineSentences)
            }
        }
        return result
    }

    private func handleWordTap(word: String, kind: TappedWordKind) {
        switch kind {
        case .foreign:
            withAnimation(.easeOut(duration: 0.18)) {
                selectedWord = word
                alignedNativeTokens = []
                pendingEnglishHighlight = nil
                isResolvingForeignWord = false
            }
        case .english:
            withAnimation(.easeOut(duration: 0.18)) {
                selectedWord = nil
                alignedNativeTokens = []
                pendingEnglishHighlight = word
                isResolvingForeignWord = true
            }
            Task { @MainActor [foreignContext, englishContext, deck] in
                let resolved = try? await DeckGenerator.findCorrespondingForeignWord(
                    englishWord: word,
                    foreignContext: foreignContext,
                    englishContext: englishContext,
                    language: deck.language,
                    dialect: deck.dialect
                )
                withAnimation(.easeOut(duration: 0.18)) {
                    isResolvingForeignWord = false
                    if let resolved, !resolved.isEmpty {
                        selectedWord = resolved
                    }
                }
            }
        }
    }

    private var deckContextLine: String {
        var line = L("Will use: %@ %@ · %@", L(deck.dialect), localizedLanguageName(deck.language), L(deck.level))
        if !deck.interests.isEmpty {
            line += L(" · interests: %@", deck.interests.joined(separator: ", "))
        }
        return line
    }

    @MainActor
    private func generate() async {
        phase = .generating
        errorText = nil
        // Clear any prior comprehension state so a regenerate starts fresh
        // (new questions, reset XP/streak guards).
        comprehensionQuestions = []
        comprehensionError = nil
        awardedQuestionIDs = []
        didRegisterComprehensionStreak = false
        didCountComprehensionSession = false
        comprehensionPhase = .idle
        // Fresh generation (incl. a regenerate) is a new artifact to keep.
        didSaveArtifact = false
        do {
            let result = try await DeckGenerator.generateContent(
                kind: kind,
                deck: deck,
                additionalDetails: additionalDetails,
                styleDirectives: flavor.promptDirectives(for: kind)
            )
            generatedContent = result.prose
            generatedPairs = result.pairs
            phase = .result
            // Signal any curriculum "content" activity that this counts as done
            // (content is on screen; the auto-save below persists it).
            onComplete?()
            // Artifact is done — chime + success haptic, matching the deck
            // generation's completion beat.
            playCompletionFeedback()
            // A fresh artifact invalidates every extra-column translation and
            // any open word mapping; re-translate each column against the new
            // text.
            wordMapping = nil
            for i in extraColumns.indices {
                extraColumns[i].translations = []
                extraColumns[i].error = nil
            }
            for col in extraColumns {
                Task { await translateColumn(col.id) }
            }
            // Follow-on call: the content is already on screen (phase is
            // .result), so questions stream in below it (skeleton → cards)
            // without blocking the reader. We await them BEFORE the save so the
            // saved artifact carries its comprehension questions.
            if kind.supportsComprehension {
                await loadComprehensionQuestions()
            }
            // Auto-save to the deck's artifacts collection — every generated
            // artifact is kept (the Save button is gone). Detached so it never
            // blocks the reader; `comprehensionQuestions` is already populated
            // by the await above, so it's saved with them.
            Task { await saveAsArtifact() }
        } catch let error as SubscriptionError {
            capError = error
            phase = .input
        } catch {
            errorText = error.localizedDescription
            phase = .input
        }
    }
}

// Sweeps a soft highlight left-to-right across its content on a loop — the
// shimmer that signals the generating skeleton is loading.
private struct GeneratingShimmer: ViewModifier {
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

// MARK: - Tappable text (word-by-word lookup)

enum TappedWordKind {
    case foreign
    case english
}

struct TappableContentText: View {
    let text: String
    let highlightedWord: String?
    let highlightedNativeWords: Set<String>
    var spokenRange: NSRange? = nil
    // Whole phrases to highlight by locating them verbatim in `text`. Unlike
    // the per-token sets above, this matches a contiguous span, so a
    // multi-character CJK word (whose characters are tokenized individually)
    // or a multi-word phrase highlights as one unit. Used by the parallel
    // columns' cross-language mapping.
    var highlightPhrases: [String] = []
    let onWordTapped: (String, TappedWordKind) -> Void

    var body: some View {
        Text(attributed)
            .font(.system(size: 16))
            .tint(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "tonguesword",
                      let host = url.host else {
                    return .systemAction
                }
                let kind: TappedWordKind = host == "english" ? .english : .foreign
                let rawWord = String(url.path.drop(while: { $0 == "/" }))
                guard let decoded = rawWord.removingPercentEncoding, !decoded.isEmpty else {
                    return .systemAction
                }
                onWordTapped(decoded, kind)
                return .handled
            })
    }

    // Languages without whitespace word boundaries (Chinese, Japanese, Korean)
    // need per-character tokenization — otherwise the entire run of CJK
    // characters lumps into a single tappable "word", and a single-character
    // match from Claude can't highlight inside it.
    private var highlightPieces: Set<String> {
        guard let word = highlightedWord else { return [] }
        let cjkChars = word.filter { $0.isCJKIdeograph }
        if cjkChars.count >= 2 {
            // Multi-character CJK phrase — decompose so each character matches
            // its own token.
            return Set(cjkChars.map { String($0) })
        }
        return [word]
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var buffer = ""
        var inWord = false
        var bufferStart = text.startIndex
        var cursor = text.startIndex

        let englishMarkerEnd: String.Index? = text.range(of: "English:")?.upperBound

        func isEnglish(at index: String.Index) -> Bool {
            guard let marker = englishMarkerEnd else { return false }
            return index >= marker
        }

        for ch in text {
            // Each CJK ideograph is its own word — flush the pending buffer
            // and emit the character on its own so a single Chinese/Japanese/
            // Korean character can be tapped and matched independently.
            if ch.isCJKIdeograph {
                append(
                    buffer: buffer,
                    isWord: inWord,
                    isEnglish: isEnglish(at: bufferStart),
                    into: &result
                )
                let cjkPos = cursor
                let nextCursor = text.index(after: cursor)
                append(
                    buffer: String(ch),
                    isWord: true,
                    isEnglish: isEnglish(at: cjkPos),
                    into: &result
                )
                buffer = ""
                inWord = false
                cursor = nextCursor
                bufferStart = nextCursor
                continue
            }

            let isWord = ch.isLetter || ch.isNumber
            if isWord != inWord {
                append(
                    buffer: buffer,
                    isWord: inWord,
                    isEnglish: isEnglish(at: bufferStart),
                    into: &result
                )
                buffer = ""
                bufferStart = cursor
                inWord = isWord
            }
            buffer.append(ch)
            cursor = text.index(after: cursor)
        }
        append(
            buffer: buffer,
            isWord: inWord,
            isEnglish: isEnglish(at: bufferStart),
            into: &result
        )

        // Yellow phrase highlights: find each mapped phrase verbatim in the
        // text and highlight the whole span. Substring-based so a multi-character
        // CJK word and a multi-word phrase both light up as a contiguous unit.
        // For Latin phrases we require word boundaries so a short phrase doesn't
        // match inside a longer word; CJK has no word spaces, so those match
        // anywhere (a word can sit flush against its neighbors).
        for phrase in highlightPhrases {
            let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            let needleIsCJK = needle.contains { $0.isCJKIdeograph }
            var from = text.startIndex
            while let r = text.range(
                of: needle,
                options: [.caseInsensitive],
                range: from..<text.endIndex
            ) {
                let boundaryOK: Bool
                if needleIsCJK {
                    boundaryOK = true
                } else {
                    let beforeOK = r.lowerBound == text.startIndex
                        || !text[text.index(before: r.lowerBound)].isLetterOrNumber
                    let afterOK = r.upperBound == text.endIndex
                        || !text[r.upperBound].isLetterOrNumber
                    boundaryOK = beforeOK && afterOK
                }
                if boundaryOK, let attrRange = Range(r, in: result) {
                    result[attrRange].backgroundColor = Color.yellow.opacity(0.55)
                }
                from = r.upperBound
            }
        }

        // Overlay the AVSpeech read-along highlight (orange, distinct from the
        // yellow tap-selected highlight).
        if let range = spokenRange,
           range.length > 0,
           let stringRange = Range(range, in: text),
           let attrRange = Range(stringRange, in: result) {
            result[attrRange].backgroundColor = Color.orange.opacity(0.55)
        }

        return result
    }

    private func append(
        buffer: String,
        isWord: Bool,
        isEnglish: Bool,
        into result: inout AttributedString
    ) {
        guard !buffer.isEmpty else { return }
        var piece = AttributedString(buffer)
        piece.foregroundColor = .primary
        if isWord,
           let encoded = buffer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            let host = isEnglish ? "english" : "foreign"
            if let url = URL(string: "tonguesword://\(host)/\(encoded)") {
                piece.link = url
                piece.underlineStyle = nil
            }
        }
        let isForeignHighlight = isWord && highlightPieces.contains(buffer)
        let isNativeHighlight = isWord && highlightedNativeWords.contains(buffer.lowercased())
        if isForeignHighlight || isNativeHighlight {
            piece.backgroundColor = Color.yellow.opacity(0.55)
        }
        result += piece
    }
}

// MARK: - CJK character detection

extension Character {
    // Convenience for word-boundary checks in the phrase highlighter.
    fileprivate var isLetterOrNumber: Bool { isLetter || isNumber }

    // Covers the Unicode blocks where each character is typically a complete
    // word (no internal spacing): Han ideographs, Hiragana, Katakana, Hangul.
    fileprivate var isCJKIdeograph: Bool {
        unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value) ||      // CJK Unified Ideographs
                   (0x3400...0x4DBF).contains(value) ||      // CJK Extension A
                   (0x20000...0x2A6DF).contains(value) ||    // CJK Extension B
                   (0xF900...0xFAFF).contains(value) ||      // CJK Compatibility Ideographs
                   (0x3040...0x309F).contains(value) ||      // Hiragana
                   (0x30A0...0x30FF).contains(value) ||      // Katakana
                   (0xAC00...0xD7AF).contains(value)         // Hangul Syllables
        }
    }
}

// MARK: - Ruby pinyin (per-character pronunciation)

// Aligns a Chinese line with its (syllable-separated) pinyin so each
// syllable can sit under its character. Alignment is intentionally strict:
// it only succeeds when the number of CJK characters exactly equals the
// number of whitespace-separated pinyin syllables. When it doesn't (e.g.
// legacy word-segmented pinyin, erhua contractions, embedded digits), it
// returns nil and the caller falls back to a plain foreign + pinyin line.
enum RubyPinyinAligner {
    struct Token: Hashable {
        let text: String
        let pinyin: String?   // nil for punctuation / non-CJK characters
        let tappable: Bool
    }

    static func align(foreign: String, pinyin: String) -> [Token]? {
        let syllables = pinyin.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !syllables.isEmpty else { return nil }

        let chars = Array(foreign)
        let cjkCount = chars.filter { $0.isCJKIdeograph }.count
        guard cjkCount == syllables.count else { return nil }

        var tokens: [Token] = []
        var next = 0
        for ch in chars {
            if ch.isCJKIdeograph {
                tokens.append(Token(text: String(ch), pinyin: syllables[next], tappable: true))
                next += 1
            } else if ch.isWhitespace {
                continue   // Chinese has no word spaces; drop any strays.
            } else {
                tokens.append(Token(text: String(ch), pinyin: nil, tappable: ch.isLetter || ch.isNumber))
            }
        }
        return tokens
    }
}

// Renders aligned ruby tokens: each character with its pinyin syllable
// centered directly underneath, wrapping across lines via FlowLayout.
// Tapping a character fires `onTap` for the same word-lookup flow as the
// flat tappable text.
private struct RubyPinyinLine: View {
    let tokens: [RubyPinyinAligner.Token]
    // Whole phrases to highlight, matched verbatim against the character run so
    // a multi-character word lights up across its tokens — mirrors the plain
    // TappableContentText highlight so the pinyin view behaves identically.
    var highlightPhrases: [String] = []
    // The read-along spoken-word range (UTF-16, into the joined character run
    // — which equals the foreign sentence), highlighted orange to match
    // TappableContentText. nil means nothing is currently being spoken. Without
    // this the karaoke highlight vanished whenever pinyin was revealed.
    var spokenRange: NSRange? = nil
    var onTap: (String) -> Void = { _ in }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                VStack(spacing: 1) {
                    Text(token.text)
                        .font(.system(size: 19))
                        .foregroundStyle(.black)
                    // A clear placeholder keeps punctuation baselines aligned
                    // with the pinyin row of neighboring characters.
                    Text(token.pinyin ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(token.pinyin == nil ? .clear : Color(white: 0.45))
                }
                .fixedSize()
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(spokenIndices.contains(index)
                              ? Color.orange.opacity(0.55)
                              : highlightedIndices.contains(index)
                                ? Color.yellow.opacity(0.55)
                                : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if token.tappable { onTap(token.text) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Token indices covered by any highlight phrase. Each token is exactly one
    // character (see RubyPinyinAligner), so a token's index equals its offset in
    // the joined character run — letting us map a matched substring straight
    // back to the tokens it spans.
    // Token indices overlapping the spoken-word range. Each token is exactly
    // one character, so its UTF-16 offset in the joined run locates it against
    // the range the speech engine reports.
    private var spokenIndices: Set<Int> {
        guard let spokenRange, spokenRange.length > 0 else { return [] }
        var indices = Set<Int>()
        var utf16Offset = 0
        for (i, token) in tokens.enumerated() {
            let length = token.text.utf16.count
            let tokenRange = NSRange(location: utf16Offset, length: length)
            if NSIntersectionRange(tokenRange, spokenRange).length > 0 {
                indices.insert(i)
            }
            utf16Offset += length
        }
        return indices
    }

    private var highlightedIndices: Set<Int> {
        guard !highlightPhrases.isEmpty else { return [] }
        let joined = tokens.map(\.text).joined()
        guard !joined.isEmpty else { return [] }
        var indices = Set<Int>()
        for phrase in highlightPhrases {
            let needle = String(phrase.filter { !$0.isWhitespace })
            guard !needle.isEmpty else { continue }
            var searchStart = joined.startIndex
            while let r = joined.range(
                of: needle,
                options: [.caseInsensitive],
                range: searchStart..<joined.endIndex
            ) {
                let start = joined.distance(from: joined.startIndex, to: r.lowerBound)
                let end = joined.distance(from: joined.startIndex, to: r.upperBound)
                for i in start..<end { indices.insert(i) }
                searchStart = r.upperBound
            }
        }
        return indices
    }
}

// MARK: - Resolving panel (shown while we look up the foreign word for a tapped English word)

struct ResolvingForeignWordPanel: View {
    let englishWord: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(englishWord)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Spacer()
                Button {
                    Haptics.light()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 10) {
                ProgressView()
                Text(L("Finding matching word…"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
    }
}

// MARK: - Word audit panel (inline bottom sheet on the result screen)

struct WordAuditPanel: View {
    let word: String
    let deck: DeckDocument
    let englishContext: String
    let onClose: () -> Void
    var onAlignedTokensLoaded: ([String]) -> Void = { _ in }
    // Bubbled up to GenerateContentSheet → DeckDetailView so the deck's
    // local items list reflects the save immediately. The Firestore
    // write itself is independent and still happens inside addToDeck.
    var onItemAdded: (GeneratedItem) -> Void = { _ in }

    @State private var wordInfo: WordInfo?
    @State private var isLoadingInfo = true
    @State private var isAdding = false
    @State private var addedSuccess = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(word)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Spacer()
                Button {
                    Haptics.light()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isLoadingInfo {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L("Looking up…"))
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let info = wordInfo {
                        infoContent(info)
                    } else if let err = errorText {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }

                    if !isLoadingInfo, wordInfo != nil {
                        addButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 340)
        .background(Color.white)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        .task(id: word) { await loadInfo() }
    }

    @ViewBuilder
    private func infoContent(_ info: WordInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // Meaning + speak button (8pt right margin, vertically centered
            // against the whole Meaning block).
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Meaning"))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(info.meaning)
                        .font(.system(size: 18))
                        .foregroundStyle(.black)
                }
                Spacer(minLength: 0)
                SpeakWaveformButton(
                    action: {
                        SpeechClient.shared.speak(
                            word,
                            language: deck.language,
                            allowForvo: true
                        )
                    },
                    font: .system(size: 18)
                )
                .padding(.trailing, 8)
            }

            if !info.partsOfSpeech.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Parts of Speech"))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(info.partsOfSpeech, id: \.self) { pos in
                            Text(pos)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }

            VStack(spacing: 6) {
                labelValueRow(
                    L("Pronunciation"),
                    value: info.pronunciation,
                    valueFont: .system(size: 13, design: .monospaced)
                )
                labelValueRow(L("Language"), value: info.language)
                labelValueRow(L("Frequency"), value: info.wordFrequency)
                labelValueRow(
                    L("Difficulty"),
                    value: info.pronunciationDifficulty,
                    valueFont: .system(size: 13, weight: .semibold)
                )
            }
        }
    }

    private func labelValueRow(
        _ label: String,
        value: String,
        valueFont: Font = .system(size: 13)
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(valueFont)
                .foregroundStyle(.black)
        }
    }

    @ViewBuilder
    private var addButton: some View {
        Button {
            Haptics.medium()
            Task { await addToDeck() }
        } label: {
            HStack(spacing: 8) {
                if isAdding {
                    ProgressView().tint(.white)
                } else if addedSuccess {
                    Image(systemName: "checkmark")
                } else {
                    Image(systemName: "plus")
                }
                Text(addedSuccess ? L("Added to deck") : (isAdding ? L("Adding…") : L("Add to Deck")))
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.black)
            .clipShape(Capsule())
        }
        .disabled(isAdding || addedSuccess)
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadInfo() async {
        wordInfo = nil
        addedSuccess = false
        errorText = nil
        onAlignedTokensLoaded([])
        isLoadingInfo = true

        // Fire the alignment lookup in parallel so the English highlight can
        // appear independently of (and often before) the slower WordInfo call.
        let alignmentTask = Task { [word, englishContext, deck] () -> [String] in
            (try? await DeckGenerator.findCorrespondingTokens(
                foreignWord: word,
                englishContext: englishContext,
                language: deck.language,
                dialect: deck.dialect
            )) ?? []
        }
        Task { @MainActor in
            let tokens = await alignmentTask.value
            onAlignedTokensLoaded(tokens)
        }

        defer { isLoadingInfo = false }
        do {
            if let cached = try await FirebaseDeckService.fetchWordInfo(
                word: word,
                language: deck.language
            ) {
                wordInfo = cached
                return
            }
            let generated = try await DeckGenerator.generateWordInfo(
                word: word,
                translation: "",
                language: deck.language,
                dialect: deck.dialect
            )
            wordInfo = generated
            try? await FirebaseDeckService.saveWordInfo(
                generated,
                word: word,
                language: deck.language
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func addToDeck() async {
        guard let info = wordInfo, let deckId = deck.id else {
            errorText = L("Deck identifier unavailable.")
            return
        }
        isAdding = true
        defer { isAdding = false }
        do {
            // Stamp addedAt + language locally so the version we bubble
            // up to the parent matches FirebaseDeckService.addItems's
            // own stamping. Differs from Firestore's timestamp by at
            // most a few milliseconds.
            let now = Date()
            let item = GeneratedItem(
                word: word,
                translation: info.meaning,
                transliteration: nil,
                language: deck.language,
                addedAt: now,
                source: SourcingMethod.artifact.rawValue
            )
            try await FirebaseDeckService.addItems(
                toDeck: deckId,
                items: [item],
                sourceLanguage: deck.language
            )
            Haptics.success()
            addedSuccess = true
            // Hand the saved item back up so the parent can append it
            // to its local deck snapshot — Firestore already has it,
            // but the in-memory @State copy in DeckDetailView needs to
            // know too.
            onItemAdded(item)
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Third-language picker (Story columns)

// Language + dialect picker for the Story view's extra translation columns.
// Each row opens the same rich pickers used elsewhere in the app —
// `AttributeOptionsSheet` (search + recently-used languages) for language and
// `DialectPickerSheet` (search + usage sort + speaker counts) for dialect —
// minus the proficiency level, which a straight translation doesn't need.
private struct ThirdLanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedLanguage: String
    @Binding var selectedDialect: String
    let onConfirm: () -> Void

    @State private var showLanguageSheet = false
    @State private var showDialectSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section(L("Language")) {
                    disclosureRow(
                        value: localizedLanguageName(selectedLanguage)
                    ) {
                        Haptics.light()
                        showLanguageSheet = true
                    }
                }

                Section(L("Dialect")) {
                    disclosureRow(
                        value: L(selectedDialect)
                    ) {
                        Haptics.light()
                        showDialectSheet = true
                    }
                }
            }
            .navigationTitle(L("Translate into"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) {
                        Haptics.medium()
                        snapDialectIfStale()
                        onConfirm()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showLanguageSheet) {
                AttributeOptionsSheet(
                    attribute: .language,
                    options: DeckAttribute.language.options,
                    selection: $selectedLanguage
                )
            }
            .sheet(isPresented: $showDialectSheet) {
                DialectPickerSheet(
                    language: selectedLanguage,
                    selection: $selectedDialect
                )
            }
            .onChange(of: selectedLanguage) { _, _ in
                snapDialectIfStale()
            }
        }
    }

    private func disclosureRow(value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(value)
                    .font(.custom("NeueHaasDisplay-Light", size: 17))
                    .foregroundStyle(.black)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    // Keep the chosen dialect valid whenever the language changes.
    private func snapDialectIfStale() {
        let valid = dialects(for: selectedLanguage)
        if !valid.contains(selectedDialect) {
            selectedDialect = valid.first ?? "Standard"
        }
    }
}
