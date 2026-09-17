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
    // Marketing-email consent from the final question. Defaults to FALSE:
    // valid consent has to be an affirmative action, never a pre-ticked box.
    // Carried here because the question is asked before sign-in, then
    // persisted with the rest of the answers once an account exists.
    var marketingOptIn: Bool = false

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
            marketingOptIn: marketingOptIn,
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
                onContinue: {
                    AnalyticsService.log(.onboardingStarted)
                    path.append(.question(1))
                },
                onSignIn: {
                    // Returning user taking the sign-in shortcut — tracked
                    // separately so it doesn't dilute the new-user funnel.
                    AnalyticsService.log(.onboardingSignInStarted, [.source: "intro"])
                    path.append(.signIn)
                }
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
                    // finish: anyone without an entitlement hits the paywall
                    // (there is no free tier); existing subscribers and comped
                    // accounts skip straight to the welcome finale.
                    OnboardingSlideshowView(
                        onFinish: {
                            let hasAccess = SubscriptionService.shared.hasAccess
                            AnalyticsService.log(.onboardingSlideshowDone, [
                                .source: hasAccess ? "skipped_paywall" : "to_paywall"
                            ])
                            if hasAccess {
                                path.append(.welcome)
                            } else {
                                path.append(.paywall)
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                case .paywall:
                    // Hard paywall — there's no free tier, so the only way past
                    // is starting the trial, restoring a purchase, or redeeming
                    // a code. `isMandatory` strips the Skip button and every
                    // swipe-out path.
                    PremiumActionSheet(
                        onFinish: { path.append(.welcome) },
                        isMandatory: true
                    )
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
                        // Terminal funnel event: this user is now activated
                        // and inside the app.
                        onFinish: {
                            AnalyticsService.log(.onboardingCompleted, [
                                .tier: SubscriptionService.shared.currentTier.rawValue
                            ])
                            onComplete()
                        }
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
        // Every one of the nine questions advances through here, so this is
        // the funnel's per-step conversion signal: comparing the count of
        // `index: 1` to `index: 9` shows exactly which question loses people.
        AnalyticsService.log(.onboardingQuestionAnswered, [
            .index: question,
            .questionId: Self.questionId(for: question)
        ])
        if question < totalQuestions {
            path.append(.question(question + 1))
        } else {
            AnalyticsService.log(.onboardingSignInStarted, [.source: "questions"])
            path.append(.login)
        }
    }

    // Stable, human-readable ids so the funnel report stays legible if the
    // question order ever changes.
    private static func questionId(for index: Int) -> String {
        switch index {
        case 1: return "motivation"
        case 2: return "destinations"
        case 3: return "languages"
        case 4: return "motivation_detail"
        case 5: return "fluency_scene"
        case 6: return "first_understand"
        case 7: return "heritage"
        case 8: return "interests"
        case 9: return "ready"
        default: return "question_\(index)"
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
