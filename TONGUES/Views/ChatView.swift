import SwiftUI

struct ChatView: View {
    @State private var vm = ChatViewModel()
    @State private var auth = AuthService.shared
    @State private var speech = SpeechRecognitionService.shared
    // Curriculum → Chat hand-off. PlanView drops a scenario here and flips
    // to this tab; we consume it below by opening the scenario conversation.
    @State private var launchRouter = ChatLaunchRouter.shared
    @FocusState private var inputFocused: Bool

    @State private var languagePickerPresented = false
    @State private var selectedLanguage: String = "Spanish"
    @State private var selectedDialect: String = "Castilian (Spain)"
    @State private var selectedLevel: String = "B1"

    @State private var saveSheetItem: GeneratedItem?
    @State private var saveSourceMessageID: UUID?
    @State private var savedToast: String?
    @State private var recapSheetPresented = false
    @State private var showClearConfirm = false
    @State private var userInterests: [String] = []
    @State private var historySheetPresented = false
    @State private var drillTarget: ConversationMessage?
    // Presents the dynamic grammatical breakdown sheet for an AI message.
    @State private var grammarTarget: ConversationMessage?

    // Auto-mic state. The mic stays hot while the user is engaged in
    // a conversation. Silence detection in SpeechRecognitionService
    // (2.5s of quiet after speech) ends the turn and auto-sends; the
    // reconciler restarts listening once the AI has replied. The mic
    // button in the input bar is a manual fallback — tap to stop and
    // drop the partial transcript into the input field (no forced
    // send), or tap to start a fresh listen session.
    @State private var hasMicAuth: Bool = false

    // Tracks the most recently auto-played assistant message so we
    // don't re-speak historical messages on conversation load or on
    // every view refresh. `isSpeakingPlayback` is a reconciler input
    // so the mic stays muted while the AI's voice plays back — without
    // it the recognizer would transcribe its own output.
    @State private var lastSpokenMessageID: UUID?
    @State private var isSpeakingPlayback: Bool = false
    // True only while the chat tab is the front-of-screen view. Used
    // to suppress auto-speech when the user is on another tab — we
    // don't want random foreign-language playback while they're
    // browsing the library or explore tabs.
    @State private var isChatTabActive: Bool = false

    // Height of the languageHeader row that used to sit below the
    // navigation bar before the language moved into the toolbar. Used
    // as a fixed top inset so message lines keep their old starting Y.
    private let removedHeaderOffset: CGFloat = 54

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chatContent
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // Preserves the vertical starting position of
                        // message lines now that the standalone
                        // languageHeader has moved into the toolbar.
                        Color.clear.frame(height: removedHeaderOffset)
                    }

                inputBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        Task { await vm.loadConversationList() }
                        historySheetPresented = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: MacLayout.f(18), weight: .regular))
                            .foregroundStyle(.black)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        languagePickerPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedLanguage)
                                .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(14)))
                                .foregroundStyle(.black)
                            Image(systemName: "chevron.down")
                                .font(.system(size: MacLayout.f(10), weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Haptics.light()
                            Task { await vm.buildRecap() }
                            recapSheetPresented = true
                        } label: {
                            Label(L("End & Recap"), systemImage: "checkmark.seal")
                        }
                        .disabled(vm.conversation?.messages.isEmpty != false)

                        Button(role: .destructive) {
                            Haptics.medium()
                            showClearConfirm = true
                        } label: {
                            Label(L("Clear conversation"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.black)
                    }
                }
            }
            .sheet(item: $drillTarget) { message in
                if let conversation = vm.conversation {
                    PronunciationDrillSheet(
                        target: message.text,
                        transliteration: message.transliteration,
                        language: conversation.language,
                        dialect: conversation.dialect
                    )
                }
            }
            .sheet(item: $grammarTarget) { message in
                if let conversation = vm.conversation {
                    GrammarBreakdownSheet(
                        sentence: message.text,
                        language: conversation.language,
                        dialect: conversation.dialect
                    )
                }
            }
            .sheet(isPresented: $historySheetPresented) {
                ChatHistorySheet(
                    language: selectedLanguage,
                    isLoading: vm.isLoadingList,
                    conversations: vm.conversationList,
                    currentConversationID: vm.conversation?.id,
                    onNewChat: {
                        vm.startNewConversation()
                        historySheetPresented = false
                    },
                    onOpen: { conversation in
                        Task { await vm.openConversation(conversation) }
                        historySheetPresented = false
                    },
                    onDelete: { conversation in
                        Task { await vm.deleteConversation(id: conversation.id) }
                    },
                    onRefresh: {
                        await vm.loadConversationList(refresh: true)
                    }
                )
            }
            .sheet(isPresented: $languagePickerPresented) {
                ConversationLanguagePickerSheet(
                    selectedLanguage: $selectedLanguage,
                    selectedDialect: $selectedDialect,
                    selectedLevel: $selectedLevel,
                    onConfirm: {
                        languagePickerPresented = false
                        Task {
                            await vm.switchLanguage(
                                to: selectedLanguage,
                                dialect: selectedDialect,
                                level: selectedLevel
                            )
                        }
                    }
                )
            }
            .sheet(item: $saveSheetItem) { item in
                if let conversation = vm.conversation {
                    DeckPickerSheet(
                        itemsToAdd: [item],
                        sourceLanguage: conversation.language,
                        sourceDialect: conversation.dialect,
                        onAdded: {
                            if let msgID = saveSourceMessageID {
                                vm.markSaved(messageID: msgID, itemID: item.id)
                            }
                            saveSheetItem = nil
                            saveSourceMessageID = nil
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                savedToast = L("Saved “%@”", item.word)
                            }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation { savedToast = nil }
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $recapSheetPresented) {
                if let conversation = vm.conversation {
                    ConversationRecapSheet(
                        isBuilding: vm.isBuildingRecap,
                        recap: vm.pendingRecap,
                        language: conversation.language,
                        dialect: conversation.dialect,
                        onSaved: {
                            recapSheetPresented = false
                            vm.pendingRecap = nil
                            // Finishing a recap counts as a completed
                            // conversation session for any active
                            // curriculum unit's conversation-check gate.
                            Task { await vm.markPlanConversationDone() }
                            // Recap-save means the user is *done* with
                            // this thread, not that they want to discard
                            // it — keep the conversation in their
                            // history and spin up a fresh in-memory
                            // chat for the next session.
                            vm.startNewConversation()
                        },
                        onDismiss: {
                            recapSheetPresented = false
                            vm.pendingRecap = nil
                        }
                    )
                }
            }
            .alert(
                L("Clear this conversation?"),
                isPresented: $showClearConfirm
            ) {
                Button(L("Clear"), role: .destructive) {
                    Task { await vm.clearCurrentConversation() }
                }
                Button(L("Cancel"), role: .cancel) { }
            } message: {
                Text(L("Your saved phrases stay in your decks."))
            }
            .overlay(alignment: .top) {
                if let toast = savedToast {
                    Text(toast)
                        .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(14)))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.88), in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if let callout = vm.translationCallout {
                    translationCalloutOverlay(callout)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.translationCallout)
        }
        .task {
            // Seed from the user's preferred language on first appear.
            if vm.conversation == nil {
                await seedFromProfile()
                await vm.switchLanguage(
                    to: selectedLanguage,
                    dialect: selectedDialect,
                    level: selectedLevel
                )
            }
            // Seed the auto-playback bookkeeper with the last existing
            // assistant message so we don't re-speak history on load.
            lastSpokenMessageID = vm.conversation?.messages.last?.id
            // Resolve mic auth so the reconciler can open the mic
            // immediately if granted.
            let status = SpeechRecognitionService.currentAuthorization()
            if status == .undetermined {
                let granted = await SpeechRecognitionService.requestAuthorization()
                hasMicAuth = granted == .authorized
            } else {
                hasMicAuth = status == .authorized
            }
            // A curriculum "Start" tap may have queued a scenario before
            // this tab first appeared — consume it once seeding is done.
            await consumePendingLaunch()
            reconcileMic()
        }
        .onChange(of: inputFocused) { _, _ in reconcileMic() }
        .onChange(of: vm.isSending) { wasSending, isSending in
            reconcileMic()
            // Auto-speech only fires on the falling edge of a send the
            // user themselves initiated (their own message OR a
            // scenario tap). Loading a conversation from history or
            // launching the app — neither flips isSending — therefore
            // can't trigger random playback.
            if wasSending, !isSending, isChatTabActive {
                speakLatestAssistantMessageIfNew()
            }
        }
        .onChange(of: vm.isLoadingConversation) { _, _ in reconcileMic() }
        .onChange(of: isSpeakingPlayback) { _, _ in reconcileMic() }
        // Suspend / resume the auto-mic as the stuck-helper opens and
        // closes so it can't compete with the suggestion flow.
        .onChange(of: vm.isSuggesting) { _, _ in reconcileMic() }
        .onChange(of: vm.suggestions.isEmpty) { _, _ in reconcileMic() }
        .onChange(of: vm.conversation?.id) { _, _ in
            if speech.isRecording { speech.stop() }
            // Stale hints belong to the thread we're leaving.
            vm.suggestions = []
            // New conversation: anchor playback to its current tail so
            // historical messages don't auto-play on switch-in.
            lastSpokenMessageID = vm.conversation?.messages.last?.id
            // Sync the toolbar language pill (and dialect/level used by
            // the picker sheet + input bar placeholder) to whatever
            // conversation just became active — without this, opening
            // a Spanish thread from history while the toolbar still
            // reads "Japanese" leaves the user confused about which
            // language they're actually replying in.
            if let conversation = vm.conversation {
                selectedLanguage = conversation.language
                selectedDialect = conversation.dialect
                selectedLevel = conversation.level
            }
            reconcileMic()
        }
        .onChange(of: selectedLanguage) { _, _ in
            if speech.isRecording { speech.stop() }
            reconcileMic()
        }
        // Fires when PlanView requests a curriculum conversation while the
        // chat tab is already alive (the common case — the tab is resident
        // in the TabView even when not front-of-screen).
        .onChange(of: launchRouter.pending) { _, newValue in
            if newValue != nil {
                Task { await consumePendingLaunch() }
            }
        }
        .onAppear { isChatTabActive = true }
        .onDisappear {
            isChatTabActive = false
            speech.stop()
        }
    }

    // MARK: - Content switch

    @ViewBuilder
    private var chatContent: some View {
        if vm.isLoadingConversation {
            conversationSkeleton
        } else if let conversation = vm.conversation, conversation.messages.isEmpty {
            scenarioStartersStrip(conversation: conversation)
        } else {
            messageList
        }
    }

    // MARK: - Empty-state scenario strip

    @ViewBuilder
    private func scenarioStartersStrip(conversation: Conversation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Start a conversation"))
                        .font(.custom("PlayfairDisplay-Regular", size: MacLayout.f(28)))
                        .tracking(-1.5)
                        .foregroundStyle(.black)
                    Text(L("Pick a scenario or just say hi."))
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(15)))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)

                // Tutor-agent quick starts: planning and placement live a
                // tier above the roleplay scenarios.
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("YOUR TUTOR"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(11)))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 10) {
                        tutorChip(
                            title: L("Make me a study plan"),
                            systemImage: "map"
                        ) {
                            vm.input = L("Make me a study plan for %@ based on my goals and progress.", conversation.language)
                            Task { await vm.send() }
                        }
                        tutorChip(
                            title: L("What should I work on?"),
                            systemImage: "scope"
                        ) {
                            vm.input = L("What should I work on next in %@?", conversation.language)
                            Task { await vm.send() }
                        }
                        tutorChip(
                            title: L("Check my level"),
                            systemImage: "checkmark.seal"
                        ) {
                            Task { await vm.startPlacement() }
                        }
                    }
                }
                .padding(.horizontal, 16)

                let scenarios = ConversationScenario.curated
                    + ConversationScenario.fromInterests(userInterestsForScenarios())

                FlowLayout(spacing: 10) {
                    ForEach(scenarios) { scenario in
                        Button {
                            Haptics.light()
                            inputFocused = false
                            Task { await vm.sendScenario(scenario) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: scenario.systemImage)
                                    .font(.system(size: MacLayout.f(13)))
                                Text(scenario.title)
                                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .overlay(
                                Capsule().stroke(Color.black.opacity(0.18))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 80)
            }
        }
    }

    private func userInterestsForScenarios() -> [String] {
        userInterests
    }

    private func tutorChip(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            inputFocused = false
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: MacLayout.f(13)))
                Text(title)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let conversation = vm.conversation {
                        ForEach(conversation.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    if vm.isSending {
                        typingIndicator
                            .id("typing")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .onChange(of: vm.conversation?.messages.count) { _, _ in
                if let last = vm.conversation?.messages.last {
                    withAnimation(.smooth(duration: 0.4)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.isSending) { _, sending in
                if sending {
                    withAnimation(.smooth(duration: 0.3)) {
                        proxy.scrollTo("typing", anchor: .bottom)
                    }
                }
            }
        }
    }

    // Placeholder chat bubbles shown while a conversation loads, mirroring the
    // alternating assistant/user layout with a looping shimmer so the wait
    // reads as "messages are arriving" rather than a bare spinner.
    private var conversationSkeleton: some View {
        ScrollView {
            VStack(spacing: 16) {
                bubbleSkeleton(fromUser: false, width: 240)
                bubbleSkeleton(fromUser: true, width: 170)
                bubbleSkeleton(fromUser: false, width: 260)
                bubbleSkeleton(fromUser: true, width: 140)
                bubbleSkeleton(fromUser: false, width: 210)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .modifier(ConversationSkeletonShimmer())
    }

    @ViewBuilder
    private func bubbleSkeleton(fromUser: Bool, width: CGFloat) -> some View {
        HStack {
            if fromUser { Spacer(minLength: 40) }
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: fromUser ? 0.88 : 0.93))
                .frame(width: width, height: 44)
            if !fromUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func messageRow(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if message.role == .user {
                    userBubble(message)
                } else if !message.text.isEmpty {
                    // Attachment-only carrier messages skip the bubble.
                    assistantBubble(message)
                }

                if message.role == .assistant, let attachment = message.attachment {
                    attachmentCard(attachment, messageID: message.id)
                        .frame(maxWidth: MacLayout.s(300), alignment: .leading)
                }

                if let corrections = message.corrections, !corrections.isEmpty {
                    CorrectionDecoration(corrections: corrections)
                        .frame(maxWidth: MacLayout.s(320), alignment: .trailing)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Agent attachment cards

    @ViewBuilder
    private func attachmentCard(_ attachment: MessageAttachment, messageID: UUID) -> some View {
        switch attachment {
        case .deckProposal(let payload):
            DeckProposalCard(payload: payload) {
                Haptics.medium()
                Task {
                    if let title = await vm.saveProposedDeck(messageID: messageID) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            savedToast = L("Saved “%@”", title)
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { savedToast = nil }
                        }
                    }
                }
            }
        case .planProposal(let payload):
            PlanProposalCard(payload: payload) {
                Haptics.medium()
                Task {
                    if await vm.acceptProposedPlan(messageID: messageID) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            savedToast = L("Plan saved — see the Explore tab")
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(2.4))
                            withAnimation { savedToast = nil }
                        }
                    }
                }
            }
        case .planUpdate(let payload):
            PlanUpdateCard(payload: payload)
        case .progressSnapshot(let payload):
            ProgressSnapshotCard(payload: payload)
        case .placementResult(let payload):
            PlacementResultCard(payload: payload)
        case .unsupported:
            EmptyView()
        }
    }

    private func userBubble(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(16)))
                .foregroundStyle(.white)
                // Cap the text's frame width so long messages wrap to
                // multiple lines and the bubble grows vertically instead of
                // pushing past the screen edge. Mirrors the assistant
                // bubble's 280pt ceiling. Short messages still hug their
                // intrinsic width because `maxWidth` is an upper bound, not
                // a fixed size.
                .frame(maxWidth: MacLayout.s(280), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // Pinyin for the learner's own Chinese turns, generated by
            // the background analysis pass. Matches the romanization the
            // assistant bubble shows, just tinted for the dark bubble.
            if let translit = message.transliteration, !translit.isEmpty {
                Text(translit)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .italic()
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: MacLayout.s(280), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
        .clipShape(
            .rect(cornerRadii: RectangleCornerRadii(
                topLeading: 18,
                bottomLeading: 18,
                bottomTrailing: 4,
                topTrailing: 18
            ))
        )
        // Tap the learner's own bubble to translate it into their
        // native language, surfaced via the shared translation callout.
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            Task { await vm.translateToken(message.text) }
        }
    }

    @ViewBuilder
    private func assistantBubble(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TappableTokenizedText(
                text: message.text,
                onTap: { token in
                    Haptics.light()
                    Task { await vm.translateToken(token) }
                }
            )
            if let translit = message.transliteration, !translit.isEmpty {
                Text(translit)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button {
                    Haptics.light()
                    SpeechClient.shared.speak(
                        message.text,
                        language: vm.conversation?.language,
                        allowForvo: false
                    )
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: MacLayout.f(16)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    Task { await vm.translateToken(message.text) }
                } label: {
                    Image(systemName: "character.bubble")
                        .font(.system(size: MacLayout.f(16)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    drillTarget = message
                } label: {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: MacLayout.f(16)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    grammarTarget = message
                } label: {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: MacLayout.f(16)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.medium()
                    Task { await stageSave(message: message) }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: MacLayout.f(16)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: MacLayout.s(280), alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(libraryHex: "F4F4F4"))
        .clipShape(
            .rect(cornerRadii: RectangleCornerRadii(
                topLeading: 18,
                bottomLeading: 4,
                bottomTrailing: 18,
                topTrailing: 18
            ))
        )
    }

    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: MacLayout.s(6), height: MacLayout.s(6))
                            .opacity(0.4)
                            .scaleEffect(1)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                value: vm.isSending
                            )
                    }
                }
                // Tool-activity chip: while the tutor agent's loop runs,
                // name what it's doing ("Reviewing your decks…") so the
                // extra latency reads as work, not lag.
                if let status = vm.toolStatus {
                    Text(status)
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(libraryHex: "F4F4F4"))
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.2), value: vm.toolStatus)
            Spacer(minLength: 40)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if vm.isSuggesting || !vm.suggestions.isEmpty {
                suggestionsStrip
            }
            Divider()
            HStack(spacing: 10) {
                Button {
                    Task { await micButtonTapped() }
                } label: {
                    Image(systemName: micIconName)
                        .font(.system(size: MacLayout.f(18)))
                        .foregroundStyle(micIconColor)
                        .frame(width: MacLayout.s(40), height: MacLayout.s(40))
                        .background(
                            Circle().fill(Color(libraryHex: "F4F4F4"))
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.conversation == nil)

                // "I'm stuck" helper — fetches a few candidate replies
                // the learner can drop into the field. Disabled while a
                // turn or another fetch is already in flight.
                Button {
                    Haptics.light()
                    // Take the mic offline before opening the helper so a
                    // pending silence-send can't fire mid-selection.
                    speech.onSilenceDetected = nil
                    if speech.isRecording { speech.stop() }
                    inputFocused = false
                    Task { await vm.requestSuggestions() }
                } label: {
                    Image(systemName: "lightbulb")
                        .font(.system(size: MacLayout.f(18)))
                        .foregroundStyle(.black)
                        .frame(width: MacLayout.s(40), height: MacLayout.s(40))
                        .background(
                            Circle().fill(Color(libraryHex: "F4F4F4"))
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.conversation == nil || vm.isSending || vm.isSuggesting)

                TextField(
                    L("Reply in %@…", selectedLanguage),
                    text: $vm.input,
                    axis: .vertical
                )
                .focused($inputFocused)
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(16)))
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(libraryHex: "F4F4F4"))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            Haptics.light()
                            inputFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: MacLayout.f(18), weight: .regular))
                                .foregroundStyle(.black)
                        }
                    }
                }

                Button {
                    Haptics.medium()
                    Task { await vm.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: MacLayout.f(16), weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: MacLayout.s(40), height: MacLayout.s(40))
                        .background(
                            Circle().fill(vm.canSend ? Color.black : Color.black.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Suggested replies ("I'm stuck")

    private var suggestionsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: MacLayout.f(11)))
                Text(vm.isSuggesting
                     ? L("Finding ways to reply…")
                     : L("Not sure what to say? Tap one."))
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(11)))
                    .tracking(0.5)
                Spacer()
                if !vm.suggestions.isEmpty {
                    Button {
                        Haptics.light()
                        vm.suggestions = []
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: MacLayout.f(11), weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.secondary)

            if vm.isSuggesting {
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(libraryHex: "F4F4F4"))
                            .frame(width: MacLayout.s(150), height: MacLayout.s(52))
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.suggestions) { suggestion in
                            suggestionChip(suggestion)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func suggestionChip(_ suggestion: ConversationClient.SuggestedReply) -> some View {
        Button {
            Haptics.light()
            // Take control from the auto-mic so a pending silence-send
            // can't overwrite the staged suggestion or start a second
            // overlapping turn.
            speech.onSilenceDetected = nil
            if speech.isRecording { speech.stop() }
            vm.useSuggestion(suggestion)
            inputFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.foreign)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(14)))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let translit = suggestion.transliteration, !translit.isEmpty {
                    Text(translit)
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(11)))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(suggestion.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: MacLayout.s(220), alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.black.opacity(0.18))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    // Full-screen host for the translation popup: a tap-anywhere-outside
    // scrim behind the card so the user can dismiss without hitting a
    // specific target, plus the card itself pinned above the input bar.
    @ViewBuilder
    private func translationCalloutOverlay(_ callout: ChatViewModel.TranslationCallout) -> some View {
        ZStack(alignment: .bottom) {
            // Tap outside the popup to dismiss.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.light()
                    vm.translationCallout = nil
                }
                .transition(.opacity)

            translateCallout(callout)
                .padding(.bottom, 88)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func translateCallout(_ callout: ChatViewModel.TranslationCallout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(callout.original)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(13)))
                    .foregroundStyle(.white)
                Text(callout.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)

            Button {
                Haptics.light()
                vm.translationCallout = nil
            } label: {
                Text(L("Close"))
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: MacLayout.s(320), alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 4)
        // Swallow taps on the card so they don't fall through to the
        // dismiss scrim behind it.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private var micIconName: String {
        speech.isRecording ? "mic.fill" : "mic"
    }

    private var micIconColor: Color {
        speech.isRecording ? .red : .black
    }

    // MARK: - Auto-mic

    // True when the auto-listen loop should currently be hot.
    private var shouldAutoListen: Bool {
        hasMicAuth
            && !inputFocused
            && !vm.isSending
            && !vm.isLoadingConversation
            && !isSpeakingPlayback
            // While the stuck-helper is open the user is choosing a
            // written reply, not speaking — keep the mic dormant so a
            // silence-send can't clobber the staged suggestion.
            && vm.suggestions.isEmpty
            && !vm.isSuggesting
            && vm.conversation != nil
    }

    // Auto-driver. Only acts when state actually shifts: it never
    // overrides a user-initiated stop, because manual stops don't
    // change any of the observed inputs and so don't re-trigger this.
    private func reconcileMic() {
        if shouldAutoListen, !speech.isRecording {
            startAutoListening()
        } else if !shouldAutoListen, speech.isRecording {
            speech.stop()
        }
    }

    // Reads the latest assistant message aloud in the conversation's
    // language. Skips if we've already spoken this message (so the
    // closure isn't re-triggered by unrelated view updates) and if the
    // last message is from the user (their own utterance shouldn't
    // echo back). Flips `isSpeakingPlayback` so the auto-mic muted
    // itself while the synthesizer is active.
    private func speakLatestAssistantMessageIfNew() {
        guard let conversation = vm.conversation,
              let last = conversation.messages.last,
              last.role == .assistant,
              !last.text.isEmpty,  // Attachment-only carrier messages have no speech.
              lastSpokenMessageID != last.id else { return }
        lastSpokenMessageID = last.id
        isSpeakingPlayback = true
        // Pre-emptively stop the mic so it doesn't pick up the AI's
        // voice before reconcileMic gets a chance to react.
        if speech.isRecording { speech.stop() }
        SpeechClient.shared.speak(
            last.text,
            language: conversation.language,
            allowForvo: false,
            onFinish: {
                Task { @MainActor in
                    isSpeakingPlayback = false
                }
            }
        )
    }

    // Auto-listening session: silence detection auto-sends. After the
    // reply arrives, the isSending onChange will call reconcileMic
    // and re-enter this function for the next turn.
    private func startAutoListening() {
        guard let conversation = vm.conversation else { return }
        let locale = appleSpeechLocale(for: conversation.language) ?? "en-US"
        let viewModel = vm
        let svc = speech
        speech.onSilenceDetected = {
            let text = svc.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            svc.stop()
            guard !text.isEmpty else { return }
            viewModel.input = text
            Task { await viewModel.send() }
        }
        do {
            // A more forgiving trailing-silence window than the 1.6s default
            // so a natural mid-sentence pause / breath doesn't auto-send and
            // cut the user off. Tune here if it feels too slow/eager.
            try speech.start(locale: locale, silenceTimeout: 2.5)
        } catch {
            vm.errorText = error.localizedDescription
        }
    }

    // Manual fallback. Tap while recording = stop and put the partial
    // transcript into the input field (no auto-send — the user is
    // explicitly taking control). Tap while idle = start a fresh
    // listen session that still auto-sends on silence, prompting for
    // mic auth on first use.
    private func micButtonTapped() async {
        if speech.isRecording {
            // Clear the auto-send callback so the (now-cancelled)
            // recognition task can't fire send on its way out.
            speech.onSilenceDetected = nil
            let text = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            speech.stop()
            if !text.isEmpty {
                vm.input = text
            }
            Haptics.light()
            return
        }
        if !hasMicAuth {
            let granted = await SpeechRecognitionService.requestAuthorization()
            hasMicAuth = granted == .authorized
            guard hasMicAuth else {
                // Surface the denial — without this the user just sees
                // the mic button do nothing, and the chat tab's
                // headline feature looks broken.
                vm.errorText = L("Enable Microphone and Speech Recognition for TONGUES in Settings to talk to the chat. You can still type your replies.")
                return
            }
        }
        Haptics.light()
        startAutoListening()
    }

    private func stageSave(message: ConversationMessage) async {
        guard let item = vm.makeItemForSave(
            foreign: message.text,
            translation: ""
        ) else { return }
        // Quick translate first so the deck row carries the English
        // side too. Failures fall through with empty translation.
        if let conversation = vm.conversation {
            let translation = (try? await ConversationClient.quickTranslate(
                message.text,
                in: conversation.language
            )) ?? ""
            saveSourceMessageID = message.id
            saveSheetItem = GeneratedItem(
                word: item.word,
                translation: translation,
                transliteration: message.transliteration,
                language: item.language,
                partsOfSpeech: ["Phrase"],
                addedAt: Date(),
                source: SourcingMethod.conversation.rawValue
            )
        }
    }

    // Opens a curriculum-requested scenario: switch the chat into the
    // plan's language, start a clean thread, and fire the scenario opener.
    // Finishing this chat's recap marks the plan's conversation activity
    // done via ChatViewModel.markPlanConversationDone().
    private func consumePendingLaunch() async {
        guard let launch = launchRouter.pending else { return }
        launchRouter.pending = nil

        selectedLanguage = launch.language
        selectedDialect = launch.dialect
        selectedLevel = launch.level

        await vm.switchLanguage(
            to: launch.language,
            dialect: launch.dialect,
            level: launch.level
        )
        // Always start the scenario in a fresh thread so it isn't appended
        // to whatever conversation happened to be open in this language.
        vm.startNewConversation()
        inputFocused = false
        await vm.sendScenario(ConversationScenario(
            id: "curriculum",
            title: launch.title,
            prompt: launch.prompt,
            systemImage: "bubble.left.and.bubble.right"
        ))
    }

    private func seedFromProfile() async {
        if let profile = try? await UserService.fetchProfile() {
            if let first = profile.onboarding?.languagePreferences?.first {
                selectedLanguage = canonicalLanguageName(first.language)
                selectedDialect = first.dialect
                selectedLevel = first.level
            }
            // Pull the user's onboarding interests so the empty-state
            // chip strip carries personalized starters next to the
            // curated set.
            userInterests = profile.onboarding?.interests ?? []
        }
    }
}

// Sweeps a soft highlight left-to-right across its content on a loop — the
// shimmer that signals the conversation skeleton is loading.
private struct ConversationSkeletonShimmer: ViewModifier {
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

// MARK: - Tap-tokenized text

// Splits the assistant's foreign-language reply into tappable word
// runs separated by whitespace + punctuation. Tapping a word fires
// `onTap` with the bare token (no surrounding punctuation), which the
// view model hands to ConversationClient.quickTranslate.
private struct TappableTokenizedText: View {
    let text: String
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if token.isTappable {
                    Button {
                        onTap(token.value)
                    } label: {
                        Text(token.surface)
                            .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(16)))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(token.surface)
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(16)))
                        .foregroundStyle(.black)
                }
            }
        }
    }

    private struct Token {
        let surface: String      // What we render in the row (includes trailing punctuation).
        let value: String        // Stripped form handed to translate.
        let isTappable: Bool
    }

    private var tokens: [Token] {
        var result: [Token] = []
        // Split on whitespace; punctuation rides with the preceding
        // token so the visual flow matches the source.
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let surface = String(raw)
            let stripped = surface.trimmingCharacters(in: .punctuationCharacters)
            result.append(Token(
                surface: surface,
                value: stripped,
                isTappable: !stripped.isEmpty
            ))
        }
        return result
    }
}

// MARK: - Agent attachment cards
//
// Native renderings of MessageAttachment payloads. Shared visual
// language: white card, hairline border, black primary action — the
// agent proposes, the user disposes.

private struct AgentCardChrome<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: MacLayout.f(11)))
                Text(label)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(11)))
                    .tracking(1.2)
            }
            .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

private struct AgentCardActionButton: View {
    let title: String
    let done: Bool
    let doneTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: MacLayout.f(12), weight: .semibold))
                }
                Text(done ? doneTitle : title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(14)))
            }
            .foregroundStyle(done ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                done ? Color.black.opacity(0.06) : Color.black,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(done)
    }
}

private struct DeckProposalCard: View {
    let payload: DeckProposalPayload
    let onSave: () -> Void

    var body: some View {
        AgentCardChrome(icon: "rectangle.stack", label: L("DECK PROPOSAL")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(17)))
                    .foregroundStyle(.black)
                Text("\(localizedLanguageName(payload.language)) · \(L(payload.level)) · \(payload.items.count) \(payload.contentType.lowercased())")
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(payload.items.prefix(3)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.word)
                            .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                            .foregroundStyle(.black)
                        Text(item.translation)
                            .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if payload.items.count > 3 {
                    Text(L("+ %d more", payload.items.count - 3))
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(11)))
                        .foregroundStyle(.secondary)
                }
            }

            AgentCardActionButton(
                title: L("Save to Library"),
                done: payload.savedDeckId != nil,
                doneTitle: L("Saved"),
                action: onSave
            )
        }
    }
}

private struct PlanProposalCard: View {
    let payload: PlanProposalPayload
    let onAccept: () -> Void

    var body: some View {
        AgentCardChrome(icon: "map", label: L("STUDY PLAN")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.plan.goalStatement)
                    .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(16)))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("%d units · toward %@", payload.plan.units.count, payload.plan.targetLevel))
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(payload.plan.units.prefix(4).enumerated()), id: \.element.id) { index, unit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: MacLayout.f(11), design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(unit.title)
                            .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(14)))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                    }
                }
                if payload.plan.units.count > 4 {
                    Text(L("+ %d more units", payload.plan.units.count - 4))
                        .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(11)))
                        .foregroundStyle(.secondary)
                }
            }

            AgentCardActionButton(
                title: L("Accept Plan"),
                done: payload.accepted == true,
                doneTitle: L("Accepted — see Explore tab"),
                action: onAccept
            )
        }
    }
}

private struct PlanUpdateCard: View {
    let payload: PlanUpdatePayload

    var body: some View {
        AgentCardChrome(icon: "arrow.triangle.2.circlepath", label: L("PLAN UPDATED")) {
            Text(payload.headline)
                .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(15)))
                .foregroundStyle(.black)
            if !payload.changes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(payload.changes, id: \.self) { change in
                        Text(change)
                            .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct ProgressSnapshotCard: View {
    let payload: ProgressSnapshotPayload

    var body: some View {
        AgentCardChrome(icon: "chart.bar", label: L("YOUR PROGRESS")) {
            HStack(spacing: 18) {
                statColumn(value: "\(payload.matureCards)", caption: L("mastered"))
                statColumn(value: "\(payload.dueNow)", caption: L("due now"))
                statColumn(value: "\(payload.streakDays)", caption: L("day streak"))
            }
            if !payload.weakWords.isEmpty {
                Text(L("Needs work: %@", payload.weakWords.prefix(5).joined(separator: ", ")))
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statColumn(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.custom("NeueHaasDisplay-Mediu", size: MacLayout.f(20)))
                .foregroundStyle(.black)
            Text(caption)
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(11)))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PlacementResultCard: View {
    let payload: PlacementResultPayload

    var body: some View {
        AgentCardChrome(icon: "checkmark.seal", label: L("LEVEL CHECK")) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(payload.level)
                    .font(.custom("PlayfairDisplay-Bold", size: MacLayout.f(30)))
                    .foregroundStyle(.black)
                Text(L("%@ · %d%% confidence", payload.language, Int((payload.confidence * 100).rounded())))
                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                    .foregroundStyle(.secondary)
            }
            Text(payload.rationale)
                .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Correction decoration

private struct CorrectionDecoration: View {
    let corrections: [ConversationCorrection]
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(corrections) { correction in
                Button {
                    Haptics.light()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        expanded = expanded == correction.id ? nil : correction.id
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: MacLayout.f(11)))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(correction.original)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: MacLayout.f(10)))
                                    .foregroundStyle(.secondary)
                                Text(correction.corrected)
                                    .foregroundStyle(.black)
                            }
                            .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(13)))
                            if expanded == correction.id {
                                Text(correction.explanation)
                                    .font(.custom("NeueHaasDisplay-Light", size: MacLayout.f(12)))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
