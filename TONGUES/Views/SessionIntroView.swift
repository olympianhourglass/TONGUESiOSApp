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

    @State private var hasStarted = false
    @State private var showLearnedInfo = false

    // "Adjust Your Session" pill is hidden until the underlying
    // session-adjustment surface lands. Flip to `true` to bring the
    // affordance back — the rest of the code path is preserved.
    private let isAdjustSessionSurfaced = false

    var body: some View {
        ZStack {
            if hasStarted {
                FlashcardView(deck: deck) {
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
                if isAdjustSessionSurfaced {
                    adjustPill
                        .padding(.bottom, 16)
                }
                statsList
                    .padding(.bottom, 28)
                beginButton
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showLearnedInfo) {
            LearnedInfoSheet(thresholdDays: Int(FSRSScheduler.learnedStabilityThresholdDays))
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
                .presentationDragIndicator(.visible)
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
            Text("Now Reviewing")
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
            DeckCard3DTile(style: deck.resolvedCoverStyle)
                .frame(maxWidth: 280)
            Spacer()
        }
    }

    private var adjustPill: some View {
        Button {
            Haptics.light()
            // Placeholder — the session-adjustment surface will hang
            // off this when it lands.
        } label: {
            HStack(spacing: 6) {
                Text("Adjust Your Session")
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var statsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(deck.language) \(deck.level)")
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Text("\(learnedCount) Learned")
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    Haptics.light()
                    showLearnedInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("\(remaining) Remaining")
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.custom("NeueHaasDisplay-Light", size: 15))
    }

    private var beginButton: some View {
        HStack {
            Spacer()
            Button {
                Haptics.medium()
                // Longer, eased cross-fade so the intro doesn't snap
                // away — the user's eye glides into the first card
                // instead of being yanked into it.
                withAnimation(.easeInOut(duration: 0.6)) {
                    hasStarted = true
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Begin")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
            .buttonStyle(.glass(.clear))
            Spacer()
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

                    paragraph("A card moves into Learned once the spaced-repetition algorithm projects you'll still remember it at least \(thresholdDays) days from now — not just immediately after seeing the answer.")

                    section(
                        title: "How a card graduates",
                        body: "Each correct review pushes its memory strength up. A single Easy grade often clears the bar by itself; two Good grades a few days apart usually do too."
                    )

                    section(
                        title: "How a card slips back out",
                        body: "Marking a card Again drops its memory strength sharply. If it falls under the \(thresholdDays)-day mark, it leaves the Learned count until you rebuild it."
                    )

                    section(
                        title: "Why not just \"correct once\"",
                        body: "Recalling something the moment after you saw the answer is recognition, not memory. Real learning is recalling it later, after you've nearly forgotten — and that's what the spacing is testing for."
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
            Text("About Learned")
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
