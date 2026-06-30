# TONGUES — Subscription Pricing

**Date:** June 2026
**Core constraint:** Every AI tutor message, deck, plan, and placement test is a live Anthropic API call. Audio adds a second cost layer (Forvo for words, ElevenLabs for sentences). Pricing is gated by AI usage, not just features — because usage *is* the cost.

> **Terminology:** Here, **"message"** = one turn in the AI tutor *chat* (the conversational back-and-forth). **"Generation"** = creating a deck or a curriculum plan. These are separate cost buckets and separate caps. If your app groups these differently (e.g. a single "generation tab"), tell me and I'll re-map the caps to your actual surfaces.

---

## The unit economics (what each action actually costs you)

Built on current API rates — Sonnet 4.6 ($3 / $15 per M tokens), Haiku 4.5 ($1 / $5), with prompt caching on the static system prompt + tool definitions (90% off cached input). Classifiers/clustering run on Haiku and are effectively free.

| Action | Model | Est. cost per action |
|---|---|---|
| Tutor chat turn (agent loop w/ tools) | Sonnet 4.6 | ~$0.02–0.04 |
| Plain conversation turn | Sonnet 4.6 | ~$0.015 |
| Deck generation (~20 cards) | Sonnet 4.6 | ~$0.04–0.05 |
| Curriculum plan (~2.5k tokens) | Sonnet 4.6 | ~$0.05 |
| Placement test (6 turns + grade) | Sonnet 4.6 | ~$0.10 |
| Classifiers / clustering | Haiku 4.5 | <$0.005 |

**Flashcard review (FSRS), saved decks, and browsing cost nothing** — no API call. So those stay unlimited on every tier; only *generation* and *live tutoring* are metered.

### Audio (on-demand, cached — the efficient setup)

Audio is generated only when a user taps to hear it, then cached and reused forever. Words pull human recordings from **Forvo**; sentences use **ElevenLabs** TTS. This keeps audio a minor cost:

| Source | What it voices | How it's billed | Cost impact |
|---|---|---|---|
| **Forvo** | Single vocab words | Flat $28.95/mo (commercial, 10k req/day), cached forever | **Fixed ~$29/mo overhead** — ~$0 per user |
| **ElevenLabs** | Sentences (~50 chars) | Per character, ~$0.08 / 1k chars (Flash/Turbo) | ~$0.004 per unique sentence, paid once |

Because audio is on-demand + cached and words are flat-rate, the per-user audio variable is small: roughly **$0.50–1/mo** for a Pro user and **$2–3/mo** for a heavy Max user. Forvo's ~$29/mo is a fixed company overhead, amortized across your whole base. Chat is text-only (not read aloud), so tutor-message cost is unchanged.

A typical engaged daily learner consumes roughly **$3–5/month** all-in (text + audio). A heavy power user can reach **$12–18/month**. The caps below are set so the worst case still clears margin, while the average user never feels them.

---

## The three tiers

Grouped by capability, anchored by usage. Naming can flex (Free / Pro / Max shown), but **Max is the top tier**.

| | **Free** | **Pro** | **Max** |
|---|---|---|---|
| **Price** | $0 | **$12.99/mo** · $99.99/yr | **$29.99/mo** · $249.99/yr |
| **Best for** | Trying it out | The daily learner | Polyglots & power users |
| **Languages** | 1 | Up to 3 | Unlimited |
| **AI tutor messages** | 30 / month | 300 / month (~10/day) | 1,500 / month (fair use) |
| **AI generations** (decks + plans) | 3 / month | 30 / month | 150 / month (fair use) |
| **Guided curriculum** | Preview only | Full plan + weekly replanning | Full + longest plans |
| **Placement tests** | 1 (one-time) | Unlimited | Unlimited |
| **Flashcard review (FSRS)** | Unlimited | Unlimited | Unlimited |
| **Pronunciation feedback** | — | ✓ | ✓ |
| **Generation speed** | Standard | Priority queue | Fastest / priority |
| **Plan-generation model** | Sonnet | Sonnet | Premium (Opus) for plans |
| **New features** (voice/live mode) | — | — | Early access |

*Annual saves ~36% on Pro and ~30% on Max. Offer a 7-day Pro trial to convert Free users at their first cap.*

---

## Why these numbers

**Free is a funnel, not a product.** 30 tutor messages (~1/day) and 3 generations is enough to feel the "wow" — make a study plan, generate a deck, have a few real conversations — and hit a wall right when the habit forms. API ceiling: ~$1/user. Keep this cheap; it's marketing spend.

**Pro is the business.** 300 messages (10/day) and 30 generations covers a genuinely committed learner doing focused daily sessions. Worst-case cost ~$7–8/month (text + audio) against ~$12.40 net (web/Polar checkout); the *typical* Pro user spends ~$3–4 all-in, an **~70–75% margin**. This is the tier most people should land on.

**Max is the anchor and the ceiling.** It exists to (1) make Pro look reasonable by comparison and (2) capture your most committed users without bleeding money. The 1,500-message "fair use" cap feels unlimited to any real human (50/day) but stops abuse. Premium model + early-access features justify the 2.3× price jump. Even typical Max users (~$12–18 all-in) leave margin; the rare cap-hitter is a known, bounded risk.

*Note on audio: because it's on-demand + cached, audio doesn't change the caps — it adds ~$0.50–3/user/mo of variable cost plus the flat ~$29/mo Forvo overhead, already reflected above. If you ever switch to pre-generating audio for every card or reading chat replies aloud, audio becomes a dominant cost and these caps would need to tighten.*

---

## Two things to decide

**1. Where you sell.** The other sessions show you're on Polar.sh — keep primary checkout on **web/Polar** (Merchant of Record, ~4% fees → ~$12.40 net on Pro). If you also ship App Store IAP, the 30% cut year-one (15% after) compresses Pro margins hard; price App Store ~20% higher or steer to web.

**2. Credits vs. caps.** I've written limits as plain caps ("300 messages") because they're transparent and easy to reason about. The alternative is a unified **"AI credit"** pool (1 chat = 1 credit, 1 generation = 2) — more flexible for users, but fuzzier. Caps are the safer default for launch.

---

## Quick gut-check on naming

- **Free / Pro / Max** — clean, "Max" as requested, instantly legible.
- **Free / Plus / Max** — "Plus" reads friendlier/more consumer than "Pro."
- **Starter / Fluent / Max** — on-theme for a language app; "Fluent" is the aspiration you're selling.

My pick: **Free / Pro / Max** for clarity, or **Free / Fluent / Max** if you want the mid-tier name to do marketing work.

---

*Sources:* Anthropic API rates — finout.io, cloudzero.com, metacto.com. Audio — elevenlabs.io/pricing, api.forvo.com/plans-and-pricing (all June 2026).
