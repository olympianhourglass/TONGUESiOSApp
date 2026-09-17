#!/usr/bin/env python3
"""
Register TONGUES' GA4 custom dimensions + metrics from the app's own source.

WHY THIS EXISTS
    GA4 stores every event parameter we send, but its reporting UI can only
    slice by parameters that have been registered as custom definitions — and
    registration is NOT retroactive. Doing it by hand is ~35 console forms and
    drifts the moment someone adds an event.

    This reads the single source of truth (TONGUES/Services/AnalyticsService.swift),
    derives the definitions, and creates whatever is missing. It is idempotent:
    run it as often as you like, including after adding new events.

USAGE
    # 0. See exactly what would happen (no credentials needed):
    python3 tools/ga4_register_dimensions.py --dry-run

    # 1. With a service-account key (recommended, repeatable):
    python3 tools/ga4_register_dimensions.py --service-account ~/ga4-sa.json

    # 2. Or with a short-lived OAuth token you pasted from anywhere:
    python3 tools/ga4_register_dimensions.py --token "ya29.…"

    # Add --property properties/123456789 to skip auto-discovery.

CREDENTIALS
    Needs the scope https://www.googleapis.com/auth/analytics.edit
    (the Firebase CLI token does NOT have it — that's why this is a separate
    credential). See tools/GA4_SETUP.md for the 2-minute setup.

DEPENDENCIES
    Standard library + the `openssl` binary. Deliberately no pip installs.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ADMIN_API = "https://analyticsadmin.googleapis.com/v1beta"
TOKEN_URI = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/analytics.edit"

REPO_ROOT = Path(__file__).resolve().parent.parent
ANALYTICS_SWIFT = REPO_ROOT / "TONGUES" / "Services" / "AnalyticsService.swift"

# GA4 free-tier ceilings. Exceeding them is a hard API error, so we stop
# short and say what got skipped rather than failing halfway through.
MAX_EVENT_SCOPED = 50
MAX_USER_SCOPED = 25

# Numeric params are far more useful as METRICS (GA4 will sum/average them)
# than as dimensions (which would treat every distinct value as a bucket).
# value_type: STANDARD (unitless int), SECONDS, or CURRENCY.
METRICS: dict[str, tuple[str, str]] = {
    "duration_seconds": ("Duration Seconds", "SECONDS"),
    "cards_graded": ("Cards Graded", "STANDARD"),
    "correct_count": ("Correct Count", "STANDARD"),
    "accuracy": ("Accuracy Pct", "STANDARD"),
    "item_count": ("Item Count", "STANDARD"),
    "cards_advanced": ("Cards Advanced", "STANDARD"),
    "turn_index": ("Chat Turn Index", "STANDARD"),
    "count": ("Count", "STANDARD"),
    "planned": ("Planned Count", "STANDARD"),
    "succeeded": ("Succeeded Count", "STANDARD"),
}

# Human display names. Anything not listed is title-cased automatically.
DISPLAY_NAMES: dict[str, str] = {
    "source": "Source",
    "tier": "Tier",
    "cycle": "Billing Cycle",
    "price": "Price Shown",
    "trial_eligible": "Trial Eligible",
    "is_trial": "Is Trial",
    "reason": "Failure Reason",
    "method": "Auth Method",
    "is_new_user": "Is New User",
    "index": "Step Index",
    "question_id": "Question ID",
    "language": "Target Language",
    "dialect": "Dialect",
    "level": "Level",
    "app_language": "App Language",
    "content_type": "Content Type",
    "deck_id": "Deck ID",
    "tab": "Tab",
    "mode": "Review Mode",
    "modes": "Review Mode Mix",
    "completed": "Completed",
    "full_deck": "Full Deck",
    "ambient_sound": "Ambient Sound",
    "ambient_music": "Ambient Music",
    "theme": "Theme",
    "action": "Action",
    "kind": "Artifact Kind",
    "script": "Handwriting Script",
    "is_correct": "Is Correct",
    "tone": "Tutor Tone",
    "code": "Promo Code",
    # user-scoped
    "is_in_trial": "User In Trial",
    "native_language": "User Native Language",
    "target_language": "User Target Language",
    "learner_level": "User Level",
    "deck_count_bucket": "User Deck Count",
    "streak_bucket": "User Streak",
    "days_install_bucket": "User Days Since Install",
    "cohort_week": "User Cohort Week",
}

# Registered first, because these are what the core dashboards need. Order
# matters only if you're near the 50-dimension cap.
PRIORITY = [
    "source", "tier", "cycle", "trial_eligible", "is_trial", "method",
    "is_new_user", "question_id", "index", "language", "content_type",
    "mode", "completed", "action", "kind",
]

# Defined in Swift but never passed at a call site — registering these would
# waste scarce dimension slots.
SKIP = {"bucket", "flavor", "remaining", "was_cached"}


# --------------------------------------------------------------------------
# Parse the Swift source so this tool can never drift from the app
# --------------------------------------------------------------------------

def parse_analytics_swift() -> tuple[list[str], list[str]]:
    """Returns (event_param_names, user_property_names) from AnalyticsService."""
    if not ANALYTICS_SWIFT.exists():
        sys.exit(f"error: cannot find {ANALYTICS_SWIFT}")
    src = ANALYTICS_SWIFT.read_text()

    def enum_body(name: str, end: str) -> str:
        try:
            return src.split(f"enum {name}")[1].split(end)[0]
        except IndexError:
            sys.exit(f"error: could not locate 'enum {name}' in AnalyticsService.swift")

    def cases(body: str) -> list[str]:
        # `case fooBar = "foo_bar"` and bare `case source`
        explicit = re.findall(r'case\s+(\w+)\s*=\s*"([a-z0-9_]+)"', body)
        bare = re.findall(r"case\s+(\w+)\s*$", body, re.M)
        out = {swift: raw for swift, raw in explicit}
        for swift in bare:
            out.setdefault(swift, swift)
        return sorted(set(out.values()))

    params = cases(enum_body("Param", "enum UserProperty"))
    user_props = cases(enum_body("UserProperty", "// MARK: - Opt-out"))
    return params, user_props


def params_in_use(names: list[str]) -> list[str]:
    """Keep only params actually passed somewhere in the app."""
    swift_files = subprocess.run(
        ["grep", "-rhoE", r"\.[a-zA-Z]+:", str(REPO_ROOT / "TONGUES"), "--include=*.swift"],
        capture_output=True, text=True,
    ).stdout
    used = {tok.strip(".:") for tok in swift_files.split()}

    # Map snake_case back to the lowerCamelCase spelling used at call sites.
    def camel(s: str) -> str:
        head, *rest = s.split("_")
        return head + "".join(w.capitalize() for w in rest)

    return [n for n in names if (camel(n) in used or n in used) and n not in SKIP]


def sanitize_label(label: str) -> str:
    """GA4 allows only alphanumerics, underscores and spaces in displayName."""
    cleaned = re.sub(r"[^A-Za-z0-9_ ]+", " ", label)
    return re.sub(r"\s{2,}", " ", cleaned).strip()


def display_name(raw: str) -> str:
    return sanitize_label(DISPLAY_NAMES.get(raw, raw.replace("_", " ").title()))


def build_plan(params: list[str], user_props: list[str]) -> dict:
    ordered = [p for p in PRIORITY if p in params] + [p for p in params if p not in PRIORITY]

    dimensions, metrics = [], []
    for raw in ordered:
        if raw in METRICS:
            label, unit = METRICS[raw]
            metrics.append({"parameterName": raw, "displayName": sanitize_label(label),
                            "measurementUnit": unit, "scope": "EVENT"})
        else:
            dimensions.append({"parameterName": raw, "displayName": display_name(raw),
                               "scope": "EVENT"})

    # GA4 enforces globally-unique displayNames across ALL custom dimensions,
    # regardless of scope. `tier` and `app_language` are registered at both
    # scopes on purpose (tier-at-event-time vs. the user's current tier), so
    # user-scoped names are always prefixed to avoid a 400 collision.
    def user_label(raw: str) -> str:
        label = display_name(raw)
        return label if label.startswith("User ") else sanitize_label(f"User {label}")

    user_dims = [{"parameterName": raw, "displayName": user_label(raw), "scope": "USER"}
                 for raw in user_props]

    # Enforce the caps locally so we fail loudly instead of mid-run.
    skipped = []
    if len(dimensions) > MAX_EVENT_SCOPED:
        skipped += [d["parameterName"] for d in dimensions[MAX_EVENT_SCOPED:]]
        dimensions = dimensions[:MAX_EVENT_SCOPED]
    if len(user_dims) > MAX_USER_SCOPED:
        skipped += [d["parameterName"] for d in user_dims[MAX_USER_SCOPED:]]
        user_dims = user_dims[:MAX_USER_SCOPED]

    all_dims = dimensions + user_dims

    # Fail fast on any remaining display-name collision rather than getting a
    # 400 halfway through creating things.
    seen: dict[str, str] = {}
    for d in all_dims + metrics:
        label = d["displayName"]
        if label in seen:
            sys.exit(
                f"error: duplicate display name {label!r} "
                f"({seen[label]} and {d['parameterName']}). "
                "Add distinct entries to DISPLAY_NAMES."
            )
        seen[label] = d["parameterName"]

    return {"dimensions": all_dims, "metrics": metrics, "skipped": skipped}


# --------------------------------------------------------------------------
# Auth — service-account JWT (signed via openssl) or a pasted access token
# --------------------------------------------------------------------------

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token_from_service_account(path: Path) -> str:
    info = json.loads(path.read_text())
    if info.get("type") != "service_account":
        sys.exit("error: that JSON is not a service-account key")

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": info["client_email"],
        "scope": SCOPE,
        "aud": TOKEN_URI,
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"

    # RS256-sign via the openssl binary so this script needs no crypto
    # dependency. openssl can't take both key and payload on stdin, so both
    # go to temp files that are deleted immediately afterwards.
    import tempfile
    key_path = data_path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as key_file:
            key_file.write(info["private_key"])
            key_path = key_file.name
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as data_file:
            data_file.write(signing_input)
            data_path = data_file.name
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, data_path],
            capture_output=True,
        )
    finally:
        for tmp in (key_path, data_path):
            if tmp:
                Path(tmp).unlink(missing_ok=True)

    if proc.returncode != 0:
        sys.exit(f"error: openssl signing failed: {proc.stderr.decode()}")

    assertion = f"{signing_input}.{b64url(proc.stdout)}"
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_URI, data=body)) as resp:
            return json.load(resp)["access_token"]
    except urllib.error.HTTPError as exc:
        sys.exit(f"error: token exchange failed: {exc.read().decode()}")


# --------------------------------------------------------------------------
# GA4 Admin API
# --------------------------------------------------------------------------

def api(method: str, path: str, token: str, payload: dict | None = None) -> dict:
    url = f"{ADMIN_API}/{path.lstrip('/')}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()
        if exc.code in (401, 403):
            sys.exit(
                f"error: {exc.code} from GA4 Admin API.\n"
                f"{detail}\n\n"
                "Most likely the credential lacks the analytics.edit scope, or the\n"
                "service account hasn't been added as an Editor on the GA4 property.\n"
                "See tools/GA4_SETUP.md."
            )
        raise SystemExit(f"error: {method} {path} -> {exc.code}\n{detail}")


def discover_property(token: str) -> str:
    summaries = api("GET", "accountSummaries?pageSize=200", token).get("accountSummaries", [])
    candidates = [
        (p["property"], p.get("displayName", ""))
        for acct in summaries
        for p in acct.get("propertySummaries", [])
    ]
    if not candidates:
        sys.exit("error: this credential can't see any GA4 properties.")
    tongues = [c for c in candidates if "tongue" in c[1].lower()]
    if len(tongues) == 1:
        print(f"→ auto-discovered property: {tongues[0][1]} ({tongues[0][0]})")
        return tongues[0][0]
    print("Multiple properties visible — re-run with --property:")
    for prop, name in candidates:
        print(f"    --property {prop}   # {name}")
    sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser(description="Register TONGUES' GA4 custom definitions.")
    ap.add_argument("--service-account", type=Path, help="path to a service-account JSON key")
    ap.add_argument("--token", help="an OAuth access token with analytics.edit scope")
    ap.add_argument("--property", help="e.g. properties/123456789 (else auto-discovered)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan and exit")
    args = ap.parse_args()

    params, user_props = parse_analytics_swift()
    plan = build_plan(params_in_use(params), user_props)

    dims, metrics = plan["dimensions"], plan["metrics"]
    print(f"Parsed {ANALYTICS_SWIFT.relative_to(REPO_ROOT)}")
    print(f"  {len(dims)} custom dimensions "
          f"({sum(1 for d in dims if d['scope'] == 'EVENT')} event-scoped, "
          f"{sum(1 for d in dims if d['scope'] == 'USER')} user-scoped)")
    print(f"  {len(metrics)} custom metrics")
    if plan["skipped"]:
        print(f"  ! over GA4's cap, NOT registering: {', '.join(plan['skipped'])}")
    print(f"  (skipping unused params: {', '.join(sorted(SKIP))})")

    if args.dry_run:
        print("\n--- DIMENSIONS ---")
        for d in dims:
            print(f"  [{d['scope']:5}] {d['displayName']:28} <- {d['parameterName']}")
        print("\n--- METRICS ---")
        for m in metrics:
            print(f"  [{m['measurementUnit']:9}] {m['displayName']:28} <- {m['parameterName']}")
        print("\nDry run only — nothing was sent. Re-run with credentials to apply.")
        return

    if args.token:
        token = args.token
    elif args.service_account:
        token = token_from_service_account(args.service_account)
    else:
        sys.exit("error: pass --service-account or --token (or --dry-run). See tools/GA4_SETUP.md")

    prop = args.property or discover_property(token)

    # Key on (parameterName, scope): `tier` and `app_language` are registered
    # at BOTH event and user scope on purpose, so a name-only check would
    # wrongly treat the second one as already present.
    existing_dims = {(d.get("parameterName"), d.get("scope")) for d in
                     api("GET", f"{prop}/customDimensions?pageSize=200", token)
                     .get("customDimensions", [])}
    existing_mets = {m.get("parameterName") for m in
                     api("GET", f"{prop}/customMetrics?pageSize=200", token)
                     .get("customMetrics", [])}
    print(f"\n{prop}: {len(existing_dims)} dimensions / {len(existing_mets)} metrics already exist")

    created = skipped = 0
    for d in dims:
        if (d["parameterName"], d["scope"]) in existing_dims:
            skipped += 1
            continue
        api("POST", f"{prop}/customDimensions", token, d)
        created += 1
        print(f"  + dimension {d['displayName']} ({d['parameterName']}, {d['scope']})")

    for m in metrics:
        if m["parameterName"] in existing_mets:
            skipped += 1
            continue
        api("POST", f"{prop}/customMetrics", token, m)
        created += 1
        print(f"  + metric    {m['displayName']} ({m['parameterName']}, {m['measurementUnit']})")

    print(f"\nDone. Created {created}, already present {skipped}.")
    print("Definitions apply to data collected from NOW ON — they are not retroactive.")


if __name__ == "__main__":
    main()
