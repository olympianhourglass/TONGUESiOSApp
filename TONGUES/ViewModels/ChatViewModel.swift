import Foundation
import Observation

@Observable
@MainActor
final class ChatViewModel {
    // MARK: - Per-language conversation state

    var conversation: Conversation?
    var input: String = ""
    var isSending = false
    var isLoadingConversation = false
    var errorText: String?

    // Pending scenario the chat is in — set when the user taps a
    // starter chip; cleared once the AI replies to its first message.
    var pendingScenarioPrompt: String?

    // MARK: Agent context (curriculum tutor)

    // Learner-facing label for the tool the agent loop is currently
    // running ("Reviewing your decks…"). Nil whenever no loop is live —
    // the typing indicator shows plain dots then.
    var toolStatus: String?
    // Cached learner model for the active language. Loaded lazily on
    // language switch; feeds both the plain-conversation goals line and
    // the agent's system prompt.
    var learnerModel: LearnerModel?
    // Foreign-side words from FSRS-due cards in the active language,
    // refreshed on language switch. Fed to the conversation system
    // prompt so chat doubles as spaced-repetition exposure.
    private var dueWordsCache: [String] = []
    // Number of user turns after which a placement conversation gets
    // graded automatically.
    private static let placementTurnThreshold = 6
    private var isGradingPlacement = false
    // Stays in the system prompt for EVERY turn of a placement thread
    // (ordinary scenario prompts only seed the opener) so the tutor
    // keeps stepping difficulty rather than settling into small talk.
    private static let placementScenarioPrompt = "You are running a short adaptive placement assessment. Across the conversation, step the difficulty of your turns up when the learner handles them comfortably and back down when they struggle — vary topics, tenses, and sentence complexity. Keep each of your turns to one or two sentences. Never mention levels, scores, or that this is a test; it should feel like a friendly chat that happens to stretch them."

    // Driver for the recap modal. Cleared when the user dismisses.
    var pendingRecap: ConversationRecap?
    var isBuildingRecap = false

    // Surfaces a "Translate: <english>" callout when the user taps a
    // word in an assistant bubble. Cleared on dismiss.
    var translationCallout: TranslationCallout?

    // Decks the user has across all languages — used to populate the
    // save-to-deck picker without a per-tap fetch.
    var decksForCurrentLanguage: [DeckDocument] = []

    // Recent threads across ALL languages, used by the history sheet.
    // Lightweight: we keep the full Conversation in memory but the
    // list query is capped at the most recent 50. Acts as the source
    // of truth — `persistCurrent` and `startNewConversation` update it
    // directly so the sheet doesn't need to re-fetch from Firestore on
    // every open. `listLoaded` flips true after the first successful
    // fetch so subsequent sheet opens skip the round trip.
    var conversationList: [Conversation] = []
    var isLoadingList = false
    private var listLoaded = false

    struct TranslationCallout: Identifiable, Hashable {
        var id: UUID = UUID()
        let original: String
        let translation: String
    }

    // MARK: - Send

    var canSend: Bool {
        !isSending
            && conversation != nil
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var current = conversation else { return }

        input = ""
        errorText = nil

        let userMessage = ConversationMessage(role: .user, text: text)
        current.messages.append(userMessage)
        conversation = current

        isSending = true
        defer {
            isSending = false
            toolStatus = nil
        }

        // Route: meta/planning requests go through the tool-using tutor
        // agent; everything else stays on the existing conversation path.
        // Placement threads never route to the agent — the whole thread
        // is an assessment conversation.
        let intent: TutorAgent.Intent
        if current.purpose == "placement" {
            intent = .conversation
        } else {
            intent = await TutorAgent.classifyIntent(text)
        }

        if intent == .meta {
            await sendViaAgent(userText: text, userMessageID: userMessage.id)
            return
        }

        let context = ConversationClient.Context(
            language: current.language,
            dialect: current.dialect,
            level: current.level,
            scenarioPrompt: current.purpose == "placement"
                ? Self.placementScenarioPrompt
                : pendingScenarioPrompt,
            dueWords: dueWordsCache,
            goalsSummary: learnerModel?.goalsLine
        )

        do {
            let reply = try await ConversationClient.sendTurn(
                history: Array(current.messages.dropLast()),
                userText: text,
                context: context
            )
            // Stamp the corrections back onto the user's turn.
            if !reply.corrections.isEmpty,
               let userIndex = current.messages.firstIndex(where: { $0.id == userMessage.id }) {
                var stamped = current.messages[userIndex]
                stamped.corrections = reply.corrections
                current.messages[userIndex] = stamped
            }
            let assistantMessage = ConversationMessage(
                role: .assistant,
                text: reply.text,
                transliteration: reply.transliteration
            )
            current.messages.append(assistantMessage)
            current.updatedAt = Date()
            conversation = current
            pendingScenarioPrompt = nil  // First reply consumed.
            // Persist in the background — failures are non-fatal.
            await persistCurrent()

            // Continuous level calibration: every graded turn feeds the
            // learner model's rolling accuracy signal. Fire-and-forget.
            let language = current.language
            let correctionCount = reply.corrections.count
            Task.detached {
                await LearnerModelService.recordConversationSignal(
                    language: language,
                    correctionCount: correctionCount
                )
            }

            // Placement threads: once enough turns are graded, score the
            // transcript and surface the result card.
            await gradePlacementIfReady()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Agent path

    private func sendViaAgent(userText: String, userMessageID: UUID) async {
        guard var current = conversation else { return }
        let agentContext = TutorAgent.Context(
            language: current.language,
            dialect: current.dialect,
            level: current.level,
            learnerModel: learnerModel
        )
        toolStatus = "Thinking…"
        do {
            let reply = try await TutorAgent.respond(
                history: Array(current.messages.dropLast()),
                userText: userText,
                context: agentContext,
                onToolEvent: { [weak self] label in
                    Task { @MainActor in
                        self?.toolStatus = label
                    }
                }
            )
            guard let refreshed = conversation, refreshed.id == current.id else { return }
            current = refreshed
            if !reply.corrections.isEmpty,
               let userIndex = current.messages.firstIndex(where: { $0.id == userMessageID }) {
                var stamped = current.messages[userIndex]
                stamped.corrections = reply.corrections
                current.messages[userIndex] = stamped
            }
            // Main reply bubble carries the first staged attachment;
            // additional attachments ride on their own (text-less)
            // assistant messages so each card renders separately.
            var attachments = reply.attachments
            let assistantMessage = ConversationMessage(
                role: .assistant,
                text: reply.text,
                transliteration: reply.transliteration,
                attachment: attachments.isEmpty ? nil : attachments.removeFirst()
            )
            current.messages.append(assistantMessage)
            for extra in attachments {
                current.messages.append(ConversationMessage(
                    role: .assistant,
                    text: "",
                    attachment: extra
                ))
            }
            current.updatedAt = Date()
            conversation = current
            pendingScenarioPrompt = nil
            await persistCurrent()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Proposal confirmation

    // Saves an agent-proposed deck to the user's library, stamps the
    // proposal card as saved, and — when the deck scaffolds a curriculum
    // unit — links it onto the plan and marks the matching planned
    // activity done. Returns the deck title for the toast, or nil if
    // nothing was saved.
    func saveProposedDeck(messageID: UUID) async -> String? {
        guard var current = conversation,
              let index = current.messages.firstIndex(where: { $0.id == messageID }),
              case .deckProposal(var payload) = current.messages[index].attachment,
              payload.savedDeckId == nil else { return nil }
        do {
            let deckId = try await FirebaseDeckService.saveDeck(
                payload.asGeneratedDeck(),
                planUnitId: payload.planUnitId,
                source: "agent"
            )
            payload.savedDeckId = deckId
            current.messages[index].attachment = .deckProposal(payload)
            conversation = current
            await persistCurrent()
            if let unitId = payload.planUnitId {
                await linkDeckToPlan(
                    deckId: deckId,
                    unitId: unitId,
                    language: payload.language,
                    topic: payload.topic
                )
            }
            await loadDecksForCurrentLanguage()
            return payload.title
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    // Accepts an agent-proposed curriculum plan: persists it and flips
    // the card. Returns true on success.
    func acceptProposedPlan(messageID: UUID) async -> Bool {
        guard var current = conversation,
              let index = current.messages.firstIndex(where: { $0.id == messageID }),
              case .planProposal(var payload) = current.messages[index].attachment,
              payload.accepted != true else { return false }
        do {
            try await FirebaseCurriculumService.save(payload.plan)
            payload.accepted = true
            current.messages[index].attachment = .planProposal(payload)
            conversation = current
            await persistCurrent()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func linkDeckToPlan(
        deckId: String,
        unitId: String,
        language: String,
        topic: String
    ) async {
        let languageID = Conversation.languageID(for: language)
        guard var plan = try? await FirebaseCurriculumService.fetch(languageID: languageID),
              let unitIndex = plan.units.firstIndex(where: { $0.id == unitId }) else { return }
        if !plan.units[unitIndex].deckIds.contains(deckId) {
            plan.units[unitIndex].deckIds.append(deckId)
        }
        // Mark the first matching (or first incomplete) deck activity done.
        let activities = plan.units[unitIndex].plannedActivities
        if let activityIndex = activities.firstIndex(where: {
            $0.type == "deck" && $0.completedAt == nil
                && ($0.spec["topic"]?.lowercased() == topic.lowercased() || activities.filter { a in a.type == "deck" && a.completedAt == nil }.count == 1)
        }) ?? activities.firstIndex(where: { $0.type == "deck" && $0.completedAt == nil }) {
            plan.units[unitIndex].plannedActivities[activityIndex].completedAt = Date()
        }
        try? await FirebaseCurriculumService.save(plan)
    }

    // Completing a recap counts as finishing a conversation session for
    // the active curriculum unit — stamps the first incomplete
    // "conversation" activity so conversation-check mastery gates can
    // pass. Called by the recap sheet's save path.
    func markPlanConversationDone() async {
        guard let current = conversation else { return }
        let languageID = current.languageID
        guard var plan = try? await FirebaseCurriculumService.fetch(languageID: languageID),
              let unitIndex = plan.units.firstIndex(where: {
                  $0.statusEnum == .active
                      && $0.plannedActivities.contains { $0.type == "conversation" && $0.completedAt == nil }
              }) else { return }
        if let activityIndex = plan.units[unitIndex].plannedActivities.firstIndex(where: {
            $0.type == "conversation" && $0.completedAt == nil
        }) {
            plan.units[unitIndex].plannedActivities[activityIndex].completedAt = Date()
            try? await FirebaseCurriculumService.save(plan)
        }
    }

    // MARK: - Placement (Phase 4)

    // Starts a fresh placement conversation: the tutor runs a short
    // adaptive assessment, and after enough turns the transcript is
    // graded into a level estimate on the learner model.
    func startPlacement() async {
        guard let current = conversation else { return }
        await persistCurrent()
        var fresh = makeFreshConversation(
            languageID: current.languageID,
            language: current.language,
            dialect: current.dialect,
            level: current.level
        )
        fresh.purpose = "placement"
        conversation = fresh
        translationCallout = nil
        input = ""
        errorText = nil

        let scenario = ConversationScenario(
            id: "placement",
            title: "Check my level",
            prompt: Self.placementScenarioPrompt
                + " Open now with a warm, easy first question in the target language.",
            systemImage: "checkmark.seal"
        )
        await sendScenario(scenario)
    }

    var isPlacementConversation: Bool {
        conversation?.purpose == "placement"
    }

    private func gradePlacementIfReady() async {
        guard let current = conversation,
              current.purpose == "placement",
              !isGradingPlacement else { return }
        let userTurns = current.messages.filter { $0.role == .user }.count
        guard userTurns >= Self.placementTurnThreshold else { return }

        isGradingPlacement = true
        defer { isGradingPlacement = false }
        toolStatus = "Scoring your level…"
        defer { toolStatus = nil }
        do {
            let result = try await TutorAgent.gradePlacement(
                history: current.messages,
                language: current.language,
                dialect: current.dialect,
                fallbackLevel: current.level
            )
            guard var refreshed = conversation, refreshed.id == current.id else { return }
            refreshed.messages.append(ConversationMessage(
                role: .assistant,
                text: "That's enough for me to place you — here's where you're at.",
                attachment: .placementResult(result)
            ))
            // Demote the thread to an ordinary conversation so grading
            // doesn't re-fire on subsequent turns.
            refreshed.purpose = nil
            refreshed.updatedAt = Date()
            conversation = refreshed
            await persistCurrent()
            // Level moved — refresh the cached learner model.
            await refreshLearnerContext()
        } catch {
            // Non-fatal: leave the thread as placement; the next turn
            // retries the grade.
            print("[Chat] Placement grading failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Agent context loading

    // Refreshes the learner model + FSRS due words for the active
    // language, and surfaces any pending tutor notice from the
    // curriculum reconciler as an assistant bubble. Best-effort.
    func refreshLearnerContext() async {
        guard let current = conversation else { return }
        let language = current.language
        let dialect = current.dialect
        let level = current.level

        learnerModel = try? await LearnerModelService.loadOrRebuild(
            language: language,
            dialect: dialect,
            fallbackLevel: level
        )

        if let due = try? await FirebaseDeckService.fetchDueSchedules(limit: 60) {
            var seen = Set<String>()
            dueWordsCache = due
                .filter { $0.language == language }
                .compactMap { schedule in
                    seen.insert(schedule.word).inserted ? schedule.word : nil
                }
            dueWordsCache = Array(dueWordsCache.prefix(12))
        } else {
            dueWordsCache = []
        }

        await surfaceTutorNoticeIfAny()
    }

    // Pops the plan doc's pending tutor notice (queued by the weekly
    // replanner / unit completions) into the chat as an assistant
    // message, then clears it so it shows exactly once.
    private func surfaceTutorNoticeIfAny() async {
        guard var current = conversation else { return }
        let languageID = current.languageID
        guard let plan = try? await FirebaseCurriculumService.fetch(languageID: languageID),
              let notice = plan.pendingTutorNotice,
              !notice.isEmpty else { return }
        guard conversation?.id == current.id else { return }
        current.messages.append(ConversationMessage(
            role: .assistant,
            text: notice,
            attachment: .planUpdate(PlanUpdatePayload(
                headline: "Plan updated",
                changes: [],
                revision: plan.revision
            ))
        ))
        current.updatedAt = Date()
        conversation = current
        await persistCurrent()
        try? await FirebaseCurriculumService.clearTutorNotice(languageID: languageID)
    }

    // MARK: - Scenario starters

    func sendScenario(_ scenario: ConversationScenario) async {
        guard var current = conversation else { return }
        errorText = nil
        pendingScenarioPrompt = scenario.prompt

        let context = ConversationClient.Context(
            language: current.language,
            dialect: current.dialect,
            level: current.level,
            scenarioPrompt: scenario.prompt,
            dueWords: dueWordsCache,
            goalsSummary: learnerModel?.goalsLine
        )

        isSending = true
        defer { isSending = false }
        do {
            // One-shot nudge to coax the AI's opener. We do NOT persist
            // this user turn — only the assistant reply lands in the
            // visible thread, so a scenario start reads as "AI just
            // begins" rather than an awkward English kickoff line.
            let reply = try await ConversationClient.sendTurn(
                history: [],
                userText: "Open this scenario now with your first turn.",
                context: context
            )
            let assistantMessage = ConversationMessage(
                role: .assistant,
                text: reply.text,
                transliteration: reply.transliteration
            )
            current.messages.append(assistantMessage)
            current.updatedAt = Date()
            conversation = current
            pendingScenarioPrompt = nil
            await persistCurrent()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Save selection to deck

    // Builds a single GeneratedItem from the user's tapped phrase + its
    // English translation. Caller hands this into DeckPickerSheet.
    func makeItemForSave(
        foreign: String,
        translation: String,
        transliteration: String? = nil
    ) -> GeneratedItem? {
        guard let current = conversation else { return nil }
        return GeneratedItem(
            word: foreign,
            translation: translation,
            transliteration: transliteration,
            language: current.language,
            partsOfSpeech: ["Phrase"],
            addedAt: Date()
        )
    }

    // Stamps a message as having had `itemId` saved to a deck so the
    // UI can show a check + the picker can prevent double-adds.
    func markSaved(messageID: UUID, itemID: UUID) {
        guard var current = conversation else { return }
        guard let idx = current.messages.firstIndex(where: { $0.id == messageID }) else { return }
        var msg = current.messages[idx]
        var ids = msg.savedDeckItemIDs ?? []
        ids.append(itemID)
        msg.savedDeckItemIDs = ids
        current.messages[idx] = msg
        conversation = current
        Task { await persistCurrent() }
    }

    // MARK: - Loading per language

    // Called when the user picks a different practice language. Loads
    // the most-recently-updated thread for that language; if there
    // isn't one yet, opens a fresh in-memory chat that won't be
    // persisted until the first message lands.
    func switchLanguage(to language: String, dialect: String, level: String) async {
        let canonical = canonicalLanguageName(language)
        let id = Conversation.languageID(for: canonical)
        if conversation?.languageID == id { return }

        await persistCurrent()

        isLoadingConversation = true
        defer { isLoadingConversation = false }

        do {
            let recent = try await FirebaseConversationService.list(
                languageID: id, limit: 1
            )
            if let mostRecent = recent.first {
                conversation = Self.normalizeAgainstLanguageData(mostRecent)
            } else {
                conversation = makeFreshConversation(
                    languageID: id,
                    language: canonical,
                    dialect: dialect,
                    level: level
                )
            }
            pendingScenarioPrompt = nil
            translationCallout = nil
            await loadDecksForCurrentLanguage()
            // Learner model + due words + tutor notices, off the critical
            // path so the conversation renders immediately.
            Task { await refreshLearnerContext() }
        } catch {
            print("[Chat] Switch-language load failed: \(error.localizedDescription) — \(error)")
            errorText = error.localizedDescription
            conversation = makeFreshConversation(
                languageID: id,
                language: canonical,
                dialect: dialect,
                level: level
            )
        }
    }

    // Spins up a fresh in-memory thread without touching Firestore.
    // The first send() will persist it; until then it costs nothing.
    func startNewConversation() {
        guard let current = conversation else { return }
        // Optimistic cache update: move the chat we're leaving to the
        // top of the in-memory recent list FIRST so the history sheet
        // shows it immediately, even if the Firestore write is still
        // in flight. Only worth doing if the departing chat actually
        // has content — empty stubs don't belong in Recent.
        if !current.messages.isEmpty {
            updateListCache(with: current)
        }
        // Kick the actual save off in the background. Failure is
        // non-fatal — the optimistic cache entry stays correct, and
        // the next loadConversationList(refresh: true) will reconcile.
        Task { await persistCurrent() }
        conversation = makeFreshConversation(
            languageID: current.languageID,
            language: current.language,
            dialect: current.dialect,
            level: current.level
        )
        pendingScenarioPrompt = nil
        translationCallout = nil
        input = ""
        errorText = nil
    }

    // Switches the in-memory thread to an existing one from the
    // history sheet. The list query already returned the full doc, so
    // no extra Firestore read is needed.
    func openConversation(_ target: Conversation) async {
        if target.id == conversation?.id { return }
        await persistCurrent()
        conversation = Self.normalizeAgainstLanguageData(target)
        pendingScenarioPrompt = nil
        translationCallout = nil
        input = ""
        errorText = nil
        Task { await refreshLearnerContext() }
    }

    // Pulled by the history sheet on appear. Skips the Firestore read
    // entirely once the in-memory cache has been populated —
    // `persistCurrent` and `startNewConversation` keep that cache
    // fresh after every turn / new-chat tap, so repeated opens of the
    // sheet within a session cost zero Firestore reads. Pass
    // `refresh: true` to force a re-fetch (pull-to-refresh). The list
    // spans all languages so the user sees one unified history.
    func loadConversationList(refresh: Bool = false) async {
        if !refresh, listLoaded, !conversationList.isEmpty {
            return
        }
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            let fetched = try await FirebaseConversationService.listAll()
            // Reconcile: keep any in-memory entries the server doesn't
            // know about yet (optimistic inserts whose Firestore write
            // is still in flight) by union'ing on id, then re-sorting.
            let pending = conversationList.filter { local in
                !fetched.contains(where: { $0.id == local.id })
            }
            let merged = (fetched + pending).sorted {
                $0.updatedAt > $1.updatedAt
            }
            conversationList = merged
            listLoaded = true
        } catch {
            // Don't surface in the sheet — an empty list reads fine as
            // "no chats yet" — but log loudly so the underlying error
            // (security rules, network, etc.) is visible while
            // debugging.
            print("[Chat] Conversation list fetch failed: \(error.localizedDescription) — \(error)")
        }
    }

    // Adds (or moves) a conversation to the top of the in-memory
    // recent list. Drives both the "Recent" strip in the history
    // sheet and the new-chat → old-chat persistence loop.
    private func updateListCache(with conversation: Conversation) {
        conversationList.removeAll { $0.id == conversation.id }
        conversationList.insert(conversation, at: 0)
        listLoaded = true
    }

    func deleteConversation(id: String) async {
        do {
            try await FirebaseConversationService.delete(id: id)
            conversationList.removeAll { $0.id == id }
            if conversation?.id == id {
                // Deleted the active one — fall back to a fresh empty
                // chat in the same language so the screen isn't blank.
                startNewConversation()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // Used by the overflow "Clear conversation" action — wipes the
    // current thread from Firestore and replaces it in memory with a
    // fresh empty one so the user can start over without changing
    // language.
    func clearCurrentConversation() async {
        guard let current = conversation else { return }
        do {
            try await FirebaseConversationService.delete(id: current.id)
            conversationList.removeAll { $0.id == current.id }
        } catch {
            errorText = error.localizedDescription
        }
        conversation = makeFreshConversation(
            languageID: current.languageID,
            language: current.language,
            dialect: current.dialect,
            level: current.level
        )
        pendingScenarioPrompt = nil
        translationCallout = nil
    }

    // MARK: - Translate a tapped word

    func translateToken(_ token: String) async {
        guard let current = conversation else { return }
        // Show the callout immediately with a placeholder so the user
        // knows we heard the tap; replace with the real translation
        // when it arrives.
        let placeholderID = UUID()
        translationCallout = TranslationCallout(
            id: placeholderID,
            original: token,
            translation: "…"
        )
        do {
            let translation = try await ConversationClient.quickTranslate(
                token,
                in: current.language
            )
            // Guard against the user tapping a different word while
            // the request was in flight.
            guard translationCallout?.id == placeholderID else { return }
            translationCallout = TranslationCallout(
                id: placeholderID,
                original: token,
                translation: translation
            )
        } catch {
            guard translationCallout?.id == placeholderID else { return }
            translationCallout = TranslationCallout(
                id: placeholderID,
                original: token,
                translation: "Couldn't translate"
            )
        }
    }

    // MARK: - Recap

    func buildRecap() async {
        guard let current = conversation, !current.messages.isEmpty else { return }
        isBuildingRecap = true
        defer { isBuildingRecap = false }
        do {
            let context = ConversationClient.Context(
                language: current.language,
                dialect: current.dialect,
                level: current.level,
                scenarioPrompt: nil,
                dueWords: []
            )
            pendingRecap = try await ConversationClient.recap(
                history: current.messages,
                context: context
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Persistence helper

    private func persistCurrent() async {
        guard let current = conversation else { return }
        // Skip empty threads — saving a doc with no messages just to
        // hold a placeholder id wastes a write. Firestore stays untouched
        // until the first send().
        guard !current.messages.isEmpty else { return }
        do {
            try await FirebaseConversationService.save(current)
            // Mirror the save into the in-memory recent list so the
            // history sheet stays consistent without a re-fetch.
            updateListCache(with: current)
        } catch {
            // Persistence failures shouldn't block the user — log loudly
            // so they're visible during debugging rather than silently
            // dropping conversations.
            print("[Chat] Conversation save failed: \(error.localizedDescription) — \(error)")
        }
    }

    // Snap a passed-in dialect / level pair to the canonical entries in
    // LanguageData. Onboarding sometimes stored dialect under a
    // different scheme ("Standard" vs "Standard (Putonghua)") which
    // would silently mismatch the deck list filter; this guarantees
    // the conversation always carries strings that match what
    // CreateDeckSheet writes onto decks.
    private func makeFreshConversation(
        languageID: String,
        language: String,
        dialect: String,
        level: String
    ) -> Conversation {
        let validDialects = dialects(for: language)
        let resolvedDialect = validDialects.contains(dialect)
            ? dialect
            : (validDialects.first ?? dialect)
        let validLevels = levels(for: language)
        let resolvedLevel = validLevels.contains(level)
            ? level
            : (validLevels.first ?? level)
        return Conversation(
            languageID: languageID,
            language: language,
            dialect: resolvedDialect,
            level: resolvedLevel
        )
    }

    // Rewrites a fetched Conversation's dialect / level if they're not
    // in the language's known sets. Preserves id, messages, and
    // timestamps so the fix is invisible to the user but the recap →
    // deck-picker filter now hits the right rows.
    private static func normalizeAgainstLanguageData(
        _ conversation: Conversation
    ) -> Conversation {
        let canonical = canonicalLanguageName(conversation.language)
        let validDialects = dialects(for: canonical)
        let validLevels = levels(for: canonical)
        let resolvedDialect = validDialects.contains(conversation.dialect)
            ? conversation.dialect
            : (validDialects.first ?? conversation.dialect)
        let resolvedLevel = validLevels.contains(conversation.level)
            ? conversation.level
            : (validLevels.first ?? conversation.level)
        if canonical == conversation.language
            && resolvedDialect == conversation.dialect
            && resolvedLevel == conversation.level {
            return conversation
        }
        return Conversation(
            id: conversation.id,
            languageID: conversation.languageID,
            language: canonical,
            dialect: resolvedDialect,
            level: resolvedLevel,
            messages: conversation.messages,
            purpose: conversation.purpose,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
    }

    private func loadDecksForCurrentLanguage() async {
        guard let current = conversation else { return }
        do {
            let all = try await FirebaseDeckService.fetchDecks()
            decksForCurrentLanguage = all.filter {
                $0.language == current.language
            }
        } catch {
            decksForCurrentLanguage = []
        }
    }
}
