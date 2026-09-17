# Registering TONGUES' GA4 custom definitions

GA4 stores every event parameter the app sends, but its reporting UI can only
slice by parameters registered as **custom definitions** — and registration is
**not retroactive**. Do this before you ship, or the first weeks of data can't
be broken down by tier, source, onboarding step, etc.

`tools/ga4_register_dimensions.py` creates all of them (41 dimensions +
10 metrics) in one command. It derives the list directly from
`TONGUES/Services/AnalyticsService.swift`, so it stays correct as events are
added, and it's idempotent — safe to re-run any time.

## See the plan first (no credentials needed)

```bash
python3 tools/ga4_register_dimensions.py --dry-run
```

## Why a new credential is needed

The GA4 Admin API requires the scope
`https://www.googleapis.com/auth/analytics.edit`.

The Firebase CLI on this machine is logged in as `olympianhourglass@gmail.com`,
but its token only carries `cloud-platform`, `firebase`, `openid`,
`userinfo.email` and `cloudplatformprojects.readonly` — **no analytics scope**.
Google enforces scopes at the token level, so that credential cannot write
custom dimensions no matter what permissions the human account has.

Pick either option below.

---

## Option A — Service account (recommended; repeatable, no browser)

1. **Create the account + key** in the Google Cloud project behind Firebase
   (`tongues-c50ca`):
   <https://console.cloud.google.com/iam-admin/serviceaccounts?project=tongues-c50ca>
   → *Create service account* → name it `ga4-admin` → *Done* →
   open it → *Keys* → *Add key* → *Create new key* → **JSON** → save it
   somewhere outside the repo, e.g. `~/ga4-sa.json`.

2. **Enable the API** (once per project):
   <https://console.cloud.google.com/apis/library/analyticsadmin.googleapis.com?project=tongues-c50ca>
   → *Enable*.

3. **Grant it access to the GA4 property.** This is the step people miss —
   a service account is a separate identity and has no GA4 access by default:
   GA4 → **Admin** → *Property access management* → **+** → paste the service
   account's email (`ga4-admin@tongues-c50ca.iam.gserviceaccount.com`) →
   role **Editor** → *Add*.

4. **Run it:**
   ```bash
   python3 tools/ga4_register_dimensions.py --service-account ~/ga4-sa.json
   ```

The key is a long-lived credential — keep it out of the repo (it is not
gitignored for you; store it in your home directory) and delete it when done
if you'd rather not keep one around.

---

## Option B — One-off access token (fastest, expires in ~1 hour)

1. Open the OAuth 2.0 Playground: <https://developers.google.com/oauthplayground/>
2. Gear icon (top right) → tick **Use your own OAuth credentials** only if you
   have them; otherwise leave defaults.
3. In *Step 1*, paste this scope into the "Input your own scopes" box:
   ```
   https://www.googleapis.com/auth/analytics.edit
   ```
   → *Authorize APIs* → sign in as the Google account that owns the GA4
   property → allow.
4. *Step 2* → **Exchange authorization code for tokens** → copy the
   **Access token** (starts `ya29.`).
5. Run:
   ```bash
   python3 tools/ga4_register_dimensions.py --token "ya29.PASTE_HERE"
   ```

---

## Property discovery

The script finds your GA4 property automatically by matching "tongues" in the
display name. If you have several, it lists them and exits so you can pass one:

```bash
python3 tools/ga4_register_dimensions.py --token "ya29.…" --property properties/123456789
```

## What gets created

- **31 event-scoped dimensions** — `source`, `tier`, `cycle`, `trial_eligible`,
  `is_trial`, `method`, `is_new_user`, `question_id`, `index`, `language`,
  `content_type`, `mode`, `completed`, `action`, `kind`, and the rest.
- **10 user-scoped dimensions** — the segmentation properties, prefixed
  `User:` so they don't collide with the event-scoped `Tier` / `App Language`
  (GA4 requires globally-unique display names).
- **10 custom metrics** — the numeric params (`duration_seconds` as SECONDS,
  the rest STANDARD), registered as metrics rather than dimensions so GA4
  sums and averages them instead of bucketing every distinct value.

Four params defined in Swift but not yet passed anywhere (`bucket`, `flavor`,
`remaining`, `was_cached`) are deliberately skipped so they don't consume
slots against GA4's free-tier caps of 50 event-scoped / 25 user-scoped.

## Verifying the events themselves

Separately from registration, confirm events are arriving: run the app with the
`-FIRDebugEnabled` launch argument (Xcode → Product → Scheme → Edit Scheme →
Run → Arguments) and watch GA4 → *Admin* → *DebugView*. In `DEBUG` builds every
event also prints to the Xcode console as `📊 event_name {params}`.
