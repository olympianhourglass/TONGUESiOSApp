import SwiftUI

struct FlashcardView: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument
    // Max cards to include this session (nil = every due + new card, up to the
    // new-card cap). Set from the intro screen so a "Start" session is a short,
    // finishable chunk instead of a march through the whole deck.
    var sessionLimit: Int? = nil
    // When true, study the entire deck (shuffled, uncapped) rather than only
    // what's due — the intro screen's "Full" option.
    var fullDeck: Bool = false
    // Which review interactions are enabled (from the pre-session Settings
    // modal). Modes are scrambled across the session from this set.
    var reviewModes: ReviewModeSettings = .all
    var onSessionComplete: () -> Void = {}
    @State private var currentIndex = 0
    @State private var isWordRevealed = false
    @State private var incorrectCount = 0
    @State private var correctCount = 0
    @State private var reviews: [CardReview] = []
    @State private var startedAt = Date()
    // Reset each time a new card becomes visible (initial display + every
    // `advance()`). Subtracting from `Date()` at grade time gives the
    // per-card timeSpent stored on CardReview.
    @State private var cardShownAt = Date()
    @State private var didSaveSession = false
    @State private var showLeaveConfirmation = false
    // Hold-to-reveal grading chip menus above the bottom buttons.
    @State private var showXMenu = false
    @State private var showCheckMenu = false
    // Tracks chip rects (in the bottom-area coordinate space) so a finger
    // drag can hit-test which chip is under it, and the grade chip that is
    // committed when the finger lifts.
    @State private var chipFrames: [ReviewResult: CGRect] = [:]
    @State private var hoveredChip: ReviewResult? = nil
    @State private var pressStartLocation: CGPoint = .zero
    @State private var pressDidStart = false
    @State private var pressTask: Task<Void, Never>? = nil
    // The "you graded X" chip that flies up to the bottom button row after
    // the card advances.
    @State private var lastSubmittedGrade: ReviewResult? = nil
    @State private var showLastGradeToast = false
    @State private var toastTask: Task<Void, Never>? = nil

    // Profile-driven language picker shown after the user reveals the word.
    @State private var preferredLanguages: [String] = []
    @State private var didLoadPreferences = false
    @State private var pickedLanguage: String?
    @State private var translatedWordOverride: String = ""
    // [cardId: [language: translation]] — keeps the same word from re-hitting
    // the API on re-swipe. Lives only for the view's lifetime; nothing persists.
    @State private var translationCache: [String: [String: String]] = [:]

    // Handwriting practice: a persisted toggle on the review screen. When on,
    // supported-script cards (Chinese/Japanese/Korean/Arabic) shift up and
    // reveal a practice rectangle below. Persists across cards and sessions.
    // Session-scoped so writing practice starts OFF every time a review
    // session opens (rather than persisting on from a previous session).
    @State private var handwritingEnabled = false
    // Cards whose word the user wrote out successfully this session — shown
    // in the summary and worth bonus XP.
    @State private var handwrittenItemIDs: Set<String> = []

    // MARK: Session working set (Phase 1: shorten)
    //
    // The cards actually studied this session — built on appear from the
    // deck's items filtered to what's due (or new), capped, and shuffled,
    // rather than the whole deck in fixed order. Mutable so a missed card can
    // be re-queued later in the same session (Phase 2).
    @State private var sessionItems: [GeneratedItem] = []
    @State private var didBuildSession = false
    @State private var isBuildingSession = true
    // No cards were due (and none new) — show the "all caught up" state
    // instead of forcing a replay of already-learned cards.
    @State private var isCaughtUp = false
    // Per-card FSRS schedule, fetched once at build. Drives which interaction
    // mode each card uses (Phase 3) and which cards count as newly learned.
    @State private var schedulesByCardID: [String: CardSchedule] = [:]
    @State private var newCardIDs: Set<String> = []
    // Cards already re-queued after a lapse, so a miss recurs at most once.
    @State private var requeuedCardIDs: Set<String> = []

    // MARK: Momentum (Phase 2)
    @State private var combo = 0
    @State private var bestCombo = 0
    // Summed XP from this session, surfaced on the finish screen once the
    // async award resolves.
    @State private var earnedXP: Int? = nil

    private var totalCount: Int { sessionItems.count }
    private var isFinished: Bool {
        !isBuildingSession && !isCaughtUp && currentIndex >= totalCount
    }
    private var currentItem: GeneratedItem? {
        guard currentIndex < sessionItems.count else { return nil }
        return sessionItems[currentIndex]
    }

    // True only while cards are actively being graded — false during the
    // build spinner, the caught-up state, and the finish screen.
    private var sessionActive: Bool {
        !isBuildingSession && !isCaughtUp && !isFinished
    }

    // The interaction mode for the card on screen. Defaults to reveal so the
    // classic X/✓ bottom controls only render for reveal cards.
    private var currentMode: FlashcardMode {
        currentItem.map { mode(for: $0) } ?? .reveal
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                    // Keep the header (and its "Leave session?" popover)
                    // above the card + handwriting practice, so the
                    // confirmation floats over the card instead of being
                    // covered by it when write mode shifts the layout up.
                    .zIndex(1)

                Spacer(minLength: 0)

                if isBuildingSession {
                    loadingView
                } else if isCaughtUp {
                    caughtUpView
                } else if isFinished {
                    finishView
                } else if let item = currentItem {
                    // Full-width carrier exists so the slide transition
                    // translates by the screen width — on iPad the visible
                    // card is capped at 440pt and centered, but
                    // `.move(edge: .leading)` would otherwise only translate
                    // by the card's own 440pt and leave the outgoing card
                    // half-visible. The carrier makes the move full-bleed
                    // while preserving the iPhone-like card aspect ratio.
                    ZStack {
                        cardCarrier(item: item)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: .infinity)
                    // Old card slides off to the left, new card slides in from
                    // the right. Pairing this with a slightly under-damped
                    // spring on `advance()` gives the new card a small bounce
                    // as it lands — like the rotated card view UIKit used to
                    // do with reusable cells.
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
                    .id(currentIndex)
                }

                Spacer(minLength: 0)

                // Placeholder reserves only the button row's height so the
                // card stays centered. The real bottomActions is an overlay
                // below, free to grow upward when chips appear without
                // disturbing the card's layout. Only reveal cards use the
                // X/✓ row — multiple-choice and typed cards grade in place.
                if sessionActive && currentMode == .reveal {
                    Color.clear.frame(height: 72 + 40)
                }
            }

            if sessionActive && currentMode == .reveal {
                bottomActions
                    .padding(.bottom, 40)
            }
        }
        .background(
            Color(white: 0.96)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if showXMenu || showCheckMenu || showLeaveConfirmation {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showXMenu = false
                            showCheckMenu = false
                            showLeaveConfirmation = false
                        }
                    }
                }
        )
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await buildSessionIfNeeded()
            await loadPreferredLanguagesIfNeeded()
        }
        // The review screen is white, so force dark (black) status-bar
        // content while it's on screen; restore on the way out.
        .onAppear { AppTabRouter.shared.forceDarkStatusBar = true }
        .onDisappear { AppTabRouter.shared.forceDarkStatusBar = false }
        .onChange(of: pickedLanguage) { _, newValue in
            // Fire only when the picker is actually on-screen (word
            // revealed). Skips the programmatic reset that happens on
            // every `advance()` and the initial load, both of which
            // happen with the word still blurred.
            if isWordRevealed {
                Haptics.light()
            }
            Task { await updateTranslation(for: newValue) }
        }
    }

    // MARK: Header (close + progress + count)

    private var header: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Button {
                    Haptics.light()
                    if isFinished || currentIndex < 2 {
                        // On the Deck Complete screen, and for the first two
                        // cards, the X dismisses directly — little work is at
                        // risk that early, so we skip the "Leave session?"
                        // confirmation. From the third card on, it appears.
                        saveSessionIfNeeded()
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showLeaveConfirmation.toggle()
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.black)
                        .frame(width: 32, height: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .overlay(alignment: .topLeading) {
                    if showLeaveConfirmation, !isFinished {
                        Button {
                            Haptics.medium()
                            // Commit any in-progress reviews before leaving —
                            // otherwise grading a few cards then bailing
                            // silently drops them and the deck's schedule
                            // never updates. `saveSessionIfNeeded` is a
                            // no-op when no cards have been graded yet.
                            saveSessionIfNeeded()
                            dismiss()
                        } label: {
                            Text(L("Leave session?"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.black, in: Capsule())
                                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .offset(y: 40)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                Spacer()
                // Live combo chip — a run of consecutive non-lapse grades.
                // Rewards momentum mid-session instead of deferring every
                // signal to the finish screen.
                if combo >= 3 && sessionActive {
                    comboChip
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: combo)
            .padding(.bottom, sessionActive ? 12 : 0)
            .zIndex(1)

            // Hide the progress bar + count outside active grading — during
            // the build spinner, the caught-up state, and the finish screen
            // the bar would be meaningless, and the screen reads cleaner.
            if sessionActive {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(white: 0.85))
                        Capsule()
                            .fill(.black)
                            .frame(width: geo.size.width * progressFraction)
                            .animation(.easeInOut(duration: 0.25), value: currentIndex)
                    }
                }
                .frame(height: 7.5)

                // Hidden while writing practice is active so it doesn't
                // compete with the practice UI; the progress bar stays.
                if !(currentItem.map { handwritingActive(for: $0) } ?? false) {
                    Text("\(displayIndex)/\(totalCount)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
    }

    private var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(min(currentIndex + (isFinished ? 0 : 1), totalCount)) / Double(totalCount)
    }

    private var displayIndex: Int {
        guard totalCount > 0 else { return 0 }
        return min(currentIndex + (isFinished ? 0 : 1), totalCount)
    }

    private var comboChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.system(size: 13))
            Text(L("%d in a row", combo))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: Card carrier (Phase 3: interaction variety)

    // Renders the right interaction for this card. New cards teach with the
    // classic reveal card; learning cards get multiple-choice recognition;
    // learned cards get typed production recall. Multiple-choice and typed
    // cards grade themselves and call `submit` directly.
    @ViewBuilder
    private func cardCarrier(item: GeneratedItem) -> some View {
        switch mode(for: item) {
        case .reveal:
            VStack(spacing: 16) {
                cardView(item: item)
                // Handwriting practice takes the picker's slot while active —
                // the card shifts up as this block grows.
                if handwritingActive(for: item), let script = handwritingScript(for: item) {
                    HandwritingPracticeView(word: item.word, script: script) {
                        handwrittenItemIDs.insert(item.id.uuidString)
                    }
                    .id("hw-\(item.id.uuidString)")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if preferredLanguages.count > 1 {
                    // Reserve the picker's space at all times once preferred
                    // languages are loaded — fading opacity instead of
                    // inserting/removing the view keeps the card pinned in
                    // place when the user reveals the word.
                    languagePicker(item: item)
                        .opacity(isWordRevealed ? 1 : 0)
                        .allowsHitTesting(isWordRevealed)
                        .animation(.easeInOut(duration: 0.2), value: isWordRevealed)
                }
            }
        case .multipleChoice:
            MultipleChoiceCard(
                word: item.word,
                correct: item.translation,
                pool: distractorPool(for: item),
                transliteration: item.transliteration,
                speak: { speakDeckWord(item) },
                onGrade: { submit($0) }
            )
        case .fillInSentence:
            FillInSentenceCard(
                sentence: item.exampleSentence ?? "",
                correct: item.word,
                hint: item.translation,
                pool: distractorWords(for: item),
                speak: { speakDeckWord(item) },
                onGrade: { submit($0) }
            )
        }
    }

    // Which interaction a card gets. The learner's Settings modal enables a
    // set of modes; we scramble across the session so the types visibly rotate
    // rather than clustering. The mode is stable per card (keyed off its fixed
    // position in the session) so it doesn't flicker on re-render, but adjacent
    // cards step through the enabled types in turn.
    private func mode(for item: GeneratedItem) -> FlashcardMode {
        let usable = reviewModes.enabledModes.filter { isAvailable($0, for: item) }
        let choices = usable.isEmpty ? [.reveal] : usable
        if choices.count == 1 { return choices[0] }

        // Rotate by the card's position in the session so modes alternate
        // evenly (reveal → multiple choice → fill-in → …) instead of a hash
        // that can land the same type several times in a row.
        let position = sessionItems.firstIndex(where: { $0.id == item.id }) ?? 0
        return choices[position % choices.count]
    }

    // Whether a mode can actually be presented for this card. Reveal always
    // works; multiple choice needs ≥3 distractors; fill-in-the-sentence needs
    // both an example sentence (sourced at generation) and ≥3 distractor words.
    private func isAvailable(_ mode: FlashcardMode, for item: GeneratedItem) -> Bool {
        switch mode {
        case .reveal:
            return true
        case .multipleChoice:
            return distractorPool(for: item).count >= 3
        case .fillInSentence:
            let hasSentence = !(item.exampleSentence ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            return hasSentence && distractorWords(for: item).count >= 3
        }
    }

    // Distinct translations from other cards in the deck, used as wrong
    // answers for the meaning multiple-choice card.
    private func distractorPool(for item: GeneratedItem) -> [String] {
        var seen = Set<String>([item.translation])
        var pool: [String] = []
        for other in deck.items where other.id != item.id {
            let t = other.translation
            guard !t.isEmpty, !seen.contains(t) else { continue }
            seen.insert(t)
            pool.append(t)
        }
        return pool
    }

    // Distinct target-language words from other cards, used as wrong answers
    // for the fill-in-the-sentence cloze.
    private func distractorWords(for item: GeneratedItem) -> [String] {
        var seen = Set<String>([item.word])
        var pool: [String] = []
        for other in deck.items where other.id != item.id {
            let w = other.word
            guard !w.isEmpty, !seen.contains(w) else { continue }
            seen.insert(w)
            pool.append(w)
        }
        return pool
    }

    // Speaks the target-language word (used by the MC / fill-in cards, which
    // always test the deck language rather than a picked translation).
    private func speakDeckWord(_ item: GeneratedItem) {
        SpeechClient.shared.speak(
            item.word,
            language: item.language ?? deck.language,
            allowForvo: true,
            pronunciation: item.transliteration
        )
    }

    // MARK: Handwriting practice

    // The script to practice for a card, or nil when handwriting doesn't
    // apply. Only offered while the deck-language word is shown — switching
    // the display to a translation changes the script, so we hide it then.
    private func handwritingScript(for item: GeneratedItem) -> HandwritingScript? {
        guard translatedWordOverride.isEmpty else { return nil }
        return HandwritingScript.resolve(itemLanguage: item.language, deckLanguage: deck.language)
    }

    private func handwritingSupported(for item: GeneratedItem) -> Bool {
        handwritingScript(for: item) != nil
    }

    private func handwritingActive(for item: GeneratedItem) -> Bool {
        handwritingEnabled && handwritingSupported(for: item)
    }

    // Kept as quiet as its neighbor, the icon-only speak button: a single
    // pencil glyph rather than a filled pill. Its state reads through weight
    // and a thin ink underline that draws itself in when active — a subtle
    // nod to writing on a ruled line — instead of a heavy black capsule.
    private var writeToggle: some View {
        Button {
            Haptics.light()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                handwritingEnabled.toggle()
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 18))
                .foregroundStyle(.black.opacity(handwritingEnabled ? 1 : 0.35))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 1.5)
                        .scaleEffect(x: handwritingEnabled ? 1 : 0, anchor: .leading)
                        .offset(y: 4)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .accessibilityLabel(L("Write"))
        }
        .buttonStyle(.plain)
    }

    // MARK: Card

    private func cardView(item: GeneratedItem) -> some View {
        let selectedLang = pickedLanguage ?? deck.language
        let isDeckLanguage = selectedLang == deck.language
        // Full opacity when we can produce sound in the user's picked
        // language — either it IS the deck language, or Apple has an
        // installed voice for it (free, no API). Otherwise fade to 30%.
        let canSpeakInSelected = isDeckLanguage || SpeechClient.appleHasInstalledVoice(for: selectedLang)

        return VStack(alignment: .leading, spacing: 8) {
            Text(item.translation)
                .font(.system(size: 17))
                .foregroundStyle(.black)

            Text(translatedWordOverride.isEmpty ? item.word : translatedWordOverride)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.black)
                // Long words wrap to a second line and shrink to fit rather
                // than clipping off the card edge — invisible for short words,
                // graceful for long ones.
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
                .blur(radius: isWordRevealed ? 0 : 18)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isWordRevealed {
                        Haptics.light()
                        withAnimation(.easeOut(duration: 0.25)) {
                            isWordRevealed = true
                        }
                    }
                }

            Spacer(minLength: 0)

            HStack {
                // Handwriting toggle — only for supported scripts, and only
                // while showing the deck-language word (not a translation).
                // Left-aligned to the card text, sharing the sound button's
                // row.
                if !isFinished, handwritingSupported(for: item) {
                    writeToggle
                }
                Spacer()
                SpeakWaveformButton(
                    action: { speakCurrentSelection(item: item) },
                    font: .system(size: 18)
                )
                .opacity(canSpeakInSelected ? 1.0 : 0.3)
                .disabled(!canSpeakInSelected)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 220)
        // Liquid Glass card — the material picks up the light-gray session
        // background behind it. `.clipped()` on the blurred word already
        // keeps the reveal blur inside the text frame, so no extra clip is
        // needed for the rounded corners.
        //
        // Corner radius matches the study-page card covers (4pt on a 220pt
        // cover) scaled up to this card's 440pt width — a 2× scale, so 8pt.
        .compositingGroup()
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    private func speakCurrentSelection(item: GeneratedItem) {
        let selectedLang = pickedLanguage ?? deck.language
        let isDeckLanguage = selectedLang == deck.language

        if isDeckLanguage {
            SpeechClient.shared.speak(
                item.word,
                language: item.language ?? deck.language,
                allowForvo: true,
                pronunciation: item.transliteration
            )
            return
        }
        // Apple TTS available for the picked language — speak the
        // translated word using Apple's voice (no API cost). If Apple
        // doesn't have a voice for this language we play nothing; the
        // .disabled state on the button should prevent us reaching here.
        if SpeechClient.appleHasInstalledVoice(for: selectedLang),
           !translatedWordOverride.isEmpty {
            SpeechClient.shared.speak(
                translatedWordOverride,
                language: selectedLang,
                allowForvo: false
            )
        }
    }

    // MARK: Bottom action buttons (FSRS grading)

    private var bottomActions: some View {
        HStack(alignment: .bottom) {
            ratingCircleButton(
                systemImage: "xmark",
                tapGrade: .hard,
                holdGrades: [.again, .hard],
                menuOpen: $showXMenu,
                onOpenMenu: { showCheckMenu = false },
                isLeading: true
            )
            Spacer()
            ratingCircleButton(
                systemImage: "checkmark",
                tapGrade: .good,
                holdGrades: [.easy, .good],
                menuOpen: $showCheckMenu,
                onOpenMenu: { showXMenu = false },
                isLeading: false
            )
        }
        .padding(.horizontal, 40)
        .coordinateSpace(name: "flashcardBottom")
        .onPreferenceChange(ChipFrameKey.self) { newFrames in
            chipFrames = newFrames
        }
        .overlay(alignment: .bottom) {
            // Pops up from below and lands with its center on the X/check
            // button row — confirming the grade just submitted for the
            // previous card.
            if showLastGradeToast, let grade = lastSubmittedGrade {
                lastGradeToast(grade: grade)
                    .padding(.bottom, 21)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showXMenu)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showCheckMenu)
    }

    // X = quick tap defaults to Hard, press-and-hold reveals Again/Hard chips
    // above the button so the user can drag onto one to commit. Check = tap
    // defaults to Good, hold reveals Easy/Good. Dragging off the chips and
    // releasing is a cancel — nothing is submitted and the menu closes.
    private func ratingCircleButton(
        systemImage: String,
        tapGrade: ReviewResult,
        holdGrades: [ReviewResult],
        menuOpen: Binding<Bool>,
        onOpenMenu: @escaping () -> Void,
        isLeading: Bool
    ) -> some View {
        // Chips live as a real sibling above the button so they occupy Y-space
        // (whitespace) — not Z-stacked on top of it. The safest grade is the
        // last item of holdGrades and lands closest to the button (and the
        // user's thumb), so a hold-and-drag defaults to the safe choice.
        VStack(alignment: isLeading ? .leading : .trailing, spacing: 16) {
            if menuOpen.wrappedValue {
                VStack(alignment: isLeading ? .leading : .trailing, spacing: 8) {
                    ForEach(holdGrades, id: \.self) { grade in
                        gradingChip(grade: grade)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.black)
                .frame(width: 72, height: 72)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
                .gesture(ratingDragGesture(
                    tapGrade: tapGrade,
                    menuOpen: menuOpen,
                    onOpenMenu: onOpenMenu
                ))
        }
    }

    private func gradingChip(grade: ReviewResult) -> some View {
        Text(grade.displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.black)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Liquid Glass chip — applied after the padding so the material
            // fills the full pill. Depth comes from the glass itself, so the
            // old white fill + drop shadow are dropped.
            .glassEffect(.regular, in: .capsule)
            .scaleEffect(hoveredChip == grade ? 1.08 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hoveredChip)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChipFrameKey.self,
                        value: [grade: proxy.frame(in: .named("flashcardBottom"))]
                    )
                }
            )
    }

    // Confirmation pill shown after a card is graded. Same styling as the
    // hold-to-reveal chips so it reads as "this is what you picked."
    private func lastGradeToast(grade: ReviewResult) -> some View {
        Text(grade.displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.black)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    private func ratingDragGesture(
        tapGrade: ReviewResult,
        menuOpen: Binding<Bool>,
        onOpenMenu: @escaping () -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("flashcardBottom"))
            .onChanged { value in
                if !pressDidStart {
                    pressDidStart = true
                    pressStartLocation = value.startLocation
                    pressTask?.cancel()
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        Haptics.medium()
                        onOpenMenu()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            menuOpen.wrappedValue = true
                        }
                    }
                }
                if menuOpen.wrappedValue {
                    let newHovered = chip(at: value.location)
                    if newHovered != hoveredChip {
                        if newHovered != nil { Haptics.light() }
                        hoveredChip = newHovered
                    }
                }
            }
            .onEnded { value in
                pressTask?.cancel()
                pressTask = nil
                let wasMenuOpen = menuOpen.wrappedValue
                let landedChip = chip(at: value.location)
                if wasMenuOpen {
                    if let landedChip {
                        Haptics.medium()
                        menuOpen.wrappedValue = false
                        submit(landedChip)
                    } else {
                        // Drag off to the side after the menu opened — treat
                        // as a cancel: close the menu and submit nothing.
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            menuOpen.wrappedValue = false
                        }
                    }
                } else {
                    // Quick tap — released before the long-press timer fired.
                    Haptics.light()
                    submit(tapGrade)
                }
                pressDidStart = false
                hoveredChip = nil
            }
    }

    private func chip(at location: CGPoint) -> ReviewResult? {
        chipFrames.first(where: { $0.value.contains(location) })?.key
    }

    private func submit(_ grade: ReviewResult) {
        if grade.isLapse {
            incorrectCount += 1
        } else {
            correctCount += 1
        }
        // Capture the mode before advancing — the grade toast only makes
        // sense for reveal cards (it lands on the X/✓ row those cards show).
        let wasReveal = currentMode == .reveal
        updateCombo(for: grade)
        recordReview(grade)
        // Re-queue a missed card BEFORE advancing so `totalCount` already
        // reflects the reinserted card when `advance()` checks for the end.
        requeueIfNeeded(for: grade)
        advance()
        if wasReveal { triggerLastGradeToast(grade) }
    }

    // Consecutive non-lapse grades build a combo; a lapse resets it.
    private func updateCombo(for grade: ReviewResult) {
        if grade.isLapse {
            combo = 0
        } else {
            combo += 1
            bestCombo = max(bestCombo, combo)
        }
    }

    // A lapsed card is slotted a few positions ahead so it recurs once more
    // this session — turning a miss into a second chance instead of a card
    // that vanishes. Guarded so a card is re-queued at most once.
    private func requeueIfNeeded(for grade: ReviewResult) {
        guard grade == .again, let item = currentItem else { return }
        let id = item.id.uuidString
        guard !requeuedCardIDs.contains(id) else { return }
        requeuedCardIDs.insert(id)
        let insertAt = min(sessionItems.count, currentIndex + 3)
        sessionItems.insert(item, at: insertAt)
    }

    private func triggerLastGradeToast(_ grade: ReviewResult) {
        toastTask?.cancel()
        lastSubmittedGrade = grade
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            showLastGradeToast = true
        }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showLastGradeToast = false
            }
        }
    }

    // MARK: Finished

    // Distinct new (previously unseen) cards the learner recalled this
    // session — a concrete "you learned N words today" payoff.
    private var newWordsLearned: Int {
        Set(
            reviews
                .filter { newCardIDs.contains($0.cardId) && !$0.result.isLapse }
                .map { $0.cardId }
        ).count
    }

    // A perfect run (no lapses) gets its own headline — the emotional peak
    // of finishing should read as a reward, not a data dump.
    private var finishHeadline: String {
        incorrectCount == 0 && !reviews.isEmpty ? L("Perfect session!") : L("Session complete")
    }

    private var hasRewards: Bool {
        (earnedXP ?? 0) > 0 || newWordsLearned > 0 || bestCombo >= 3 || !handwrittenItemIDs.isEmpty
    }

    private var finishView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Editorial header — mirrors the intro's overline + display title:
            // the deck as a quiet kicker, the outcome as the headline.
            VStack(alignment: .leading, spacing: 6) {
                Text(deck.title)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.black.opacity(0.45))
                    .lineLimit(1)
                Text(finishHeadline)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 34))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            statsRow
                .padding(.top, 28)

            if hasRewards {
                VStack(alignment: .leading, spacing: 10) {
                    if let earnedXP, earnedXP > 0 {
                        rewardPill(icon: "bolt.fill", text: L("+%d XP earned", earnedXP))
                    }
                    if newWordsLearned > 0 {
                        rewardPill(
                            icon: "sparkles",
                            text: newWordsLearned == 1
                                ? L("1 new word learned")
                                : L("%d new words learned", newWordsLearned)
                        )
                    }
                    if bestCombo >= 3 {
                        rewardPill(icon: "flame.fill", text: L("Best streak: %d in a row", bestCombo))
                    }
                    if !handwrittenItemIDs.isEmpty {
                        rewardPill(
                            icon: "pencil.line",
                            text: handwrittenItemIDs.count == 1
                                ? L("Wrote 1 word by hand · +%d XP", 3)
                                : L("Wrote %d words by hand · +%d XP", handwrittenItemIDs.count, handwrittenItemIDs.count * 3)
                        )
                    }
                }
                .padding(.top, 20)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: earnedXP)
            }

            Spacer(minLength: 24)

            timeSpentSection

            Spacer(minLength: 24)

            Button {
                Haptics.success()
                onSessionComplete()
                // Push a fresh widget snapshot now so home/lock-screen
                // widgets reflect the FSRS state from the session that
                // just ended, instead of waiting for the next Library
                // load.
                WidgetSnapshotWriter.refreshFromBackend()
                dismiss()
            } label: {
                Text(L("Finish"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Color.black, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
    }

    // Reviewed / Correct / Incorrect as one lifted card split by hairline
    // dividers — reads as a single considered unit rather than three numbers
    // crammed together in the middle of the screen.
    private var statsRow: some View {
        HStack(spacing: 0) {
            statTile(value: "\(reviews.count)", label: L("Reviewed"))
            statDivider
            statTile(value: "\(correctCount)", label: L("Correct"))
            statDivider
            statTile(value: "\(incorrectCount)", label: L("Incorrect"))
        }
        .padding(.vertical, 22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    private func rewardPill(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 18)
            Text(text)
                .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1))
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Build / caught-up / loading states

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.black)
            Text(L("Building your session…"))
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.black.opacity(0.5))
        }
    }

    private var caughtUpView: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.black)
            Text(L("You're all caught up"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 26))
                .foregroundStyle(.black)
            Text(L("No cards are due for review right now. Come back later, or study ahead."))
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.black.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Button {
                    Haptics.medium()
                    studyAhead()
                } label: {
                    Text(L("Study ahead"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Color.black, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Text(L("Done"))
                        .font(.custom("NeueHaasDisplay-Light", size: 16))
                        .foregroundStyle(.black.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 24)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.custom("NeueHaasDisplay-Mediu", size: 30))
                .foregroundStyle(.black)
                .monospacedDigit()
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.black.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // Total deck time + a collapsible per-card breakdown. Total uses the
    // sum of `timeSpent` across this session's reviews, so it represents
    // active study time (matches the per-card rows when expanded) rather
    // than wall-clock from launch.
    private var timeSpentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row: label + total. The per-card breakdown below is always
            // visible, so this is a static heading rather than a collapse toggle.
            HStack(spacing: 8) {
                Text(L("Time"))
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.black.opacity(0.5))
                Spacer()
                Text(formatTotalDuration(totalReviewTime))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.black)
            }

            if !reviews.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(reviews.enumerated()), id: \.offset) { _, review in
                        HStack {
                            Text(review.word)
                                .font(.system(size: 14))
                                .foregroundStyle(.black)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 12)
                            Text(formatCardDuration(review.timeSpent ?? 0))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(.black.opacity(0.5))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var totalReviewTime: TimeInterval {
        reviews.reduce(0) { $0 + ($1.timeSpent ?? 0) }
    }

    // Total: "X m Y s" / "Y s" — minute granularity is the natural unit
    // for a deck-level summary. Cards under a minute drop the leading 0m.
    private func formatTotalDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins == 0 { return "\(secs)s" }
        if secs == 0 { return "\(mins)m" }
        return "\(mins)m \(secs)s"
    }

    // Card-level: sub-minute durations get one decimal place for the
    // typical 2–30 s range; anything past a minute folds into m + s.
    private func formatCardDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let totalSeconds = Int(seconds.rounded())
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if secs == 0 { return "\(mins)m" }
        return "\(mins)m \(secs)s"
    }

    // MARK: Advance

    private func advance() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            currentIndex = min(currentIndex + 1, totalCount)
            isWordRevealed = false
            translatedWordOverride = ""
            pickedLanguage = deck.language
        }
        cardShownAt = Date()
        if currentIndex >= totalCount {
            saveSessionIfNeeded()
        }
    }

    private func recordReview(_ grade: ReviewResult) {
        guard let item = currentItem else { return }
        // Per-card timing closes here (right when the grade lands) so it
        // doesn't include the post-grade animation or the next card's
        // think-time.
        let elapsed = Date().timeIntervalSince(cardShownAt)
        reviews.append(
            CardReview(
                cardId: item.id.uuidString,
                word: item.word,
                language: item.language ?? deck.language,
                result: grade,
                reviewedAt: Date(),
                timeSpent: max(0, elapsed)
            )
        )
    }

    // MARK: Session build

    // Builds the working set once: due cards + a capped batch of new cards,
    // shuffled, then trimmed to the length the learner picked on the intro
    // screen. This is what makes a session a short, finishable chunk instead
    // of a march through every card in the deck.
    @MainActor
    private func buildSessionIfNeeded() async {
        guard !didBuildSession else { return }
        didBuildSession = true

        let ids = deck.items.map { $0.id.uuidString }
        let schedules = (try? await FirebaseDeckService.fetchSchedules(cardIds: ids)) ?? [:]
        schedulesByCardID = schedules

        // Track which cards are brand-new (no schedule) for the "new words
        // learned" payoff and for interaction-mode selection.
        let now = Date()
        for item in deck.items where schedules[item.id.uuidString] == nil {
            newCardIDs.insert(item.id.uuidString)
        }

        // "Full" start: study the entire deck, shuffled and uncapped.
        if fullDeck {
            sessionItems = deck.items.shuffled()
            startedAt = Date()
            cardShownAt = Date()
            isBuildingSession = false
            return
        }

        var due: [GeneratedItem] = []
        var fresh: [GeneratedItem] = []
        for item in deck.items {
            if let schedule = schedules[item.id.uuidString] {
                if schedule.nextReviewAt <= now { due.append(item) }
            } else {
                fresh.append(item)
            }
        }

        // Cap new cards so a brand-new deck doesn't dump every unseen word at
        // once — introducing a steady trickle is both gentler and more
        // effective than front-loading 50 novel items.
        let newCardCap = 20
        fresh = Array(fresh.shuffled().prefix(newCardCap))

        var working = (due + fresh).shuffled()
        if let limit = sessionLimit, limit > 0 {
            working = Array(working.prefix(limit))
        }

        if working.isEmpty {
            isCaughtUp = true
            isBuildingSession = false
            return
        }

        sessionItems = working
        startedAt = Date()
        cardShownAt = Date()
        isBuildingSession = false
    }

    // From the caught-up state: review already-learned cards anyway, capped so
    // "study ahead" is still a bounded session.
    private func studyAhead() {
        let cap = sessionLimit ?? 20
        var working = deck.items.shuffled()
        if working.count > cap { working = Array(working.prefix(cap)) }
        startedAt = Date()
        cardShownAt = Date()
        withAnimation(.easeInOut(duration: 0.3)) {
            sessionItems = working
            currentIndex = 0
            isCaughtUp = false
        }
    }

    // MARK: Language picker

    @ViewBuilder
    private func languagePicker(item: GeneratedItem) -> some View {
        // Light-gray backing matches the flashcard's 4pt corner radius. The
        // trailing spacer ensures even the last language has enough scroll
        // room to be snapped to the leading edge as "selected".
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(preferredLanguages, id: \.self) { lang in
                        Button {
                            // Haptic comes from the shared onChange so
                            // tap and scroll landings both feel
                            // identical. Tap to select: writing to the
                            // bound scroll position id triggers an
                            // animated scroll that makes the tapped
                            // language the leftmost item.
                            withAnimation(.easeInOut(duration: 0.3)) {
                                pickedLanguage = lang
                            }
                        } label: {
                            Text(lang)
                                .font(.system(size: 15, weight: pickedLanguage == lang ? .semibold : .regular))
                                .foregroundStyle(pickedLanguage == lang ? .black : .black.opacity(0.4))
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(lang)
                    }
                    // Reserve a full viewport of trailing space so even the
                    // last (and shortest) language can scroll all the way to
                    // the leading edge and stay snapped there under
                    // .viewAligned — a smaller reserve let short final items
                    // bounce back to the second-to-last.
                    Color.clear
                        .frame(width: proxy.size.width, height: 1)
                }
                .padding(.leading, 20)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $pickedLanguage, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: 44)
        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 4))
        // Wider leading fade gives the prior-selected language room to slide
        // out under the gradient as the new pick takes its place.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 44)
                Rectangle().fill(.black)
            }
        }
    }

    @MainActor
    private func loadPreferredLanguagesIfNeeded() async {
        guard !didLoadPreferences else { return }
        didLoadPreferences = true

        var langs: [String] = []
        if let profile = try? await UserService.fetchProfile(),
           let prefs = profile.onboarding?.languagePreferences {
            langs = prefs.map { $0.language }
        }
        // Always put the deck's language at the leading (selected) end so
        // the card starts on its native value with no API call needed.
        let others = langs.filter { $0 != deck.language }
        let combined = [deck.language] + others
        preferredLanguages = combined
        if pickedLanguage == nil {
            pickedLanguage = deck.language
        }
    }

    @MainActor
    private func updateTranslation(for newLanguage: String?) async {
        guard let language = newLanguage, let item = currentItem else { return }

        // Deck's native language — show the original word, no API call.
        if language == deck.language {
            translatedWordOverride = ""
            return
        }

        let cardId = item.id.uuidString
        if let cached = translationCache[cardId]?[language] {
            translatedWordOverride = cached
            return
        }

        do {
            let translated = try await DeckGenerator.translate(item.translation, to: language)
            // If the card has already advanced or language has changed
            // since we kicked off this call, drop the result.
            guard pickedLanguage == language, currentItem?.id.uuidString == cardId else { return }
            translationCache[cardId, default: [:]][language] = translated
            translatedWordOverride = translated
        } catch {
            print("Flashcard translation failed (\(language)): \(error)")
        }
    }

    private func saveSessionIfNeeded() {
        guard !didSaveSession, !reviews.isEmpty, let deckId = deck.id else { return }
        didSaveSession = true
        let session = StudySession(
            deckId: deckId,
            deckTitle: deck.title,
            language: deck.language,
            startedAt: startedAt,
            completedAt: Date(),
            totalReviewed: reviews.count,
            correctCount: correctCount,
            incorrectCount: incorrectCount,
            reviews: reviews
        )
        let reviewsToCommit = reviews
        let gradesForXP = reviews.map { $0.result }
        let deckIdForXP = deckId
        let languageForXP = deck.language
        let handwrittenForXP = handwrittenItemIDs.count
        // Completion + pace gate the flat "Deck complete"/"Perfect" bonuses.
        // `isFinished` is true only when the last card was reached (not an
        // early exit); the average dwell per reviewed card guards against
        // mashing through. Partial/rushed sessions still record the study
        // session (streak) and earn per-card review XP.
        let completedForXP = isFinished
        let elapsedForXP = max(0, Date().timeIntervalSince(startedAt))
        let avgPerCardForXP = reviews.isEmpty ? 0 : elapsedForXP / Double(reviews.count)
        Task {
            do {
                _ = try await FirebaseDeckService.saveStudySession(session)
                try await FirebaseDeckService.applyReviews(
                    reviewsToCommit,
                    deckId: deckId,
                    targetRetention: deck.resolvedTargetRetention
                )
            } catch {
                print("Failed to save study session: \(error)")
            }
            // XP runs independently of the session save above — even if
            // one fails the other should still proceed.
            await awardFlashcardXP(
                deckId: deckIdForXP,
                language: languageForXP,
                grades: gradesForXP,
                handwrittenCount: handwrittenForXP,
                completed: completedForXP,
                averageSecondsPerCard: avgPerCardForXP
            )
        }
    }

    private func awardFlashcardXP(
        deckId: String,
        language: String,
        grades: [ReviewResult],
        handwrittenCount: Int,
        completed: Bool,
        averageSecondsPerCard: Double
    ) async {
        do {
            let sessionGrants = try await XPService.awardFlashcardSession(
                deckId: deckId,
                language: language,
                cardGrades: grades,
                handwrittenCount: handwrittenCount,
                completed: completed,
                averageSecondsPerCard: averageSecondsPerCard
            )
            let dailyGrants = try await XPService.awardDailyBonusIfNeeded()
            let all = sessionGrants + dailyGrants
            let total = all.reduce(0) { $0 + $1.amount }
            await MainActor.run {
                XPToastCenter.shared.enqueue(all)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    earnedXP = total
                }
            }
        } catch {
            print("XP award (flashcard) failed: \(error)")
        }
    }
}

struct SessionCompleteToast: View {
    var body: some View {
        Text(L("Session complete!"))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.toastBackground, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

private struct ChipFrameKey: PreferenceKey {
    static var defaultValue: [ReviewResult: CGRect] { [:] }
    static func reduce(value: inout [ReviewResult: CGRect], nextValue: () -> [ReviewResult: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func sessionCompleteToast(isPresented: Binding<Bool>) -> some View {
        overlay(alignment: .bottom) {
            if isPresented.wrappedValue {
                SessionCompleteToast()
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(.easeOut(duration: 0.3)) {
                            isPresented.wrappedValue = false
                        }
                    }
            }
        }
    }
}

