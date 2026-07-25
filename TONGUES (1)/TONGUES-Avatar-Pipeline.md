# TONGUES — Realistic Tutor Avatar Pipeline

**MetaHuman → Unity → iOS, lip-synced in real time to the AI tutor**
*July 17, 2026 · Architecture & build plan. Companion to TONGUES-Extension-Architecture.md.*

---

## TL;DR

Build the character once in **MetaHuman Creator** (free, Unreal-grade fidelity, now licensed for use in Unity), export the head with **ARKit-compatible blendshapes via glTF**, optimize it for mobile, and render it in **Unity embedded inside the existing iOS app** ("Unity as a Library"). Drive the face with **blendshape frames generated server-side alongside the TTS audio** and streamed to the phone — the phone does zero ML, just plays back audio + animation curves in sync.

Marginal cost per conversation minute: **effectively $0 beyond TTS** — which is the entire reason this path beats streaming-avatar APIs ($0.10+/min) at TONGUES' price points.

One decision this doc makes for you and flags loudly: **prefer audio-driven lip sync (Audio2Face-3D) over per-language viseme mapping.** TONGUES is multilingual by definition; audio-driven animation works identically for Spanish, Arabic, and Korean, while viseme/phoneme pipelines must be built and QA'd per language.

---

## Pipeline at a glance

```
                    OFFLINE (once per character)
┌─────────────────┐   ┌──────────────────┐   ┌───────────────────┐
│ MetaHuman        │ → │ UE 5.7 + glTF/    │ → │ Mobile optimize:   │
│ Creator          │   │ ARKit export      │   │ decimate, hair     │
│ (design tutor)   │   │ plugin            │   │ cards, bake maps   │
└─────────────────┘   └──────────────────┘   └─────────┬─────────┘
                                                        │ .glb + textures
                                                        ▼
                       RUNTIME (every conversation)   ┌───────────────────┐
┌────────────┐  text  ┌────────────┐  audio (stream)  │ Unity (URP)        │
│ AI tutor    │ ─────→ │ TTS         │ ───────────────→ │ embedded in iOS    │
│ (existing   │        │ (streaming) │                  │ app via UaaL       │
│ backend)    │        └─────┬──────┘                  │                    │
└────────────┘              │ audio                    │ blendshape player  │
                             ▼                          │ + audio player,    │
                      ┌────────────────┐  55-shape     │ synced by          │
                      │ Audio2Face-3D   │  frames @30-  │ timestamp          │
                      │ (GPU server)    │ ─60fps ─────→ │                    │
                      └────────────────┘  (WebSocket)   └───────────────────┘
```

Two channels arrive at the phone: the **audio stream** and a **timestamped blendshape stream**. The Unity player buffers ~200ms and plays both against the same clock. That's the whole trick — sync is a timestamp alignment problem, not an ML problem, once animation is computed server-side.

---

## Stage 1 — Create the character (MetaHuman Creator)

- Use **MetaHuman Creator** (bundled with UE 5.6+; current release 5.8). Cost: free.
- **Licensing:** as of the June 2025 licensing change, MetaHumans may be used **outside Unreal Engine — including Unity** — and in shipped commercial products. Read the current license text once before shipping; the key former restriction ("Unreal Engine only") is the one that was lifted.
- Design guidance from the brand: warm, documentary, dignified — resist the "corporate presenter" default. Strongly consider designing **2–3 tutors of visibly different ages/ethnicities** now; the incremental cost per additional character is one afternoon, and it matches the photography brief's casting principle.
- Skip clothing/body complexity — TONGUES needs head-and-shoulders framing. Everything below the collarbone is wasted polygons.

## Stage 2 — Export with facial rig intact

This is the step where naive attempts die: **UE's stock FBX export produces a static head with no blendshapes.** Use the glTF + ARKit route instead:

1. Bring the MetaHuman into a UE 5.7 project (UE is being used purely as an export bench — nothing Unreal ships in the app).
2. Install the **MetaHuman → glTF + ARKit export plugin** (Holotype's `MHARKitExport`, on the Epic forums/Fab). It derives the **52 ARKit blendshapes from MetaHuman's ControlRig mappings** and writes a glTF/GLB with them baked in.
3. Export head + textures. Hair usually needs separate handling (strand-based grooms don't survive export — see Stage 3).

**Validation gate before proceeding:** open the GLB in Blender or a glTF viewer and confirm all 52 ARKit shapes exist and deform correctly (`jawOpen`, `mouthFunnel`, `mouthPucker`, `tongueOut` especially — a language tutor lives and dies on mouth shapes). If tongue shapes are missing or weak, fix them here, not in Unity.

**Fallback if the export fight drags on:** Reallusion **Character Creator 4** characters ship with ARKit blendshapes natively, export to Unity in one click, and are mobile-optimized out of the box. ~90% of MetaHuman quality for ~10% of the pipeline pain. Time-box the MetaHuman export to a week; take the CC4 exit if you're still fighting it.

## Stage 3 — Mobile optimization

Budget targets for a single hero head on iPhone 12-and-up class hardware:

| Asset | Source (MetaHuman) | Mobile target |
|---|---|---|
| Head mesh | ~700k tris (LOD0, cinematic) | **40–80k tris** (use MetaHuman's own LOD2/LOD3 as starting point) |
| Textures | 8K sets | **2K albedo/normal, 1K rest**, ASTC compression |
| Hair | Strand-based groom | **Hair cards** (or a short/tied-back style chosen in Stage 1 to make this easy) |
| Skin shader | UE subsurface profile | URP lit + baked thickness/SSS approximation map |
| Eyes | Full parallax/refraction rig | Simplified: cubemap reflection + normal-mapped iris |

- Do the decimation in Blender against the glTF, preserving blendshape integrity (Blender's decimate keeps shape keys; verify mouth shapes after).
- Frame the character **tight — head and shoulders** — so all texture/polygon budget concentrates where the camera looks. This also hides most of what mobile rendering does worst.
- Target **60fps render with thermals in check on a 10-minute session**; test on the oldest supported device, not the newest.

## Stage 4 — Unity, embedded in the existing iOS app

- **Unity 6 + URP.** Unity embeds into a native app via **Unity as a Library (UaaL)** — official, documented, production-proven. The avatar becomes one full-screen (or sheet) view the SwiftUI app presents; the rest of TONGUES stays pure Swift.
- Practical UaaL notes:
  - Unity wants to run as a singleton — one `UnityFramework` instance, show/hide rather than create/destroy.
  - Swift ↔ Unity messaging goes over a thin bridge (`sendMessageToGO` / native callbacks). Keep the protocol tiny: `StartSession(config)`, `PlayUtterance(audioURL, animURL | stream)`, `Interrupt()`, `SetIdle()`.
  - **App size cost: expect roughly +30–60MB** after stripping (IL2CPP, ARM64-only, strip engine code, no unused modules). Meaningful but survivable; Unreal would be 3–10× that.
- Build the **idle layer** in Unity, and treat it as a first-class feature: blink cycles, micro head movement, breathing, gaze that occasionally meets the camera. In the streaming-avatar comparisons, **idle quality — not speech quality — was what separated "alive" from "creepy."** Budget real time here.
- Listening state: subtle head tilt + eyebrow raise while the user speaks. Interruption: on user speech detected, fade blendshape weights to idle over ~150ms and stop audio. Never let the mouth keep moving after audio stops.

## Stage 5 — Voice + lip-sync (the "talks at the same rate as the AI" part)

**Recommended: NVIDIA Audio2Face-3D, self-hosted (open-sourced late 2025).**

- Runs as a Docker/NIM microservice on any NVIDIA GPU box (T4/A10/L4-class is plenty; an L4 cloud instance runs ~$400–600/mo and serves many concurrent streams — it's generating animation curves, not video).
- Input: the TTS audio stream. Output: **timestamped ARKit-style blendshape frames** (mouth + brows + squints — actual facial *performance*, not just flapping lips) streamed over gRPC/WebSocket.
- **Language-agnostic** — it animates from sound, so Spanish, Portuguese, French, Arabic, Japanese all work identically with zero per-language work. For TONGUES this is decisive.
- Server-side placement means the phone never runs inference; old iPhones perform identically to new ones.

**Simpler v1 / fallback: Azure Speech TTS blendshape events.**

- Azure TTS emits, during streaming synthesis, either viseme IDs or **full 3D blendshape frames: 55 facial positions at 60fps**, timestamped against the audio (`VisemeReceived` events). If Azure is an acceptable TTS voice, lip sync is nearly free — one vendor, no GPU server.
- Two caveats to verify in a spike: (1) blendshape-format locale coverage for your priority languages (viseme ID coverage is broad; blendshape coverage must be confirmed per locale — SVG format is en-US-only, blendshapes are a separate list); (2) voice quality vs. ElevenLabs for the tutor persona.

**If ElevenLabs voices are non-negotiable:** ElevenLabs returns character-level timestamps → map to phonemes → visemes → blendshape curves. Works, but it's per-language mapping work — the thing this doc recommends avoiding. Better: ElevenLabs audio **into** Audio2Face-3D, which takes any audio source. That combination (best voices + audio-driven animation) is the target end state.

### Sync + latency budget (target: first lip movement < 1.5s after user stops talking)

| Segment | Budget |
|---|---|
| STT finalization (streaming, on-device or cloud) | 150–300ms |
| LLM first token (streaming) | 300–600ms |
| TTS first audio chunk (streaming, sentence-chunked) | 200–400ms |
| Audio2Face first blendshape frames | 50–150ms (pipelined with TTS chunks) |
| Network + client buffer | 200ms fixed jitter buffer |

Key implementation rule: **chunk at sentence boundaries and pipeline everything** — the avatar starts speaking sentence 1 while the LLM is still writing sentence 3. Lip-sync tolerance is ~±45ms before humans notice; a shared clock + 200ms jitter buffer on the client handles it. Drift correction: resync animation clock to audio playback position every chunk boundary.

---

## Cost model

| Item | Cost | Notes |
|---|---|---|
| MetaHuman Creator | $0 | License now permits Unity + commercial use |
| Unity | $0 at current scale | Personal/Pro thresholds by revenue; no per-install runtime fee (rescinded 2024) |
| Export plugin / Blender | ~$0–100 one-time | |
| TTS | ~$0.001–0.01 per tutor reply | Existing cost — already in the pricing model's AI-cost line |
| Audio2Face GPU server | ~$400–600/mo flat | Serves all users; skip entirely in v1 by using Azure blendshapes |
| Per-minute avatar cost | **~$0** | vs. $0.10+/min for HeyGen/Tavus-class streaming — at 10k users × 30 min/mo that's $30k/mo avoided |

The flat-cost structure is the strategic point: avatar minutes don't erode the ~70–75% Pro margin, so the avatar can exist on lower tiers if it earns its place.

---

## Risks and honest caveats

- **Uncanny valley on mobile.** A decimated MetaHuman with card hair under URP is "excellent game character," not "video human." If testing shows the full face reads as creepy, the pre-designed exit is the **mouth-macro concept**: tight crop on the mouth alone, black-and-white, straight out of the photography brief ("the instrument in macro"). Cheaper, on-brand, pedagogically better for pronunciation, and immune to dead-eye syndrome. Design the Unity scene so the camera can push in to that framing — then it's an A/B test, not a rebuild.
- **The export step is the fragile link.** Epic's tooling changes version to version; the community plugin route works today but pin your UE version and archive the working export. Budget one week; CC4 is the escape hatch.
- **Solo-founder scope.** This is realistically **4–8 weeks of focused work** — appropriate *after* the extension ships and the capture loop is live, per the competitive brief's sequencing. Praktika's avatars are their moat; TONGUES' moat is the loop. The avatar is retention polish, not the wedge.
- **Verify two things in week one, before any art:** (1) Azure blendshape locale coverage for Spanish/French/Portuguese; (2) a UaaL "hello cube" building inside the actual TONGUES iOS project. These are the two unknowns that can invalidate the plan; everything else is known-hard, not unknown.

## Build order (two-week proof, then commit)

| Week | Milestone |
|---|---|
| 1 | UaaL spike: Unity view inside the TONGUES app, Swift↔Unity bridge round-trip. In parallel: Azure viseme/blendshape locale check. |
| 2 | Any rigged ARKit head (grab a free CC4/sample head — don't touch MetaHuman yet) lip-syncing to streamed Azure TTS on-device. **This proves the entire runtime.** |
| 3–4 | MetaHuman export + mobile optimization pass; swap the head. |
| 5–6 | Idle/listening/interruption states; thermal + old-device testing. |
| 7–8 | (If voices demand it) ElevenLabs + Audio2Face-3D server; polish; A/B face vs. mouth-macro framing. |

*The runtime is proven in week 2 with a placeholder head. The MetaHuman itself is a swappable asset — which is exactly how it should stay.*
