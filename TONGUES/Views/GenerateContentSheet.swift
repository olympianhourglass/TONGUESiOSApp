import SwiftUI

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

    @State private var additionalDetails: String = ""
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
    // Picker state for the result view. False = "Story" (the existing
    // foreign-block-then-English-block layout). True = "Line by line"
    // (sentence-pair interleave).
    @State private var isInterleaved = false
    // Save-to-Artifacts state. `didSaveArtifact` flips to true after
    // a successful write so the toolbar bookmark fills in and the
    // button disables — no double-saves, and the user gets visible
    // confirmation that the keep landed.
    @State private var isSavingArtifact = false
    @State private var didSaveArtifact = false
    // Surfaced by `.subscriptionCapAlert` when generate or save
    // throws SubscriptionError.capExceeded.
    @State private var capError: SubscriptionError?

    enum Phase {
        case input, generating, result
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
                .navigationTitle("Generate \(kind.rawValue)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .disabled(phase == .generating)
                    }
                    if phase == .result {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Haptics.light()
                                Task { await saveAsArtifact() }
                            } label: {
                                Image(systemName: didSaveArtifact ? "bookmark.fill" : "bookmark")
                                    .foregroundStyle(.black)
                            }
                            .disabled(isSavingArtifact || didSaveArtifact || generatedContent.isEmpty)
                            .accessibilityLabel(didSaveArtifact ? "Saved to Artifacts" : "Save to Artifacts")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
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
            createdAt: Date()
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
                errorText = "Couldn't save artifact: \(error.localizedDescription)"
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Add any additional details (optional)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                kind.placeholder,
                text: $additionalDetails,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...6)

            Text(deckContextLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let err = errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                Task { await generate() }
            } label: {
                Text("Generate")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    private var generatingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Generating \(kind.rawValue.lowercased())…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Format", selection: $isInterleaved) {
                        Text("Story").tag(false)
                        Text("Line by line").tag(true)
                    }
                    .pickerStyle(.segmented)

                    Text("Tap any word to look it up or add it to this deck.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if isInterleaved {
                        interleavedContent
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
                                    language: deck.language
                                )
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: speech.isSpeaking ? "stop.fill" : "waveform")
                                    .symbolEffect(.variableColor.iterative.nonReversing, options: .speed(2), value: readAloudPlayCount)
                                Text(speech.isSpeaking ? "Stop" : "Read aloud")
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
                                Text("Regenerate")
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
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        TappableContentText(
                            text: pair.foreign,
                            highlightedWord: selectedWord,
                            highlightedNativeWords: nativeHighlightWords,
                            // Pipe the spoken-word highlight only to the
                            // pair the speech engine is currently reading.
                            spokenRange: highlight?.pairIndex == index ? highlight?.range : nil,
                            onWordTapped: { word, kind in
                                Haptics.light()
                                handleWordTap(word: word, kind: kind)
                            }
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
        var line = "Will use: \(deck.dialect) \(deck.language) · \(deck.level)"
        if !deck.interests.isEmpty {
            line += " · interests: \(deck.interests.joined(separator: ", "))"
        }
        return line
    }

    @MainActor
    private func generate() async {
        phase = .generating
        errorText = nil
        do {
            let result = try await DeckGenerator.generateContent(
                kind: kind,
                deck: deck,
                additionalDetails: additionalDetails
            )
            generatedContent = result.prose
            generatedPairs = result.pairs
            phase = .result
        } catch let error as SubscriptionError {
            capError = error
            phase = .input
        } catch {
            errorText = error.localizedDescription
            phase = .input
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
                Text("Finding matching word…")
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
                            Text("Looking up…")
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
                    Text("Meaning")
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
                    Text("Parts of Speech")
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
                    "Pronunciation",
                    value: info.pronunciation,
                    valueFont: .system(size: 13, design: .monospaced)
                )
                labelValueRow("Language", value: info.language)
                labelValueRow("Frequency", value: info.wordFrequency)
                labelValueRow(
                    "Difficulty",
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
                Text(addedSuccess ? "Added to deck" : (isAdding ? "Adding…" : "Add to Deck"))
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(addedSuccess ? Color(red: 0.18, green: 0.45, blue: 0.22) : .black)
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
            errorText = "Deck identifier unavailable."
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
                addedAt: now
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
