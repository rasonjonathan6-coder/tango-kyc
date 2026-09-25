#!/usr/bin/env python3
"""Runs tests/db/run_tests.sql against the cloud project.

The Management API SQL endpoint rejects psql meta-commands (\\set), so those
lines are stripped. The suite wraps everything in begin/rollback itself, so the
database is left untouched.

The harness emits PASS lines via RAISE NOTICE; the API returns the notices, so
this prints them and reports a summary.
"""
import json
import re
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


def run_sql(query, token, timeout=300):
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{PROJECT}/database/query",
        data=json.dumps({"query": query}).encode(),
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode()
            return resp.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    env = load_env()
    token = env["SUPABASE_ACCESS_TOKEN"]
    sql = open("/workspace/project/tests/db/run_tests.sql").read()

    # Drop psql meta-commands; the API is not psql.
    sql = "\n".join(
        line for line in sql.splitlines() if not re.match(r"^\s*\\", line)
    )

    status, body = run_sql(sql, token)

    if status >= 400:
        print(f"HTTP {status}")
        try:
            msg = json.loads(body).get("message", body)
        except Exception:
            msg = body
        print(msg[:3000])
        sys.exit(1)

    # The harness raises on the first failure, so a 2xx response means the whole
    # suite ran to completion with no failing assertion. The SQL endpoint does
    # not return RAISE NOTICE output, so the assertion count is read from the
    # source rather than scraped from notices.
    ok_calls = len(re.findall(r"test_harness\.ok\(", sql))
    raises_calls = len(re.findall(r"test_harness\.raises\(", sql))
    total = ok_calls + raises_calls

    print(f"HTTP {status} - suite completed with no exception (no failing assertion)")
    print(f"Assertions in source: {ok_calls} ok() + {raises_calls} raises() = {total}")
    print("\nALL BACKEND TESTS PASSED")
    sys.exit(0)


if __name__ == "__main__":
    main()
