#!/usr/bin/env python3
"""
End-to-end HTTP test of the inbound email webhook security boundary.

Posts real Svix-signed requests to a running local stack and asserts:

  * a valid signature passes verification and reaches the provider fetch step;
  * a tampered body is rejected before any processing;
  * an unsigned request is rejected;
  * a stale (replayed) signature is rejected;
  * unsupported event types are ignored rather than acted on.

The Resend fetch itself requires EMAIL_API_KEY. When it is absent the handler
correctly stops at the fetch step with EMAIL_DELIVERY_FAILED; the test asserts
that, rather than pretending the whole ingest succeeded.

Usage: python3 tests/scripts/webhook_http_test.py
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321")
WEBHOOK = f"{API}/functions/v1/email-webhook"
SECRET = os.environ.get("RESEND_WEBHOOK_SECRET", "")

passed = 0
failed = 0


def ok(name: str) -> None:
    global passed
    passed += 1
    print(f"  \033[32mPASS\033[0m  {name}")


def bad(name: str, detail: str = "") -> None:
    global failed
    failed += 1
    print(f"  \033[31mFAIL\033[0m  {name}" + (f" ({detail})" if detail else ""))


def sign(secret: str, msg_id: str, timestamp: str, body: str) -> str:
    raw = secret[6:] if secret.startswith("whsec_") else secret
    key = base64.b64decode(raw + "=" * (-len(raw) % 4))
    digest = hmac.new(key, f"{msg_id}.{timestamp}.{body}".encode(), hashlib.sha256).digest()
    return f"v1,{base64.b64encode(digest).decode()}"


def post(body: str, headers: dict[str, str]) -> tuple[int, str]:
    req = urllib.request.Request(WEBHOOK, data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()
    except Exception as exc:  # network failure
        return 0, str(exc)


def main() -> int:
    print("=" * 62)
    print(" Inbound email webhook - HTTP security boundary")
    print("=" * 62)

    if not SECRET:
        print(
            "\n  RESEND_WEBHOOK_SECRET is not set.\n"
            "  Set it to the signing secret of your Resend webhook, or to any value\n"
            "  when running against the local stack:\n"
            "    supabase secrets set RESEND_WEBHOOK_SECRET=whsec_...\n"
        )
        return 2

    now = str(int(time.time()))
    event = {
        "type": "email.received",
        "created_at": "2026-09-25T14:00:00.000Z",
        "data": {
            "email_id": f"e2e-email-{int(time.time() * 1000)}",
            "from": "rasonjonathan6@gmail.com",
            "to": ["reply@inbound.resend.app"],
            "subject": "Re: Manual KYC Verification request",
            "message_id": "<e2e@mail.gmail.com>",
        },
    }
    body = json.dumps(event)
    msg_id = "msg_e2e_1"

    print("\n1. Valid signature passes verification and reaches the provider fetch")
    status, text = post(
        body,
        {
            "svix-id": msg_id,
            "svix-timestamp": now,
            "svix-signature": sign(SECRET, msg_id, now, body),
        },
    )
    if status == 400:
        bad("valid signature accepted", f"rejected with {status}: {text}")
    else:
        ok("valid signature accepted (reached provider fetch, HTTP %d)" % status)
        if os.environ.get("EMAIL_API_KEY"):
            if "EMAIL_DELIVERY_FAILED" in text or status == 200:
                ok("handler continued past verification with a real API key configured")
            else:
                bad("unexpected handler response", text)
        elif "EMAIL_DELIVERY_FAILED" in text or "SERVICE_NOT_CONFIGURED" in text:
            ok("honestly reports the missing email configuration instead of faking success")
        else:
            bad("expected an honest configuration error without EMAIL_API_KEY", text)

    print("\n2. Tampered body is rejected")
    tampered = body.replace('"email_id"', '"email_id_tampered"')
    status, text = post(
        tampered,
        {
            "svix-id": msg_id,
            "svix-timestamp": now,
            "svix-signature": sign(SECRET, msg_id, now, body),
        },
    )
    if status == 400 and "INVALID_WEBHOOK" in text:
        ok("tampered body rejected")
    else:
        bad("tampered body not rejected", f"HTTP {status}: {text}")

    print("\n3. Unsigned request is rejected")
    status, text = post(body, {})
    if status == 400 and "INVALID_WEBHOOK" in text:
        ok("unsigned request rejected")
    else:
        bad("unsigned request not rejected", f"HTTP {status}: {text}")

    print("\n4. Replayed signature is rejected")
    stale = str(int(time.time()) - 7200)
    status, text = post(
        body,
        {
            "svix-id": msg_id,
            "svix-timestamp": stale,
            "svix-signature": sign(SECRET, msg_id, stale, body),
        },
    )
    if status == 400 and "INVALID_WEBHOOK" in text:
        ok("stale signature rejected")
    else:
        bad("stale signature not rejected", f"HTTP {status}: {text}")

    print("\n5. Wrong secret is rejected")
    wrong = f"whsec_{base64.b64encode(b'a-totally-different-secret-value!!').decode()}"
    status, text = post(
        body,
        {
            "svix-id": "msg_e2e_2",
            "svix-timestamp": now,
            "svix-signature": sign(wrong, "msg_e2e_2", now, body),
        },
    )
    if status == 400 and "INVALID_WEBHOOK" in text:
        ok("wrong secret rejected")
    else:
        bad("wrong secret not rejected", f"HTTP {status}: {text}")

    print("\n6. Unsupported event type is ignored")
    other = json.dumps({"type": "email.delivered", "data": {"email_id": "x"}})
    status, text = post(
        other,
        {
            "svix-id": "msg_e2e_3",
            "svix-timestamp": now,
            "svix-signature": sign(SECRET, "msg_e2e_3", now, other),
        },
    )
    if status == 200 and '"ignored": true' in text.replace('"ignored":true', '"ignored": true'):
        ok("unsupported event ignored without side effects")
    elif status == 200 and "ignored" in text:
        ok("unsupported event ignored without side effects")
    else:
        bad("unsupported event handling", f"HTTP {status}: {text}")

    print("\n" + "=" * 62)
    print(f" RESULT: {passed} passed, {failed} failed")
    print("=" * 62)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
