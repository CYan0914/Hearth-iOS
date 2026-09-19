#!/usr/bin/env python3
"""Attach an App Store review screenshot to a subscription.

Why this needs a script:

A subscription that is otherwise complete -- localization, price, availability --
still reads MISSING_METADATA until it has a review screenshot, and
tools/asc_release.py refuses to attach a MISSING_METADATA product to a
submission (correctly: Apple rejects the whole submission for it). The screenshot
is also the one field the web UI insists on, so the product cannot be finished
without either clicking through App Store Connect by hand or doing this.

The upload is App Store Connect's usual three-step dance:

  1. POST the screenshot record with its fileName and byte count. Apple replies
     with uploadOperations: a list of {method, url, offset, length,
     requestHeaders} describing exactly which byte range goes where. For an
     image this is normally a single PUT, but the offsets are read rather than
     assumed.
  2. PUT the bytes to those URLs. These are NOT the API host and carry no
     Authorization header -- they are pre-signed object-storage URLs, and adding
     our bearer token to them makes the signature invalid.
  3. PATCH uploaded=true, which is what commits it. Until this lands the asset
     exists but is not part of the product.

Usage:
    python3 tools/asc_sub_review_shot.py --product com.cyan0914.hearth.pro.monthly \
        --image shot.png --inspect
    python3 tools/asc_sub_review_shot.py --product com.cyan0914.hearth.pro.monthly \
        --image shot.png --replace

Credentials: APPSTORE_KEY_ID, APPSTORE_ISSUER_ID, APPSTORE_KEY_PATH.
"""
from __future__ import annotations

import argparse
import base64
import json
import mimetypes
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

    def __call__(self, method: str, path: str, body: dict | None = None,
                 raw_body: bytes | None = None,
                 headers: dict | None = None, absolute: bool = False):
        url = path if absolute else API + path
        hdrs = {"Content-Type": "application/json"}
        if not absolute:
            hdrs["Authorization"] = f"Bearer {self.token}"
        if headers:
            hdrs.update(headers)
        data = raw_body if raw_body is not None else (
            json.dumps(body).encode() if body else None)

        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                payload = resp.read()
                return (json.loads(payload) if payload else {}), resp.status
        except urllib.error.HTTPError as exc:
            text = exc.read().decode()
            try:
                first = json.loads(text)["errors"][0]
                detail = f"{first.get('code')}: {first.get('detail')}"
            except Exception:
                detail = text[:300]
            return {"error": detail}, exc.code
        except Exception as exc:  # noqa: BLE001
            return {"error": f"{type(exc).__name__}: {exc}"}, 0


def find_subscription(api: ASC, product_id: str) -> dict | None:
    data, _ = api("GET", f"/apps/{_app_id(api)}/subscriptionGroups?limit=50")
    for group in data.get("data") or []:
        items, _ = api("GET", f"/subscriptionGroups/{group['id']}/subscriptions?limit=50")
        for sub in items.get("data") or []:
            if sub["attributes"].get("productId") == product_id:
                return sub
    return None


_APP: list[str] = []


def _app_id(api: ASC) -> str:
    if not _APP:
        data, status = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
        if status != 200 or not data.get("data"):
            raise SystemExit(f"app {BUNDLE_ID} not found ({status})")
        _APP.append(data["data"][0]["id"])
    return _APP[0]


def upload_file(api: ASC, path: Path, operations: list[dict]) -> bool:
    """PUT each byte range Apple asked for. Returns True if all landed."""
    blob = path.read_bytes()
    for op in operations:
        offset = op.get("offset", 0)
        length = op.get("length", len(blob))
        chunk = blob[offset:offset + length]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        _, status = api(op.get("method", "PUT"), op["url"], raw_body=chunk,
                        headers=headers, absolute=True)
        print(f"    PUT {op.get('method')} offset={offset} len={length} -> {status}")
        if status // 100 != 2:
            return False
    return True


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
    ap.add_argument("--product", required=True, help="subscription productId")
    ap.add_argument("--image", required=True, help="PNG to upload")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--inspect", action="store_true", help="report only")
    g.add_argument("--replace", action="store_true",
                   help="delete any existing review screenshot, then upload")
    g.add_argument("--apply", action="store_true",
                   help="upload only if none exists (refuses otherwise)")
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

    image = Path(args.image)
    if not image.exists():
        print(f"image not found: {image}", file=sys.stderr)
        return 2

    api = ASC(key_id, issuer, key_path)
    sub = find_subscription(api, args.product)
    if not sub:
        print(f"no subscription with productId {args.product}", file=sys.stderr)
        return 2
    sub_id = sub["id"]
    print(f"subscription {args.product}  id={sub_id}  state={sub['attributes'].get('state')}")

    existing, status = api("GET", f"/subscriptions/{sub_id}/appStoreReviewScreenshot")
    have = existing.get("data")
    print(f"review screenshot: {'present' if have else 'none'} ({status})")
    if have:
        a = have["attributes"]
        print(f"  {a.get('fileName')}  {a.get('fileSize')} bytes  state={a.get('assetDeliveryState')}")

    print(f"\nimage  {image.name}  {image.stat().st_size} bytes")

    if args.inspect:
        print("\n(dry run -- nothing changed)")
        return 0

    if have and args.apply:
        print("\nrefusing: a review screenshot already exists; use --replace",
              file=sys.stderr)
        return 2

    if have:
        _, status = api("DELETE", f"/subscriptions/{sub_id}/appStoreReviewScreenshot")
        print(f"deleted existing screenshot -> {status}")

    mime = mimetypes.guess_type(image.name)[0] or "image/png"
    payload, status = api("POST", "/subscriptionAppStoreReviewScreenshots", {"data": {
        "type": "subscriptionAppStoreReviewScreenshots",
        "attributes": {"fileName": image.name, "fileSize": image.stat().st_size},
        "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub_id}}},
    }})
    if status // 100 != 2:
        print(f"\ncreate failed ({status}): {payload.get('error')}", file=sys.stderr)
        return 2
    rec = payload["data"]
    shot_id = rec["id"]
    ops = rec["attributes"].get("uploadOperations") or []
    print(f"\ncreated {shot_id}, {len(ops)} upload operation(s)")

    if not upload_file(api, image, ops):
        print("upload failed", file=sys.stderr)
        return 2

    commit, status = api("PATCH", f"/subscriptionAppStoreReviewScreenshots/{shot_id}",
                         {"data": {"type": "subscriptionAppStoreReviewScreenshots",
                                   "id": shot_id,
                                   "attributes": {"uploaded": True}}})
    if status // 100 != 2:
        print(f"commit failed ({status}): {commit.get('error')}", file=sys.stderr)
        return 2

    # Re-read rather than trust the response: the screenshot landing does not
    # necessarily flip the subscription's state in the same transaction.
    _, _ = api("GET", f"/subscriptions/{sub_id}/appStoreReviewScreenshot")
    after, _ = api("GET", f"/subscriptions/{sub_id}")
    print(f"\ncommitted. subscription state now: {after['data']['attributes'].get('state')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
