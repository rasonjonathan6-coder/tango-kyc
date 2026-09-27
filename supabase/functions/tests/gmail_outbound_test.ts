/**
 * Unit tests for the Gmail API outbound transport.
 *
 * The live send is never exercised: OAuth and the send endpoint are both
 * stubbed through an injected `fetch`, so the MIME shape, encoding, retry
 * handling, and failure mapping are verified without touching the network and
 * without any credential ever leaving a test-local literal.
 */
import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  base64UrlEncode,
  buildMimeMessage,
  describeGoogleFailure,
  encodeDisplayName,
  encodeHeaderValue,
  filterHeaders,
  GMAIL_SEND_ENDPOINT,
  GMAIL_TOKEN_ENDPOINT,
  GmailCredentials,
  gmailCredentialsFromEnv,
  gmailConfigured,
  normalizeMessageId,
  resetGmailTokenCache,
  sendGmailMessage,
  toRecipients,
} from "../_shared/gmail-outbound.ts";
import { AppError } from "../_shared/http.ts";

const CREDS: GmailCredentials = {
  clientId: "test-client-id.apps.googleusercontent.com",
  clientSecret: "test-client-secret",
  refreshToken: "test-refresh-token",
  fromEmail: "customerservicefor032@gmail.com",
  senderName: "Tango KYC",
};

const BASE_ARGS = {
  to: "kyc-test-recipient@example.com",
  subject: "Manual KYC Verification request",
  text: "hello",
};

/** Reverses base64url so a built message can be inspected. */
function decodeBase64Url(value: string): string {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const withPadding = padded + "=".repeat((4 - (padded.length % 4)) % 4);
  return new TextDecoder().decode(
    Uint8Array.from(atob(withPadding), (c) => c.charCodeAt(0)),
  );
}

/** Decodes a quoted-printable-free base64 body block. */
function decodeBase64Body(value: string): string {
  return new TextDecoder().decode(
    Uint8Array.from(atob(value.replace(/\s+/g, "")), (c) => c.charCodeAt(0)),
  );
}

interface StubCall {
  url: string;
  init?: RequestInit;
}

interface StubPlan {
  token?: () => Response | Promise<Response>;
  send?: (call: StubCall, index: number) => Response | Promise<Response>;
  messageMetadata?: () => Response | Promise<Response>;
}

function withFetchStub(
  plan: StubPlan,
  run: (calls: StubCall[]) => Promise<void>,
  ctx: Deno.TestContext,
): Promise<void> {
  const original = globalThis.fetch;
  const calls: StubCall[] = [];
  let sendCount = 0;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (url === GMAIL_TOKEN_ENDPOINT) {
      calls.push({ url, init });
      return Promise.resolve(
        plan.token?.() ?? new Response(JSON.stringify({ access_token: "at-1", expires_in: 3600 }), { status: 200 }),
      );
    }
    if (url === GMAIL_SEND_ENDPOINT) {
      calls.push({ url, init });
      const index = sendCount++;
      return Promise.resolve(
        plan.send?.({ url, init }, index) ??
          new Response(JSON.stringify({ id: `gmail-${index}` }), { status: 200 }),
      );
    }
    calls.push({ url, init });
    return Promise.resolve(
      plan.messageMetadata?.() ??
        new Response(
          JSON.stringify({ payload: { headers: [{ name: "Message-ID", value: "<confirmed@google>" }] } }),
          { status: 200 },
        ),
    );
  }) as typeof fetch;

  resetGmailTokenCache();
  return run(calls).finally(() => {
    globalThis.fetch = original;
    resetGmailTokenCache();
    ctx;
  });
}

// --- 1. MIME construction ------------------------------------------------

Deno.test("buildMimeMessage emits the required headers and both bodies", () => {
  const mime = buildMimeMessage({
    from: CREDS.fromEmail,
    senderName: CREDS.senderName,
    to: ["kyc-test-recipient@example.com"],
    subject: "Hello",
    text: "plain body",
    html: "<p>html body</p>",
    replyTo: "reply+abc@inbound.example.com",
    messageId: "<tng-1@tango-kyc.local>",
    boundary: "BND",
  });

  assertStringIncludes(mime, "From: Tango KYC <customerservicefor032@gmail.com>");
  assertStringIncludes(mime, "To: kyc-test-recipient@example.com");
  assertStringIncludes(mime, "Reply-To: reply+abc@inbound.example.com");
  assertStringIncludes(mime, "Subject: Hello");
  assertStringIncludes(mime, "Message-ID: <tng-1@tango-kyc.local>");
  assertStringIncludes(mime, "MIME-Version: 1.0");
  assertStringIncludes(mime, 'Content-Type: multipart/alternative; boundary="BND"');
  assertStringIncludes(mime, "Content-Type: text/plain");
  assertStringIncludes(mime, "Content-Type: text/html");
  assertStringIncludes(mime, "--BND--");

  const plainBlock = mime.split("--BND")[1];
  const htmlBlock = mime.split("--BND")[2];
  assertStringIncludes(decodeBase64Body(plainBlock.split("\r\n\r\n")[1]), "plain body");
  assertStringIncludes(decodeBase64Body(htmlBlock.split("\r\n\r\n")[1]), "<p>html body</p>");
});

Deno.test("buildMimeMessage falls back to text/plain when there is no html", () => {
  const mime = buildMimeMessage({
    from: CREDS.fromEmail,
    senderName: CREDS.senderName,
    to: ["a@example.com"],
    subject: "Hi",
    text: "only text",
    messageId: "<tng-2@tango-kyc.local>",
  });
  assertStringIncludes(mime, "Content-Type: text/plain");
  assert(!mime.includes("multipart/alternative"), "no multipart when html is absent");
});

Deno.test("buildMimeMessage omits Reply-To when not provided", () => {
  const mime = buildMimeMessage({
    from: CREDS.fromEmail,
    senderName: CREDS.senderName,
    to: ["a@example.com"],
    subject: "Hi",
    text: "x",
    messageId: "<tng-3@tango-kyc.local>",
  });
  assert(!mime.includes("Reply-To:"), "Reply-To must be absent when unset");
});

// --- 2. base64url --------------------------------------------------------

Deno.test("base64UrlEncode produces unpadded url-safe output", () => {
  const encoded = base64UrlEncode("hello world");
  assertEquals(encoded, "aGVsbG8gd29ybGQ");
  assert(!encoded.includes("+") && !encoded.includes("/") && !encoded.includes("="));
});

Deno.test("base64UrlEncode round-trips UTF-8 content", () => {
  const source = "Sécurité · Tango KYC — 8 chiffres";
  assertEquals(decodeBase64Url(base64UrlEncode(source)), source);
});

// --- 3. Subject UTF-8 ----------------------------------------------------

Deno.test("encodeHeaderValue leaves ASCII untouched", () => {
  assertEquals(encodeHeaderValue("Plain subject"), "Plain subject");
});

Deno.test("encodeHeaderValue encodes non-ASCII as RFC 2047", () => {
  const encoded = encodeHeaderValue("Votre code de sécurité · Tango KYC");
  assert(encoded.startsWith("=?UTF-8?B?"), "must use UTF-8 encoded word");
  assert(encoded.endsWith("?="));
  const inner = encoded.slice("=?UTF-8?B?".length, -2);
  assertEquals(decodeBase64Body(inner), "Votre code de sécurité · Tango KYC");
});

Deno.test("encodeHeaderValue strips CR/LF header injection", () => {
  assertEquals(encodeHeaderValue("a\r\nBcc: victim@example.com"), "a Bcc: victim@example.com");
});

Deno.test("encodeDisplayName quotes or encodes as needed", () => {
  assertEquals(encodeDisplayName("Tango KYC"), "Tango KYC");
  assert(encodeDisplayName("Tango KYC · Support").startsWith("=?UTF-8?B?"));
});

// --- 4. Reply-To ---------------------------------------------------------

Deno.test("sendGmailMessage transmits the Reply-To header in the MIME", async (ctx) => {
  await withFetchStub(
    {},
    async (calls) => {
      await sendGmailMessage(
        { ...BASE_ARGS, replyTo: "reply+0123456789abcdef0123456789abcdef@inbound.example.com" },
        CREDS,
        { boundary: "BND", verifyMessageId: false },
      );
      const sendCall = calls.find((c) => c.url === GMAIL_SEND_ENDPOINT)!;
      const raw = JSON.parse(String(sendCall.init?.body)).raw as string;
      assertStringIncludes(
        decodeBase64Url(raw),
        "Reply-To: reply+0123456789abcdef0123456789abcdef@inbound.example.com",
      );
    },
    ctx,
  );
});

// --- 5. Message-ID -------------------------------------------------------

Deno.test("sendGmailMessage returns the locally generated RFC Message-ID by default", async (ctx) => {
  await withFetchStub(
    { messageMetadata: () => new Response(JSON.stringify({}), { status: 200 }) },
    async () => {
      const result = await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND" });
      assert(/^<tng-[0-9a-f-]{36}@tango-kyc\.local>$/.test(result.id), `unexpected id: ${result.id}`);
    },
    ctx,
  );
});

Deno.test("sendGmailMessage prefers the Message-ID confirmed by Gmail", async (ctx) => {
  await withFetchStub(
    {
      messageMetadata: () =>
        new Response(
          JSON.stringify({ payload: { headers: [{ name: "Message-ID", value: "real-id@mail.gmail.com" }] } }),
          { status: 200 },
        ),
    },
    async () => {
      const result = await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND" });
      assertEquals(result.id, "<real-id@mail.gmail.com>");
    },
    ctx,
  );
});

Deno.test("normalizeMessageId brackets bare ids and keeps bracketed ones", () => {
  assertEquals(normalizeMessageId("abc@d.com"), "<abc@d.com>");
  assertEquals(normalizeMessageId("<abc@d.com>"), "<abc@d.com>");
  assertEquals(normalizeMessageId("  "), null);
  assertEquals(normalizeMessageId(undefined), null);
});

// --- 6. OAuth token exchange (mocked) -----------------------------------

Deno.test("sendGmailMessage exchanges the refresh token for an access token", async (ctx) => {
  await withFetchStub(
    {},
    async (calls) => {
      await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false });
      const tokenCall = calls.find((c) => c.url === GMAIL_TOKEN_ENDPOINT)!;
      assert(tokenCall, "the token endpoint must be called");
      assertEquals(tokenCall.init?.method, "POST");
      const body = new URLSearchParams(String(tokenCall.init?.body));
      assertEquals(body.get("grant_type"), "refresh_token");
      assertEquals(body.get("client_id"), CREDS.clientId);
      assertEquals(body.get("refresh_token"), CREDS.refreshToken);
    },
    ctx,
  );
});

Deno.test("the access token is cached across sends", async (ctx) => {
  await withFetchStub(
    {},
    async (calls) => {
      await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false });
      await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false });
      assertEquals(calls.filter((c) => c.url === GMAIL_TOKEN_ENDPOINT).length, 1);
    },
    ctx,
  );
});

// --- 7. Gmail send (mocked) ---------------------------------------------

Deno.test("sendGmailMessage posts { raw } to the messages.send endpoint", async (ctx) => {
  await withFetchStub(
    {},
    async (calls) => {
      await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false });
      const sendCall = calls.find((c) => c.url === GMAIL_SEND_ENDPOINT)!;
      assertEquals(sendCall.init?.method, "POST");
      const body = JSON.parse(String(sendCall.init?.body));
      assertEquals(Object.keys(body), ["raw"]);
      const decoded = decodeBase64Url(body.raw);
      assertStringIncludes(decoded, "From: Tango KYC <customerservicefor032@gmail.com>");
      assertStringIncludes(decoded, "Subject: Manual KYC Verification request");
    },
    ctx,
  );
});

Deno.test("sendGmailMessage never puts credentials in the URL", async (ctx) => {
  await withFetchStub(
    {},
    async (calls) => {
      await sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false });
      for (const call of calls) {
        assert(!String(call.url).includes(CREDS.clientSecret));
        assert(!String(call.url).includes(CREDS.refreshToken));
        assert(!String(call.url).includes("at-1"));
      }
    },
    ctx,
  );
});

// --- 8. HTTP errors ------------------------------------------------------

Deno.test("sendGmailMessage reports a refused message as 502 without leaking secrets", async (ctx) => {
  await withFetchStub(
    {
      send: () =>
        new Response(JSON.stringify({ error: { status: "PERMISSION_DENIED", message: "no send scope" } }), {
          status: 403,
        }),
    },
    async () => {
      const error = await assertRejects(() =>
        sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false })
      );
      assert(error instanceof AppError);
      assertEquals((error as AppError).status, 502);
      assert(!String(String((error as AppError).message)).includes(CREDS.refreshToken));
      assert(!String(String((error as AppError).message)).includes(CREDS.clientSecret));
    },
    ctx,
  );
});

Deno.test("sendGmailMessage maps an invalid_grant token failure to 503", async (ctx) => {
  await withFetchStub(
    { token: () => new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }) },
    async () => {
      const error = await assertRejects(() =>
        sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false })
      );
      assert(error instanceof AppError);
      assertEquals((error as AppError).status, 503);
    },
    ctx,
  );
});

// --- 9. 429 / retry ------------------------------------------------------

Deno.test("sendGmailMessage retries a 429 then succeeds", async (ctx) => {
  await withFetchStub(
    {
      send: (_call, index) =>
        index === 0
          ? new Response(JSON.stringify({ error: { message: "rate limit" } }), { status: 429 })
          : new Response(JSON.stringify({ id: "ok-after-retry" }), { status: 200 }),
    },
    async () => {
      const result = await sendGmailMessage(BASE_ARGS, CREDS, {
        boundary: "BND",
        verifyMessageId: false,
        sleep: () => Promise.resolve(),
      });
      assert(result.id.length > 0);
    },
    ctx,
  );
});

Deno.test("sendGmailMessage refreshes the access token once after a 401", async (ctx) => {
  let tokenCalls = 0;
  await withFetchStub(
    {
      token: () => {
        tokenCalls++;
        return new Response(JSON.stringify({ access_token: `at-${tokenCalls}`, expires_in: 3600 }), {
          status: 200,
        });
      },
      send: (_call, index) =>
        index === 0
          ? new Response(JSON.stringify({ error: { message: "expired" } }), { status: 401 })
          : new Response(JSON.stringify({ id: "sent" }), { status: 200 }),
    },
    async () => {
      await sendGmailMessage(BASE_ARGS, CREDS, {
        boundary: "BND",
        verifyMessageId: false,
        sleep: () => Promise.resolve(),
      });
      assert(tokenCalls >= 2, "a second token must be fetched after the 401");
    },
    ctx,
  );
});

Deno.test("sendGmailMessage stops after the attempt budget is exhausted", async (ctx) => {
  let sends = 0;
  await withFetchStub(
    {
      send: () => {
        sends++;
        return new Response(JSON.stringify({ error: { message: "busy" } }), { status: 503 });
      },
    },
    async () => {
      const error = await assertRejects(() =>
        sendGmailMessage(BASE_ARGS, CREDS, {
          boundary: "BND",
          verifyMessageId: false,
          sleep: () => Promise.resolve(),
        })
      );
      assertEquals((error as AppError).status, 502);
      assertEquals(sends, 3, "attempts must be bounded");
    },
    ctx,
  );
});

Deno.test("sendGmailMessage reports an unreachable provider as 502", async (ctx) => {
  const original = globalThis.fetch;
  globalThis.fetch = (() => {
    throw new TypeError("network down");
  }) as typeof fetch;
  resetGmailTokenCache();
  try {
    const error = await assertRejects(() =>
      sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false, sleep: () => Promise.resolve() })
    );
    assertEquals((error as AppError).status, 502);
  } finally {
    globalThis.fetch = original;
    resetGmailTokenCache();
    ctx;
  }
});

// --- 10. Missing secret --------------------------------------------------

Deno.test("sendGmailMessage refuses to run without complete credentials", async () => {
  const error = await assertRejects(() =>
    sendGmailMessage(BASE_ARGS, { ...CREDS, refreshToken: "" }, {
      boundary: "BND",
      verifyMessageId: false,
      fetchImpl: (() => {
        throw new Error("must not be called");
      }) as typeof fetch,
    })
  );
  assert(error instanceof AppError);
  assertEquals((error as AppError).status, 503);
});

Deno.test("gmailCredentialsFromEnv reports missing configuration as null", () => {
  const before = ["GMAIL_CLIENT_ID", "GMAIL_CLIENT_SECRET", "GMAIL_REFRESH_TOKEN", "GMAIL_FROM_EMAIL"]
    .map((k) => [k, Deno.env.get(k)] as const);
  for (const [key] of before) Deno.env.delete(key);
  try {
    assertEquals(gmailCredentialsFromEnv(), null);
    assertEquals(gmailConfigured(), false);
  } finally {
    for (const [key, value] of before) if (value !== undefined) Deno.env.set(key, value);
  }
});

// --- 11. Invalid Gmail response -----------------------------------------

Deno.test("sendGmailMessage rejects a success response with no id", async (ctx) => {
  await withFetchStub(
    { send: () => new Response(JSON.stringify({}), { status: 200 }) },
    async () => {
      const error = await assertRejects(() =>
        sendGmailMessage(BASE_ARGS, CREDS, { boundary: "BND", verifyMessageId: false })
      );
      assertEquals((error as AppError).status, 502);
    },
    ctx,
  );
});

Deno.test("sendGmailMessage tolerates a non-JSON error body", async (ctx) => {
  await withFetchStub(
    { send: () => new Response("<html>gateway error</html>", { status: 502 }) },
    async () => {
      const error = await assertRejects(() =>
        sendGmailMessage(BASE_ARGS, CREDS, {
          boundary: "BND",
          verifyMessageId: false,
          sleep: () => Promise.resolve(),
        })
      );
      assertEquals((error as AppError).status, 502);
    },
    ctx,
  );
});

Deno.test("describeGoogleFailure surfaces the provider message only", () => {
  const described = describeGoogleFailure(
    { error: { status: "INVALID_ARGUMENT", message: "Invalid To header" } },
    "",
  );
  assertStringIncludes(described, "INVALID_ARGUMENT");
  assertStringIncludes(described, "Invalid To header");
  assertEquals(describeGoogleFailure(null, ""), "no response body");
});

// --- 12. Idempotence helpers --------------------------------------------

Deno.test("filterHeaders drops transport-reserved headers", () => {
  const kept = filterHeaders({
    "X-Ticket-Code": "TNG-KYC-1234",
    "Message-ID": "<forged@example.com>",
    From: "attacker@example.com",
  });
  assertEquals(kept, { "X-Ticket-Code": "TNG-KYC-1234" });
});

Deno.test("toRecipients flattens arrays, commas, and blanks", () => {
  assertEquals(toRecipients("a@example.com, b@example.com"), ["a@example.com", "b@example.com"]);
  assertEquals(toRecipients(["a@example.com", "", "  "]), ["a@example.com"]);
  assertEquals(toRecipients(""), []);
});
