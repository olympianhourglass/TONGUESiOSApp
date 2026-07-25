# TONGUES Browser Extension — Architecture Plan

**Goal:** A Chrome extension that lets a TONGUES user highlight a word or phrase in any article, get it translated, and have it appear in their flashcard decks in the native iOS/Android app — same account, same Firebase backend, instant sync.

**Context this plan assumes:** the mobile app is native Swift/Kotlin, auth is Google + Apple + email/password, and translation is currently called from the client via a third-party API. Deliverable date: July 2026; targets Chrome Manifest V3 (also portable to Edge, and to Firefox/Safari with modest adjustments — see §9).

---

## 1. The big idea: you don't need to "link" accounts

The most important architectural fact: **if the extension initializes the Firebase JS SDK with the same Firebase project config as the mobile app, accounts are already shared.** A Firebase user is a UID scoped to the project, not to a platform. When Albert signs into the extension with the same Google account (or email/password) he uses in the app, Firebase Auth resolves to the **same UID**, and every Firestore read/write in the extension hits the same documents the app sees.

So "interlinked accounts people can switch between" costs you nothing extra. There is no account-linking service to build, no token exchange, no shared session. Each surface signs in independently against the same project, and the data layer (Firestore) is the single source of truth. The user experience of "I saved a word on my laptop and it's on my phone" falls out of Firestore's realtime sync automatically.

Two things you *do* need to get right:

**Provider account linking.** A user who signed up in the app with Apple might sign into the extension with Google using the same email address. In Firebase Console → Authentication → Settings, keep **"One account per email address"** enabled so Firebase merges these into one UID where possible, and handle the `auth/account-exists-with-different-credential` error in the extension by prompting the user to sign in with their original provider and then calling `linkWithCredential`. Do the mirror-image handling in the mobile app. This is the only genuine "account linking" work in the whole project.

**Consistent data model.** The app and extension must agree on the Firestore schema for decks and cards (§4). If the app's current schema is informal, formalize it now — it becomes the API contract between surfaces.

---

## 2. System overview

```
┌─────────────────────┐        ┌──────────────────────────┐
│  iOS / Android app   │        │  Chrome extension (MV3)  │
│  (Swift / Kotlin)    │        │                          │
│  Firebase native SDK │        │  content script          │
└─────────┬───────────┘        │   └─ selection UI        │
          │                     │  service worker          │
          │                     │   └─ Firebase JS SDK     │
          │                     │  popup / side panel      │
          │                     │   └─ deck picker, review │
          │                     └────────────┬─────────────┘
          │                                  │
          ▼                                  ▼
┌───────────────────────────────────────────────────────────┐
│                    ONE Firebase project                    │
│                                                            │
│  Firebase Auth (Google, Apple, email/password)             │
│  Cloud Firestore (users/{uid}/decks/... — realtime sync)   │
│  Cloud Functions:                                          │
│    • translateAndSave (callable) — translation API lives   │
│      here, key never ships to clients                      │
└───────────────────────────────────────────────────────────┘
```

The extension is a **thin new client** on the existing backend, not a new backend. All new server-side work is one or two Cloud Functions.

---

## 3. Prerequisite: move translation behind a Cloud Function

Today the mobile app calls the translation API directly from the client. For the extension this is a hard blocker: any API key bundled into a Chrome extension is trivially extractable by anyone who downloads it (extension source is just a zip). This is your one piece of backend work, and it benefits the mobile app too.

Create a **callable Cloud Function** `translateAndSave`:

```ts
// functions/src/index.ts (v2 callable, Node 20+)
export const translateAndSave = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first");
  const { text, sourceLang, targetLang, deckId, context } = request.data;

  // 1. Validate: text length cap (e.g. 200 chars), rate limit per uid
  // 2. Call DeepL / Google Translate / your current provider — key is in
  //    Secret Manager, never on the client
  // 3. Write the card to Firestore under users/{uid}/decks/{deckId}/cards
  // 4. Return the created card so the extension can show instant feedback
});
```

Doing translation *and* the Firestore write server-side gives you one round trip from the extension, guarantees the card format is always valid (the function is the only writer for new cards, if you want), and gives you a single place for rate limiting, usage metering (relevant to your pricing tiers), caching of repeated lookups, and swapping translation providers later.

Migrate the mobile app to call this same function when convenient — extension first is fine, since the function is additive and doesn't break the app's current path.

---

## 4. Firestore data model (the contract between app and extension)

If the app already has a decks/cards schema, adapt this to match rather than migrating. The shape that works well:

```
users/{uid}
  profile: { displayName, nativeLang, learningLangs: [...] }

users/{uid}/decks/{deckId}
  { name, sourceLang, targetLang, createdAt, updatedAt, cardCount }

users/{uid}/decks/{deckId}/cards/{cardId}
  {
    front: "l'esprit de l'escalier",     // saved word/phrase
    back: "staircase wit",               // translation
    sourceLang: "fr",
    targetLang: "en",
    context: "…the whole sentence it appeared in…",
    source: {                            // extension-specific provenance
      type: "web",                       // vs "manual" | "app"
      url: "https://lemonde.fr/…",
      title: "Article title",
    },
    createdAt, createdBy: "extension",   // or "ios" | "android"
    srs: { interval, ease, due, reps }   // spaced-repetition state
  }
```

Notes on this design: keeping cards under the user subtree makes security rules one line (`request.auth.uid == uid`); the `context` sentence is a big pedagogical win and the extension gets it for free from the page; `source.url` lets the app show "saved from Le Monde" and link back; `createdBy` helps you debug sync and measure extension adoption; and SRS state living in the card document means a review done on the phone is instantly reflected if you ever add review to the extension.

Security rules:

```
match /users/{uid}/{document=**} {
  allow read, write: if request.auth != null && request.auth.uid == uid;
}
```

If you make `translateAndSave` the sole creator of web-sourced cards, tighten `create` on cards to reject `source.type == "web"` from clients.

---

## 5. Auth in a Manifest V3 extension (the tricky part)

This is where extensions genuinely differ from web apps. MV3 service workers have no DOM and restrict remote code, so the standard `signInWithPopup` doesn't work directly. Firebase ships a dedicated entry point for this: **import from `firebase/auth/web-extension` instead of `firebase/auth`** ([Firebase docs](https://firebase.google.com/docs/auth/web/chrome-extension)).

Per method you support:

**Email/password — trivial.** `signInWithEmailAndPassword` from `firebase/auth/web-extension` works out of the box in the popup or service worker. Build this first; it de-risks everything else.

**Google — use `chrome.identity`, skip the popup entirely.** The clean pattern for a Chrome extension is:

```ts
// In the extension (popup or service worker)
const redirectUrl = await chrome.identity.launchWebAuthFlow({
  url: googleOAuthUrl,        // accounts.google.com authorize URL with
  interactive: true,          // client_id + redirect_uri = the extension's
});                           // https://<ext-id>.chromiumapp.org/ URL
const idToken = parseIdToken(redirectUrl);
await signInWithCredential(auth, GoogleAuthProvider.credential(idToken));
```

`signInWithCredential` is fully supported in the web-extension entry point with no offscreen document. You'll create an additional OAuth client ID (type "Web application") in the Google Cloud console for the extension with the `https://<extension-id>.chromiumapp.org/` redirect URI. (Alternative: `chrome.identity.getAuthToken` is Chrome-only and tied to the browser profile's Google account; `launchWebAuthFlow` is more portable and works in Edge.)

**Apple — same `launchWebAuthFlow` pattern.** Register a Services ID in the Apple Developer console, point its redirect at either the `chromiumapp.org` URL or a tiny hosted redirect page, run Apple's OAuth URL through `launchWebAuthFlow`, then `signInWithCredential(auth, new OAuthProvider('apple.com').credential({ idToken }))`. This works but is the fiddliest of the three — it's reasonable to ship the extension with Google + email/password only at first, since "one account per email" means most Apple-sign-in users can still get into their account via email or Google.

**Fallback for anything stubborn: the offscreen-document pattern.** Firebase's official guide covers running `signInWithPopup` inside an offscreen document that iframes a page you host ([docs](https://firebase.google.com/docs/auth/web/chrome-extension)). It works, but it requires hosting an auth page and juggling three message-passing layers. Treat it as plan B; `launchWebAuthFlow` + `signInWithCredential` covers your providers with far less machinery.

**Session persistence:** Firebase Auth in extensions persists to IndexedDB by default, so users stay signed in across browser restarts and service-worker suspensions. Also add your extension origin (`chrome-extension://<EXTENSION_ID>`) to Firebase Auth's authorized domains.

---

## 6. Extension architecture

Three cooperating pieces, standard MV3 layout:

**Content script** — injected into pages the user reads. Listens for text selection; shows a small floating "Save to TONGUES" button near the selection (or via right-click context menu, which needs no injection UI at all and is a great v1). On click, it grabs the selected text plus the surrounding sentence and page metadata, and sends a message to the service worker. It holds **no Firebase code and no auth state** — content scripts run in untrusted page contexts; keep them dumb.

A context-menu-only v1 deserves serious consideration: `chrome.contextMenus` ("Save '%s' to TONGUES") requires no content script at all for the core flow, which shrinks the permissions you request (`activeTab` instead of broad host permissions) and makes Chrome Web Store review dramatically easier. Add the floating-button polish in v2.

**Service worker (background)** — owns the Firebase app instance: auth state, `signInWithCredential`, and the `httpsCallable('translateAndSave')` invocation. Receives "save word" messages, calls the function, fires a notification or badge on success. MV3 service workers are killed after ~30s idle — this is fine, because our worker is purely reactive (wake on message → one network call → done) and Firebase auth state rehydrates from IndexedDB on wake. Don't design anything that needs a long-lived listener in v1; if you later want live deck updates in the extension UI, run the Firestore `onSnapshot` in the popup/side panel while it's open, not in the worker.

**Popup (and/or side panel)** — the visible UI on the toolbar icon. Sign-in screen when logged out; when logged in: default-deck picker, last few saved words, link to open the app. Chrome's Side Panel API is a nice upgrade path for a "reading mode" showing all words saved from the current page. Build it with whatever you like (plain TS + Vite is plenty; the extension UI is small). The popup can safely use the full Firebase JS SDK including Firestore listeners, since it's a real DOM page.

**The save flow, end to end:** user highlights "l'esprit de l'escalier" → clicks Save → content script sends `{text, sentence, url, title}` → service worker checks auth (if signed out, opens the popup instead) → calls `translateAndSave` with the user's default deck → function translates, writes the card, returns it → worker shows a ✓ badge/notification → the card is *already on the phone* the next time the app's Firestore listener ticks, typically within a second or two.

Optimistic-latency option for later: have the extension write a `pending` card directly to Firestore and let a Firestore-triggered function fill in the translation asynchronously. Saves feel instant even on slow translation APIs, and the app can render a subtle "translating…" state.

---

## 7. What "switching between app and extension" feels like when done

Nothing to build beyond the above — this is the payoff of one project + one schema: save a word on desktop, it's in the deck on the phone in seconds via each platform's native Firestore sync; review on the phone updates `srs` state that the extension sees; sign out on one surface doesn't affect the other (sessions are independent, which is what users expect); offline saves on either surface queue locally and sync on reconnect (Firestore's offline persistence, free on both platforms).

---

## 8. Build plan

**Phase 0 — backend prep (½–1 week).** Formalize/confirm the Firestore schema in a short doc; ship `translateAndSave` with the API key in Secret Manager; add security rules + rate limiting; add `chrome-extension://<id>` to authorized domains once you have an ID.

**Phase 1 — skeleton extension (1 week).** MV3 manifest, Vite + TS build; email/password sign-in via `firebase/auth/web-extension`; context-menu save → callable function → card appears in the mobile app. *This is the whole concept proven end to end.*

**Phase 2 — real auth + UX (1–2 weeks).** Google via `launchWebAuthFlow` + `signInWithCredential`, with `account-exists-with-different-credential` linking flow; popup UI with deck picker and recent saves; success/error notifications.

**Phase 3 — polish & ship (1–2 weeks).** Floating selection button (content script); language auto-detection (`<html lang>` or detect via the translate API); Apple sign-in if metrics say you need it; Chrome Web Store listing — privacy policy required, and minimal permissions (`contextMenus`, `identity`, `storage`, `activeTab`) keep review fast.

**Phase 4 — later.** Side-panel reading view; in-extension flashcard review (SRS already syncs); Firefox/Safari ports; per-tier usage metering in `translateAndSave` aligned with TONGUES pricing.

---

## 9. Gotchas & notes

**Bundle imports:** always `firebase/auth/web-extension` in the extension — the regular entry point breaks in service workers. **CSP:** MV3 forbids remote scripts; bundle the Firebase SDK with your build, never load from a CDN `<script>` tag. **Service worker lifecycle:** never keep state in worker memory; use `chrome.storage.local` for things like the default deck ID ([Chrome docs](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)). **Apple review parity:** saving from the extension shows up in the iOS app — that's fine, but if you later sell extension-only subscriptions, route purchases carefully around App Store rules. **Firefox/Safari:** WebExtensions APIs are ~95% shared; Firefox needs `browser.identity.launchWebAuthFlow` (same API, different namespace), Safari wraps the extension in an Xcode project — feasible later, don't design for it now beyond avoiding Chrome-only APIs like `getAuthToken`. **Abuse control:** the callable function is your choke point — cap text length, per-user daily quotas (ties neatly into free vs. paid tiers), and consider Firebase App Check on mobile now and on the extension when its App Check support matures.

---

## 10. Key references

- Firebase: [Authenticate with Firebase in a Chrome extension](https://firebase.google.com/docs/auth/web/chrome-extension)
- Google Cloud Identity Platform: [Signing in users from a Chrome extension](https://docs.cloud.google.com/identity-platform/docs/web/chrome-extension)
- Chrome: [Extension service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)
- Chrome: [chrome.identity API](https://developer.chrome.com/docs/extensions/reference/api/identity)
- Firebase: [Callable Cloud Functions](https://firebase.google.com/docs/functions/callable)
