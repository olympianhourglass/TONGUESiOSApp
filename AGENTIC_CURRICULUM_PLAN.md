# TONGUES — Agentic Curriculum Design Doc

*June 2026 · Grounded in the current codebase (ChatViewModel, ConversationClient, DeckGenerator, FSRSScheduler, FirebaseDeckService, XPService, onboarding models)*

---

## 0. Reading list (start here)

Five things, in order. The first two are the core of how this gets built; the rest are domain background.

1. **Anthropic — "Building Effective Agents"** (anthropic.com/research/building-effective-agents). The single most useful read. Its core argument maps exactly to your situation: you don't need a fully autonomous agent — you need *workflows* (prompt chaining, routing) plus one well-scoped *agent loop* (the chat tutor with tools). It will stop you from over-building.
2. **Anthropic — Tool Use docs** (docs.claude.com/en/docs/build-with-claude/tool-use). The API mechanism everything below rests on. Today every call in `DeckGenerator` and `ConversationClient` is "please return only JSON" + `extractJSON()`. Tool use replaces that with schema-enforced calls and — more importantly — lets Claude *invoke your app's functions* (create a deck, read progress) mid-conversation.
3. **FSRS wiki — "ABC of FSRS"** (github.com/open-spaced-repetition/fsrs4anki/wiki). You already implemented FSRS-5 (`FSRSScheduler.swift` is a clean reference implementation). Read the sections on stability/difficulty semantics — the curriculum agent will use those two numbers as its primary "what does this learner actually know" signal.
4. **CEFR self-assessment grid + can-do descriptors** (Council of Europe, search "CEFR self-assessment grid"). Your levels are already CEFR (A1–C2 in `DeckAttribute.level`). Can-do statements ("can order food", "can describe past events") are the right *unit* for a curriculum — they're checkable, and they map naturally to your scenario chips and deck topics.
5. **Anthropic — "Effective context engineering for AI agents"** (anthropic.com/engineering). How to keep a long-running tutor agent's context small: compact summaries, structured memory docs, just-in-time retrieval. This is the "learner model" pattern below.

---

## 1. What you have today (audit)

The good news: you've already built ~70% of the raw material for an agentic curriculum. What's missing is the connective tissue — a memory, a plan object, and a tool-using loop.

**Already in place:**

- **Chat with pedagogy baked in** — `ConversationClient.sendTurn` does level-calibrated conversation, inline corrections, transliteration, per-turn translation. Corrections are persisted per message (`ConversationMessage.corrections`).
- **Deck generation** — `DeckGenerator.generate` produces decks from language/dialect/level/interests/prompt. Decks carry provenance (`userPrompt`, `interests`, `promptSent`).
- **A real memory algorithm** — FSRS-5 with per-card `CardSchedule` (stability, difficulty, lapses), a `CardReview` event log, per-deck urgency scoring, and `targetRetention` per deck.
- **Rich motivational onboarding** — `OnboardingAnswers` captures `motivationDetail`, `fluencyScene`, `firstUnderstand`, `heritageBackground`, `interests`, `destinations`, ordered `languagePreferences`. This is exactly the data a curriculum planner needs… and today it's only used for the onboarding summary screen and Explore suggestions.
- **Behavioral stats** — `XPService` tracks streaks, xpByDay, flashcard vs. audio session counts; `PronunciationAttempt` history is persisted per sentence.
- **Activity surface area** — flashcards, listen sessions, pronunciation drills, sentence studio, content generation (stories/dialogues/songs), camera vocab, recap-to-deck. These become the curriculum's *activity types*.

**The gaps:**

1. **No learner model.** Knowledge is scattered: FSRS state knows what they remember, conversations know what they get wrong, onboarding knows why they're learning — nothing unifies it. Every AI call gets a thin slice of context.
2. **No plan object.** There is nothing in Firestore that represents "where this learner is going and what comes next." Decks are islands.
3. **No tools.** `AnthropicClient` is a bare `/v1/messages` text call. Claude can *describe* a curriculum but can't *do* anything — can't create the deck it recommends, can't look up your weak words. That's the difference between a chatbot and an agent, and it's the thing users feel.
4. **Designed-but-disconnected loops.** `ConversationClient.Context.dueWords` exists so chat can weave in FSRS-due vocab — but `ChatViewModel.send()` passes `[]`. The recap → deck pipeline exists but is user-initiated only. Corrections are stored but never aggregated.
5. **Architecture constraint.** The API key is hardcoded client-side (rotate it!), all calls are stateless one-shots, and nothing can run when the app is closed.

---

## 2. The concept

Three new nouns, one new capability:

| Piece | What it is | Where it lives |
|---|---|---|
| **Learner Model** | One compact doc per user per language: level estimate, goals, weak skills, known/lapsed vocab summary, habits | `users/{uid}/learnerModels/{languageID}` |
| **Curriculum Plan** | Ordered units with can-do goals, each unit linking to generated decks + activities + a mastery gate | `users/{uid}/curricula/{languageID}` |
| **Tutor Agent** | The existing chat, upgraded with tools — it can read both docs, write both docs, and create decks mid-conversation | `ConversationClient` → agent loop |
| **Guided Decks** | Decks generated *by the plan*, gap-aware (skip mastered words, recycle lapsed ones), stamped with `planUnitId` | existing `DeckDocument` + 2 fields |

The user experience you're after — "the AI is robust enough to guide me" — comes from one moment: the user says *"help me get ready for my trip to Osaka in October"* and the agent **looks at their actual data** (tool calls they can see happening), **proposes a concrete plan** (rendered as a native card, not a wall of text), and **builds the first deck on the spot**. Everything below is in service of that moment.

---

## 3. Phase 0 — Plumbing (prerequisite, ~1 week)

**3.1 Proxy the API key.** Move Anthropic calls behind a Firebase Cloud Function (you already have Firebase wired: `.firebaserc`, `firebase.json`, Firestore, Auth). The function verifies the Firebase Auth token, forwards to Anthropic, returns the response. `AnthropicClient.sendMessage` changes its URL and auth header; every call site stays identical. This kills the leaked-key problem and gives you a place to do server-side agent work later (Phase 4), per-user rate limiting, and model routing you can change without an App Store release.

**3.2 Add tool use + streaming to `AnthropicClient`.** Extend the request body with `tools` and `tool_choice`, handle `stop_reason: "tool_use"`, and add a streaming variant (SSE). Keep the old text-only `sendMessage` for all the existing one-shot calls — don't migrate them; they're fine as workflows.

**3.3 Build the Learner Model doc + aggregator.** A pure-Swift `LearnerModelBuilder` that composes what you already store:

```json
{
  "language": "Japanese", "dialect": "Standard",
  "levelEstimate": { "value": "A2", "confidence": 0.6, "source": "onboarding|placement|inferred" },
  "goals": {
    "motivation": "<onboarding.motivationDetail>",
    "fluencyScene": "<onboarding.fluencyScene>",
    "firstUnderstand": "<onboarding.firstUnderstand>",
    "destinations": ["Osaka"], "interests": ["Cooking", "Film"],
    "heritage": "<onboarding.heritageBackground>",
    "targetDate": null
  },
  "vocab": {
    "totalCards": 412, "mature": 180, "young": 96, "new": 60, "lapsing": 23,
    "weakWords": [{ "word": "難しい", "lapses": 4, "stability": 1.2 }],
    "recentTopics": ["food", "directions"]
  },
  "skills": {
    "recurringErrors": [{ "pattern": "particle は/が", "count": 7, "examples": ["..."] }],
    "pronunciationTrouble": [{ "phoneme": "long vowels", "evidence": "3 drills < 60" }]
  },
  "habits": { "streak": 12, "preferredMethod": "active", "bestTime": "evening", "minutesPerDay": 9 },
  "updatedAt": "..."
}
```

Sources, all existing: FSRS `CardSchedule`s (vocab block — *mature* = stability > 21d, *lapsing* = lapses ≥ 3 or recent `again`), `ConversationCorrection`s aggregated across threads (recurringErrors — one cheap Haiku call to cluster them, like your `summarizeFavoriteTopic` pattern), `PronunciationAttempt`s, `XPService` (habits), `OnboardingAnswers` (goals). Rebuild it on app open if stale (> 24h) or after a study session; it's cheap because it's mostly arithmetic.

**Quick win to ship alongside Phase 0:** populate `dueWords` in `ChatViewModel.send()` from the FSRS schedules (the parameter already exists and the system prompt already handles it) and inject a one-line goals summary from onboarding into `buildSystemPrompt`. Two small changes; chat immediately feels like it knows the user.

---

## 4. Phase 1 — The tool-using tutor in chat (~2–3 weeks)

This is the centerpiece. The chat becomes an agent loop.

**4.1 Tool definitions.** Start with six. Tools execute *on-device* against your existing services — the loop runs in Swift, dispatching `tool_use` blocks to local functions and returning `tool_result` blocks. (The Anthropic round-trip goes through the proxy; the tools themselves are local since all data is already client-accessible via the Firestore SDK.)

| Tool | Maps to | Returns |
|---|---|---|
| `get_learner_model` | read the Phase-0 doc | the JSON above |
| `list_decks(language)` | `FirebaseDeckService.fetchDecks` | id, title, level, topic, card count, mastery % |
| `get_deck_progress(deckId)` | FSRS schedules + urgency | due/new/mature counts, weakest cards |
| `create_deck(spec)` | `DeckGenerator.generate` + save | deck id + preview items |
| `get_curriculum` / `update_curriculum(plan)` | Phase-2 doc (no-op stub in Phase 1) | plan JSON |
| `get_review_history(query)` | `studySessions` log | recent results, filterable by word/date |

Design rules: every tool result must be compact (summaries, not raw dumps — don't return 412 schedules); every mutating tool (`create_deck`, `update_curriculum`) returns a *proposal* the UI renders for confirmation rather than committing silently. The user taps "Save deck" — agent proposes, user disposes. This keeps trust high and bugs cheap.

**4.2 The loop.** New `TutorAgent` service, alongside (not replacing) `ConversationClient`:

```
send(history, userText, learnerModel) →
  while stop_reason == "tool_use" (max 6 iterations):
    execute tools locally → append tool_results → call again
  → final structured reply (same JSON contract as today: reply/transliteration/corrections)
```

System prompt = today's `buildSystemPrompt` + the learner model JSON + tool guidance ("when the learner asks about progress, what to learn next, or for a plan/deck, use tools rather than guessing; keep conversation in the target language but conduct planning in English"). Route this on Sonnet — tool orchestration doesn't need Opus, and the loop multiplies token cost; keep plain conversational turns on the current path/model and only enter the agent loop when routing detects a meta-request (a cheap Haiku classifier on the user's message: *conversation* vs. *meta/planning* — this is the "routing" workflow from the Anthropic essay).

**4.3 Visible agency in the UI.** Two changes to `ChatView`:

- **Tool activity chips** while the loop runs: "Reviewing your decks…", "Checking your weak words…". This latency *builds* the robustness perception rather than hurting it — the user watches the tutor actually look things up.
- **Structured message attachments.** Extend `ConversationMessage` with an optional codable `attachment` enum: `.deckProposal(items, spec)` (preview card + Save button → existing `DeckResultsView` path), `.planCard(planSummary)` (Phase 2), `.progressSnapshot(stats)`, `.drillSuggestion(sentence)` (launches `PronunciationDrillSheet`). Decode unknown cases to nil so old messages keep loading — same backward-compat trick you already use everywhere.

**Phase-1 acceptance test:** "What should I work on?" → agent calls `get_learner_model` + `list_decks`, replies with one paragraph naming the user's actual weak area and a tappable deck proposal targeting it; user taps Save; deck appears in the Library. No plan object needed yet — this alone delivers most of the perceived magic.

---

## 5. Phase 2 — The Curriculum Plan (~2 weeks)

**5.1 Schema.** `users/{uid}/curricula/{languageID}`:

```json
{
  "goalStatement": "Conversational Japanese for an Osaka trip",
  "targetLevel": "B1", "targetDate": "2026-10-01",
  "status": "active",
  "units": [{
    "id": "u1", "order": 1, "title": "Getting around",
    "canDo": ["Ask for and follow directions", "Buy train tickets"],
    "status": "active",            // locked | active | completed
    "deckIds": ["abc123"],          // guided decks stamped with this unit
    "plannedActivities": [
      { "type": "deck",        "spec": { "topic": "train stations", "contentType": "Phrases", "amount": "20" } },
      { "type": "conversation","spec": { "scenario": "Buying a ticket at Osaka station" } },
      { "type": "pronunciation","spec": { "focus": "long vowels" } },
      { "type": "content",     "spec": { "kind": "Conversation", "topic": "asking directions" } }
    ],
    "masteryGate": { "matureFraction": 0.8, "conversationCheck": true }
  }],
  "createdBy": "agent", "revision": 3, "updatedAt": "..."
}
```

Notes: `canDo` strings are the CEFR-style checkable goals. `plannedActivities.type` maps 1:1 onto surfaces you already built (deck → `DeckGenerator`, conversation → scenario chip, pronunciation → drill sheet, content → `generateContent`). `masteryGate.matureFraction` is computable today from FSRS stability — no new tracking needed. `conversationCheck` means the unit closes with a scenario conversation the agent grades (it already produces corrections; "≤ N corrections across the check conversation" is the pass bar).

**5.2 Plan generation** is a single (non-agentic) Opus/Sonnet call — a workflow, not a loop: learner model in, plan JSON out, 4–8 units, each unit ≤ ~2 weeks at the user's observed `minutesPerDay`. Triggered from chat ("make me a plan") via `update_curriculum`, or from a "Create my plan" card on Explore/Study for users who never open chat. Always rendered as a proposal card the user confirms.

**5.3 Guided decks.** Add `planUnitId: String?` and `source: String?` ("agent" | "user") to `DeckDocument` (optional fields — legacy decks decode fine). When the agent generates a unit deck, extend the `DeckGenerator` prompt with: *known words to exclude* (mature cards' foreign sides) and *lapsing words to recycle* (work 3–5 of them in). This is what makes guided decks feel personal rather than generic — the deck literally avoids what you know and re-attacks what you keep forgetting.

**5.4 Surfacing — "Today" strip.** On the Study tab (or top of chat), assembled with zero AI calls: ① due reviews (FSRS already knows), ② next planned activity of the active unit, ③ one-line "why" from the plan. The plan itself gets a simple native view (units as a path, can-dos as checkmarks, progress = matureFraction). Tapping any item deep-links to the existing surface.

---

## 6. Phase 3 — The loop closes: maintenance & adaptation (~2–3 weeks, ongoing)

A curriculum users trust is one that *reacts*. Three mechanisms, in increasing order of ambition:

**6.1 On-open reconciliation (deterministic, free).** On app open: recompute mastery for the active unit; if the gate is passed, mark complete + unlock next (with an XP toast — `XPService` is right there); if the user is idle 5+ days, don't guilt — shrink. Flag `needsReplan` if drift is large (e.g., user ignored unit decks but did 200 reviews elsewhere).

**6.2 Agent-driven re-planning (cheap call, weekly or on `needsReplan`).** Feed the learner model delta + plan to Sonnet: "revise the remaining units." Constraints: never edit completed units; output a diff-style summary the user sees as a chat message from the tutor — *"You've nailed directions vocab faster than planned, and は/が keeps biting you — I've pulled the particles unit forward. [View changes]"*. That message — the agent noticing — is the single strongest "this thing is guiding me" signal in the entire system.
**Signals feeding it:** aggregated `ConversationCorrection` patterns, `PronunciationAttempt` scores, FSRS lapse clusters, pace (planned vs. actual minutes), recap phrases the user chose to save (revealed interest).

**6.3 Scheduled background runs (needs the Phase-0 proxy).** A scheduled Cloud Function runs the weekly checkpoint server-side and writes the revision + a pending tutor message, so the user opens the app to find the curriculum already adjusted. Pair with your existing widget: the lock-screen widget cycles words from the *active unit's* deck.

---

## 7. Phase 4 — Placement & assessment (polish, ~1–2 weeks)

Onboarding level is self-reported (`currentLevel`), which is famously wrong in both directions. Two cheap fixes:

- **Conversational placement.** First chat in a new language: the tutor runs a 6–8 turn adaptive conversation, starting at the claimed level, stepping difficulty up/down by correction density, then calls a `record_placement` tool to write `levelEstimate` (with confidence) to the learner model. It's just a scenario + a tool — almost free given Phase 1.
- **Continuous calibration.** Corrections-per-turn and FSRS difficulty drift update `levelEstimate.confidence` over time; the re-planner reads it.

---

## 8. Cross-cutting concerns

**Model routing.** Conversation turns: keep current model. Agent loop: Sonnet. Plan generation / weekly replan: Sonnet (try Opus only if plan quality disappoints). Classifiers, clustering, summaries: Haiku, like your existing utility calls. The proxy makes routing a server-side config knob.

**Cost envelope.** The agent loop is the only multiplier (2–4 round trips when triggered). With routing-gated entry, expect the average chat-heavy user to cost only ~1.5–2× today. Plan generation is rare. Phase-3 reconciliation is mostly arithmetic.

**Latency.** Stream the final response always; show tool chips during the loop; cap at 6 tool iterations with a graceful "here's what I found so far" fallback.

**Trust & safety rails.** Mutating tools always propose, never commit. Plan revisions never touch completed work. The agent never invents progress numbers — if a tool fails, it says so. Cap decks-created-per-conversation (3) to prevent runaway loops.

**Schema evolution.** You already follow optionals-with-fallback everywhere (`coverStyle`, `targetRetention`, `addedAt`) — keep that discipline for `attachment`, `planUnitId`, learner-model fields.

**Evaluation.** Build a tiny harness before Phase 1 ships: ~20 canned learner models + user messages, assert on the *tool-call trace* (did it consult the learner model before recommending? did it propose rather than commit?), and rubric-grade final replies with Haiku. Re-run on every prompt change. This is cheaper than debugging vibes in TestFlight.

---

## 9. Build order summary

| Phase | What ships | User-visible? | Effort |
|---|---|---|---|
| 0 | Key proxy, tool-capable client, learner model, `dueWords` quick win | Chat subtly smarter | ~1 wk |
| 1 | Tool loop in chat, deck proposals, tool chips, attachments | **The wow moment** | 2–3 wks |
| 2 | Plan schema + generation, guided decks, Today strip, plan view | Visible curriculum | ~2 wks |
| 3 | Mastery gates, weekly replan, tutor-notices messages | "It's guiding me" | 2–3 wks |
| 4 | Conversational placement, continuous calibration | Better targeting | 1–2 wks |

Each phase is independently shippable, and 0→1 alone delivers most of the perceived robustness you're describing.
