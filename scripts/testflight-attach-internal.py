#!/usr/bin/env python3
"""Wait for the latest TestFlight build to be VALID, then attach it to the
Internal Testers group.

Apple's `xcrun altool --upload-app` deposits the IPA into App Store Connect
but does NOT attach the resulting build to any TestFlight tester group.
Without this step the build sits in "Builds" forever; testers see only
the most recent build that someone manually attached. Causes the symptom:
"I uploaded v4.0.20 but TestFlight still shows v4.0.16".

Reads ASC creds from env (NVPN_ASC_AUTH_KEY_PATH / _ID / _ISSUER_ID), with
~/.appstoreconnect/ as a fallback.
"""

from __future__ import annotations

import base64
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

BUNDLE_ID = os.environ.get("NVPN_IOS_BUNDLE_ID", "to.iris.nvpn")
GROUP_NAME = os.environ.get("NVPN_TESTFLIGHT_INTERNAL_GROUP", "Internal Testers")
WAIT_ATTEMPTS = int(os.environ.get("NVPN_TESTFLIGHT_WAIT_ATTEMPTS", "30"))
WAIT_SECONDS = int(os.environ.get("NVPN_TESTFLIGHT_WAIT_SECONDS", "30"))


def fail(msg: str, code: int = 1) -> None:
    print(f"testflight-attach-internal: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_asc_creds() -> tuple[str, str, str]:
    asc_root = os.path.expanduser(os.environ.get("NVPN_ASC_ROOT", "~/.appstoreconnect"))
    key_path = os.environ.get("NVPN_ASC_AUTH_KEY_PATH")
    if not key_path:
        candidates = sorted(glob.glob(f"{asc_root}/private_keys/AuthKey_*.p8"))
        if not candidates:
            fail("no ASC API key found; set NVPN_ASC_AUTH_KEY_PATH or place AuthKey_*.p8 under ~/.appstoreconnect/private_keys/")
        key_path = candidates[-1]
    if not os.path.isfile(key_path):
        fail(f"ASC API key not found: {key_path}")
    key_id = os.environ.get("NVPN_ASC_AUTH_KEY_ID")
    if not key_id:
        name = os.path.basename(key_path)
        if name.startswith("AuthKey_") and name.endswith(".p8"):
            key_id = name[len("AuthKey_") : -len(".p8")]
        else:
            fail("set NVPN_ASC_AUTH_KEY_ID")
    issuer = os.environ.get("NVPN_ASC_AUTH_KEY_ISSUER_ID")
    if not issuer:
        issuer_file = f"{asc_root}/issuer.txt"
        if os.path.isfile(issuer_file):
            with open(issuer_file) as f:
                issuer = f.read().strip()
    if not issuer:
        fail("set NVPN_ASC_AUTH_KEY_ISSUER_ID or write the issuer to ~/.appstoreconnect/issuer.txt")
    return key_path, key_id, issuer


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(key_path: str, key_id: str, issuer: str) -> str:
    with open(key_path, "rb") as f:
        pk = serialization.load_pem_private_key(f.read(), password=None)
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64url(
        json.dumps(
            {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
        ).encode()
    )
    signing_input = f"{header}.{claims}".encode()
    sig_der = pk.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(sig_der)
    sig = b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    return f"{header}.{claims}.{sig}"


def asc_request(token: str, method: str, path: str, body: dict | None = None):
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com/v1/{path}",
        data=data,
        headers=headers,
        method=method,
    )
    try:
        return urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", "replace")[:1000]
        fail(f"HTTP {e.code} on {method} {path}: {body_text}")


def main() -> None:
    key_path, key_id, issuer = resolve_asc_creds()
    token = make_token(key_path, key_id, issuer)

    apps = json.loads(
        asc_request(token, "GET", f"apps?filter[bundleId]={BUNDLE_ID}").read()
    )
    if not apps.get("data"):
        fail(f"no app with bundleId={BUNDLE_ID} on App Store Connect")
    app_id = apps["data"][0]["id"]

    # Find the Internal Testers group.
    groups = json.loads(
        asc_request(token, "GET", f"betaGroups?filter[app]={app_id}&limit=50").read()
    )
    matching = [
        g
        for g in groups.get("data", [])
        if g["attributes"].get("name") == GROUP_NAME
        and g["attributes"].get("isInternalGroup")
    ]
    if not matching:
        names = [g["attributes"].get("name") for g in groups.get("data", [])]
        fail(
            f"no internal beta group named {GROUP_NAME!r}; have: {names}. "
            f"Set NVPN_TESTFLIGHT_INTERNAL_GROUP to override."
        )
    group_id = matching[0]["id"]

    # Poll for the latest VALID build. altool returns immediately after upload
    # but Apple processing typically takes 5-15 minutes before the build
    # transitions PROCESSING -> VALID and becomes attachable.
    target = None
    for attempt in range(1, WAIT_ATTEMPTS + 1):
        builds = json.loads(
            asc_request(
                token,
                "GET",
                f"builds?filter[app]={app_id}&sort=-uploadedDate&limit=1",
            ).read()
        )
        if builds.get("data"):
            b = builds["data"][0]
            state = b["attributes"].get("processingState")
            if state == "VALID":
                target = b
                break
            print(
                f"waiting for latest build to become VALID (currently {state}); "
                f"attempt {attempt}/{WAIT_ATTEMPTS}",
                file=sys.stderr,
            )
        else:
            print(f"no builds found yet; attempt {attempt}/{WAIT_ATTEMPTS}", file=sys.stderr)
        time.sleep(WAIT_SECONDS)

    if target is None:
        fail(
            f"latest build did not become VALID within "
            f"{WAIT_ATTEMPTS * WAIT_SECONDS}s; check App Store Connect for processing errors."
        )

    build_id = target["id"]
    a = target["attributes"]
    print(
        f"attaching build CFBundleVersion={a.get('version')} "
        f"(id={build_id}, uploaded={a.get('uploadedDate')}) to {GROUP_NAME}..."
    )
    asc_request(
        token,
        "POST",
        f"betaGroups/{group_id}/relationships/builds",
        body={"data": [{"type": "builds", "id": build_id}]},
    )
    print(
        f"TESTFLIGHT_ATTACH_OK build {a.get('version')} attached to "
        f"internal group {GROUP_NAME!r} ({group_id})"
    )


if __name__ == "__main__":
    main()
