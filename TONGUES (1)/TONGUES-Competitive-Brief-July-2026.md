# TONGUES — Competitive Brief & Strategy Update

**July 15, 2026** · Landscape scan, position assessment, pivot question, and virality plan
*Compiled from ~40 primary sources (earnings filings, TechCrunch/Forbes coverage, Chrome Web Store data, product changelogs, community reviews). Confidence flags noted where sources conflict.*

---

## TL;DR

**Nobody has built your product.** As of July 2026, no one combines (1) an any-website highlight-to-flashcard extension, (2) a polished native mobile app with FSRS review, and (3) an AI tutor + AI-generated curriculum in one account. The space is crowded on each leg individually and empty at the intersection. **You should not pivot — you should sharpen.** The one repositioning that matters: lead with the capture loop (the extension), not the AI tutor. "AI language tutor" is the most crowded, best-funded corner of the market and Google gives it away free. "The web becomes your course" has no owner.

The clock is real, though: Duolingo shipped Flashcards in Nov 2025, Babbel owns a (frozen) browser extension, and Migaku/Trancy are approaching your intersection from opposite sides. The window is open but not indefinitely.

---

## 1. The landscape — three fronts

### Front 1: Incumbents — big, wounded, and moving into your territory

**Duolingo** is the weather. Q1 2026: 56.5M DAUs (+21% YoY), 12.5M paid subs, $292M quarterly revenue — but growth decelerated from +49% to +21% in four quarters, MAUs saw their first sequential decline, and the stock fell ~78% from its May 2025 peak on weak 2026 guidance. Its "AI-first" memo (April 2025) caused genuine brand damage — 400K+ TikTok followers lost, app deletions, an exhibit at the Museum of Failure — and it has since pivoted to prioritizing "user growth and teaching better" over monetization, pushing AI features (Explain My Answer, Video Call) down to free/cheaper tiers.

Two moves directly relevant to you:

- **Duolingo Flashcards launched Nov 18, 2025** — active-recall stacks for its top 8 languages. Crucially: **course-vocab only, no user-added words, no import from content**. They validated the mechanic without touching your wedge.
- **No Duolingo browser extension exists** (only third-party hacks like Duolingo Ninja). Duolingo's whole model is closed-course content; "learn from the open web" is structurally off-strategy for them.

**Babbel** is the only incumbent with a browser extension — it acquired **Toucan** in Sept 2023 (word-swap-while-you-browse + save vocab). But the extension was last updated **March 2024**; it's effectively in maintenance mode, and its integration with Babbel's course loop is shallow. Babbel shipped its own AI conversation product (Babbel Speak, Sept 2025) under a new CEO. **Busuu** (Chegg, in crisis — 45% layoffs) and **Memrise** (Podchats, AI Mems, Feb 2026) have AI conversation features; **Rosetta Stone** has text-based Chat Missions; **Pimsleur and Drops have essentially no AI**. None of them do flashcards-from-arbitrary-content.

**Google is the free substitute:** Google Translate added Gemini-powered "Practice" (Aug 2025) — adaptive listening/speaking sessions, positioned by press as a direct Duolingo attack. ChatGPT voice + Study Mode is the informal tutor of choice for many. Free, generic conversation practice is being commoditized in real time.

### Front 2: AI tutor startups — the crowded, well-funded corner

| Company | Money / traction | What they have | What they lack (vs TONGUES) |
|---|---|---|---|
| **Speak** | $1B valuation, **$100M+ ARR**, 15M downloads, OpenAI-backed | Voice-first course path, Smart Review SRS, custom lessons | No extension, no learn-from-your-content, weak placement |
| **Praktika** | $35.5M Series A, ~$20M+ ARR, 1.2M MAU | Avatar tutors, multi-agent curriculum planner (GPT-5.2) | No flashcards/SRS at all, no extension |
| **Issen** (YC F24) | 2-person team, $20–29/mo | Voice tutor + generated curriculum + SRS cards from conversations | No extension, weak beginner experience |
| **Langua** | Bootstrapped, ~$3.5M rev (unverified) | Content import, save-word → flashcards, AI stories from your words | No extension, no native capture loop, no placement |
| TalkPal, Loora, Gliglish, Jumpspeak, Univerbal, Toko, Lingostar | Small/stale | Conversation practice | Nearly everything else |

New money keeps flowing to the *speaking* niche (Lucida $7M seed June 2026; BoldVoice $21M Series A Jan 2026 at $10M ARR; Preply $150M at $1.2B for human+AI hybrid). Notably: **not one funded AI-tutor startup ships a browser extension or a learn-from-what-you-read loop.** And **no competitor anywhere brands or confirms FSRS** — the algorithm gold standard is commoditized in Anki but unclaimed in consumer products.

### Front 3: The capture/immersion tools — your closest structural relatives

This is the segment to watch. Each near-miss fails on a different leg:

| Tool | Users | Has | Fatal gap |
|---|---|---|---|
| **Language Reactor** | **2M Chrome users** | Netflix/YouTube dual subs, saved words | No mobile app, no real SRS, stagnant since ~2022, clunky Anki export |
| **Migaku** | ~40K Chrome, $9–11/mo | **Extension + native iOS/Android + built-in SRS** — closest overall | No AI tutor/curriculum, "FSRS-compatible" (unverified), chronic UX complaints, no free tier, steep setup |
| **Trancy** | 300K Chrome, 4.7★ | Extension + mobile + AITalk chat — widest surface | Shallow/unverified SRS, mobile is review-only companion, translation-tool DNA |
| **LingQ** | 15+ yr veteran | Importer + mobile + Lynx AI tutor ($42/mo tier) | SRS review is its most-complained-about feature; legacy UX debt |
| **Relingo** | 40K Chrome, $29.90/yr | Auto-highlight unknown words + mobile | No tutor, no serious SRS, CN-market English focus |
| **Yomitan + Anki (FSRS)** | free DIY | The full capture→FSRS-mobile loop | Hours of setup, no AI, no sync polish, no tutor — the power-user benchmark you're productizing |

A visible wave of 2025–26 micro-startups (Linglass, Lexpresso, TubeVocab…) exists purely to farm "Language Reactor alternative" SEO — several market FSRS explicitly — but none has a native mobile app. **Language Reactor's 2M stagnant users are the single most obvious poaching pool in the category.**

---

## 2. The whitespace, stated precisely

Your stack — **any-website capture → context-aware AI card (with the sentence, the source URL, human Forvo audio) → instant Firestore sync → native FSRS mobile review → AI tutor + curriculum that know your words** — has no direct incumbent. The competitive map splits cleanly:

- AI tutor apps (Speak, Praktika…) have the intelligence but **no connection to what you actually read**.
- Capture tools (Migaku, Trancy, LR…) have the connection but **no intelligence and/or no mobile polish**.
- Incumbents have distribution but are **structurally committed to closed course content**.

Secondary whitespace worth owning in marketing: **placement tests are a universal weak spot** (self-select level is the norm everywhere, even Speak), and **nobody claims FSRS by name** despite it being the community's known gold standard. Both are cheap credibility wedges with the serious-learner crowd on Reddit/YouTube.

---

## 3. How you're doing — an honest read

**What's strong:**

- **Right product at the right intersection.** Confirmed above — and your architecture doc shows you understand the moat is the *loop* (one Firebase project, one schema, card-on-phone-in-seconds), not any single feature.
- **Pricing is genuinely well-built.** Usage-gated tiers with unit economics done properly ($12.99 Pro / $29.99 Max, ~70–75% margin on typical Pro users) — you're ahead of most seed-stage consumer apps here. Your instinct to keep FSRS review unlimited on free is exactly right: the free tier should own the habit, and it costs you nothing.
- **Brand is a real asset, not a placeholder.** The black-and-white mouth/ear/hands photography system is distinctive in a category drowning in mascots and Memphis-style illustration. Premium visual identity supports premium pricing.
- **Marketing groundwork is unusually mature for this stage.** A 50-creator vetted outreach list (with conflict screening — most funded startups don't do this), a swear-word UGC campaign brief with the two-cut (organic spicy / paid clean) structure already solved, and a World Cup activation window. This is a coherent go-to-market, not vibes.

**What's exposed:**

- **The extension isn't shipped.** Deliverable is July 2026 — i.e., now. Everything strategic in this brief depends on it. Until it ships, TONGUES is competitively just another AI tutor app, and that market has a $1B leader.
- **No share loop in the product yet.** Your review flow is private by design; nothing currently generates the artifact people post (see §5). Praktika gets 60% of new users from word of mouth because sharing is engineered in.
- **Solo-founder speed vs. a closing window.** Migaku ships monthly; Duolingo published 20,500 course units in Q1 2026 alone via AI. Your defense is focus, not breadth: the capture loop end-to-end, polished, before anything else.
- **Timing pressure on the campaign itself:** your brief targets the World Cup knockouts, which run **through July 19** — that window is closing this week. Either execute a compressed version now or explicitly re-anchor the campaign to the next cultural moment (see §5).

Grade, if you want one: **product thesis A, execution timing B-, distribution readiness B+ (planned, unproven).**

---

## 4. Should you pivot?

**No. Reposition the lead, keep the product.** Three specific adjustments:

**1. Lead with the loop, not the tutor.** Every funded competitor says "AI language tutor." Google gives conversation practice away free. If your homepage and App Store listing lead with the tutor, you're a worse-funded Speak. If they lead with *"highlight a word anywhere on the internet — it's a flashcard on your phone before you've finished the article"*, you have no competitor and an obvious demo video. The tutor becomes the retention layer ("...and your tutor already knows every word you've saved"), which is where it's most defensible anyway.

**2. Claim FSRS and real placement loudly.** Cheap, honest differentiation that the serious-learner community (r/languagelearning, Anki refugees, LR's 2M stagnant users) will actually verify and respect. "The algorithm Anki power users trust, without the afternoon of setup" is a complete Reddit pitch.

**3. Don't market the AI, market the outcome.** The Duolingo AI-first backlash is the cautionary tale of the cycle: leading with "AI-powered" now carries brand risk and zero differentiation. Your photography brand — "language is something the body does, between people" — is the perfect counter-position: deeply human brand, quietly excellent AI underneath.

**Watch-and-respond triggers** (monitor quarterly): Duolingo adding user-added words/import to Flashcards (their most dangerous possible move — mitigation: be so entrenched with serious learners that Duolingo's version reads as a toy); Babbel waking Toucan up; Migaku shipping an AI tutor; Speak shipping an extension. None has happened yet.

---

## 5. Making it viral — what the evidence supports

The proven playbooks in this exact category, ranked by fit:

**A. The Praktika template (highest-confidence fit).** Praktika went $1K → $100K MRR in ~3 months on one insight: find a micro-creator with an *outlier view-to-follower ratio* (their guy had 10K followers but 2–3M views/video), sign an exclusive deal, and build the format around **funny failure** — the creator making ridiculous mistakes with the AI. Then re-run winning organic formats as paid ads. Your creator list is already screened for exactly this ("comedic timing over follower count") — your job is to find your Gustavo among the A-tier rows and go deep with 1–2 rather than shallow with 25.

**B. Your swear-word campaign is validated white space — run it.** The research found *no documented profanity-led campaign by any language app* despite "swear words in X" being a durable high-engagement TikTok vein and Duolingo proving adult humor works (until they retreated from "unhinged" in 2026 — leaving that lane emptier). Your two-cut structure already solves the ad-policy problem. One adjustment: the World Cup hook expires July 19. Salvage what you can this week with 3–5 fast creators, then re-anchor the evergreen version to "the words the textbook won't teach you" — it doesn't need the tournament.

**C. Build the demo that markets itself.** The single most TikTok-able thing you own is the sync magic trick: *highlight a word on a laptop, and the phone lying next to it lights up with the card within seconds.* One continuous shot, no cuts, ends the "is this real" debate in-frame. This should be the hero video on the site, the first creator brief, and the App Store preview. (Cal AI's founder posted 281 organic videos of his own product before spending a dollar — founder-posted demo volume is a legitimate channel.)

**D. Engineer the share artifact.** Duolingo's Year in Review lesson: personality-type cards ("learner styles") drove significantly more shares than stat cards, and power users generate most shares. Your version is better than theirs because your data is *provenance*: "Words I learned from Le Monde this month," "My vocabulary DNA: 40% football, 25% cooking, 35% profanity." Nobody else can generate that card, because nobody else knows where your words came from. Ship a monthly recap card before you ship any referral program.

**E. Community embedding for the extension (slow burn, compounding).** Extensions don't go TikTok-viral; they grow through the immersion-learning scene — Reddit (r/languagelearning: 3.4M members, self-promo tolerated at ~9:1 participation ratio, so start commenting now), the Anki/Yomitan Discord world, and "Language Reactor alternative" / "Migaku vs" SEO, which a wave of micro-startups is already farming. Product Hunt is largely dead for consumer (0.5–2% conversion); Reddit converts 3–8%.

**F. Newsjack language moments.** The precedent: TikTok-ban → RedNote migration drove +216% US Mandarin learners in a week and Duolingo rode it hard. Your extension is uniquely suited to react — "reading about X in the news? Learn the words as you read" — within 24–48h of any language-adjacent spike (visa rules, a breakout anime/K-drama, a World Cup final between two specific countries on July 19).

**What to skip:** rage-bait launches (Cluely's playbook bought awareness, then imploded); paid referral cash incentives before product-market fit; oversized creator deals (your own screening already excluded them — correct); leading ads with "AI-powered" (see §4.3).

---

## 6. The one-page action view

| Horizon | Action |
|---|---|
| **This week** | Ship/finish the extension (Phase 1 loop end-to-end). Salvage World Cup cuts with 3–5 fast creators before July 19. Film the sync magic-trick demo. |
| **This month** | Reposition homepage/App Store around the capture loop. Start Reddit participation (not promotion). Pick 2 A-tier creators for a Praktika-style deep partnership test. |
| **This quarter** | Ship the monthly provenance recap card (share artifact). Run the evergreen "words the textbook won't teach you" campaign with two-cut structure. Claim FSRS + real placement test in all serious-learner channels. |
| **Monitor** | Duolingo Flashcards adding user words; Toucan revival; Migaku AI tutor; Speak extension. Quarterly check is enough. |

---

## Appendix: source notes & confidence

Key data points and where they came from (all accessed July 15, 2026):

- Duolingo Q1 2026 figures: [SEC shareholder letter](https://www.sec.gov/Archives/edgar/data/1562088/000162828026029790/q1fy26duolingo3-31x26share.htm); stock decline: [Fast Company](https://www.fastcompany.com/91499936/duolingo-stock-price-falls-dramatic-collapse-ai-first-memo); Flashcards launch: [Duolingo blog](https://blog.duolingo.com/duolingo-flashcards/); AI-first backlash: [TechCrunch](https://techcrunch.com/2025/04/30/duolingo-launches-148-courses-created-with-ai-after-sharing-plans-to-replace-contractors-with-ai/), [Fortune](https://fortune.com/2025/06/09/duolingo-ceo-surprised-backlash-ai-first-company-announcement/)
- Speak $100M ARR / $1B valuation: [Forbes, Nov 2025](https://www.forbes.com/sites/rashishrivastava/2025/11/12/this-startup-is-racing-duolingo-to-replace-human-language-tutors-with-ai/), [TechCrunch](https://techcrunch.com/2024/12/10/openai-backed-speak-raises-78m-at-1b-valuation-to-help-users-learn-languages-by-talking-out-loud/)
- Praktika growth playbook: [Consumer Startups](https://www.consumerstartups.com/p/praktika-ai), [OpenAI case study](https://openai.com/index/praktika/) (vendor-sourced — treat metrics as marketing)
- Migaku, Trancy, Language Reactor, Relingo user counts: Chrome Web Store / [chrome-stats.com](https://chrome-stats.com) listings; feature detail from [immit review](https://immit.co/blog/migaku-review-2026-is-it-worth-it-for-japanese-learners), [Lexpresso comparison](https://lexpresso.io/blog/language-reactor-vs-migaku-vs-trancy-vs-lexpresso/), [Migaku changelog](https://migaku.com/blog/changelog)
- Toucan frozen since Mar 2024: [chrome-stats](https://chrome-stats.com/d/lokjgaehpcnlmkebpmjiofccpklbmoci); Babbel acquisition: [TechCrunch](https://techcrunch.com/2023/09/19/babbel-acquires-language-learning-browser-extension-toucan/)
- Google Translate Practice: [TechCrunch, Aug 2025](https://techcrunch.com/2025/08/26/google-translate-takes-on-duolingo-with-new-language-learning-tools/)
- Duo-death campaign numbers: [PR Daily](https://www.prdaily.com/duolingo-shares-pr-secrets-of-viral-death-of-duo-campaign/), [Meltwater](https://www.meltwater.com/en/blog/duolingo-dead-mascot-campaign); Year in Review share mechanics: [Duolingo blog](https://blog.duolingo.com/year-in-review-behind-the-scenes/); Friend Streak +22%: [Duolingo blog](https://blog.duolingo.com/product-lessons-friend-streak/)
- RedNote Mandarin spike: [TechCrunch](https://techcrunch.com/2025/01/15/duolingo-sees-216-spike-in-u-s-users-learning-chinese-amid-tiktok-ban-and-move-to-rednote/); Cal AI playbook: [Growthcurve](https://growthcurve.co/three-engines-and-an-exit-the-cal-ai-growth-playbook); Reddit/PH channel comparison: [luka.to analysis](https://luka.to/blog/product-hunt-dead-indie-hackers-first-users-2026) (single source — directional)

**Known uncertainties:** Migaku's actual SRS algorithm ("FSRS-compatible" is self-described); Migaku pricing varies across sources ($9–20/mo); Langua/TalkPal revenue figures are third-party estimates; Reddit sentiment was gathered via secondary review blogs (direct Reddit access unavailable); Toucan's development status inferred from update timestamps, not an official statement. Nothing in the strategic conclusions hinges on these.
