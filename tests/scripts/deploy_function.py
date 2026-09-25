#!/usr/bin/env python3
"""Deploys an Edge Function to the cloud project via the Management API.

The Supabase CLI is not installed in this sandbox. The Management API accepts a
multipart upload of the function's entrypoint plus its imports, which is enough
for these functions because they import from `_shared/` and from jsr/npm
specifiers resolved at deploy time.

Usage: python3 tests/scripts/deploy_function.py <slug> [--no-verify-jwt]
"""
import json
import mimetypes
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

PROJECT = "hbvjpawnszzcbcjmbkuf"
FUNCTIONS_DIR = Path("/workspace/project/supabase/functions")
ENV_FILE = Path("/workspace/project/.env")


def load_env():
    env = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def collect_files(slug):
    """Entrypoint plus every file under _shared/ that it may import.

    The function's imports are written as `../_shared/<module>.ts`, so the
    uploaded tree has to keep that shape: the entrypoint goes in as
    `<slug>/index.ts` and the shared modules as `_shared/<module>.ts`.
    """
    files = [("file", FUNCTIONS_DIR / slug / "index.ts", f"{slug}/index.ts")]

    for shared in sorted((FUNCTIONS_DIR / "_shared").glob("*.ts")):
        files.append(("file", shared, f"_shared/{shared.name}"))

    return files


def build_multipart(slug, files, metadata):
    boundary = "----" + uuid.uuid4().hex
    body = bytearray()

    def add_field(name, value):
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(f"{value}\r\n".encode())

    add_field("metadata", json.dumps(metadata))

    for field, path, rel in files:
        ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(
            f'Content-Disposition: form-data; name="{field}"; filename="{rel}"\r\n'.encode()
        )
        body.extend(f"Content-Type: {ctype}\r\n\r\n".encode())
        body.extend(path.read_bytes())
        body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode())
    return boundary, bytes(body)


def main():
    if len(sys.argv) < 2:
        print("usage: deploy_function.py <slug> [--no-verify-jwt]")
        sys.exit(2)

    slug = sys.argv[1]
    verify_jwt = "--no-verify-jwt" not in sys.argv[2:]
    token = load_env()["SUPABASE_ACCESS_TOKEN"]

    files = collect_files(slug)
    metadata = {
        "name": slug,
        "verify_jwt": verify_jwt,
        # The API unpacks the upload under `source/`, so the entrypoint path is
        # the uploaded relative path, not a bare `index.ts`.
        "entrypoint_path": f"{slug}/index.ts",
    }
    boundary, body = build_multipart(slug, files, metadata)

    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{PROJECT}/functions/deploy?slug={slug}",
        data=body,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            print("HTTP", resp.status)
            print(resp.read().decode()[:800])
    except urllib.error.HTTPError as e:
        print("HTTP", e.code)
        print(e.read().decode()[:1500])
        sys.exit(1)


if __name__ == "__main__":
    main()
