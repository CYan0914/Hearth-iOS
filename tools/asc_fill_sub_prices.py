#!/usr/bin/env python3
"""Give a subscription a price in every territory it is available in.

The problem this solves:

Create a subscription through the API, set its price for the base territory, and
it sits at MISSING_METADATA forever. Nothing in the API says why. App Store
Connect's web UI equalises a price across all available territories in one
action; the API does not -- you get the one territory you asked for, and Apple
treats a subscription that is available in 175 territories but priced in one as
incomplete. tools/asc_release.py then (correctly) refuses to attach it to a
submission, so the version cannot ship.

Comparing against an app in this account with three approved subscriptions:
those carry one price row per available territory. That is the target state.

How a price point is chosen:

A subscriptionPricePoint id is base64url of {"s": <subscriptionId>, "t":
<territory>, "p": <ordinal>}. The ordinal is 10000 plus the tier's index in
Apple's global price ladder -- USA runs 10001 = $0.29 upward, and 10062 is
$4.99 there. The same ordinal is the same tier in every other territory: the
$4.99 tier resolves to GBP 4.99 / JPY 660 / EUR 4.99 / CAD 4.99.

Not every territory stocks every tier, so an ordinal that resolves in the USA
can be absent elsewhere. When Apple rejects one, this falls back to the nearest
ordinal that territory actually offers and reports the substitution, rather
than leaving a silent hole.

Usage:
    python3 tools/asc_fill_sub_prices.py --product com.cyan0914.hearth.pro.monthly --inspect
    python3 tools/asc_fill_sub_prices.py --product com.cyan0914.hearth.pro.monthly --apply
    python3 tools/asc_fill_sub_prices.py --all --apply

Credentials: APPSTORE_KEY_ID, APPSTORE_ISSUER_ID, APPSTORE_KEY_PATH.
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

# Territories we never want a price in. None by default -- the point is to
# match availability, and availability is already the curated list.
SKIP_TERRITORIES: set[str] = set()


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def unb64(s: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))


def price_point_id(sub_id: str, territory: str, ordinal: str) -> str:
    return b64(json.dumps({"s": sub_id, "t": territory, "p": ordinal},
                          separators=(",", ":")).encode())


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
        req = urllib.request.Request(
            API + path,
            data=json.dumps(body).encode() if body else None,
            method=method,
            headers={"Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return (json.loads(raw) if raw else {}), resp.status
        except urllib.error.HTTPError as exc:
            text = exc.read().decode()
            try:
                first = json.loads(text)["errors"][0]
                return {"error": f"{first.get('code')}: {first.get('detail')}"}, exc.code
            except Exception:
                return {"error": text[:200]}, exc.code
        except Exception as exc:  # noqa: BLE001
            return {"error": f"{type(exc).__name__}: {exc}"}, 0


def app_id(api: ASC) -> str:
    data, status = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    if status != 200 or not data.get("data"):
        raise SystemExit(f"app {BUNDLE_ID} not found ({status})")
    return data["data"][0]["id"]


def all_subscriptions(api: ASC) -> list[dict]:
    data, _ = api("GET", f"/apps/{app_id(api)}/subscriptionGroups?limit=50")
    out = []
    for group in data.get("data") or []:
        items, _ = api("GET", f"/subscriptionGroups/{group['id']}/subscriptions?limit=50")
        out.extend(items.get("data") or [])
    return out


def existing_prices(api: ASC, sub_id: str) -> dict[str, str]:
    """territory -> price point id, for everything already priced."""
    out: dict[str, str] = {}
    cursor = None
    while True:
        q = f"/subscriptions/{sub_id}/prices?limit=200&include=territory,subscriptionPricePoint"
        if cursor:
            q += f"&cursor={cursor}"
        data, status = api("GET", q)
        if status != 200:
            break
        for row in data.get("data") or []:
            rel = row.get("relationships", {})
            terr = (rel.get("territory", {}).get("data") or {}).get("id")
            point = (rel.get("subscriptionPricePoint", {}).get("data") or {}).get("id")
            if terr and point:
                out[terr] = point
        cursor = (data.get("meta", {}).get("paging", {}) or {}).get("nextCursor")
        if not cursor:
            break
    return out


def available_territories(api: ASC, sub_id: str) -> list[str]:
    data, status = api("GET", f"/subscriptions/{sub_id}/subscriptionAvailability")
    avail = data.get("data")
    if status != 200 or not avail:
        return []
    out, cursor = [], None
    while True:
        q = f"/subscriptionAvailabilities/{avail['id']}/availableTerritories?limit=200"
        if cursor:
            q += f"&cursor={cursor}"
        page, status = api("GET", q)
        if status != 200:
            break
        out.extend(t["id"] for t in page.get("data") or [])
        cursor = (page.get("meta", {}).get("paging", {}) or {}).get("nextCursor")
        if not cursor:
            break
    return out


def territory_ordinals(api: ASC, sub_id: str, territory: str) -> list[int]:
    """Every tier ordinal this territory actually stocks, ascending."""
    out, cursor = [], None
    while True:
        q = (f"/subscriptions/{sub_id}/pricePoints?filter[territory]={territory}"
             f"&limit=200")
        if cursor:
            q += f"&cursor={cursor}"
        page, status = api("GET", q)
        if status != 200:
            break
        for point in page.get("data") or []:
            try:
                out.append(int(unb64(point["id"])["p"]))
            except Exception:
                pass
        cursor = (page.get("meta", {}).get("paging", {}) or {}).get("nextCursor")
        if not cursor:
            break
    return sorted(out)


def set_price(api: ASC, sub_id: str, territory: str, ordinal: str):
    return api("POST", "/subscriptionPrices", {"data": {
        "type": "subscriptionPrices",
        "attributes": {"planType": "UPFRONT"},
        "relationships": {
            "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
            "subscriptionPricePoint": {
                "data": {"type": "subscriptionPricePoints",
                         "id": price_point_id(sub_id, territory, ordinal)}},
            "territory": {"data": {"type": "territories", "id": territory}},
        },
    }})


def fill(api: ASC, sub: dict, apply: bool) -> int:
    sub_id = sub["id"]
    product = sub["attributes"].get("productId")
    priced = existing_prices(api, sub_id)
    territories = available_territories(api, sub_id)

    if not territories:
        print(f"\n{product}: no availability record -- set that first")
        return 1

    # The base territory's ordinal is the tier to mirror everywhere. Prefer USA;
    # fall back to whatever is priced so this still works if the base moves.
    base = priced.get("USA") or (next(iter(priced.values())) if priced else None)
    if not base:
        print(f"\n{product}: no price at all -- set the base territory first")
        return 1
    target = unb64(base)["p"]
    print(f"\n{product}")
    print(f"  tier ordinal {target}  (from {'USA' if 'USA' in priced else 'the priced base'})")
    print(f"  availability {len(territories)} territories, priced {len(priced)}")

    missing = [t for t in territories if t not in priced and t not in SKIP_TERRITORIES]
    print(f"  missing      {len(missing)}")
    if not missing:
        return 0

    if not apply:
        print(f"  would price: {', '.join(missing[:12])}"
              + (" ..." if len(missing) > 12 else ""))
        return 0

    added = substituted = failed = 0
    for i, terr in enumerate(missing, 1):
        _, status = set_price(api, sub_id, terr, target)
        if status // 100 == 2:
            added += 1
        else:
            # That territory does not stock this tier. Take the nearest it has.
            options = territory_ordinals(api, sub_id, terr)
            if not options:
                failed += 1
                print(f"    {terr}: no price points available, skipping")
                continue
            near = min(options, key=lambda o: abs(o - int(target)))
            _, status = set_price(api, sub_id, terr, str(near))
            if status // 100 == 2:
                substituted += 1
                print(f"    {terr}: tier {target} absent, used nearest {near}")
            else:
                failed += 1
                print(f"    {terr}: failed ({status})")
        if i % 25 == 0:
            print(f"    ... {i}/{len(missing)}")

    print(f"  priced {added} at the target tier, {substituted} at the nearest, "
          f"{failed} failed")

    after, _ = api("GET", f"/subscriptions/{sub_id}")
    print(f"  state now: {after['data']['attributes'].get('state')}")
    return 0 if failed == 0 else 1


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
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--product", help="subscription productId")
    g.add_argument("--all", action="store_true", help="every subscription on the app")
    a = ap.add_mutually_exclusive_group(required=True)
    a.add_argument("--inspect", action="store_true", help="report only")
    a.add_argument("--apply", action="store_true", help="create the prices")
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
    subs = all_subscriptions(api)
    if args.product:
        subs = [s for s in subs if s["attributes"].get("productId") == args.product]
        if not subs:
            print(f"no subscription with productId {args.product}", file=sys.stderr)
            return 2

    rc = 0
    for sub in subs:
        rc |= fill(api, sub, args.apply)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
