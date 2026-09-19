#!/usr/bin/env python3
"""Submit a Hearth build for App Store review, with its purchases attached.

Why this is a script and not a few clicks in App Store Connect:

Apple requires an app's first auto-renewable subscription to go to review *with*
an app version. A subscription created in the web UI and left out of the
submission sits at "Ready to Submit" forever -- the version goes to review
without it and comes back rejected for a missing in-app purchase, and that
build number is spent. The same applies to a non-consumable first offered
alongside a new version.

So the submission is assembled explicitly: the version, every subscription that
is ready, and every non-consumable that is ready, as items on one
reviewSubmission, submitted once.

Nothing here creates or edits a product. It only decides what goes in the
submission and submits it. Creating products is a web-UI job, because
POST /v1/inAppPurchases is not an allowed operation on the API -- it returns
403 with "Allowed operation is: GET_INSTANCE".

Usage:
    python3 tools/asc_release.py --build 1 --inspect     # report, change nothing
    python3 tools/asc_release.py --build 1 --submit      # assemble and submit

Credentials come from the environment:
    APPSTORE_KEY_ID, APPSTORE_ISSUER_ID   and the key at
    APPSTORE_KEY_PATH (default ~/private_keys/AuthKey_<KEY_ID>.p8)

Locally, when there is no repo checkout to run from, the keys live in
`~/.app-store/env` (KEY_ID / ISSUER_ID / P8_PATH), written by this project's
tooling so a one-off run does not need the secrets pasted into a shell.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

BUNDLE_ID = "com.cyan0914.hearth"
API = "https://api.appstoreconnect.apple.com/v1"

# The version states a submission can be built from. Anything else (WAITING_FOR_
# REVIEW, IN_REVIEW, READY_FOR_SALE) already has a submission or is live, and
# adding it to a new one is refused.
SUBMITTABLE_STATES = {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW",
                      "DEVELOPER_REJECTED", "REJECTED", "INVALID_BINARY"}

# Product states worth attaching. READY_TO_SUBMIT is the one that matters: it
# means the product is complete and waiting only for a version to ride with.
# MISSING_METADATA deliberately falls through to a warning rather than being
# silently included, because Apple will reject the whole submission for it.
ATTACHABLE_STATES = {"READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "APPROVED"}


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


class ASC:
    def __init__(self, key_id: str, issuer: str, key_path: Path):
        key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        now = int(time.time())
        h = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"},
                           separators=(",", ":")).encode())
        p = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200,
                            "aud": "appstoreconnect-v1"},
                           separators=(",", ":")).encode())
        der = key.sign(f"{h}.{p}".encode(), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        self.token = f"{h}.{p}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"

    def __call__(self, method: str, path: str, body: dict | None = None):
        """Returns (payload, status). Raises nothing -- callers check status.

        A failed step here should not abort the run: the point of --inspect is
        to report the whole picture, and a submission assembled from three of
        four products is worse than one that never started.
        """
        req = urllib.request.Request(
            API + path,
            data=json.dumps(body).encode() if body else None,
            method=method,
            headers={"Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return (json.loads(raw) if raw else {}), resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode()
            try:
                first = json.loads(raw)["errors"][0]
                detail = f"{first.get('code')}: {first.get('detail')}"
            except Exception:
                detail = raw[:300]
            return {"error": detail}, exc.code
        except Exception as exc:  # noqa: BLE001 -- report, never crash the job
            return {"error": f"{type(exc).__name__}: {exc}"}, 0


def version_state(attrs: dict) -> str | None:
    """The version's state, under whichever name the API is using today.

    appStoreVersions carries `appStoreState` and `appVersionState` -- both are
    present and they disagree once a version has ever been submitted (review
    state versus sale state). Reading `state` returns None, which reads as "not
    submittable" and makes the whole script report an empty app rather than
    failing loudly.
    """
    return attrs.get("appVersionState") or attrs.get("appStoreState")


def load_env_file(path: Path) -> None:
    """Fill in any of the three names the environment did not already provide.

    Set values win: on CI the secrets are the only source, and locally a
    variable exported for one run should not be silently overridden by a file
    written weeks ago.
    """
    if not path.exists():
        return
    mapping = {"KEY_ID": "APPSTORE_KEY_ID", "ISSUER_ID": "APPSTORE_ISSUER_ID",
               "P8_PATH": "APPSTORE_KEY_PATH"}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        target = mapping.get(name.strip())
        if target and not os.environ.get(target):
            os.environ[target] = value.strip().strip('"')


def main() -> int:
    load_env_file(Path.home() / ".app-store" / "env")

    ap = argparse.ArgumentParser()
    ap.add_argument("--build", required=True,
                    help="CURRENT_PROJECT_VERSION of the build to submit")
    ap.add_argument("--version", help="marketing version; default: the live editable one")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--inspect", action="store_true", help="report only, change nothing")
    g.add_argument("--submit", action="store_true", help="assemble the submission and submit")
    args = ap.parse_args()

    key_id = os.environ.get("APPSTORE_KEY_ID", "")
    issuer = os.environ.get("APPSTORE_ISSUER_ID", "")
    if not key_id or not issuer:
        print("APPSTORE_KEY_ID and APPSTORE_ISSUER_ID must be set", file=sys.stderr)
        return 2
    key_path = Path(os.environ.get("APPSTORE_KEY_PATH",
                                   f"~/private_keys/AuthKey_{key_id}.p8")).expanduser()
    if not key_path.exists():
        print(f"API key not found at {key_path}", file=sys.stderr)
        return 2

    api = ASC(key_id, issuer, key_path)

    # ── The app ────────────────────────────────────────────────────────────
    data, status = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    if status != 200 or not data.get("data"):
        print(f"app {BUNDLE_ID} not found ({status}: {data.get('error')})", file=sys.stderr)
        return 2
    app_id = data["data"][0]["id"]

    # ── The version ────────────────────────────────────────────────────────
    q = f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=50"
    if args.version:
        q += f"&filter[versionString]={args.version}"
    data, status = api("GET", q)
    versions = [v for v in data.get("data", [])
                if version_state(v["attributes"]) in SUBMITTABLE_STATES]
    if not versions:
        print("no version in a submittable state", file=sys.stderr)
        return 2
    version = versions[0]
    ver_id = version["id"]
    vstate = version_state(version["attributes"])
    print(f"app       {app_id}")
    print(f"version   {version['attributes']['versionString']}  state={vstate}  id={ver_id}")

    # Confirm the build is the one attached to that version. Submitting the
    # wrong build is unrecoverable in the way that matters: review sees it.
    data, _ = api("GET", f"/appStoreVersions/{ver_id}/build")
    build = (data.get("data") or {}).get("attributes", {})
    if build:
        print(f"build     {build.get('version')}  state={build.get('processingState')}")
        if str(build.get("version")) != str(args.build):
            print(f"\nREFUSING: version is attached to build {build.get('version')}, "
                  f"not {args.build}.", file=sys.stderr)
            return 2
    else:
        print("build     (none attached to this version yet)")

    # ── Purchases: subscriptions and non-consumables ───────────────────────
    subs, status = api("GET", f"/apps/{app_id}/subscriptionGroups?limit=50")
    groups = subs.get("data") or []
    subscriptions = []
    for group in groups:
        items, _ = api("GET", f"/subscriptionGroups/{group['id']}/subscriptions?limit=50")
        for s in items.get("data") or []:
            subscriptions.append(s)

    iaps, _ = api("GET", f"/apps/{app_id}/inAppPurchasesV2?limit=50")
    non_consumables = iaps.get("data") or []

    print(f"\n{len(subscriptions)} subscription(s), {len(non_consumables)} in-app purchase(s):")
    problems = []
    for item in subscriptions + non_consumables:
        a = item["attributes"]
        st = a.get("state")
        ok = st in ATTACHABLE_STATES
        print(f"  {'[x]' if ok else '[ ]'} {a.get('productId'):45} {st}")
        if not ok:
            problems.append((a.get("productId"), st))

    if problems:
        print("\nNot attachable yet:")
        for pid, st in problems:
            hint = (" -- the product is incomplete in App Store Connect"
                    if st in ("MISSING_METADATA", "READY_TO_SUBMIT") else "")
            print(f"  {pid}: {st}{hint}")

    attached = [i for i in subscriptions + non_consumables
                if i["attributes"].get("state") in ATTACHABLE_STATES]

    if args.inspect:
        print(f"\nwould submit: version {ver_id} + {len(attached)} purchase(s)")
        print("(dry run -- nothing changed)")
        return 0

    # ── Assemble the submission ────────────────────────────────────────────
    #
    # Apple's API allows exactly one open submission per platform, and returns
    # it from the collection rather than requiring us to remember an id.
    data, status = api("GET",
                       f"/reviewSubmissions?filter[app]={app_id}"
                       f"&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW")
    submission = (data.get("data") or [None])[0]
    if submission:
        sub_id = submission["id"]
        print(f"\nusing open submission {sub_id}")
    else:
        data, status = api("POST", "/reviewSubmissions", {"data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})
        if status // 100 != 2:
            print(f"could not open a submission: {data.get('error')}", file=sys.stderr)
            return 2
        sub_id = data["data"]["id"]
        print(f"\nopened submission {sub_id}")

    existing, _ = api("GET", f"/reviewSubmissions/{sub_id}/items?limit=100")
    have = existing.get("data") or []

    # What is attached, keyed by relationship name. The id that matters for a
    # purchase item is the *version* id, not the product id -- a subscription
    # and its subscriptionVersion are different entities, and matching on the
    # product id would re-add an item that is already there and fail.
    have_ids: dict[str, set[str]] = {}
    for item in have:
        for name, rel in (item.get("relationships") or {}).items():
            ident = (rel.get("data") or {}).get("id")
            if ident:
                have_ids.setdefault(name, set()).add(ident)

    def already(kind: str, ident: str) -> bool:
        return ident in have_ids.get(kind, set())

    def add(payload: dict, label: str) -> bool:
        _, st = api("POST", "/reviewSubmissionItems", {"data": payload})
        print(f"  {'added' if st // 100 == 2 else 'FAILED'}  {label}"
              + ("" if st // 100 == 2 else f"  ({st})"))
        return st // 100 == 2

    added = 0
    if not already("appStoreVersion", ver_id):
        added += add({"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}},
        }}, f"version {version['attributes']['versionString']}")

    for item in subscriptions:
        a = item["attributes"]
        if a.get("state") not in ATTACHABLE_STATES:
            continue
        # A subscription is not directly submittable: the item carries its
        # `subscriptionVersion`. Apple keeps the localized metadata (the review
        # screenshot, the description) on the version, and it is the version
        # that goes to review.
        versions, _ = api("GET", f"/subscriptions/{item['id']}/versions?limit=10")
        for version in versions.get("data") or []:
            if already("subscriptionVersion", version["id"]):
                continue
            label = f"{a.get('productId', item['id'])} v{version['attributes'].get('version')}"
            added += add({"type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                "subscriptionVersion": {
                    "data": {"type": "subscriptionVersions", "id": version["id"]},
                },
            }}, label)

    for item in non_consumables:
        a = item["attributes"]
        # No version entity here: `inAppPurchasesV2` is itself the thing that
        # goes to review, which is why the id can be attached directly and the
        # subscriptions above cannot.
        if a.get("state") not in ATTACHABLE_STATES or already("inAppPurchaseV2", item["id"]):
            continue
        added += add({"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
            "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": item["id"]}},
        }}, a.get("productId", item["id"]))

    print(f"\n{added} item(s) added to submission {sub_id}")

    # ── Submit ─────────────────────────────────────────────────────────────
    #
    # PATCH submitted=true is the endpoint that actually hands it to Apple.
    # There is no undo: withdrawing is a separate, visible action.
    data, status = api("PATCH", f"/reviewSubmissions/{sub_id}", {"data": {
        "type": "reviewSubmissions", "id": sub_id,
        "attributes": {"submitted": True},
    }})
    if status // 100 != 2:
        print(f"\nSUBMIT FAILED ({status}): {data.get('error')}", file=sys.stderr)
        return 2

    print(f"\nSUBMITTED -- state={data['data']['attributes'].get('state')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
