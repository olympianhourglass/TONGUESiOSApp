import SwiftUI

// Song / video link page (Create New Deck → page 4, between Direct and
// Large body text). The user pastes a YouTube / web-video / song URL;
// we identify the media, pull its original-language transcript +
// English translation, and break it into difficulty-ranked word and
// sentence lists the learner can multi-select and save to a deck.
//
// The heavy lifting is in DeckGenerator.extractFromMediaLink — see the
// note there on how "fetching" works (model knowledge, not a live web
// fetch). This view stays a thin presentation + save layer, sharing the
// exact save flow LargeBodyTextPage / CameraPage / DirectPage use.
struct SongVideoLinkPage: View {
    // language / dialect are still threaded in (and written back to)
    // because the saved deck reads them — but they're no longer shown as
    // editable pickers. After a fetch they're auto-set to the detected
    // language + a valid dialect for it (see runFetch); the detected
    // chip is the only thing the user sees.
    @Binding var language: String
    @Binding var dialect: String
    let level: String
    let onSaved: () -> Void

    // Which breakdown the segmented control is showing. Selection state
    // is kept per-segment so toggling back and forth preserves picks.
    private enum Segment: String, CaseIterable {
        case words = "Words"
        case sentences = "Sentences"
    }

    @State private var urlText: String = ""
    @State private var extraction: DeckGenerator.MediaLinkExtraction?
    // True after a fetch that came back `recognized == false` so we can
    // show the "couldn't identify this" state instead of empty lists.
    @State private var didFailToRecognize = false
    @State private var isProcessing = false
    @State private var errorText: String?
    @State private var segment: Segment = .words
    @State private var selectedWordIDs: Set<UUID> = []
    @State private var selectedSentenceIDs: Set<UUID> = []
    @State private var showTranscript = false
    @State private var showDeckPicker = false
    @State private var showCreateCover = false
    @State private var isSavingNewDeck = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                linkField
                if isProcessing {
                    processingBanner
                }
                if didFailToRecognize {
                    notRecognizedBanner
                }
                if let extraction, extraction.recognized {
                    titleBanner(extraction)
                    transcriptDisclosure(extraction)
                    segmentPicker
                    breakdownList(extraction)
                    saveActions
                }
            }
            .padding(.horizontal, 8)
            // Clears the parent sheet's custom close-X overlay
            // (8pt top inset + 36pt circle = 44pt) plus breathing room.
            .padding(.top, 80)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: $showDeckPicker) {
            DeckPickerSheet(
                itemsToAdd: selectedItems,
                sourceLanguage: resolvedLanguage,
                sourceDialect: resolvedDialect,
                onAdded: {
                    showDeckPicker = false
                    onSaved()
                }
            )
        }
        .sheet(isPresented: $showCreateCover) {
            DeckCoverCustomizationSheet(
                initialTitle: defaultDeckTitle,
                language: resolvedLanguage,
                level: level
            ) { newTitle, chosenStyle, isPublic in
                showCreateCover = false
                Task {
                    await saveAsNewDeck(
                        title: newTitle,
                        style: chosenStyle,
                        isPublic: isPublic
                    )
                }
            }
            .presentationDetents([.fraction(0.8), .large])
        }
    }

    // MARK: Link field

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a song or video link")
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("", text: $urlText)
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.black)
                    // Black caret/selection instead of the system blue accent.
                    .tint(.black)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { startFetch() }
                    // Custom placeholder so its color is black (muted) rather
                    // than the system's default tinted prompt.
                    .overlay(alignment: .leading) {
                        if urlText.isEmpty {
                            Text("https://youtube.com/watch?v=…")
                                .font(.custom("NeueHaasDisplay-Light", size: 15))
                                .foregroundStyle(.black.opacity(0.4))
                                .allowsHitTesting(false)
                        }
                    }
                if !urlText.isEmpty {
                    Button {
                        Haptics.light()
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )

            HStack(spacing: 12) {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        Haptics.light()
                        urlText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Haptics.medium()
                    startFetch()
                } label: {
                    Text(isProcessing ? "Reading…" : "Translate & Break Down")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(canFetch ? Color.black : Color(white: 0.75))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canFetch)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("We pull the captions or audio, then translate the whole thing and pull out study words and sentences.")
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("Longer videos can take up to two minutes.")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var canFetch: Bool {
        !isProcessing && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Processing / not-recognized banners

    private var processingBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().tint(.black)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribing + translating the whole thing…")
                    .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                    .foregroundStyle(.black)
                Text("This can take up to two minutes for longer videos. You can keep this screen open.")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.92), lineWidth: 1)
        )
    }

    private var notRecognizedBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            Text("Couldn't identify that link. Try a well-known song or a popular video — or paste the lyrics directly on the Large Body Text page.")
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: Title + transcript

    private func titleBanner(_ extraction: DeckGenerator.MediaLinkExtraction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(extraction.title.isEmpty ? "Untitled" : extraction.title)
                .font(.custom("NeueHaasDisplay-Roman", size: 22))
                .foregroundStyle(.black)
                .lineLimit(2)
            // Detected-language chip. After a fetch the language +
            // dialect pickers are auto-set to the detected language and
            // a valid dialect for it (see runFetch), so this chip, the
            // attributes row, and the saved deck all agree.
            detectedLanguageChip(language)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detectedLanguageChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 11))
            Text("Detected: \(name)")
                .font(.custom("NeueHaasDisplay-Mediu", size: 12))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.06)))
    }

    private func transcriptDisclosure(_ extraction: DeckGenerator.MediaLinkExtraction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.light()
                withAnimation(.easeInOut(duration: 0.2)) { showTranscript.toggle() }
            } label: {
                HStack {
                    Text("Transcript & Full Translation")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Image(systemName: showTranscript ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTranscript {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Original transcript (the foreign language).
                        if !extraction.transcript.isEmpty {
                            transcriptBlock(
                                label: "Original · \(extraction.resolvedLanguage)",
                                text: extraction.transcript,
                                prominent: true
                            )
                        }
                        // Full English translation of the entire transcript.
                        if !extraction.englishTranslation.isEmpty {
                            Divider()
                            transcriptBlock(
                                label: "English translation",
                                text: extraction.englishTranslation,
                                prominent: false
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .frame(maxHeight: 360)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.88), lineWidth: 1)
        )
    }

    private func transcriptBlock(label: String, text: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(text)
                .font(prominent
                      ? .custom("NeueHaasDisplay-Roman", size: 16)
                      : .system(size: 14))
                .foregroundStyle(prominent ? .black : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: Segmented control

    private var segmentPicker: some View {
        Picker("Breakdown", selection: $segment) {
            ForEach(Segment.allCases, id: \.self) { seg in
                Text(seg.rawValue).tag(seg)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Breakdown list (difficulty-ranked, multi-select)

    @ViewBuilder
    private func breakdownList(_ extraction: DeckGenerator.MediaLinkExtraction) -> some View {
        let items = currentItems(extraction)
        let selection = currentSelectionBinding()
        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                Text("No \(segment.rawValue.lowercased()) found in this track.")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Hardest first")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Text("\(selection.wrappedValue.count) / \(items.count) selected")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                    Button(allSelected(items, selection.wrappedValue) ? "Deselect all" : "Select all") {
                        Haptics.light()
                        if allSelected(items, selection.wrappedValue) {
                            selection.wrappedValue.removeAll()
                        } else {
                            selection.wrappedValue = Set(items.map(\.id))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, rank: index + 1, selection: selection)
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )
            }
        }
    }

    private func row(_ item: GeneratedItem, rank: Int, selection: Binding<Set<UUID>>) -> some View {
        let selected = selection.wrappedValue.contains(item.id)
        return Button {
            Haptics.light()
            if selected {
                selection.wrappedValue.remove(item.id)
            } else {
                selection.wrappedValue.insert(item.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? .black : Color(white: 0.7))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.word)
                        .font(.custom("NeueHaasDisplay-Roman", size: 18))
                        .foregroundStyle(.black)
                        .lineLimit(3)
                    Text(item.translation)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Save actions

    private var saveActions: some View {
        HStack(spacing: 12) {
            ActionCard(
                title: isSavingNewDeck ? "Saving…" : "Create New Deck",
                systemImage: isSavingNewDeck ? "arrow.up.circle" : "square.stack.3d.up",
                isPrimary: false
            ) {
                Haptics.medium()
                showCreateCover = true
            }
            .disabled(selectedItems.isEmpty || isSavingNewDeck)
            ActionCard(title: "Save to Deck", systemImage: "plus.circle", isPrimary: true) {
                Haptics.medium()
                showDeckPicker = true
            }
            .disabled(selectedItems.isEmpty || isSavingNewDeck)
        }
    }

    // MARK: Selection helpers

    private func currentItems(_ extraction: DeckGenerator.MediaLinkExtraction) -> [GeneratedItem] {
        switch segment {
        case .words:     return extraction.words
        case .sentences: return extraction.sentences
        }
    }

    // Returns a Binding into whichever per-segment selection set is
    // active, so the row + select-all controls mutate the right one.
    private func currentSelectionBinding() -> Binding<Set<UUID>> {
        switch segment {
        case .words:
            return Binding(get: { selectedWordIDs }, set: { selectedWordIDs = $0 })
        case .sentences:
            return Binding(get: { selectedSentenceIDs }, set: { selectedSentenceIDs = $0 })
        }
    }

    private func allSelected(_ items: [GeneratedItem], _ selection: Set<UUID>) -> Bool {
        !items.isEmpty && selection.count == items.count
    }

    // The currently-selected items in the active segment — what the
    // save actions operate on.
    private var selectedItems: [GeneratedItem] {
        guard let extraction else { return [] }
        switch segment {
        case .words:
            return extraction.words.filter { selectedWordIDs.contains($0.id) }
        case .sentences:
            return extraction.sentences.filter { selectedSentenceIDs.contains($0.id) }
        }
    }

    // Media is foreign-source. On a successful fetch, runFetch syncs the
    // language + dialect pickers to the detected language and a valid
    // dialect for it, so the saved deck simply reads those bindings —
    // guaranteeing the chip, the attributes row, and the deck all match
    // and that (language, dialect) is always a real schema pair.
    private var resolvedLanguage: String { language }
    private var resolvedDialect: String { dialect }

    private var contentType: String {
        segment == .words ? "Words" : "Sentences"
    }

    // MARK: Fetch

    private func startFetch() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }
        Task { await runFetch(trimmed) }
    }

    @MainActor
    private func runFetch(_ url: String) async {
        isProcessing = true
        didFailToRecognize = false
        defer { isProcessing = false }
        do {
            let result = try await DeckGenerator.extractFromMediaLink(
                url: url,
                foreignLanguage: language,
                dialect: dialect,
                level: level
            )
            guard result.recognized else {
                Haptics.error()
                extraction = nil
                didFailToRecognize = true
                return
            }
            Haptics.success()
            extraction = result
            // Auto-set the language + dialect pickers from the detected
            // language so the saved deck falls into the existing
            // (language, dialect) schema. `canonicalLanguageName` maps
            // Claude's name onto the app's canonical list (e.g.
            // "Mandarin" → "Chinese (Mandarin)"); `dialects(for:)`
            // always yields at least ["Standard"], so the first entry is
            // a valid dialect for that language.
            let canonical = canonicalLanguageName(result.resolvedLanguage)
            language = canonical
            dialect = dialects(for: canonical).first ?? "Standard"
            // Default to everything selected in both lists so the user
            // can save in one tap, then trim down if they want.
            selectedWordIDs = Set(result.words.map(\.id))
            selectedSentenceIDs = Set(result.sentences.map(\.id))
            // Open on whichever list actually has content.
            segment = result.words.isEmpty && !result.sentences.isEmpty ? .sentences : .words
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    // MARK: Save flows

    private var defaultDeckTitle: String {
        guard let title = extraction?.title, !title.isEmpty else {
            return "Lyrics – Picks"
        }
        let base = title.prefix(36)
        return segment == .words ? "\(base) – Words" : "\(base) – Sentences"
    }

    @MainActor
    private func saveAsNewDeck(title: String, style: DeckCoverStyle, isPublic: Bool) async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        isSavingNewDeck = true
        defer { isSavingNewDeck = false }
        let saveLanguage = resolvedLanguage
        let saveDialect = resolvedDialect
        let deck = GeneratedDeck(
            title: title,
            items: items.map { $0.withLanguage(saveLanguage) },
            language: saveLanguage,
            dialect: saveDialect,
            level: level,
            contentType: contentType,
            amount: "\(items.count)",
            tones: [],
            interests: [],
            userPrompt: "Song or video link",
            promptSent: "",
            rawJSON: ""
        )
        do {
            _ = try await FirebaseDeckService.saveDeck(
                deck,
                title: title,
                coverStyle: style.rawValue,
                isPublic: isPublic
            )
            Haptics.success()
            onSaved()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }
}
