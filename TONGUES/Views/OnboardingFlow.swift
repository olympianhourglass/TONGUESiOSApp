import SwiftUI

@Observable
@MainActor
final class OnboardingState {
    var name: String?
    var destinations: [Destination] = []
    var languagePreferences: [LanguagePreference] = []
    var currentLevel: String?
    var motivationDetail: String?
    var fluencyScene: String?
    var firstUnderstand: String?
    var heritageBackground: String?
    var interests: [String] = []
    // The starter-deck titles suggested on the final onboarding page.
    // Captured so they can be auto-generated into the library after sign-up.
    var sampleDecks: [String] = []

    func record(answer: String, forQuestion n: Int) {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch n {
        case 1: name = value
        case 4: motivationDetail = value
        case 5: fluencyScene = value
        case 6: firstUnderstand = value
        case 7: heritageBackground = value
        default: break
        }
    }

    // Replaces a language pref's language and snaps dialect/level to valid
    // options for the new language so we never end up with stale combinations.
    func updateLanguage(at index: Int, to newLanguage: String) {
        guard index < languagePreferences.count else { return }
        var pref = languagePreferences[index]
        pref.language = newLanguage
        let validDialects = dialects(for: newLanguage)
        if !validDialects.contains(pref.dialect) {
            pref.dialect = validDialects.first ?? "Standard"
        }
        let validLevels = levels(for: newLanguage)
        if !validLevels.contains(pref.level) {
            pref.level = validLevels.first ?? "A1"
        }
        languagePreferences[index] = pref
    }

    var answers: OnboardingAnswers {
        OnboardingAnswers(
            name: name,
            languageOfInterest: languagePreferences.first?.language,
            currentLevel: currentLevel,
            dailyTime: nil,
            motivation: nil,
            languagePreferences: languagePreferences,
            destinations: destinations,
            motivationDetail: motivationDetail,
            fluencyScene: fluencyScene,
            firstUnderstand: firstUnderstand,
            heritageBackground: heritageBackground,
            interests: interests.isEmpty ? nil : interests,
            completedAt: Date()
        )
    }
}

struct OnboardingFlow: View {
    let onComplete: () -> Void
    @State private var path: [OnboardingStep] = []
    @State private var state = OnboardingState()

    enum OnboardingStep: Hashable {
        case question(Int)
        case login
        case signIn
        case slideshow
        case paywall
        case welcome
    }

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingIntroView(
                // "Get Started" begins the questions; the swipeable slideshow
                // now comes later, after sign-up and before the paywall.
                onContinue: { path.append(.question(1)) },
                onSignIn: { path.append(.signIn) }
            )
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .question(let n):
                    switch n {
                    case 2:
                        OnboardingDestinationsQuestionView(
                            questionNumber: n,
                            totalQuestions: totalQuestions,
                            state: state,
                            onNext: { handleNext(after: n) }
                        )
                    case 3:
                        OnboardingLanguagesQuestionView(
                            questionNumber: n,
                            totalQuestions: totalQuestions,
                            state: state,
                            onNext: { handleNext(after: n) }
                        )
                    case 8:
                        OnboardingInterestsQuestionView(
                            questionNumber: n,
                            totalQuestions: totalQuestions,
                            state: state,
                            onNext: { handleNext(after: n) }
                        )
                    case 9:
                        OnboardingReadyQuestionView(
                            state: state,
                            onNext: { handleNext(after: n) }
                        )
                    default:
                        OnboardingQuestionView(
                            questionNumber: n,
                            totalQuestions: totalQuestions,
                            question: questionContent(for: n),
                            state: state,
                            onNext: { handleNext(after: n) }
                        )
                    }
                case .login:
                    OnboardingLoginView(
                        onboardingAnswers: state.answers,
                        // After sign-up, everyone sees the slideshow; it then
                        // routes to the paywall (or straight into the app if the
                        // account is already paid).
                        onComplete: { path.append(.slideshow) },
                        sampleDeckTitles: state.sampleDecks
                    )
                case .signIn:
                    OnboardingLoginView(
                        onboardingAnswers: state.answers,
                        // Returning users also see the slideshow; it then decides
                        // the paywall (free) or straight into the app (paid).
                        onComplete: { path.append(.slideshow) },
                        isSignIn: true
                    )
                case .slideshow:
                    // Shown after sign-up. Everyone sees it, regardless of
                    // subscription. The slideshow manages its own per-slide
                    // status-bar tint (it mixes light and dark slides). On
                    // finish: free accounts go to the paywall; already-paid
                    // accounts skip straight to the welcome finale.
                    OnboardingSlideshowView(
                        onFinish: {
                            if SubscriptionService.shared.currentTier == .free {
                                path.append(.paywall)
                            } else {
                                path.append(.welcome)
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                case .paywall:
                    // After the paywall (skip or purchase) the welcome finale
                    // is the last beat before the app.
                    PremiumActionSheet(onFinish: { path.append(.welcome) })
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationBarBackButtonHidden(true)
                        // The paywall is dark; force light status-bar content
                        // over it (overrides the flow-wide dark setting).
                        .onAppear { AppTabRouter.shared.forceLightStatusBar = true }
                        .onDisappear { AppTabRouter.shared.forceLightStatusBar = false }
                case .welcome:
                    // The closing beat, shown to everyone: a personalized
                    // greeting; swiping on enters the app.
                    OnboardingWelcomeView(
                        userName: state.name,
                        onFinish: onComplete
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                }
            }
        }
        // Onboarding surfaces are light, so force black status-bar content
        // for the whole flow; clear it when onboarding hands off to the app.
        .onAppear { AppTabRouter.shared.forceDarkStatusBar = true }
        .onDisappear { AppTabRouter.shared.forceDarkStatusBar = false }
    }

    private let totalQuestions = 9

    private func handleNext(after question: Int) {
        if question < totalQuestions {
            path.append(.question(question + 1))
        } else {
            path.append(.login)
        }
    }

    private func questionContent(for n: Int) -> OnboardingQuestion {
        // Per-language questions read the user's top-priority language from Q3
        // so the prompts feel personal. Fall back to a neutral phrase if none.
        let topLanguage = state.languagePreferences.first?.language ?? L("this language")
        switch n {
        case 1:
            return OnboardingQuestion(
                title: L("What should we call you?"),
                kind: .freeText(placeholder: "Your name")
            )
        case 4:
            return OnboardingQuestion(
                title: L("What's pulling you towards %@?", topLanguage),
                kind: .options([
                    "Travel",
                    "Someone I love",
                    "My heritage",
                    "Work",
                    "Curiosity",
                    "A trip I've booked"
                ])
            )
        case 5:
            return OnboardingQuestion(
                title: L("When you picture yourself speaking fluently, where are you?"),
                kind: .options([
                    "A café abroad",
                    "A family dinner",
                    "On a date",
                    "In a meeting",
                    "Just out in the world understanding everything"
                ])
            )
        case 6:
            return OnboardingQuestion(
                title: L("What would you most love to understand right now in %@?", topLanguage),
                kind: .options([
                    "A song's lyrics",
                    "A conversation around me",
                    "A movie without subtitles",
                    "A menu",
                    "A letter or message"
                ])
            )
        case 7:
            return OnboardingQuestion(
                title: L("Did you grow up around %@?", topLanguage),
                kind: .options([
                    "Yes, I understand more than I can speak",
                    "A little in my family",
                    "No, it's brand new",
                    "It's where I'm from, but I never learned it"
                ])
            )
        default:
            return OnboardingQuestion(title: "Question \(n)", kind: .options(["A", "B", "C"]))
        }
    }
}

struct OnboardingQuestion: Hashable {
    let title: String
    let kind: Kind

    enum Kind: Hashable {
        case freeText(placeholder: String)
        case options([String])
    }
}
