#!/usr/bin/env python3
"""End-to-end MVola flow against the deployed cloud project.

Creates throwaway users with the service role, then drives the real Edge
Functions exactly as the Flutter client would. Every assertion is against live
behaviour, not a mock.

Usage: python3 tests/scripts/mvola_e2e.py
"""
import json
import sys
import urllib.error
import urllib.request

PROJECT = "hbvjpawnszzcbcjmbkuf"


def load_env(path="/workspace/project/.env"):
    env = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


ENV = load_env()
BASE = ENV["SUPABASE_URL"].rstrip("/")
ANON = ENV["SUPABASE_ANON_KEY"]
SERVICE = ENV["SUPABASE_SERVICE_ROLE_KEY"]

PASSED = []
FAILED = []


def check(name, condition, detail=""):
    if condition:
        PASSED.append(name)
        print(f"  PASS  {name}")
    else:
        FAILED.append(name)
        print(f"  FAIL  {name}  {detail}")


def request(method, url, body=None, headers=None, timeout=90):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        headers=headers or {},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw


def admin_api(path, method="GET", body=None):
    return request(
        method,
        f"{BASE}{path}",
        body,
        {
            "apikey": SERVICE,
            "Authorization": f"Bearer {SERVICE}",
            "Content-Type": "application/json",
        },
    )


def create_user(email, password, role=None):
    payload = {"email": email, "password": password, "email_confirm": True}
    if role:
        # `handle_new_user` copies app_metadata.role into profiles.role, which is
        # what is_admin() reads. This is how a real admin is provisioned.
        payload["app_metadata"] = {"role": role}
    status, data = admin_api("/auth/v1/admin/users", "POST", payload)
    if status >= 400:
        raise RuntimeError(f"could not create {email}: {status} {data}")
    return data["id"]


def sign_in(email, password):
    status, data = request(
        "POST",
        f"{BASE}/auth/v1/token?grant_type=password",
        {"email": email, "password": password},
        {"apikey": ANON, "Content-Type": "application/json"},
    )
    if status >= 400:
        raise RuntimeError(f"sign-in failed for {email}: {status} {data}")
    return data["access_token"]


def call_fn(fn, body, token=None):
    headers = {"apikey": ANON, "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return request("POST", f"{BASE}/functions/v1/{fn}", body, headers)


def main():
    suffix = "mvola-e2e-1"
    user_a_email = f"user.a+{suffix}@example.com"
    user_b_email = f"user.b+{suffix}@example.com"
    admin_email = ENV.get("ADMIN_EMAIL", "rason<secret-hidden>6@gmail.com")
    password = "Password123!"

    print("== Setup: users ==")
    for email in (user_a_email, user_b_email):
        # Idempotent: remove any leftover from a previous run.
        _, existing = admin_api(f"/auth/v1/admin/users?page=1&per_page=200")
        for u in (existing or {}).get("users", []):
            if u.get("email") == email:
                admin_api(f"/auth/v1/admin/users/{u['id']}", "DELETE")
    user_a = create_user(user_a_email, password)
    user_b = create_user(user_b_email, password)
    print(f"  user A = {user_a}")
    print(f"  user B = {user_b}")

    token_a = sign_in(user_a_email, password)
    token_b = sign_in(user_b_email, password)

    print("\n== Admin role for the real admin account ==")
    _, listed = admin_api("/auth/v1/admin/users?page=1&per_page=200")
    admin_id = None
    for u in (listed or {}).get("users", []):
        if u.get("email") == admin_email:
            admin_id = u["id"]
    check("the admin account exists", admin_id is not None)

    # A disposable admin exercises the decision path without touching the real
    # admin account or requiring its password.
    admin_probe_email = f"admin.probe+{suffix}@example.com"
    for u in (listed or {}).get("users", []):
        if u.get("email") == admin_probe_email:
            admin_api(f"/auth/v1/admin/users/{u['id']}", "DELETE")
    admin_probe = create_user(admin_probe_email, password, role="admin")
    admin_token = sign_in(admin_probe_email, password)

    print("\n== 1. Create a KYC ticket for user A ==")
    status, created = call_fn("create-kyc-request", {
        "tango_profile_link": "https://tango.me/e2e-a",
        "register_value": user_a_email,
    }, token_a)
    check("ticket creation succeeds", status == 201, f"{status} {created}")
    ticket_a = (created or {}).get("ticket", {})
    check("a ticket code is returned", bool(ticket_a.get("ticket_code")), str(ticket_a))
    ticket_a_id = ticket_a.get("id")

    print("\n== 2. MVola config is served from the server ==")
    status, cfg = call_fn("mvola-payments", {"action": "config"}, token_a)
    check("config succeeds", status == 200, f"{status} {cfg}")
    config = (cfg or {}).get("config", {})
    check("recipient number is configured", config.get("recipient_number") == "0346715622", str(config))
    check("amount is configured", config.get("amount") == 20000, str(config))
    check("currency is MGA", config.get("currency") == "MGA", str(config))
    check(
        "USSD code matches the configured template",
        config.get("ussd_code") == "#111*1*2*0346715622*20000*2#",
        str(config.get("ussd_code")),
    )
    check("instructions are provided", bool(config.get("instructions")))

    print("\n== 3. A fresh request is gated on the MVola payment ==")
    check("ticket creation marks the request payment required",
          ticket_a.get("payment_required") is True, str(ticket_a))
    check("the request is not yet submitted",
          ticket_a.get("is_submitted") is False, str(ticket_a))
    check("the submission state is awaiting_submission",
          ticket_a.get("payment_status") == "awaiting_submission", str(ticket_a))

    print("\n== 4. Start a payment ==")
    status, started = call_fn("mvola-payments", {"action": "start", "ticket_id": ticket_a_id}, token_a)
    check("start succeeds", status == 200, f"{status} {started}")
    payment = (started or {}).get("payment", {})
    payment_id = payment.get("id")
    check("a payment id is returned", bool(payment_id), str(payment))
    check("the payment is pending", payment.get("status") == "pending", str(payment))
    check("the amount came from the server", float(payment.get("amount", 0)) == 20000, str(payment))
    check("the payment is not yet submitted", payment.get("submitted_at") in (None, ""), str(payment))

    print("\n== 4b. Double payment protection ==")
    status, again = call_fn("mvola-payments", {"action": "start", "ticket_id": ticket_a_id}, token_a)
    check("a second start succeeds", status == 200, f"{status} {again}")
    check(
        "a second start returns the same payment",
        (again or {}).get("payment", {}).get("id") == payment_id,
        str(again),
    )

    print("\n== 5. A user cannot pay for another user's ticket ==")
    status, foreign = call_fn("mvola-payments", {"action": "start", "ticket_id": ticket_a_id}, token_b)
    check("another user is refused", status == 403, f"{status} {foreign}")
    check("the refusal uses the FORBIDDEN code", (foreign or {}).get("error") == "FORBIDDEN", str(foreign))

    print("\n== 6. A user cannot submit another user's payment ==")
    status, stolen = call_fn("mvola-payments", {
        "action": "submit",
        "payment_id": payment_id,
        "transaction_reference": "REF-STOLEN",
    }, token_b)
    check("another user is refused", status == 403, f"{status} {stolen}")

    print("\n== 7. Reference validation ==")
    status, empty = call_fn("mvola-payments", {
        "action": "submit", "payment_id": payment_id, "transaction_reference": "   ",
    }, token_a)
    check("an empty reference is refused", status == 422, f"{status} {empty}")
    check(
        "the refusal uses the reference code",
        (empty or {}).get("error") == "MVOLA_REFERENCE_REQUIRED",
        str(empty),
    )

    status, markup = call_fn("mvola-payments", {
        "action": "submit", "payment_id": payment_id, "transaction_reference": "<script>alert(1)</script>",
    }, token_a)
    check("a reference containing markup is refused", status == 422, f"{status} {markup}")

    print("\n== 8. Submit the payment ==")
    status, submitted = call_fn("mvola-payments", {
        "action": "submit",
        "payment_id": payment_id,
        "transaction_reference": "  MV-123456789  ",
        "payer_number": "+261 34 12 345 67",
    }, token_a)
    check("submit succeeds", status == 200, f"{status} {submitted}")
    sub = (submitted or {}).get("payment", {})
    check("the status stays pending after submit", sub.get("status") == "pending", str(sub))
    check("the reference is trimmed", sub.get("transaction_reference") == "MV-123456789", str(sub))
    check("the payer number is normalised", sub.get("payer_number") == "+261341234567", str(sub))
    check("submitted_at is recorded", bool(sub.get("submitted_at")), str(sub))

    print("\n== 9. A user cannot approve their own payment ==")
    status, self_approve = call_fn("admin-actions", {
        "action": "mvola_decision", "payment_id": payment_id, "decision": "approved",
    }, token_a)
    check("a normal user is refused", status in (401, 403), f"{status} {self_approve}")

    print("\n== 10. A user sees only their own payments ==")
    status, mine_a = call_fn("mvola-payments", {"action": "mine"}, token_a)
    check("user A lists their payments", status == 200, f"{status} {mine_a}")
    ids_a = {p["id"] for p in (mine_a or {}).get("payments", [])}
    check("user A sees their own payment", payment_id in ids_a, str(ids_a))

    status, mine_b = call_fn("mvola-payments", {"action": "mine"}, token_b)
    ids_b = {p["id"] for p in (mine_b or {}).get("payments", [])}
    check("user B does not see user A's payment", payment_id not in ids_b, str(ids_b))

    print("\n== 11. An unknown ticket is reported, not created ==")
    status, unknown = call_fn("mvola-payments", {
        "action": "start", "ticket_id": "00000000-0000-0000-0000-000000000000",
    }, token_a)
    check("an unknown ticket is refused", status == 404, f"{status} {unknown}")

    print("\n== 12. Admin surface ==")
    status, listed = call_fn("admin-actions", {"action": "mvola_list"}, admin_token)
    check("the admin lists payments", status == 200, f"{status} {listed}")
    rows = (listed or {}).get("payments", [])
    row = next((r for r in rows if r["id"] == payment_id), None)
    check("the admin sees the submitted payment", row is not None, str(rows)[:300])
    if row:
        check("the listing joins the ticket code", row.get("ticket_code") == ticket_a.get("ticket_code"), str(row))
        check("the listing shows the owner email", row.get("user_email") == user_a_email, str(row))
        check("the listing shows the reference", row.get("transaction_reference") == "MV-123456789", str(row))

    print("\n== 13. A rejection requires a reason ==")
    status, no_reason = call_fn("admin-actions", {
        "action": "mvola_decision", "payment_id": payment_id, "decision": "rejected",
    }, admin_token)
    check("rejecting without a reason is refused", status == 422, f"{status} {no_reason}")
    check(
        "the refusal uses the reason code",
        (no_reason or {}).get("error") == "MVOLA_REASON_REQUIRED",
        str(no_reason),
    )

    print("\n== 14. An invalid decision is refused ==")
    status, bad = call_fn("admin-actions", {
        "action": "mvola_decision", "payment_id": payment_id, "decision": "pending",
    }, admin_token)
    check("an invalid decision is refused", status == 422, f"{status} {bad}")

    print("\n== 15. The admin rejects, then approves the resubmission ==")
    status, rejected = call_fn("admin-actions", {
        "action": "mvola_decision", "payment_id": payment_id, "decision": "rejected",
        "reason": "Reference MVola introuvable.",
    }, admin_token)
    check("the admin rejects", status == 200, f"{status} {rejected}")
    check(
        "the rejection reason is stored",
        (rejected or {}).get("payment", {}).get("rejection_reason") == "Reference MVola introuvable.",
        str(rejected),
    )

    status, seen = call_fn("mvola-payments", {"action": "mine"}, token_a)
    mine = next((p for p in (seen or {}).get("payments", []) if p["id"] == payment_id), None)
    check("the user sees the rejection", (mine or {}).get("status") == "rejected", str(mine))
    check(
        "the user sees the rejection reason",
        (mine or {}).get("rejection_reason") == "Reference MVola introuvable.",
        str(mine),
    )

    status, retry = call_fn("mvola-payments", {"action": "start", "ticket_id": ticket_a_id}, token_a)
    retry_id = (retry or {}).get("payment", {}).get("id")
    check("a rejected payment allows a fresh start", status == 200 and retry_id != payment_id, f"{status} {retry}")

    status, resubmitted = call_fn("mvola-payments", {
        "action": "submit", "payment_id": retry_id, "transaction_reference": "MV-987654321",
    }, token_a)
    check("the resubmission is accepted", status == 200, f"{status} {resubmitted}")

    status, approved = call_fn("admin-actions", {
        "action": "mvola_decision", "payment_id": retry_id, "decision": "approved",
    }, admin_token)
    check("the admin approves", status == 200, f"{status} {approved}")
    check(
        "the approval is recorded",
        (approved or {}).get("payment", {}).get("status") == "approved",
        str(approved),
    )

    status, decided = call_fn("admin-actions", {
        "action": "mvola_decision", "payment_id": retry_id, "decision": "rejected", "reason": "too late",
    }, admin_token)
    check("an already decided payment cannot be decided again", status == 409, f"{status} {decided}")

    status, blocked = call_fn("mvola-payments", {"action": "start", "ticket_id": ticket_a_id}, token_a)
    check(
        "an approved ticket returns the approved payment, not a new one",
        (blocked or {}).get("payment", {}).get("id") == retry_id,
        str(blocked),
    )

    print("\n== 16. Cleanup ==")
    for uid in (user_a, user_b, admin_probe):
        admin_api(f"/auth/v1/admin/users/{uid}", "DELETE")
    print("  removed the throwaway users")

    print(f"\n{'=' * 46}")
    print(f"PASSED {len(PASSED)}   FAILED {len(FAILED)}")
    if FAILED:
        for name in FAILED:
            print(f"  FAILED: {name}")
        sys.exit(1)
    print("MVOLA E2E PASSED")
    print("=" * 46)


if __name__ == "__main__":
    main()
