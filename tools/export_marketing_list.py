#!/usr/bin/env python3
"""
Export the consented marketing list from Firestore as CSV, ready to import
into any email platform (Loops, Mailchimp, Resend, Kit, Beehiiv…).

WHY A SCRIPT AND NOT A SYNC
    Until there's a real audience, a periodic export beats standing up a
    Cloud Function: nothing to deploy, nothing to keep alive, no API key to
    rotate. Swap to a Firestore-trigger sync once hand-running this gets
    annoying — i.e. at hundreds of users, not at zero.

WHAT IT GUARANTEES
    • Only exports records with `optIn == true`. Never the whole user table.
      Mailing people who didn't consent is both a legal problem and the
      fastest way to wreck deliverability.
    • Separates Apple private-relay aliases into their own file. Those
      deliver ONLY if your sending domain is registered under "Sign in with
      Apple for Email Communication" in the Apple Developer portal. Sending
      to them unregistered means hard bounces, which damage sender
      reputation for everyone else.
    • Emits a `source` column so app-sourced contacts stay distinguishable
      from website signups once both feed one list.

USAGE
    python3 tools/export_marketing_list.py --service-account ~/fb-admin.json
    python3 tools/export_marketing_list.py --service-account ~/fb-admin.json --out ./lists

    A Firebase service-account key: Firebase console → Project settings →
    Service accounts → Generate new private key. Keep it out of the repo.

DEPENDENCIES
    pip install google-cloud-firestore
"""

from __future__ import annotations

import argparse
import csv
import sys
from datetime import datetime, timezone
from pathlib import Path

APPLE_RELAY_SUFFIX = "@privaterelay.appleid.com"


def main() -> None:
    ap = argparse.ArgumentParser(description="Export consented marketing contacts.")
    ap.add_argument("--service-account", type=Path, required=True,
                    help="Firebase service-account JSON key")
    ap.add_argument("--out", type=Path, default=Path("."),
                    help="output directory (default: cwd)")
    args = ap.parse_args()

    try:
        from google.cloud import firestore
    except ImportError:
        sys.exit("error: pip install google-cloud-firestore")

    if not args.service_account.exists():
        sys.exit(f"error: no such key file: {args.service_account}")

    db = firestore.Client.from_service_account_json(str(args.service_account))

    # Collection-group query over users/{uid}/marketing/consent, filtered
    # server-side to consented records only. Nothing else may leave the
    # database for a marketing purpose.
    #
    # Consent lives in a SUBCOLLECTION because firestore.rules grants every
    # signed-in user read access to any users/{uid} document — an address on
    # the profile doc would be readable by every other user. The Admin SDK
    # bypasses rules, so this export still works.
    query = db.collection_group("marketing").where("optIn", "==", True)

    deliverable: list[dict] = []
    relay: list[dict] = []
    missing_email = 0

    for doc in query.stream():
        consent = doc.to_dict() or {}
        email = (consent.get("email") or "").strip()
        # users/{uid}/marketing/consent -> walk up two levels for the uid.
        uid = doc.reference.parent.parent.id if doc.reference.parent.parent else ""

        if not email:
            # Consented but no stored address (e.g. an Apple account that
            # withheld email). Counted, never guessed at.
            missing_email += 1
            continue

        # Enrich from the profile doc so the list can be segmented by what
        # someone is actually learning.
        profile = {}
        if uid:
            snap = db.collection("users").document(uid).get()
            profile = snap.to_dict() or {}
        onboarding = profile.get("onboarding") or {}
        prefs = onboarding.get("languagePreferences") or []
        primary = prefs[0] if prefs else {}

        row = {
            "email": email,
            "firstName": (onboarding.get("name") or "").split(" ")[0],
            "targetLanguage": primary.get("language", ""),
            "level": primary.get("level", ""),
            "interfaceLanguage": profile.get("interfaceLanguage", ""),
            "source": consent.get("source") or "app",
            "consentedAt": _iso(consent.get("optInAt")),
            "userId": uid,
        }

        if email.lower().endswith(APPLE_RELAY_SUFFIX) or consent.get("isAppleRelay"):
            relay.append(row)
        else:
            deliverable.append(row)

    args.out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    wrote = []
    if deliverable:
        wrote.append(_write(args.out / f"marketing-{stamp}.csv", deliverable))
    if relay:
        wrote.append(_write(args.out / f"marketing-{stamp}-apple-relay.csv", relay))

    print(f"consented contacts : {len(deliverable) + len(relay)}")
    print(f"  standard         : {len(deliverable)}")
    print(f"  apple relay      : {len(relay)}")
    if missing_email:
        print(f"  skipped (no email): {missing_email}")
    for path in wrote:
        print(f"wrote {path}")

    if relay:
        print(
            "\nNOTE: the Apple-relay file is a SEPARATE import on purpose.\n"
            "Those addresses bounce unless your sending domain is registered at\n"
            "developer.apple.com → Certificates, IDs & Profiles → Sign in with\n"
            "Apple for Email Communication. Register the domain first, then\n"
            "import them; otherwise leave that file alone."
        )


def _write(path: Path, rows: list[dict]) -> Path:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    return path


def _iso(value) -> str:
    if value is None:
        return ""
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


if __name__ == "__main__":
    main()
