import SwiftUI

struct FlashcardView: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument
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
    @State private var isTimeBreakdownExpanded = false
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

    private var totalCount: Int { deck.items.count }
    private var isFinished: Bool { currentIndex >= totalCount }
    private var currentItem: GeneratedItem? {
        guard currentIndex < deck.items.count else { return nil }
        return deck.items[currentIndex]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header

                Spacer(minLength: 0)

                if isFinished {
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
                        VStack(spacing: 16) {
                            cardView(item: item)
                            // Reserve the picker's space at all times once preferred
                            // languages are loaded — fading opacity instead of
                            // inserting/removing the view keeps the card pinned in
                            // place when the user reveals the word.
                            if preferredLanguages.count > 1 {
                                languagePicker(item: item)
                                    .opacity(isWordRevealed ? 1 : 0)
                                    .allowsHitTesting(isWordRevealed)
                                    .animation(.easeInOut(duration: 0.2), value: isWordRevealed)
                            }
                        }
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
                // disturbing the card's layout.
                if !isFinished {
                    Color.clear.frame(height: 72 + 40)
                }
            }

            if !isFinished {
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
            await loadPreferredLanguagesIfNeeded()
        }
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
                    if isFinished {
                        // On the Deck Complete screen the user is
                        // already done — no in-progress work to
                        // protect — so the X dismisses directly
                        // without surfacing a "Leave session?"
                        // confirmation.
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
                            Text("Leave session?")
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
            }
            .padding(.bottom, isFinished ? 0 : 12)
            .zIndex(1)

            // Hide the progress bar + count on the Deck Complete
            // screen — the session is over, the bar is always full,
            // and the screen reads cleaner without it.
            if !isFinished {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(white: 0.85))
                        Rectangle()
                            .fill(.black)
                            .frame(width: geo.size.width * progressFraction)
                            .animation(.easeInOut(duration: 0.25), value: currentIndex)
                    }
                }
                .frame(height: 10)

                Text("\(displayIndex)/\(totalCount)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
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
        .background(Color.white)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
    }

    private func speakCurrentSelection(item: GeneratedItem) {
        let selectedLang = pickedLanguage ?? deck.language
        let isDeckLanguage = selectedLang == deck.language

        if isDeckLanguage {
            SpeechClient.shared.speak(
                item.word,
                language: item.language ?? deck.language,
                allowForvo: true
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
                .background(Color.white)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
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
            .background(Color.white, in: Capsule())
            .scaleEffect(hoveredChip == grade ? 1.08 : 1.0)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
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
        recordReview(grade)
        advance()
        triggerLastGradeToast(grade)
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

    private var finishView: some View {
        VStack(spacing: 20) {
            Text("Deck complete")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.black)

            HStack(spacing: 32) {
                statTile(value: "\(totalCount)", label: "Reviewed")
                statTile(value: "\(correctCount)", label: "Correct")
                statTile(value: "\(incorrectCount)", label: "Incorrect")
            }
            .padding(.top, 8)

            timeSpentSection
                .padding(.top, 4)

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
                Text("Finish")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .padding(.horizontal, 8)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.black)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // Total deck time + a collapsible per-card breakdown. Total uses the
    // sum of `timeSpent` across this session's reviews, so it represents
    // active study time (matches the per-card rows when expanded) rather
    // than wall-clock from launch.
    private var timeSpentSection: some View {
        VStack(spacing: 12) {
            statTile(value: formatTotalDuration(totalReviewTime), label: "Time")

            if !reviews.isEmpty {
                if isTimeBreakdownExpanded {
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
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                }

                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTimeBreakdownExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: isTimeBreakdownExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
                    // Reserve enough trailing space that any language —
                    // even the last in the list — can be scrolled to the
                    // leading edge of the strip.
                    Color.clear
                        .frame(width: max(0, proxy.size.width - 120), height: 1)
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
            await awardFlashcardXP(deckId: deckIdForXP, language: languageForXP, grades: gradesForXP)
        }
    }

    private func awardFlashcardXP(
        deckId: String,
        language: String,
        grades: [ReviewResult]
    ) async {
        do {
            let sessionGrants = try await XPService.awardFlashcardSession(
                deckId: deckId,
                language: language,
                cardGrades: grades
            )
            let dailyGrants = try await XPService.awardDailyBonusIfNeeded()
            await MainActor.run {
                XPToastCenter.shared.enqueue(sessionGrants + dailyGrants)
            }
        } catch {
            print("XP award (flashcard) failed: \(error)")
        }
    }
}

struct SessionCompleteToast: View {
    var body: some View {
        Text("Session complete!")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black, in: Capsule())
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

