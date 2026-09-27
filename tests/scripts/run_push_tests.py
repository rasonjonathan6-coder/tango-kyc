#!/usr/bin/env python3
"""Runs tests/db/push_tokens_tests.sql against the cloud project.

Companion to run_db_tests.py, kept separate because the push/realtime suite
depends on migration 20260928000600_push_tokens_and_realtime.sql. Once that
migration is deployed, both runners are valid; until then the main suite stays
green and only the push migration is missing.

The suite wraps everything in begin/rollback itself, so the database is left
untouched. The Management API SQL endpoint rejects psql meta-commands, so those
lines are stripped.
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
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    env = load_env()
    sql = open("/workspace/project/tests/db/push_tokens_tests.sql").read()
    sql = "\n".join(line for line in sql.splitlines() if not re.match(r"^\s*\\", line))

    status, body = run_sql(sql, env["SUPABASE_ACCESS_TOKEN"])

    if status >= 400:
        print(f"HTTP {status}")
        try:
            print(json.loads(body).get("message", body)[:3000])
        except Exception:
            print(body[:3000])
        sys.exit(1)

    ok_calls = len(re.findall(r"test_harness\.ok\(", sql))
    raises_calls = len(re.findall(r"test_harness\.raises\(", sql))
    print(f"HTTP {status} - suite completed with no exception (no failing assertion)")
    print(f"Assertions in source: {ok_calls} ok() + {raises_calls} raises() = {ok_calls + raises_calls}")
    print("\nALL PUSH/REALTIME TESTS PASSED")
    sys.exit(0)


if __name__ == "__main__":
    main()
