import SwiftUI

struct OnboardingQuestionView: View {
    let questionNumber: Int
    let totalQuestions: Int
    let question: OnboardingQuestion
    let state: OnboardingState
    let onNext: () -> Void
    // Suppresses the linear progress bar + "X of Y" caption so the view
    // can double as the editing surface from ProfileView without leaking
    // the onboarding chrome.
    var showsProgress: Bool = true

    @State private var textAnswer: String = ""
    // Multi-select: questions can have more than one answer.
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsProgress {
                ProgressView(value: Double(questionNumber), total: Double(totalQuestions))
                    .progressViewStyle(.linear)
                    .tint(.black)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Text("\(questionNumber) of \(totalQuestions)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            // Question
            Text(question.title)
                .font(.custom("PlayfairDisplay-Regular", size: 32))
                .tracking(-2.56)
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.top, 32)

            // Answer area
            Group {
                switch question.kind {
                case .freeText(let placeholder):
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(placeholder, text: $textAnswer)
                            .textFieldStyle(.plain)
                            .font(.custom("NeueHaasDisplay-Light", size: 28))
                            .foregroundStyle(.primary)
                        Rectangle()
                            .fill(Color(white: 0.85))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                case .options(let options):
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(options, id: \.self) { option in
                                let isSelected = selectedOptions.contains(option)
                                Button {
                                    Haptics.light()
                                    if isSelected {
                                        selectedOptions.remove(option)
                                    } else {
                                        selectedOptions.insert(option)
                                    }
                                } label: {
                                    HStack {
                                        Text(option)
                                            .font(.system(size: 16))
                                            .foregroundStyle(.black)
                                        Spacer(minLength: 12)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.black)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                isSelected ? Color.black : Color(white: 0.85),
                                                lineWidth: isSelected ? 1.5 : 1
                                            )
                                    )
                                    // Make the WHOLE row reliably tappable —
                                    // without this the empty gap between the
                                    // label and checkmark didn't register taps,
                                    // which is why answers felt "stuck".
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                    }
                }
            }

            Spacer()

            Button {
                Haptics.medium()
                recordAndAdvance()
            } label: {
                Text(questionNumber == totalQuestions ? "Continue" : "Next")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canContinue ? Color.black : Color.gray.opacity(0.4))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Free-text questions (e.g., the name input) are mandatory — no Skip.
            if case .options = question.kind {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        Haptics.light()
                        onNext()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canContinue: Bool {
        switch question.kind {
        case .freeText:
            return !textAnswer.trimmingCharacters(in: .whitespaces).isEmpty
        case .options:
            return !selectedOptions.isEmpty
        }
    }

    private func recordAndAdvance() {
        let answer: String
        switch question.kind {
        case .freeText:
            answer = textAnswer
        case .options(let options):
            // Join the selected answers in their displayed order.
            answer = options.filter { selectedOptions.contains($0) }
                .joined(separator: ", ")
        }
        state.record(answer: answer, forQuestion: questionNumber)
        onNext()
    }
}
