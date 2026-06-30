import SwiftUI
import Speech
import AVFoundation

// Direct page (Create New Deck → page 3). A lightweight translator
// surface: type or speak something in either English or the user's
// target language and the other side appears beneath it. Claude
// auto-detects direction so the user doesn't have to flip a toggle.
// Same two Save actions DeckResultsView and CameraPage use.

// MARK: - Speech-to-text controller

@Observable
@MainActor
final class SpeechDictation {
    enum State { case idle, listening, denied }
    var state: State = .idle
    var transcript: String = ""

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var currentLocaleID: String?

    // Asks for both speech recognition + microphone permission, then
    // boots an `AVAudioEngine` tap that feeds buffers into Apple's
    // on-device recognizer.
    func start(localeID: String) async {
        guard state != .listening else { return }
        let speechAuth = await requestSpeechAuth()
        let micAuth = await requestMicAuth()
        guard speechAuth, micAuth else {
            state = .denied
            return
        }

        // Recreate the recognizer if the user changed languages
        // between sessions (different locale → different model).
        if currentLocaleID != localeID || recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
            currentLocaleID = localeID
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .denied
            return
        }

        do {
            try configureAudioSession()
        } catch {
            state = .idle
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanup()
            state = .idle
            return
        }

        transcript = ""
        state = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self?.stop()
                    }
                }
                if error != nil {
                    self?.stop()
                }
            }
        }
    }

    func stop() {
        cleanup()
        state = .idle
    }

    private func cleanup() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

// MARK: - Page

struct DirectPage: View {
    @Binding var language: String
    @Binding var dialect: String
    let level: String
    let onAttributeTap: (DeckAttribute) -> Void
    let onSaved: () -> Void

    @State private var inputText: String = ""
    @State private var translated: DeckGenerator.DirectTranslateResult?
    @State private var isTranslating = false
    @State private var errorText: String?
    @State private var showDeckPicker = false
    @State private var showCreateCover = false
    @State private var isSavingNewDeck = false
    @State private var dictation = SpeechDictation()
    @FocusState private var isInputFocused: Bool

    // Two input modes: the original type/speak translator, and a new
    // Conversation mode that records far-field audio, transcribes the
    // whole clip, then translates + extracts study picks.
    private enum InputMode: String, CaseIterable {
        case translate = "Translate"
        case conversation = "Conversation"
    }
    @State private var mode: InputMode = .translate

    // Conversation-mode state.
    @State private var recorder = ConversationRecorder()
    @State private var isTranscribing = false
    @State private var isAnalyzing = false
    @State private var conversationTranscript = ""
    @State private var conversationAnalysis: DeckGenerator.ConversationAnalysis?
    @State private var selectedConvItemIDs: Set<UUID> = []
    @State private var showConvDeckPicker = false
    @State private var showConvCreateCover = false
    @State private var isSavingConvDeck = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                attributesSection
                modePicker
                if mode == .translate {
                    inputCard
                    actionRow
                    resultSection
                    saveActions
                } else {
                    conversationSection
                }
            }
            .padding(.horizontal, 8)
            // Clears the parent sheet's custom close-X overlay
            // (8pt top inset + 36pt circle = 44pt) plus breathing room.
            .padding(.top, 80)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isInputFocused = false }
        )
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: $showDeckPicker) {
            if let item = translated?.item {
                DeckPickerSheet(
                    itemsToAdd: [item],
                    sourceLanguage: language,
                    sourceDialect: dialect,
                    onAdded: {
                        showDeckPicker = false
                        clear()
                        onSaved()
                    }
                )
            }
        }
        .sheet(isPresented: $showCreateCover) {
            if let item = translated?.item {
                DeckCoverCustomizationSheet(
                    initialTitle: deckTitle(for: item),
                    language: language,
                    level: level
                ) { newTitle, chosenStyle, isPublic in
                    showCreateCover = false
                    Task {
                        await saveAsNewDeck(
                            item: item,
                            title: newTitle,
                            style: chosenStyle,
                            isPublic: isPublic
                        )
                    }
                }
                .presentationDetents([.fraction(0.8), .large])
            }
        }
        // Conversation-mode save sheets.
        .sheet(isPresented: $showConvDeckPicker) {
            DeckPickerSheet(
                itemsToAdd: selectedConvItems,
                sourceLanguage: convLanguage,
                sourceDialect: convDialect,
                onAdded: {
                    showConvDeckPicker = false
                    resetConversation()
                    onSaved()
                }
            )
        }
        .sheet(isPresented: $showConvCreateCover) {
            DeckCoverCustomizationSheet(
                initialTitle: convDeckTitle,
                language: convLanguage,
                level: level
            ) { newTitle, chosenStyle, isPublic in
                showConvCreateCover = false
                Task {
                    await saveConversationAsNewDeck(
                        title: newTitle,
                        style: chosenStyle,
                        isPublic: isPublic
                    )
                }
            }
            .presentationDetents([.fraction(0.8), .large])
        }
        // Mirror the dictation transcript into the editable text field
        // so the user can tweak after speaking.
        .onChange(of: dictation.transcript) { _, new in
            inputText = new
        }
        // A finished recording (manual stop OR auto-stop at 60s) kicks
        // off transcription + analysis.
        .onChange(of: recorder.finishedURL) { _, url in
            if let url { Task { await handleRecording(url) } }
        }
        .onDisappear {
            dictation.stop()
            recorder.cancel()
        }
    }

    // MARK: Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(InputMode.allCases, id: \.self) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Attributes

    private var attributesSection: some View {
        HStack(alignment: .top, spacing: 12) {
            attribute(.language, value: language)
            attribute(.dialect, value: dialect)
            Spacer(minLength: 0)
        }
    }

    private func attribute(_ kind: DeckAttribute, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title)
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .foregroundStyle(.black)
                .lineLimit(1)
            Button {
                Haptics.light()
                onAttributeTap(kind)
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.custom("NeueHaasDisplay-Light", size: 16))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Input card

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type or speak")
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            TextField(
                "English or \(language)…",
                text: $inputText,
                axis: .vertical
            )
            .font(.custom("NeueHaasDisplay-Roman", size: 22))
            .foregroundStyle(.primary)
            .textFieldStyle(.plain)
            .lineLimit(2...6)
            .focused($isInputFocused)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    // MARK: Action row (mic + Translate)

    private var actionRow: some View {
        HStack(spacing: 12) {
            micButton
            translateButton
        }
    }

    // Borrows the SpeakWaveformButton's interaction vocabulary
    // (.symbolEffect on a waveform) so users recognize it as "voice"
    // input. Toggles between mic / mic.fill while recording.
    private var micButton: some View {
        Button {
            Haptics.light()
            toggleDictation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: dictation.state == .listening ? "mic.fill" : "mic")
                    .font(.system(size: 16, weight: .semibold))
                Text(dictation.state == .listening ? "Listening…" : "Speak")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
            }
            .foregroundStyle(dictation.state == .listening ? .white : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    dictation.state == .listening ? Color.red : Color(white: 0.93)
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(dictation.state == .denied)
    }

    private var translateButton: some View {
        Button {
            Haptics.medium()
            Task { await translate() }
        } label: {
            HStack(spacing: 8) {
                if isTranslating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(isTranslating ? "Translating…" : "Translate")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.black))
        }
        .buttonStyle(.plain)
        .disabled(isTranslating || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Result section

    @ViewBuilder
    private var resultSection: some View {
        if let result = translated {
            let item = result.item
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(result.direction == .fromEnglish ? "English → \(language)" : "\(language) → English")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.translation)
                        .font(.custom("NeueHaasDisplay-Roman", size: 20))
                        .foregroundStyle(.black)
                    Text(item.word)
                        .font(.custom("NeueHaasDisplay-Roman", size: 26))
                        .foregroundStyle(.black)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 14))
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .padding(.horizontal, 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )
            }
        }
    }

    // MARK: Save actions (mirrors DeckResultsView / CameraPage)

    @ViewBuilder
    private var saveActions: some View {
        if translated != nil {
            HStack(spacing: 12) {
                ActionCard(
                    title: isSavingNewDeck ? "Saving…" : "Create New Deck",
                    systemImage: isSavingNewDeck ? "arrow.up.circle" : "square.stack.3d.up",
                    isPrimary: false
                ) {
                    Haptics.medium()
                    showCreateCover = true
                }
                .disabled(isSavingNewDeck)
                ActionCard(title: "Save to Deck", systemImage: "plus.circle", isPrimary: true) {
                    Haptics.medium()
                    showDeckPicker = true
                }
                .disabled(isSavingNewDeck)
            }
        }
    }

    // MARK: Translate

    @MainActor
    private func translate() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if dictation.state == .listening { dictation.stop() }
        isInputFocused = false
        isTranslating = true
        defer { isTranslating = false }
        do {
            let result = try await DeckGenerator.directTranslate(
                text: text,
                foreignLanguage: language,
                dialect: dialect
            )
            Haptics.success()
            translated = result
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    // MARK: Dictation toggle

    private func toggleDictation() {
        switch dictation.state {
        case .listening:
            dictation.stop()
        case .idle:
            // Foreign locale by default — Apple's recognizer handles
            // most English-in-foreign-locale cases acceptably, and
            // Claude does the actual direction detection at translate
            // time, so accuracy isn't critical here.
            let localeID = appleSpeechLocale(for: language) ?? "en-US"
            Task { await dictation.start(localeID: localeID) }
        case .denied:
            errorText = "Enable Microphone and Speech Recognition for TONGUES in Settings."
        }
    }

    // MARK: Conversation mode

    @ViewBuilder
    private var conversationSection: some View {
        if let analysis = conversationAnalysis {
            conversationResult(analysis)
        } else {
            recorderCard
            if isTranscribing || isAnalyzing {
                convProcessingBanner
            }
        }
    }

    private var recorderCard: some View {
        VStack(spacing: 18) {
            Text("Put your phone down and record up to a minute of a conversation. We'll transcribe and translate the whole thing.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.medium()
                toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.black)
                        .frame(width: 84, height: 84)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing || isAnalyzing)

            Text(timerText)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .red : .secondary)

            levelMeter
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.88), lineWidth: 1)
        )
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.92))
                Capsule()
                    .fill(Color.red)
                    .frame(width: geo.size.width * recorder.level)
            }
        }
        .frame(height: 6)
        .opacity(recorder.isRecording ? 1 : 0.25)
        .animation(.linear(duration: 0.05), value: recorder.level)
    }

    private var timerText: String {
        let cur = Int(recorder.elapsed)
        let maxS = Int(recorder.maxDuration)
        return String(format: "%d:%02d / %d:%02d", cur / 60, cur % 60, maxS / 60, maxS % 60)
    }

    private var convProcessingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.black)
            Text(isTranscribing ? "Transcribing the recording…" : "Translating + finding study words…")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.92), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func conversationResult(_ analysis: DeckGenerator.ConversationAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Detected language + record-again.
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text("Detected: \(analysis.resolvedLanguage)")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.06)))
                Spacer()
                Button("Record again") {
                    Haptics.light()
                    resetConversation()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
            }

            // Transcript + translation.
            VStack(alignment: .leading, spacing: 14) {
                convTextBlock(label: "Transcript", text: conversationTranscript, prominent: true)
                if !analysis.translation.isEmpty {
                    convTextBlock(label: "Translation", text: analysis.translation, prominent: false)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )

            // Study items multi-select.
            if analysis.items.isEmpty {
                Text("No study-worthy words found in that clip.")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Study picks · hardest first")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Text("\(selectedConvItemIDs.count) / \(analysis.items.count)")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                    Button(allConvSelected(analysis) ? "Deselect all" : "Select all") {
                        Haptics.light()
                        if allConvSelected(analysis) {
                            selectedConvItemIDs.removeAll()
                        } else {
                            selectedConvItemIDs = Set(analysis.items.map(\.id))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                }
                VStack(spacing: 0) {
                    ForEach(analysis.items) { item in
                        convItemRow(item)
                        if item.id != analysis.items.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )

                conversationSaveActions
            }
        }
    }

    private func convTextBlock(label: String, text: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(text)
                .font(.custom("NeueHaasDisplay-Roman", size: prominent ? 17 : 15))
                .foregroundStyle(prominent ? .black : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func convItemRow(_ item: GeneratedItem) -> some View {
        let selected = selectedConvItemIDs.contains(item.id)
        return Button {
            Haptics.light()
            if selected { selectedConvItemIDs.remove(item.id) }
            else { selectedConvItemIDs.insert(item.id) }
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
                        .lineLimit(2)
                    Text(item.translation)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

    private var conversationSaveActions: some View {
        HStack(spacing: 12) {
            ActionCard(
                title: isSavingConvDeck ? "Saving…" : "Create New Deck",
                systemImage: isSavingConvDeck ? "arrow.up.circle" : "square.stack.3d.up",
                isPrimary: false
            ) {
                Haptics.medium()
                showConvCreateCover = true
            }
            .disabled(selectedConvItems.isEmpty || isSavingConvDeck)
            ActionCard(title: "Save to Deck", systemImage: "plus.circle", isPrimary: true) {
                Haptics.medium()
                showConvDeckPicker = true
            }
            .disabled(selectedConvItems.isEmpty || isSavingConvDeck)
        }
    }

    private func allConvSelected(_ analysis: DeckGenerator.ConversationAnalysis) -> Bool {
        !analysis.items.isEmpty && selectedConvItemIDs.count == analysis.items.count
    }

    private var convLanguage: String { conversationAnalysis?.resolvedLanguage ?? language }
    private var convDialect: String { conversationAnalysis?.resolvedDialect ?? dialect }
    private var selectedConvItems: [GeneratedItem] {
        guard let analysis = conversationAnalysis else { return [] }
        return analysis.items.filter { selectedConvItemIDs.contains($0.id) }
    }
    private var convDeckTitle: String { "Conversation – Picks" }

    // MARK: Conversation handlers

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            do {
                try recorder.start()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    @MainActor
    private func handleRecording(_ url: URL) async {
        isTranscribing = true
        do {
            // Best-effort locale from the selected language; Claude
            // re-detects + cleans up afterward, so an imperfect locale
            // still yields usable text.
            let locale = appleSpeechLocale(for: language) ?? "en-US"
            let text = try await SpeechRecognitionService.transcribeFile(at: url, locale: locale)
            try? FileManager.default.removeItem(at: url)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            isTranscribing = false
            guard !trimmed.isEmpty else {
                errorText = "Couldn't make out any speech in that recording. Try again a bit closer, or in a quieter spot."
                return
            }
            conversationTranscript = trimmed
            await runConversationAnalysis()
        } catch {
            isTranscribing = false
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func runConversationAnalysis() async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let analysis = try await DeckGenerator.analyzeConversation(
                transcript: conversationTranscript,
                foreignLanguage: language,
                dialect: dialect,
                level: level
            )
            Haptics.success()
            conversationAnalysis = analysis
            selectedConvItemIDs = Set(analysis.items.map(\.id))
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func saveConversationAsNewDeck(title: String, style: DeckCoverStyle, isPublic: Bool) async {
        let items = selectedConvItems
        guard !items.isEmpty else { return }
        isSavingConvDeck = true
        defer { isSavingConvDeck = false }
        let deck = GeneratedDeck(
            title: title,
            items: items.map { $0.withLanguage(convLanguage) },
            language: convLanguage,
            dialect: convDialect,
            level: level,
            contentType: "Words",
            amount: "\(items.count)",
            tones: [],
            interests: [],
            userPrompt: "Conversation",
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
            resetConversation()
            onSaved()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private func resetConversation() {
        conversationTranscript = ""
        conversationAnalysis = nil
        selectedConvItemIDs = []
    }

    // MARK: Save flows

    private func clear() {
        inputText = ""
        translated = nil
    }

    private func deckTitle(for item: GeneratedItem) -> String {
        let label = item.translation.capitalized
        return "\(label) – Direct"
    }

    @MainActor
    private func saveAsNewDeck(
        item: GeneratedItem,
        title: String,
        style: DeckCoverStyle,
        isPublic: Bool
    ) async {
        isSavingNewDeck = true
        defer { isSavingNewDeck = false }
        let deck = GeneratedDeck(
            title: title,
            items: [item.withLanguage(language)],
            language: language,
            dialect: dialect,
            level: level,
            contentType: "Words",
            amount: "1",
            tones: [],
            interests: [],
            userPrompt: "Direct translation",
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
            clear()
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
