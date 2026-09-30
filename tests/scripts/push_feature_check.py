#!/usr/bin/env python3
"""Feature check for the Android push pipeline on the deployed project.

This exercises the real, deployed behaviour - not a mock - with the cloud
credentials in `.env`:

  1. the `device_tokens` table, its RLS policies and the `register_device_token`
     helper are present;
  2. a signed-in user (a real GoTrue session) can register a device token and
     reads back only its own row;
  3. a second user cannot see the first user's token;
  4. `notifications` and `kyc_requests` are members of the realtime publication;
  5. the deployed `email-webhook` refuses an unsigned request (the boundary the
     push path sits behind).

It provisions and deletes its own throwaway users, so it is safe to re-run.
The FCM send itself needs a Firebase service account and a real device, which
this environment does not have; that path is reported as NOT TESTED here.

Usage: python3 tests/scripts/push_feature_check.py
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROJECT = "hbvjpawnszzcbcjmbkuf"
ENV_FILE = Path("/workspace/project/.env")


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def request(url, token, *, method="GET", payload=None, headers=None, timeout=120):
    data = None
    hdrs = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode()
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def admin_sql(token: str, sql: str):
    return request(
        f"https://api.supabase.com/v1/projects/{PROJECT}/database/query",
        token,
        method="POST",
        payload={"query": sql},
    )


def auth_signup(url: str, anon: str, email: str, password: str):
    return request(
        f"{url}/auth/v1/signup",
        anon,
        method="POST",
        payload={"email": email, "password": password},
        headers={"apikey": anon},
    )


def make_admin_user(service_key: str, url: str, email: str) -> str:
    """Creates a confirmed user through the GoTrue admin API and returns its id."""
    status, body = request(
        f"{url}/auth/v1/admin/users",
        service_key,
        method="POST",
        payload={"email": email, "password": "feature-pass-123", "email_confirm": True},
        headers={"apikey": service_key},
    )
    if status >= 400:
        raise RuntimeError(f"could not create {email}: {status} {body[:300]}")
    return json.loads(body)["id"]


def sign_in(url: str, anon: str, email: str, password: str) -> str | None:
    status, body = request(
        f"{url}/auth/v1/token?grant_type=password",
        anon,
        method="POST",
        payload={"email": email, "password": password},
        headers={"apikey": anon},
    )
    if status >= 400:
        print(f"  sign-in for {email} failed: {status} {body[:200]}")
        return None
    return json.loads(body).get("access_token")


def cleanup(token: str, uids: list[str]):
    if not uids:
        return
    ids = ",".join(f"'{u}'" for u in uids)
    admin_sql(token, f"delete from auth.users where id in ({ids});")


def rest(url: str, anon: str, access: str, path: str, *, method="GET", payload=None):
    return request(
        f"{url}/rest/v1/{path}",
        access,
        method=method,
        payload=payload,
        headers={
            "apikey": anon,
            "Authorization": f"Bearer {access}",
            "Prefer": "return=representation,resolution=merge-duplicates",
        },
    )


def main() -> int:
    env = load_env()
    token = env["SUPABASE_ACCESS_TOKEN"]
    url = env["SUPABASE_URL"]
    anon = env["SUPABASE_ANON_KEY"]
    failures: list[str] = []
    uids: list[str] = []

    try:
        # 1. Schema artifacts.
        status, body = admin_sql(
            token,
            "select to_regclass('public.device_tokens') is not null as t,"
            " to_regprocedure('public.register_device_token(text,text)') is not null as f,"
            " (select count(*) from pg_policies where tablename='device_tokens') as policies;",
        )
        row = json.loads(body)[0] if status < 400 else {}
        checks = [
            ("device_tokens table exists", row.get("t") is True),
            ("register_device_token exists", row.get("f") is True),
            ("device_tokens has RLS policies", (row.get("policies") or 0) >= 4),
        ]

        status, body = admin_sql(
            token,
            "select tablename from pg_publication_tables"
            " where pubname='supabase_realtime'"
            " and tablename in ('notifications','kyc_requests') order by 1;",
        )
        tables = {r["tablename"] for r in json.loads(body)} if status < 400 else set()
        checks.append(("notifications published for realtime", "notifications" in tables))
        checks.append(("kyc_requests published for realtime", "kyc_requests" in tables))

        # 2. Real sessions register and isolate tokens.
        email_a = f"push-feature-a-{__import__('uuid').uuid4().hex[:8]}@example.com"
        email_b = f"push-feature-b-{__import__('uuid').uuid4().hex[:8]}@example.com"
        uids.append(make_admin_user(token, email_a))
        uids.append(make_admin_user(token, email_b))
        access_a = sign_in(url, anon, email_a, "feature-pass-123")
        access_b = sign_in(url, anon, email_b, "feature-pass-123")
        checks.append(("user A gets a real session", access_a is not None))
        checks.append(("user B gets a real session", access_b is not None))

        if access_a and access_b:
            token_a = "feature-token-a-" + "0" * 20
            token_b = "feature-token-b-" + "0" * 20

            st, bd = rest(url, anon, access_a, "rpc/register_device_token",
                          method="POST", payload={"p_token": token_a, "p_platform": "android"})
            checks.append(("A registers its token", st in (200, 204)))
            if st not in (200, 204):
                print("   register A:", st, bd[:200])

            rest(url, anon, access_b, "rpc/register_device_token",
                 method="POST", payload={"p_token": token_b, "p_platform": "android"})

            st, bd = rest(url, anon, access_a, "device_tokens?select=token")
            seen = {r["token"] for r in json.loads(bd)} if st < 400 else set()
            checks.append(("A reads its own token", token_a in seen))
            checks.append(("A cannot see B's token", token_b not in seen))
            if st >= 400:
                print("   read A:", st, bd[:200])

            # Re-registering is idempotent.
            rest(url, anon, access_a, "rpc/register_device_token",
                 method="POST", payload={"p_token": token_a, "p_platform": "android"})
            st, bd = admin_sql(
                token,
                f"select count(*) as n from public.device_tokens where token='{token_a}';",
            )
            n = json.loads(bd)[0]["n"] if st < 400 else -1
            checks.append(("re-registering does not duplicate", n == 1))

            # Unregister removes the token.
            st, _ = rest(url, anon, access_a, f"device_tokens?token=eq.{token_a}", method="DELETE")
            st2, bd2 = admin_sql(
                token,
                f"select count(*) as n from public.device_tokens where token='{token_a}';",
            )
            n2 = json.loads(bd2)[0]["n"] if st2 < 400 else -1
            checks.append(("unregister deletes the token", n2 == 0))

        # 3. The deployed webhook still enforces its signature boundary.
        st, bd = request(
            f"{url}/functions/v1/email-webhook",
            anon,
            method="POST",
            payload={"type": "email.received", "data": {"email_id": "x"}},
            headers={"apikey": anon},
        )
        checks.append(("webhook rejects an unsigned request", st == 400))

        print("\nFeature check results")
        print("=" * 60)
        for name, ok in checks:
            print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
            if not ok:
                failures.append(name)

        print("\n  [NOT TESTED] end-to-end FCM delivery to a real device: needs a")
        print("               Firebase service account and a physical device.")

        print("=" * 60)
        if failures:
            print(f"{len(failures)} FAILED")
            return 1
        print("ALL PUSH FEATURE CHECKS PASSED")
        return 0
    finally:
        cleanup(token, uids)


if __name__ == "__main__":
    sys.exit(main())
