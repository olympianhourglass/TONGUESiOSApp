import SwiftUI

// Shown briefly before the flashcard session begins. Lets the user
// confirm what they're about to review (deck title, language + level,
// learned + remaining counts) and see the deck's actual cardback come
// to life one more time before grading kicks off. Tapping Begin
// transitions into FlashcardView; X dismisses back to the previous
// screen.
//
// Composition over routing: the view owns its own `hasStarted` flag
// and swaps to FlashcardView inline. That keeps the surrounding
// fullScreenCover / navigationDestination call sites trivial — they
// only need to change which view they present, not coordinate a
// two-step transition externally.
struct SessionIntroView: View {
    // How the view was presented. Drives the leading button glyph —
    // a downward dismiss reads as an X (modal), a back-pop reads as a
    // chevron — and lets the StudyView push hide the tab bar without
    // the DeckDetailView fullScreenCover doing it twice.
    enum Presentation {
        case modal
        case pushed
    }

    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument
    // Optional because the parent may not have loaded urgency yet
    // (DeckDetailView fetches it asynchronously in `loadUrgency`).
    // When nil, the stats degrade to the deck's static totals rather
    // than reading "0 of 0".
    var urgency: DeckUrgency? = nil
    var presentation: Presentation = .modal
    var onSessionComplete: () -> Void = {}

    // A single item-driven sheet — stacking two `.sheet(isPresented:)` on one
    // view left the first unable to dismiss, so both routes share one.
    private enum IntroSheet: String, Identifiable {
        case settings, learned
        var id: String { rawValue }
    }
    @State private var activeSheet: IntroSheet?

    @State private var hasStarted = false
    // A "Start" session is a short quick chunk; "Full" studies the whole deck.
    // Set by whichever button the learner taps, then read by FlashcardView.
    @State private var fullDeck = false

    // Which review interactions are enabled, persisted across sessions. All on
    // by default so the learner gets the full scrambled mix out of the box.
    @AppStorage("review.mode.reveal") private var revealEnabled = true
    @AppStorage("review.mode.multipleChoice") private var multipleChoiceEnabled = true
    @AppStorage("review.mode.fillInSentence") private var fillInSentenceEnabled = true

    private var reviewModes: ReviewModeSettings {
        ReviewModeSettings(
            reveal: revealEnabled,
            multipleChoice: multipleChoiceEnabled,
            fillInSentence: fillInSentenceEnabled
        )
    }

    // Cards in a quick "Start" session.
    private let quickSessionCount = 15

    var body: some View {
        ZStack {
            if hasStarted {
                FlashcardView(
                    deck: deck,
                    sessionLimit: fullDeck ? nil : quickSessionCount,
                    fullDeck: fullDeck,
                    reviewModes: reviewModes
                ) {
                    onSessionComplete()
                }
                // Fade in from the dark intro so the user's eye lands
                // on the first card already in place — no hard cut.
                .transition(.opacity)
            } else {
                intro
                    .transition(.opacity)
            }
        }
        // Both intro and FlashcardView live on the same fullscreen
        // surface, so hiding the tab bar at the root keeps the push
        // from StudyView immersive without flashing tab-bar chrome
        // during the cross-fade into the first card.
        .toolbar(.hidden, for: .tabBar)
    }

    private var intro: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                header
                Spacer(minLength: 24)
                cardbackTile
                Spacer(minLength: 24)
                statsList
                    .padding(.bottom, 28)
                beginButtons
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                ReviewSettingsSheet(
                    reveal: $revealEnabled,
                    multipleChoice: $multipleChoiceEnabled,
                    fillInSentence: $fillInSentenceEnabled,
                    onDone: { activeSheet = nil }
                )
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
                .presentationDragIndicator(.visible)
            case .learned:
                LearnedInfoSheet(thresholdDays: Int(FSRSScheduler.learnedStabilityThresholdDays))
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.black)
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Pieces

    // Modal presentations dismiss downward, so the natural glyph is X.
    // Pushed presentations pop back up the navigation stack, so a
    // leading chevron reads correctly.
    private var leadingGlyph: String {
        switch presentation {
        case .modal:  return "xmark"
        case .pushed: return "chevron.left"
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: leadingGlyph)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Now Reviewing"))
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.55))
            Text(deck.title)
                .font(.custom("NeueHaasDisplay-Mediu", size: 30))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    // Deck's actual cardback rendered as a 3D card the user can spin
    // with a pan gesture. The front face shows the deck's chosen cover
    // style (mirroring what they picked during customization); the
    // back is solid black with the TONGUES wordmark. Sits inside an
    // SCNView with a matching black background so the canvas blends
    // into the surrounding intro screen seamlessly.
    private var cardbackTile: some View {
        HStack {
            Spacer()
            // 2× larger on Mac. The card's corner radius is defined as a
            // ratio of its width (normalized card units), so it scales in
            // proportion automatically — no separate corner tuning needed.
            DeckCard3DTile(style: deck.resolvedCoverStyle)
                .frame(maxWidth: MacLayout.isMac ? 560 : 280)
            Spacer()
        }
    }

    private var statsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(localizedLanguageName(deck.language)) \(L(deck.level))")
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Text(L("%d Learned", learnedCount))
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    Haptics.light()
                    activeSheet = .learned
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("%d Remaining", remaining))
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.custom("NeueHaasDisplay-Light", size: 15))
    }

    // Two ways in: "Full" (left) runs the whole deck; "Quick Session" (right,
    // the primary CTA) runs a short quick session. Quick Session greedily
    // fills the remaining width so it reads as the default action.
    private var beginButtons: some View {
        // Both use the same clear glass so they read as one control. Full deck
        // hugs its label; Quick Session takes whatever width is left, so it's
        // always the widest, most prominent control.
        //
        // Deliberately NOT sizing Quick Session as a measured multiple of the
        // Full Deck button: feeding a geometry read back into @State and then
        // into a sibling's width creates a layout feedback loop that can pin
        // the main thread (Full Deck compresses → Quick shrinks → row fits →
        // Full Deck expands → repeat), freezing the intro on tap. A greedy
        // maxWidth needs no measurement and can't oscillate.
        HStack(spacing: 8) {
            // Session settings live all the way on the leading edge, apart
            // from the two start actions so they don't read as a third way in.
            Button {
                Haptics.light()
                activeSheet = .settings
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .glassEffect(.clear, in: .circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Session settings"))

            Button {
                begin(full: true)
            } label: {
                Text(L("Full Deck"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 50)
                    .glassEffect(.clear, in: .capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()

            Button {
                begin(full: false)
            } label: {
                HStack(spacing: 8) {
                    Text(L("Quick Session"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .glassEffect(.clear, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private func begin(full: Bool) {
        Haptics.medium()
        fullDeck = full
        // Longer, eased cross-fade so the intro doesn't snap away — the
        // user's eye glides into the first card instead of being yanked in.
        withAnimation(.easeInOut(duration: 0.6)) {
            hasStarted = true
        }
    }

    // MARK: - Derived stats

    // Cards FSRS projects you'll still remember at least a week from
    // now — stability ≥ 7 days, which a single `easy` grade or a
    // couple of `good` reviews in a row will clear. A lapse drops
    // stability sharply, so the count contracts the moment the user
    // starts forgetting a card again. Falls back to 0 while urgency
    // is still loading rather than guessing from deck totals.
    private var learnedCount: Int {
        urgency?.learnedCount ?? 0
    }

    // Everything not yet learned: new cards + still-learning cards.
    // Pairs with `learnedCount` so the two numbers add up to the deck
    // total, giving the user a clear sense of progress on this deck.
    // Falls back to the full deck count when urgency hasn't loaded,
    // so a fresh deck doesn't briefly read "0 Remaining".
    private var remaining: Int {
        guard let urgency else { return deck.items.count }
        return max(0, urgency.totalCount - urgency.learnedCount)
    }
}

// Pre-session settings: which review interactions to mix into the upcoming
// flashcard session. All on by default; the learner can trim the set, but at
// least one must stay enabled (the last-on row can't be turned off).
private struct ReviewSettingsSheet: View {
    @Binding var reveal: Bool
    @Binding var multipleChoice: Bool
    @Binding var fillInSentence: Bool
    // Closure instead of @Environment(\.dismiss): this sheet is presented from
    // inside a fullScreenCover, where the environment dismiss can resolve to
    // the wrong presentation. Clearing the parent's item binding directly is
    // unambiguous.
    var onDone: () -> Void

    private var enabledCount: Int {
        [reveal, multipleChoice, fillInSentence].filter { $0 }.count
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(spacing: 12) {
                    row(
                        title: L("Flashcard"),
                        subtitle: L("Reveal the word, then grade yourself."),
                        isOn: $reveal
                    )
                    row(
                        title: L("Multiple choice"),
                        subtitle: L("Pick the meaning from four options."),
                        isOn: $multipleChoice
                    )
                    row(
                        title: L("Fill in the sentence"),
                        subtitle: L("Choose the word that completes an example sentence."),
                        isOn: $fillInSentence
                    )
                }
                .padding(.top, 22)
                Spacer(minLength: 24)
                doneButton
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Review types"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 26))
                .foregroundStyle(.white)
            Text(L("Your session mixes the types you keep on, scrambled card to card."))
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func row(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        // The last enabled row can't be switched off — a session needs at
        // least one review type.
        let isLastOn = isOn.wrappedValue && enabledCount == 1
        return Button {
            guard !isLastOn else { Haptics.medium(); return }
            Haptics.light()
            withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                checkbox(on: isOn.wrappedValue)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func checkbox(on: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(on ? Color.white : Color.clear)
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(on ? 0 : 0.4), lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 26, height: 26)
    }

    private var doneButton: some View {
        Button {
            Haptics.light()
            onDone()
        } label: {
            Text(L("Done"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
}

// Black sheet that explains what "Learned" means in this app — the
// spaced-repetition thinking is non-obvious and a first-time user
// will reasonably expect a single correct answer to count, so this
// is the place to walk them through why the algorithm gates on
// retention instead. Threshold is injected from FSRSScheduler so the
// copy stays accurate if the constant ever moves.
private struct LearnedInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let thresholdDays: Int

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    paragraph(L("A card moves into Learned once the spaced-repetition algorithm projects you'll still remember it at least %d days from now — not just immediately after seeing the answer.", thresholdDays))

                    section(
                        title: L("How a card graduates"),
                        body: L("Each correct review pushes its memory strength up. A single Easy grade often clears the bar by itself; two Good grades a few days apart usually do too.")
                    )

                    section(
                        title: L("How a card slips back out"),
                        body: L("Marking a card Again drops its memory strength sharply. If it falls under the %d-day mark, it leaves the Learned count until you rebuild it.", thresholdDays)
                    )

                    section(
                        title: L("Why not just \"correct once\""),
                        body: L("Recalling something the moment after you saw the answer is recognition, not memory. Real learning is recalling it later, after you've nearly forgotten — and that's what the spacing is testing for.")
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("About Learned"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 26))
                .foregroundStyle(.white)
        }
        .padding(.top, 8)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.custom("NeueHaasDisplay-Light", size: 15))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                .foregroundStyle(.white)
            Text(body)
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
