/**
 * Unit tests for Svix webhook signature verification.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/svix_test.ts
 *
 * These tests sign payloads with a real HMAC and assert that verification
 * accepts genuine signatures and rejects tampering, replays and missing headers.
 */
import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.6";
import { verifySvixSignature } from "../_shared/svix.ts";

/** Mirrors the Svix scheme so tests do not depend on network access. */
async function sign(secret: string, id: string, timestamp: string, body: string): Promise<string> {
  const raw = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  const keyBytes = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(`${id}.${timestamp}.${body}`) as BufferSource,
    ),
  );
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return `v1,${btoa(binary)}`;
}

const SECRET = `whsec_${btoa("test-signing-secret-value-32bytes")}`;
const BODY = JSON.stringify({ type: "email.received", data: { email_id: "abc" } });

Deno.test("accepts a correctly signed payload", async () => {
  const now = Math.floor(Date.now() / 1000);
  const ts = String(now);
  const ok = await verifySvixSignature({
    rawBody: BODY,
    svixId: "msg_1",
    svixTimestamp: ts,
    svixSignature: await sign(SECRET, "msg_1", ts, BODY),
    secret: SECRET,
    now,
  });
  assertEquals(ok, true);
});

Deno.test("accepts the signature when it is one of several entries", async () => {
  const now = Math.floor(Date.now() / 1000);
  const ts = String(now);
  const valid = await sign(SECRET, "msg_2", ts, BODY);
  const ok = await verifySvixSignature({
    rawBody: BODY,
    svixId: "msg_2",
    svixTimestamp: ts,
    svixSignature: `v1,deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefde ${valid}`,
    secret: SECRET,
    now,
  });
  assertEquals(ok, true);
});

Deno.test("rejects a tampered body", async () => {
  const now = Math.floor(Date.now() / 1000);
  const ts = String(now);
  const signature = await sign(SECRET, "msg_3", ts, BODY);
  await assertRejects(() =>
    verifySvixSignature({
      rawBody: JSON.stringify({ type: "email.received", data: { email_id: "evil" } }),
      svixId: "msg_3",
      svixTimestamp: ts,
      svixSignature: signature,
      secret: SECRET,
      now,
    })
  );
});

Deno.test("rejects a wrong secret", async () => {
  const now = Math.floor(Date.now() / 1000);
  const ts = String(now);
  const signature = await sign(SECRET, "msg_4", ts, BODY);
  const other = `whsec_${btoa("a-completely-different-secret-32bytes")}`;
  await assertRejects(() =>
    verifySvixSignature({
      rawBody: BODY,
      svixId: "msg_4",
      svixTimestamp: ts,
      svixSignature: signature,
      secret: other,
      now,
    })
  );
});

Deno.test("rejects a replayed timestamp outside the tolerance window", async () => {
  const now = Math.floor(Date.now() / 1000);
  const stale = now - 3600;
  const signature = await sign(SECRET, "msg_5", String(stale), BODY);
  await assertRejects(() =>
    verifySvixSignature({
      rawBody: BODY,
      svixId: "msg_5",
      svixTimestamp: String(stale),
      svixSignature: signature,
      secret: SECRET,
      now,
    })
  );
});

Deno.test("rejects missing signature headers", async () => {
  const now = Math.floor(Date.now() / 1000);
  await assertRejects(() =>
    verifySvixSignature({
      rawBody: BODY,
      svixId: null,
      svixTimestamp: String(now),
      svixSignature: null,
      secret: SECRET,
      now,
    })
  );
});

Deno.test("refuses to trust a request when no secret is configured", async () => {
  const now = Math.floor(Date.now() / 1000);
  await assertRejects(() =>
    verifySvixSignature({
      rawBody: BODY,
      svixId: "msg_6",
      svixTimestamp: String(now),
      svixSignature: "v1,whatever",
      secret: "",
      now,
    })
  );
});
