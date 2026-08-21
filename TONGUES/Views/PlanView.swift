import SwiftUI
import Observation

// The curriculum surface: shows the active plan's units as a path —
// can-do goals, mastery progress, planned activities — and hosts the
// "create my plan" flow for users who don't chat. Deck activities
// execute in place (gap-aware generation, saved with planUnitId);
// conversation/pronunciation/content activities point at their tabs.
// Identifiable launch payloads for the in-place activity sheets, so a
// pronunciation drill / content generation opened from the plan can stamp the
// right activity complete when it finishes.
private struct PronunciationLaunch: Identifiable {
    let id = UUID()
    let unitId: String
    let activityId: String
    let target: String
}

private struct ContentLaunch: Identifiable {
    let id = UUID()
    let unitId: String
    let activityId: String
    let kind: ContentGenerationKind
    let deck: DeckDocument
}

struct PlanView: View {
    @State private var vm = PlanViewModel()
    @State private var showRefreshConfirm = false
    @State private var pronunciationLaunch: PronunciationLaunch?
    @State private var contentLaunch: ContentLaunch?

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
        .navigationTitle(L("Your Plan"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Per-language switcher — shown only for polyglots (>1 language).
            if vm.availableLanguages.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(vm.availableLanguages) { option in
                            Button {
                                Haptics.light()
                                Task { await vm.select(languageID: option.id) }
                            } label: {
                                if option.id == vm.selectedLanguageID {
                                    Label(option.name, systemImage: "checkmark")
                                } else {
                                    Text(option.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(vm.language ?? L("Language"))
                                .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                    }
                    .accessibilityLabel(L("Switch language"))
                }
            }
            if vm.plan != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        showRefreshConfirm = true
                    } label: {
                        if vm.isRevising {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.black)
                        }
                    }
                    .disabled(vm.isRevising)
                    .accessibilityLabel(L("Refresh plan"))
                }
            }
        }
        .confirmationDialog(
            L("Refresh your plan?"),
            isPresented: $showRefreshConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Refresh plan")) {
                Task { await vm.revisePlan() }
            }
            Button(L("Cancel"), role: .cancel) { }
        } message: {
            Text(L("Completed units stay done. Upcoming units are regenerated from your latest progress."))
        }
        .task { await vm.load() }
        .overlay(alignment: .top) {
            if let toast = vm.toast {
                Text(toast)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.toastBackground, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.toast)
        .subscriptionCapAlert(Binding(
            get: { vm.capError },
            set: { vm.capError = $0 }
        ))
        // A pronunciation activity drills its focus phrase; a graded attempt
        // stamps the activity complete.
        .sheet(item: $pronunciationLaunch) { launch in
            PronunciationDrillSheet(
                target: launch.target,
                transliteration: nil,
                language: vm.language ?? "",
                dialect: vm.dialect,
                onGraded: {
                    Task { await vm.completeActivity(unitId: launch.unitId, activityId: launch.activityId) }
                }
            )
        }
        // A content activity generates reading off the unit's deck; reaching a
        // finished result stamps the activity complete.
        .sheet(item: $contentLaunch) { launch in
            GenerateContentSheet(
                kind: launch.kind,
                deck: launch.deck,
                onComplete: {
                    Task { await vm.completeActivity(unitId: launch.unitId, activityId: launch.activityId) }
                }
            )
        }
    }

    // MARK: - Create state

    private var createState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("No plan yet"))
                    .font(.custom("PlayfairDisplay-Regular", size: 28))
                    .tracking(-1.5)
                    .foregroundStyle(.black)
                Text(vm.language == nil
                     ? L("Finish onboarding to pick a language first.")
                     : L("Your tutor will look at your goals, your decks, and what you keep forgetting, then lay out a unit-by-unit path for %@.", vm.language ?? "")
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
                        Text(L("Create my plan"))
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
                        Text(L(step.label))
                            .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                            .foregroundStyle(isDone || isActive ? .black : .secondary)
                        if isActive, let detail = step.detail {
                            Text(vm.stageSeconds >= 3
                                 ? L("%@ · %ds", L(detail), vm.stageSeconds)
                                 : L(detail))
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
                    Text(L("%@ · toward %@ · %d/%d units done", plan.language, plan.targetLevel, plan.completedUnitCount, plan.units.count))
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if !vm.todayItems.isEmpty {
                    todayCard(vm.todayItems)
                        .padding(.horizontal, 16)
                }

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

    // MARK: - Today

    // The per-language daily queue: a few ranked, tappable next actions.
    private func todayCard(_ items: [CurriculumTodayItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("TODAY"))
                .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(items) { item in
                    todayRow(item)
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
    }

    private func todayRow(_ item: CurriculumTodayItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.black)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.subtitle)
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if item.kind == .deck, vm.generatingActivityID == item.activityId {
                ProgressView().frame(width: 70, height: 30)
            } else {
                Button {
                    Haptics.medium()
                    runToday(item)
                } label: {
                    Text(L(todayCTALabel(item.kind)))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(item.kind == .deck && vm.generatingActivityID != nil)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func todayCTALabel(_ kind: CurriculumTodayItem.Kind) -> String {
        switch kind {
        case .review:        return "Review"
        case .deck:          return "Generate"
        case .conversation:  return "Start"
        case .pronunciation: return "Practice"
        case .content:       return "Read"
        }
    }

    // A review item jumps to the Study tab; any other item resolves its
    // activity + unit and runs the shared executor.
    private func runToday(_ item: CurriculumTodayItem) {
        if item.kind == .review {
            AppTabRouter.shared.current = .study
            return
        }
        guard let unitId = item.unitId, let activityId = item.activityId,
              let unit = vm.plan?.units.first(where: { $0.id == unitId }),
              let activity = unit.plannedActivities.first(where: { $0.id == activityId })
        else { return }
        execute(activity, unit: unit)
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
                    Text("\(Int((vm.progress(for: unit) * 100).rounded()))%")
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
                // Weighted progress bar toward the unit's gate (vocabulary
                // maturity + every non-deck activity).
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.07))
                        Capsule()
                            .fill(Color.black)
                            .frame(width: geo.size.width * vm.progress(for: unit))
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
            Text(activity.label)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            activityControl(activity, unit: unit)
        }
        .padding(10)
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // Trailing control for an activity row: a green check when done, an inline
    // spinner while a deck generates, otherwise a single action button that
    // launches the right surface for every activity type.
    @ViewBuilder
    private func activityControl(_ activity: PlannedActivity, unit: CurriculumUnit) -> some View {
        if activity.completedAt != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
        } else if activity.type == "deck" && vm.generatingActivityID == activity.id {
            ProgressView().frame(width: 70, height: 30)
        } else {
            Button {
                Haptics.medium()
                execute(activity, unit: unit)
            } label: {
                Text(L(ctaLabel(for: activity.type)))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black, in: Capsule())
            }
            .buttonStyle(.plain)
            // Only deck generation is globally exclusive (one at a time).
            .disabled(activity.type == "deck" && vm.generatingActivityID != nil)
        }
    }

    // Verb on an activity's action button.
    private func ctaLabel(for type: String) -> String {
        switch type {
        case "deck":          return "Generate"
        case "conversation":  return "Start"
        case "pronunciation": return "Practice"
        case "content":       return "Read"
        default:              return "Open"
        }
    }

    // Dispatches an activity to its surface. Deck/conversation reuse the
    // existing paths; pronunciation and content present sheets in-place and
    // stamp the activity done on success (drill graded / content generated).
    private func execute(_ activity: PlannedActivity, unit: CurriculumUnit) {
        switch activity.type {
        case "deck":
            Task { await vm.generateDeck(activity: activity, unit: unit) }
        case "conversation":
            startConversation(activity)
        case "pronunciation":
            pronunciationLaunch = PronunciationLaunch(
                unitId: unit.id,
                activityId: activity.id,
                target: activity.spec["focus"] ?? activity.label
            )
        case "content":
            if let deck = vm.firstDeck(for: unit) {
                contentLaunch = ContentLaunch(
                    unitId: unit.id,
                    activityId: activity.id,
                    kind: ContentGenerationKind(rawValue: activity.spec["kind"] ?? "Story") ?? .story,
                    deck: deck
                )
            } else {
                vm.flash(L("Generate this unit's deck first"))
            }
        default:
            break
        }
    }

    // Hands a conversation activity to the Chat tab: drops the unit's
    // scenario into the shared launch router and flips to Chat, which
    // opens a fresh scenario conversation in this plan's language.
    // Finishing that chat's recap marks the activity done via the
    // existing markPlanConversationDone() path.
    private func startConversation(_ activity: PlannedActivity) {
        guard let language = vm.language else { return }
        ChatLaunchRouter.shared.request(ChatScenarioLaunch(
            language: language,
            dialect: vm.dialect,
            level: vm.level,
            title: activity.label,
            prompt: activity.spec["scenario"] ?? activity.label
        ))
        AppTabRouter.shared.current = .chat
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

// One selectable language in the Plan's per-language switcher. Built from the
// union of the learner's onboarding language preferences and any curricula they
// already have, so a polyglot can jump between plans (and start one for a
// language that doesn't have a plan yet).
struct PlanLanguageOption: Identifiable, Hashable {
    let id: String        // languageID
    let name: String      // canonical language name
    let dialect: String
    let level: String     // fallback level for creation/revision
    let hasPlan: Bool
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
    var isRevising = false
    // All the learner's plans, kept in sync so switching languages is instant
    // and local mutations (deck generated, activity done) reflect everywhere.
    var plans: [CurriculumPlan] = []
    // Languages offered in the switcher; shown only when there's more than one.
    var availableLanguages: [PlanLanguageOption] = []
    // Which language the surface is currently showing.
    var selectedLanguageID: String?
    // FSRS-due card count for the selected language, feeding the Today queue.
    var dueCount = 0
    // The per-language Today queue rendered at the top of the plan.
    var todayItems: [CurriculumTodayItem] = []
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

        // Fetch everything once: profile (for the language menu), all plans,
        // and the full deck/schedule state (progress + Today read from these).
        let profile = try? await UserService.fetchProfile()
        plans = (try? await FirebaseCurriculumService.fetchAll()) ?? []
        decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
        schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? [:]

        availableLanguages = Self.buildLanguageOptions(profile: profile, plans: plans)
        selectedLanguageID = resolveSelectedLanguageID(preferred: selectedLanguageID)

        await applySelection(forceReconcile: forceReconcile, kickReplan: true)
    }

    /// Switches the surface to another language's plan without a full reload —
    /// decks/schedules are already loaded for every language.
    func select(languageID: String) async {
        guard languageID != selectedLanguageID else { return }
        selectedLanguageID = languageID
        await applySelection(forceReconcile: false, kickReplan: true)
    }

    // Points the surface at `selectedLanguageID`: sets the language metadata,
    // reconciles that plan if active, and rebuilds the Today queue. The gated,
    // at-most-weekly paid replan is kicked from here (moved off the Explore
    // browse tab) so it only runs where the learner is actually planning.
    private func applySelection(forceReconcile: Bool, kickReplan: Bool) async {
        guard let id = selectedLanguageID else {
            plan = nil
            todayItems = []
            dueCount = 0
            return
        }
        if let option = availableLanguages.first(where: { $0.id == id }) {
            language = option.name
            dialect = option.dialect
            level = option.level
        }

        var current = plans.first(where: { $0.languageID == id })
        if let existing = current, forceReconcile || existing.status == "active" {
            let outcome = await CurriculumReconciler.reconcile(plan: existing, decks: decks, schedules: schedules)
            current = outcome.plan
            updatePlansEntry(outcome.plan)
        }
        plan = current
        if let plan {
            language = plan.language
            dialect = plan.dialect
        }
        recomputeToday()

        if kickReplan, let plan, plan.status == "active" {
            let lid = plan.languageID
            Task.detached { await CurriculumReconciler.reconcileAndMaybeReplan(languageID: lid) }
        }
    }

    func mastery(for unit: CurriculumUnit) -> Double {
        CurriculumReconciler.unitMastery(unit, decks: decks, schedules: schedules)
    }

    /// Weighted 0…1 progress toward completing the unit (vocab maturity + every
    /// non-deck activity). Drives the bar + percentage in the unit card.
    func progress(for unit: CurriculumUnit) -> Double {
        CurriculumReconciler.unitProgress(unit, decks: decks, schedules: schedules)
    }

    /// The unit's first generated deck, if any — the deck a "content" activity
    /// reads from and the pronunciation drill draws context from.
    func firstDeck(for unit: CurriculumUnit) -> DeckDocument? {
        decks.first { deck in
            deck.id.map { unit.deckIds.contains($0) } ?? false
        }
    }

    /// Stamps a non-deck activity (pronunciation / content / conversation)
    /// complete, persists it, then reconciles — which may now finish the unit.
    func completeActivity(unitId: String, activityId: String) async {
        guard var working = plan,
              let ui = working.units.firstIndex(where: { $0.id == unitId }),
              let ai = working.units[ui].plannedActivities.firstIndex(where: { $0.id == activityId }),
              working.units[ui].plannedActivities[ai].completedAt == nil
        else { return }

        working.units[ui].plannedActivities[ai].completedAt = Date()
        // Persist the stamp first — reconcile only saves when a unit's status
        // changes, so a stamp that doesn't yet complete the unit would be lost.
        try? await FirebaseCurriculumService.save(working)
        let outcome = await CurriculumReconciler.reconcile(plan: working, decks: decks, schedules: schedules)
        plan = outcome.plan
        updatePlansEntry(outcome.plan)
        recomputeToday()
    }

    private func recomputeToday() {
        guard let plan else {
            dueCount = 0
            todayItems = []
            return
        }
        let now = Date()
        dueCount = schedules.values.filter { $0.language == plan.language && $0.nextReviewAt <= now }.count
        todayItems = CurriculumToday.build(plan: plan, decks: decks, schedules: schedules, dueCount: dueCount)
    }

    private func updatePlansEntry(_ updated: CurriculumPlan) {
        if let idx = plans.firstIndex(where: { $0.languageID == updated.languageID }) {
            plans[idx] = updated
        } else {
            plans.append(updated)
        }
    }

    private func resolveSelectedLanguageID(preferred: String?) -> String? {
        if let preferred, availableLanguages.contains(where: { $0.id == preferred }) {
            return preferred
        }
        if let active = plans.filter({ $0.status == "active" }).sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            return active.languageID
        }
        if let anyPlan = plans.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            return anyPlan.languageID
        }
        return availableLanguages.first?.id
    }

    // Union of onboarding language preferences (source of dialect/level for
    // languages without a plan yet) and existing plans (authoritative, and
    // marked `hasPlan`). Ordered plan-languages-first by recency, then by name.
    private static func buildLanguageOptions(
        profile: UserProfile?,
        plans: [CurriculumPlan]
    ) -> [PlanLanguageOption] {
        var byID: [String: PlanLanguageOption] = [:]
        if let prefs = profile?.onboarding?.languagePreferences {
            for pref in prefs {
                let name = canonicalLanguageName(pref.language)
                let id = Conversation.languageID(for: name)
                byID[id] = PlanLanguageOption(
                    id: id, name: name, dialect: pref.dialect, level: pref.level, hasPlan: false
                )
            }
        }
        for plan in plans {
            byID[plan.languageID] = PlanLanguageOption(
                id: plan.languageID, name: plan.language, dialect: plan.dialect,
                level: plan.targetLevel, hasPlan: true
            )
        }
        let recency = plans.sorted { $0.updatedAt > $1.updatedAt }.map { $0.languageID }
        return byID.values.sorted { a, b in
            let ai = recency.firstIndex(of: a.id) ?? Int.max
            let bi = recency.firstIndex(of: b.id) ?? Int.max
            if ai != bi { return ai < bi }
            return a.name < b.name
        }
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
            updatePlansEntry(generated)
            selectedLanguageID = generated.languageID
            recomputeToday()
            showToast(L("Plan created"))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func advance(to step: PlanCreationStep) {
        creationStep = step
        stageSeconds = 0
    }

    /// On-demand replan. Revises the plan against the learner's latest
    /// model — completed units carry through verbatim; upcoming units are
    /// regenerated/reordered. Gives users a manual trigger for what the
    /// weekly reconciler does only on drift.
    func revisePlan() async {
        guard let existing = plan, let language else { return }
        isRevising = true
        defer { isRevising = false }
        do {
            let model = try await LearnerModelService.loadOrRebuild(
                language: language,
                dialect: dialect,
                fallbackLevel: level
            )
            let (revised, changes) = try await CurriculumPlanner.revisePlan(
                existing: existing,
                learnerModel: model
            )
            try await FirebaseCurriculumService.save(revised)
            plan = revised
            updatePlansEntry(revised)
            decks = (try? await FirebaseDeckService.fetchDecks()) ?? decks
            schedules = (try? await FirebaseDeckService.fetchAllSchedules()) ?? schedules
            recomputeToday()
            showToast(changes.first.map { L("Plan refreshed — %@", $0) } ?? L("Plan refreshed"))
        } catch let error as SubscriptionError {
            capError = error
        } catch {
            errorText = error.localizedDescription
            showToast(L("Couldn't refresh the plan"))
        }
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
                updatePlansEntry(plan)
            }
            decks = (try? await FirebaseDeckService.fetchDecks()) ?? decks
            recomputeToday()
            showToast(L("Saved “%@” to your library", deck.title))
        } catch let error as SubscriptionError {
            capError = error
        } catch {
            errorText = error.localizedDescription
            showToast(L("Couldn't generate that deck"))
        }
    }

    /// Surfaces a transient toast from the view layer (e.g. a nudge that a
    /// unit needs a deck before its content activity can run).
    func flash(_ text: String) { showToast(text) }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            toast = nil
        }
    }
}
