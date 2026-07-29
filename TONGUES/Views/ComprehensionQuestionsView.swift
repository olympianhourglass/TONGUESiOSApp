import SwiftUI

// MARK: - Comprehension question card

// One reading-comprehension question with four tappable multiple-choice
// answers. Owns its own answer state: a wrong tap turns that choice red and
// disables it (other choices stay live so the learner can keep trying); the
// correct tap turns green, locks the card, and fires `onCorrect` exactly
// once. The parent handles the XP award / streak credit inside `onCorrect`.
struct ComprehensionQuestionCard: View {
    let index: Int
    let question: ComprehensionQuestion
    // Fired exactly once, on the learner's FIRST answer tap, carrying whether
    // that first guess was correct. Drives the XP award (10 for a correct
    // first try, 5 for a wrong first guess).
    let onFirstAttempt: (_ correct: Bool) -> Void
    // Fired when the correct answer is chosen (possibly after wrong guesses),
    // so the parent can register the comprehension study-session for the streak.
    let onSolved: () -> Void

    @State private var wrongIndices: Set<Int> = []
    @State private var solved = false
    @State private var firstAttemptMade = false
    // Eye toggle: reveals the native-language translation (and, for non-Latin
    // target scripts, the pronunciation) of each answer choice.
    @State private var revealMeanings = false

    private let correctGreen = Color(red: 0.18, green: 0.45, blue: 0.22)
    private let correctFill = Color(red: 0.88, green: 0.97, blue: 0.88)
    private let wrongRed = Color(red: 0.6, green: 0.2, blue: 0.2)
    private let wrongFill = Color(red: 1.0, green: 0.92, blue: 0.92)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1). \(question.question)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        revealMeanings.toggle()
                    }
                } label: {
                    Image(systemName: revealMeanings ? "eye.fill" : "eye")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(revealMeanings ? .black : Color(white: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealMeanings ? L("Hide answer translations") : L("Show answer translations"))
            }

            VStack(spacing: 8) {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { i, choice in
                    choiceRow(index: i, choice: choice)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func choiceRow(index i: Int, choice: String) -> some View {
        let isCorrect = i == question.correctIndex
        let showAsCorrect = solved && isCorrect
        let showAsWrong = wrongIndices.contains(i)
        let disabled = solved || showAsWrong

        Button {
            guard !disabled else { return }
            // The very first tap on this question drives the XP award,
            // reporting whether that first guess was right.
            if !firstAttemptMade {
                firstAttemptMade = true
                onFirstAttempt(isCorrect)
            }
            if isCorrect {
                Haptics.success()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    solved = true
                }
                onSolved()
            } else {
                Haptics.error()
                withAnimation(.easeOut(duration: 0.18)) {
                    _ = wrongIndices.insert(i)
                }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice)
                        .font(.system(size: 15))
                        .foregroundStyle(foreground(correct: showAsCorrect, wrong: showAsWrong))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if revealMeanings, let pronunciation = question.pronunciation(at: i) {
                        Text(pronunciation)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryText(correct: showAsCorrect, wrong: showAsWrong))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if revealMeanings, let translation = question.translation(at: i) {
                        Text(translation)
                            .font(.system(size: 13))
                            .italic()
                            .foregroundStyle(secondaryText(correct: showAsCorrect, wrong: showAsWrong))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if showAsCorrect {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(correctGreen)
                } else if showAsWrong {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(wrongRed)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(background(correct: showAsCorrect, wrong: showAsWrong))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(border(correct: showAsCorrect, wrong: showAsWrong), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func foreground(correct: Bool, wrong: Bool) -> Color {
        if correct { return correctGreen }
        if wrong { return wrongRed }
        return .black
    }

    // Muted variant of the row foreground for the revealed translation and
    // pronunciation, so they read as secondary to the choice itself while
    // still picking up the correct/wrong tint.
    private func secondaryText(correct: Bool, wrong: Bool) -> Color {
        if correct { return correctGreen.opacity(0.8) }
        if wrong { return wrongRed.opacity(0.8) }
        return Color(white: 0.45)
    }

    private func background(correct: Bool, wrong: Bool) -> Color {
        if correct { return correctFill }
        if wrong { return wrongFill }
        return .white
    }

    private func border(correct: Bool, wrong: Bool) -> Color {
        if correct { return correctGreen.opacity(0.5) }
        if wrong { return wrongRed.opacity(0.4) }
        return Color(white: 0.85)
    }
}

// MARK: - Loading skeleton

// Shown while the comprehension questions generate. Mirrors the shape of
// three question cards (a title bar + four choice bars each) with a looping
// shimmer, so the wait reads as "questions are materializing here" rather
// than a bare spinner.
struct ComprehensionLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    bar(width: 220, height: 14)
                    VStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            bar(width: nil, height: 40, corner: 6)
                        }
                    }
                }
                .padding(16)
                .background(Color(white: 0.97))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .modifier(ComprehensionShimmer())
    }

    @ViewBuilder
    private func bar(width: CGFloat?, height: CGFloat, corner: CGFloat = 4) -> some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(Color(white: 0.90))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

// Sweeps a soft highlight left-to-right across its content on a loop — the
// shimmer that signals the comprehension skeleton is loading.
private struct ComprehensionShimmer: ViewModifier {
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
