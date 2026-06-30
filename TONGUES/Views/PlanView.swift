import SwiftUI
import Observation

// The curriculum surface: shows the active plan's units as a path —
// can-do goals, mastery progress, planned activities — and hosts the
// "create my plan" flow for users who don't chat. Deck activities
// execute in place (gap-aware generation, saved with planUnitId);
// conversation/pronunciation/content activities point at their tabs.
struct PlanView: View {
    @State private var vm = PlanViewModel()

    var body: some View {
        Group {
            if vm.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let plan = vm.plan {
                planList(plan)
            } else {
                createState
            }
        }
        .navigationTitle("Your Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .overlay(alignment: .top) {
            if let toast = vm.toast {
                Text(toast)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.88), in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.toast)
        .subscriptionCapAlert(Binding(
            get: { vm.capError },
            set: { vm.capError = $0 }
        ))
    }

    // MARK: - Create state

    private var createState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("No plan yet")
                    .font(.custom("PlayfairDisplay-Regular", size: 28))
                    .tracking(-1.5)
                    .foregroundStyle(.black)
                Text(vm.language == nil
                     ? "Finish onboarding to pick a language first."
                     : "Your tutor will look at your goals, your decks, and what you keep forgetting, then lay out a unit-by-unit path for \(vm.language ?? "")."
                )
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let error = vm.errorText {
                    Text(error)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.red)
                }

                if vm.isGenerating {
                    creationMilestones
                } else {
                    Button {
                        Haptics.medium()
                        Task { await vm.createPlan() }
                    } label: {
                        Text("Create my plan")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.black, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.language == nil)
                }
            }
            .padding(20)
        }
    }

    // Milestone checklist shown while the plan generates: completed
    // stages get a checkmark, the live one a spinner + elapsed seconds,
    // pending ones sit dimmed. Stages are real (they flip when each
    // underlying call starts), so this is honest progress, not theater.
    private var creationMilestones: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(PlanCreationStep.allCases) { step in
                let current = vm.creationStep
                let isDone = (current?.rawValue ?? -1) > step.rawValue
                let isActive = current == step

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)
                        } else if isActive {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                    .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                            .foregroundStyle(isDone || isActive ? .black : .secondary)
                        if isActive, let detail = step.detail {
                            Text(vm.stageSeconds >= 3
                                 ? "\(detail) · \(vm.stageSeconds)s"
                                 : detail)
                                .font(.custom("NeueHaasDisplay-Light", size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.creationStep)
    }

    // MARK: - Plan list

    private func planList(_ plan: CurriculumPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.goalStatement)
                        .font(.custom("PlayfairDisplay-Regular", size: 24))
                        .tracking(-1.2)
                        .foregroundStyle(.black)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(plan.language) · toward \(plan.targetLevel) · \(plan.completedUnitCount)/\(plan.units.count) units done")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                VStack(spacing: 14) {
                    ForEach(plan.units.sorted { $0.order < $1.order }) { unit in
                        unitCard(unit)
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 60)
            }
        }
        .refreshable { await vm.load(forceReconcile: true) }
    }

    @ViewBuilder
    private func unitCard(_ unit: CurriculumUnit) -> some View {
        let status = unit.statusEnum
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(status))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status == .completed ? Color.green : (status == .active ? Color.black : Color.secondary))
                Text(unit.title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                    .foregroundStyle(status == .locked ? Color.secondary : Color.black)
                Spacer()
                if status == .active {
                    Text("\(Int((vm.mastery(for: unit) * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if status != .locked {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(unit.canDo, id: \.self) { goal in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: status == .completed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(status == .completed ? .green : .secondary)
                            Text(goal)
                                .font(.custom("NeueHaasDisplay-Light", size: 13))
                                .foregroundStyle(.black)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if status == .active {
                // Mastery bar toward the unit's gate.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.07))
                        Capsule()
                            .fill(Color.black)
                            .frame(width: geo.size.width * vm.mastery(for: unit))
                    }
                }
                .frame(height: 4)

                VStack(spacing: 8) {
                    ForEach(unit.plannedActivities) { activity in
                        activityRow(activity, unit: unit)
                    }
                }
            }
        }
        .padding(16)
        .background(status == .active ? Color.white : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(status == .active ? 0.18 : 0.08), lineWidth: 0.5)
        )
        .opacity(status == .locked ? 0.6 : 1)
    }

    @ViewBuilder
    private func activityRow(_ activity: PlannedActivity, unit: CurriculumUnit) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activityIcon(activity.type))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.label)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                if activity.type != "deck" && activity.completedAt == nil {
                    Text(activityHint(activity.type))
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if activity.completedAt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            } else if activity.type == "deck" {
                Button {
                    Haptics.medium()
                    Task { await vm.generateDeck(activity: activity, unit: unit) }
                } label: {
                    if vm.generatingActivityID == activity.id {
                        ProgressView()
                            .frame(width: 70, height: 30)
                    } else {
                        Text("Generate")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.black, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(vm.generatingActivityID != nil)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusIcon(_ status: CurriculumUnit.Status) -> String {
        switch status {
        case .completed: return "checkmark.seal.fill"
        case .active:    return "circle.dotted.circle"
        case .locked:    return "lock"
        }
    }

    private func activityIcon(_ type: String) -> String {
        switch type {
        case "deck":          return "rectangle.stack"
        case "conversation":  return "bubble.left.and.bubble.right"
        case "pronunciation": return "waveform.badge.mic"
        case "content":       return "book"
        default:              return "sparkles"
        }
    }

    private func activityHint(_ type: String) -> String {
        switch type {
        case "conversation":  return "Open the Chat tab and finish with End & Recap"
        case "pronunciation": return "Drill any chat message with the mic icon"
        case "content":       return "Generate from the unit's deck detail page"
        default:              return ""
        }
    }
}

// MARK: - View model

// Real stages of plan creation, surfaced as a milestone checklist so
// the ~1 minute generation reads as visible work instead of a stuck
// spinner. Each stage flips exactly when its underlying call starts.
enum PlanCreationStep: Int, CaseIterable, Identifiable {
    case profile
    case drafting
    case saving

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .profile:  return "Reading your learner profile"
        case .drafting: return "Drafting your units"
        case .saving:   return "Saving your plan"
        }
    }

    var detail: String? {
        switch self {
        case .profile:  return "Your goals, decks, and trouble spots"
        case .drafting: return "The long part — usually under a minute"
        case .saving:   return nil
        }
    }
}

@Observable
@MainActor
final class PlanViewModel {
    var plan: CurriculumPlan?
    var language: String?
    var dialect: String = "Standard"
    var level: String = "A1"
    var isLoading = false
    var isGenerating = false
    // Which creation stage is live (nil when idle). Steps with a lower
    // rawValue render as completed in the checklist.
    var creationStep: PlanCreationStep?
    // Elapsed seconds on the current stage — reassures on the long
    // drafting call ("23s · usually under a minute").
    var stageSeconds: Int = 0
    var generatingActivityID: String?
    var errorText: String?
    var capError: SubscriptionError?
    var toast: String?

    private var decks: [DeckDocument] = []
    private var schedules: [String: CardSchedule] = [:]

    func load(forceReconcile: Bool = false) async {
        if plan == nil { isLoading = true }
        defer { isLoading = false }

        // Resolve the learner's primary language for the no-plan state.
        if language == nil,
           let profile = try? await UserService.fetchProfile(),
           let first = profile.onboarding?.languagePreferences?.first {
            language = canonicalLanguageName(first.language)
            dialect = first.dialect
            level = first.level
        }

        // Most relevant plan: the most recently updated one (multi-plan
        // users iterate per language elsewhere; one surface = one plan).
        let plans = (try? await FirebaseCurriculumService.fetchAll()) ?? []
        var current = plans.sorted { $0.updatedAt > $1.updatedAt }.first
        if let existing = current, forceReconcile || existing.status == "active" {
            let outcome = await CurriculumReconciler.reconcile(plan: existing)
            current = outcome.plan
        }
        plan = current
        if let plan {
            language = plan.language
            dialect = plan.dialect
        }

        decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
        schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]
    }

    func mastery(for unit: CurriculumUnit) -> Double {
        CurriculumReconciler.unitMastery(unit, decks: decks, schedules: schedules)
    }

    func createPlan() async {
        guard let language else { return }
        isGenerating = true
        errorText = nil
        // Per-stage elapsed ticker. Lives for the whole creation; resets
        // whenever the stage advances (see advance(to:)).
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run { self.stageSeconds += 1 }
            }
        }
        defer {
            ticker.cancel()
            isGenerating = false
            creationStep = nil
            stageSeconds = 0
        }
        do {
            advance(to: .profile)
            let model = try await LearnerModelService.loadOrRebuild(
                language: language,
                dialect: dialect,
                fallbackLevel: level
            )
            advance(to: .drafting)
            let generated = try await CurriculumPlanner.generatePlan(learnerModel: model)
            advance(to: .saving)
            try await FirebaseCurriculumService.save(generated)
            plan = generated
            showToast("Plan created")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func advance(to step: PlanCreationStep) {
        creationStep = step
        stageSeconds = 0
    }

    /// Executes a "deck" activity: gap-aware generation, save with
    /// curriculum provenance, link onto the unit, stamp the activity.
    func generateDeck(activity: PlannedActivity, unit: CurriculumUnit) async {
        guard var plan, let language else { return }
        generatingActivityID = activity.id
        defer { generatingActivityID = nil }
        do {
            let inLanguage = schedules.values.filter { $0.language == language }
            let known = inLanguage
                .filter { ($0.stability ?? Double($0.intervalDays)) >= LearnerModelService.matureStabilityDays }
                .map { $0.word }
            let recycle = inLanguage
                .filter { $0.lapses >= 2 }
                .sorted { $0.lapses > $1.lapses }
                .prefix(8)
                .map { $0.word }

            let topic = activity.spec["topic"] ?? activity.label
            let contentType = activity.spec["contentType"] ?? "Phrases"
            let amount = activity.spec["amount"] ?? "10"

            let deck = try await DeckGenerator.generate(
                userPrompt: topic,
                interests: [],
                language: language,
                dialect: dialect,
                contentType: ["Words", "Phrases", "Sentences"].contains(contentType) ? contentType : "Phrases",
                amount: ["5", "10", "20", "50"].contains(amount) ? amount : "10",
                level: plan.targetLevel,
                tones: [],
                knownWordsToAvoid: Array(known.prefix(60)),
                recycleWords: Array(recycle)
            )
            let deckId = try await FirebaseDeckService.saveDeck(
                deck,
                planUnitId: unit.id,
                source: "agent"
            )

            if let unitIndex = plan.units.firstIndex(where: { $0.id == unit.id }) {
                if !plan.units[unitIndex].deckIds.contains(deckId) {
                    plan.units[unitIndex].deckIds.append(deckId)
                }
                if let activityIndex = plan.units[unitIndex].plannedActivities.firstIndex(where: { $0.id == activity.id }) {
                    plan.units[unitIndex].plannedActivities[activityIndex].completedAt = Date()
                }
                try await FirebaseCurriculumService.save(plan)
                self.plan = plan
            }
            decks = (try? await FirebaseDeckService.fetchDecks()) ?? decks
            showToast("Saved “\(deck.title)” to your library")
        } catch let error as SubscriptionError {
            capError = error
        } catch {
            errorText = error.localizedDescription
            showToast("Couldn't generate that deck")
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            toast = nil
        }
    }
}
