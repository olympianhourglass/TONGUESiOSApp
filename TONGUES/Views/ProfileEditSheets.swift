import SwiftUI

// Edit sheets surfaced from ProfileView. Each one re-uses the matching
// onboarding view as its body so the editing UX is visually identical
// to the original onboarding flow — the user asked for that explicitly.
// Each sheet seeds a transient OnboardingState from the current profile,
// runs the existing view, and on completion patches the saved
// OnboardingAnswers back into Firestore via UserService.saveOnboarding
// (which uses `merge: true`, so unaffected fields stay untouched).

// MARK: - Field discriminator

enum ProfileEditField: Identifiable, Hashable {
    case name
    case understand
    case destinations
    case languages
    case interests

    var id: String {
        switch self {
        case .name: return "name"
        case .understand: return "understand"
        case .destinations: return "destinations"
        case .languages: return "languages"
        case .interests: return "interests"
        }
    }
}

// MARK: - Container

// Wraps the field-specific edit body in a NavigationStack with a Cancel
// toolbar item. The onboarding views provide their own primary action
// (Next / Continue) which we intercept to save instead of advancing.
struct ProfileEditSheet: View {
    let field: ProfileEditField
    let initialAnswers: OnboardingAnswers
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state = OnboardingState()
    @State private var isSeeded = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            body(for: field)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .alert(
                    "Couldn't save",
                    isPresented: Binding(
                        get: { saveError != nil },
                        set: { if !$0 { saveError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(saveError ?? "")
                }
        }
        .onAppear { seedIfNeeded() }
    }

    private func seedIfNeeded() {
        guard !isSeeded else { return }
        isSeeded = true
        state.name = initialAnswers.name
        state.destinations = initialAnswers.destinations ?? []
        state.languagePreferences = initialAnswers.languagePreferences ?? []
        state.motivationDetail = initialAnswers.motivationDetail
        state.fluencyScene = initialAnswers.fluencyScene
        state.firstUnderstand = initialAnswers.firstUnderstand
        state.heritageBackground = initialAnswers.heritageBackground
        state.interests = initialAnswers.interests ?? []
    }

    @ViewBuilder
    private func body(for field: ProfileEditField) -> some View {
        switch field {
        case .name:
            OnboardingQuestionView(
                questionNumber: 1,
                totalQuestions: 1,
                question: OnboardingQuestion(
                    title: "What should we call you?",
                    kind: .freeText(placeholder: "Your name")
                ),
                state: state,
                onNext: { Task { await save() } },
                showsProgress: false,
                ctaTitle: "Save"
            )
        case .understand:
            // Reuses the Q6 options copy. Falls back to neutral phrasing
            // when the user hasn't picked a target language yet.
            let topLanguage = state.languagePreferences.first?.language ?? "this language"
            OnboardingQuestionView(
                questionNumber: 6,
                totalQuestions: 1,
                question: OnboardingQuestion(
                    title: "What would you most love to understand right now in \(topLanguage)?",
                    kind: .options([
                        "A song's lyrics",
                        "A conversation around me",
                        "A movie without subtitles",
                        "A menu",
                        "A letter or message"
                    ])
                ),
                state: state,
                onNext: { Task { await save() } },
                showsProgress: false,
                ctaTitle: "Save"
            )
        case .destinations:
            OnboardingDestinationsQuestionView(
                questionNumber: 1,
                totalQuestions: 1,
                state: state,
                onNext: { Task { await save() } },
                showsProgress: false,
                ctaTitle: "Save"
            )
        case .languages:
            OnboardingLanguagesQuestionView(
                questionNumber: 1,
                totalQuestions: 1,
                state: state,
                onNext: { Task { await save() } },
                showsProgress: false,
                ctaTitle: "Save"
            )
        case .interests:
            OnboardingInterestsQuestionView(
                questionNumber: 1,
                totalQuestions: 1,
                state: state,
                onNext: { Task { await save() } },
                showsProgress: false,
                ctaTitle: "Save"
            )
        }
    }

    @MainActor
    private func save() async {
        var answers = initialAnswers
        // Patch only the field this sheet edits — the other onboarding
        // values stay exactly as they were.
        switch field {
        case .name:
            answers.name = state.name
        case .understand:
            answers.firstUnderstand = state.firstUnderstand
        case .destinations:
            answers.destinations = state.destinations
        case .languages:
            answers.languagePreferences = state.languagePreferences
            answers.languageOfInterest = state.languagePreferences.first?.language
        case .interests:
            answers.interests = state.interests.isEmpty ? nil : state.interests
        }
        do {
            try await UserService.saveOnboarding(answers)
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
