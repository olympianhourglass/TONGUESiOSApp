import SwiftUI

// The interaction a flashcard presents. Scrambled across a session (per the
// learner's enabled set) so it mixes recognition and recall instead of
// repeating one motion for every card.
enum FlashcardMode: String, CaseIterable, Hashable {
    case reveal          // tap to reveal, then self-grade (the classic card)
    case multipleChoice  // pick the meaning from four options
    case fillInSentence  // choose the word that completes an example sentence
}

// Which review interactions the learner has enabled for the session. Toggled
// in the pre-session Settings modal; all on by default. Persisted by
// SessionIntroView via AppStorage so the choice sticks between sessions.
struct ReviewModeSettings: Equatable {
    var reveal: Bool = true
    var multipleChoice: Bool = true
    var fillInSentence: Bool = true

    static let all = ReviewModeSettings()

    // The enabled modes, in a stable order. Never empty — the modal prevents
    // turning the last one off, but we guard here too so a session can always
    // fall back to the classic card.
    var enabledModes: [FlashcardMode] {
        var modes: [FlashcardMode] = []
        if reveal { modes.append(.reveal) }
        if multipleChoice { modes.append(.multipleChoice) }
        if fillInSentence { modes.append(.fillInSentence) }
        return modes.isEmpty ? [.reveal] : modes
    }
}

// MARK: - Multiple choice

// Recognition card: shows the target-language word and four candidate
// meanings. A correct first tap grades `.good`; a wrong tap grades `.again`.
// Either way the correct option is revealed briefly before the card advances.
// Styling mirrors the reveal card (Liquid Glass, left-aligned) so the session
// feels of a piece as the mode changes card to card.
struct MultipleChoiceCard: View {
    let word: String
    let correct: String
    let pool: [String]
    let transliteration: String?
    let speak: () -> Void
    let onGrade: (ReviewResult) -> Void

    // Built once on appear so options don't reshuffle on every re-render.
    @State private var options: [String] = []
    @State private var chosen: String? = nil
    // Options fade in after the card finishes sliding into place, rather than
    // arriving already-formed with it.
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card
            optionsList
                .opacity(showOptions ? 1 : 0)
                .scaleEffect(showOptions ? 1 : 0.97, anchor: .top)
                .allowsHitTesting(showOptions)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showOptions)
        }
        .onAppear {
            if options.isEmpty {
                options = ([correct] + pool.shuffled().prefix(3)).shuffled()
            }
            // Wait for the card's slide-in spring to settle, then reveal.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                showOptions = true
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Choose the meaning"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                Text(word)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                SpeakWaveformButton(action: speak, font: .system(size: 18))
            }

            if let transliteration, !transliteration.isEmpty {
                Text(transliteration)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 170)
        .compositingGroup()
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    private var optionsList: some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        let answered = chosen != nil
        let isChosen = chosen == option
        let isCorrect = option == correct
        // After answering, the correct option always turns solid black; a
        // wrong pick is tinted so the mistake reads without adding color noise
        // to the otherwise monochrome UI.
        let background: Color = {
            guard answered else { return Color(white: 0.95) }
            if isCorrect { return .black }
            if isChosen { return Color.red.opacity(0.14) }
            return Color(white: 0.95)
        }()
        let foreground: Color = (answered && isCorrect) ? .white : .black

        return Button {
            guard chosen == nil else { return }
            chosen = option
            Haptics.medium()
            let grade: ReviewResult = isCorrect ? .good : .again
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(isCorrect ? 650 : 1200))
                onGrade(grade)
            }
        } label: {
            HStack {
                Text(option)
                    .font(.system(size: 16))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if answered && isCorrect {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(answered)
        .animation(.easeOut(duration: 0.2), value: chosen)
    }
}

// MARK: - Fill in the sentence

// Cloze card: shows an example sentence with the target word blanked out, plus
// the word's meaning as a hint, and asks the learner to choose the word that
// completes it. A correct first tap grades `.good`; a wrong tap grades
// `.again`, then the correct option is revealed before advancing. Works for
// every script (no typing), and its only AI-sourced input — the sentence —
// was produced at deck generation, so it costs nothing at review time.
struct FillInSentenceCard: View {
    let sentence: String        // example sentence in the target language
    let correct: String         // the target-language word that fills the blank
    let hint: String            // the word's meaning (native language)
    let pool: [String]          // other target-language words, for distractors
    let speak: () -> Void
    let onGrade: (ReviewResult) -> Void

    @State private var options: [String] = []
    @State private var chosen: String? = nil
    // Options fade in after the card finishes sliding into place.
    @State private var showOptions = false

    // The blank token substituted for the word in the sentence.
    private static let blank = "\u{2003}____\u{2003}"

    // Replace the first verbatim occurrence of the word with a blank. If the
    // word doesn't appear literally (inflection, etc.), fall back to appending
    // a blank so the card still reads as a fill-in prompt.
    private var clozeSentence: String {
        if let range = sentence.range(of: correct) {
            return sentence.replacingCharacters(in: range, with: Self.blank)
        }
        return sentence + Self.blank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card
            optionsList
                .opacity(showOptions ? 1 : 0)
                .scaleEffect(showOptions ? 1 : 0.97, anchor: .top)
                .allowsHitTesting(showOptions)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showOptions)
        }
        .onAppear {
            if options.isEmpty {
                options = ([correct] + pool.shuffled().prefix(3)).shuffled()
            }
            // Wait for the card's slide-in spring to settle, then reveal.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                showOptions = true
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Fill in the sentence"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                SpeakWaveformButton(action: speak, font: .system(size: 16))
            }

            Text(clozeSentence)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)

            Text(hint)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 200)
        .compositingGroup()
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    private var optionsList: some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        let answered = chosen != nil
        let isChosen = chosen == option
        let isCorrect = option == correct
        let background: Color = {
            guard answered else { return Color(white: 0.95) }
            if isCorrect { return .black }
            if isChosen { return Color.red.opacity(0.14) }
            return Color(white: 0.95)
        }()
        let foreground: Color = (answered && isCorrect) ? .white : .black

        return Button {
            guard chosen == nil else { return }
            chosen = option
            Haptics.medium()
            let grade: ReviewResult = isCorrect ? .good : .again
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(isCorrect ? 650 : 1200))
                onGrade(grade)
            }
        } label: {
            HStack {
                Text(option)
                    .font(.system(size: 16))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if answered && isCorrect {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(answered)
        .animation(.easeOut(duration: 0.2), value: chosen)
    }
}
