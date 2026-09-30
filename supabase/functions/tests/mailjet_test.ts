/**
 * Unit tests for the Mailjet outbound transport.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/mailjet_test.ts
 *
 * These tests never touch the network: `sendMailjetMessage` is exercised with a
 * stubbed `fetch`, so no credential and no real email is involved. The stubs
 * mirror the payload and response shapes documented at
 * https://dev.mailjet.com/docs/email-api/send-api-v31/send-basic-email
 */
import { assertEquals, assertStringIncludes, assertRejects } from "jsr:@std/assert@1.0.6";
import {
  basicAuthHeader,
  buildMailjetMessage,
  buildMailjetPayload,
  describeFailure,
  extractErrors,
  extractMessageId,
  filterHeaders,
  parseAddress,
  sendMailjetMessage,
  toRecipients,
} from "../_shared/mailjet.ts";

const CREDENTIALS = { apiKey: "test-api-key", secretKey: "test-secret-key" };

/** Captures the request a stubbed fetch received. */
interface Captured {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

/** Replaces globalThis.fetch for the duration of `fn`. */
async function withFetch(
  response: Response,
  fn: (captured: Captured) => Promise<void>,
): Promise<void> {
  const original = globalThis.fetch;
  let captured: Captured | null = null;

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    captured = {
      url: String(input),
      method: init?.method ?? "GET",
      headers: Object.fromEntries(headers.entries()),
      body: JSON.parse(String(init?.body ?? "{}")),
    };
    return Promise.resolve(response);
  }) as typeof fetch;

  try {
    await fn({
      get url() {
        return captured!.url;
      },
      get method() {
        return captured!.method;
      },
      get headers() {
        return captured!.headers;
      },
      get body() {
        return captured!.body;
      },
    });
  } finally {
    globalThis.fetch = original;
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// --- address parsing --------------------------------------------------------

Deno.test("parseAddress handles a display name", () => {
  assertEquals(parseAddress("Tango KYC <kyc@example.com>"), {
    Email: "kyc@example.com",
    Name: "Tango KYC",
  });
});

Deno.test("parseAddress handles a quoted display name", () => {
  assertEquals(parseAddress('"Tango, KYC" <kyc@example.com>'), {
    Email: "kyc@example.com",
    Name: "Tango, KYC",
  });
});

Deno.test("parseAddress handles a bare address", () => {
  assertEquals(parseAddress("  kyc@example.com  "), { Email: "kyc@example.com" });
});

Deno.test("toRecipients splits comma separated lists and drops blanks", () => {
  assertEquals(toRecipients("a@example.com, b@example.com, "), [
    { Email: "a@example.com" },
    { Email: "b@example.com" },
  ]);
});

Deno.test("toRecipients accepts an array", () => {
  assertEquals(toRecipients(["a@example.com", "b@example.com"]), [
    { Email: "a@example.com" },
    { Email: "b@example.com" },
  ]);
});

// --- payload construction ---------------------------------------------------

Deno.test("buildMailjetMessage maps the documented v3.1 fields", () => {
  const message = buildMailjetMessage({
    from: "Tango KYC <kyc@example.com>",
    to: "user@example.com",
    subject: "Manual KYC Verification request",
    text: "plain body",
    html: "<p>html body</p>",
    replyTo: "reply+abc@inbound.example.com",
  });

  assertEquals(message.From, { Email: "kyc@example.com", Name: "Tango KYC" });
  assertEquals(message.To, [{ Email: "user@example.com" }]);
  assertEquals(message.Subject, "Manual KYC Verification request");
  assertEquals(message.TextPart, "plain body");
  assertEquals(message.HTMLPart, "<p>html body</p>");
  assertEquals(message.ReplyTo, { Email: "reply+abc@inbound.example.com" });
});

Deno.test("buildMailjetMessage omits HTMLPart when there is no HTML", () => {
  const message = buildMailjetMessage({
    from: "kyc@example.com",
    to: "user@example.com",
    subject: "s",
    text: "t",
  });
  assertEquals("HTMLPart" in message, false);
});

Deno.test("buildMailjetMessage keeps the Reply-To pointing at the inbound address", () => {
  const message = buildMailjetMessage({
    from: "kyc@example.com",
    to: "admin@example.com",
    subject: "s",
    text: "t",
    replyTo: "reply+0123456789abcdef0123456789abcdef@inbound.example.com",
  });
  assertEquals(message.ReplyTo?.Email, "reply+0123456789abcdef0123456789abcdef@inbound.example.com");
});

Deno.test("buildMailjetMessage caps CustomID at 255 characters", () => {
  const message = buildMailjetMessage({
    from: "kyc@example.com",
    to: "user@example.com",
    subject: "s",
    text: "t",
    customId: "x".repeat(400),
  });
  assertEquals(message.CustomID?.length, 255);
});

Deno.test("buildMailjetPayload wraps exactly one message", () => {
  const payload = buildMailjetPayload({
    from: "kyc@example.com",
    to: "user@example.com",
    subject: "s",
    text: "t",
  });
  assertEquals(payload.Messages.length, 1);
});

// --- header filtering -------------------------------------------------------

Deno.test("filterHeaders drops headers Mailjet reserves for itself", () => {
  const kept = filterHeaders({
    "Message-Id": "<should-be-dropped@example.com>",
    Date: "Thu, 25 Sep 2026 10:00:00 +0000",
    From: "spoofed@example.com",
    "X-Ticket-Id": "TNG-KYC-8F42A91C",
  });
  assertEquals(kept, { "X-Ticket-Id": "TNG-KYC-8F42A91C" });
});

Deno.test("filterHeaders is case insensitive", () => {
  const kept = filterHeaders({ "message-id": "<x@example.com>", "X-Custom": "1" });
  assertEquals(kept, { "X-Custom": "1" });
});

Deno.test("filterHeaders returns undefined when nothing survives", () => {
  assertEquals(filterHeaders({ Subject: "nope" }), undefined);
  assertEquals(filterHeaders(undefined), undefined);
});

// --- credentials ------------------------------------------------------------

Deno.test("basicAuthHeader encodes the key pair as HTTP Basic", () => {
  assertEquals(basicAuthHeader("pub", "priv"), `Basic ${btoa("pub:priv")}`);
});

Deno.test("basicAuthHeader never exposes the raw secret in its output", () => {
  const header = basicAuthHeader("pub", "super-secret-value");
  assertEquals(header.includes("super-secret-value"), false);
});

// --- response parsing -------------------------------------------------------

Deno.test("extractMessageId prefers MessageUUID", () => {
  const response = {
    Messages: [{ Status: "success", To: [{ Email: "u@example.com", MessageUUID: "uuid-1", MessageID: 42 }] }],
  };
  assertEquals(extractMessageId(response), "uuid-1");
});

Deno.test("extractMessageId falls back to the numeric MessageID", () => {
  const response = { Messages: [{ Status: "success", To: [{ Email: "u@example.com", MessageID: 42 }] }] };
  assertEquals(extractMessageId(response), "42");
});

Deno.test("extractMessageId returns null for an error response", () => {
  const response = { Messages: [{ Status: "error", Errors: [{ ErrorCode: "send-0003" }] }] };
  assertEquals(extractMessageId(response), null);
});

Deno.test("extractErrors reads the documented per-message error shape", () => {
  const response = {
    Messages: [{
      Status: "error",
      Errors: [{ ErrorCode: "mj-0005", StatusCode: 400, ErrorMessage: "The To is mandatory but missing from the input" }],
    }],
  };
  assertEquals(extractErrors(response), ["mj-0005: The To is mandatory but missing from the input"]);
});

Deno.test("extractErrors is empty for a successful response", () => {
  assertEquals(extractErrors({ Messages: [{ Status: "success" }] }), []);
});

Deno.test("extractErrors flags an error message with no detail", () => {
  assertEquals(extractErrors({ Messages: [{ Status: "error" }] }), ["unspecified Mailjet error"]);
});

// --- sending ----------------------------------------------------------------

Deno.test("sendMailjetMessage posts to the v3.1 endpoint with Basic auth", async () => {
  const response = jsonResponse({ Messages: [{ Status: "success", To: [{ MessageUUID: "uuid-9" }] }] });

  await withFetch(response, async (captured) => {
    const result = await sendMailjetMessage(
      { from: "kyc@example.com", to: "user@example.com", subject: "s", text: "t" },
      CREDENTIALS,
    );

    assertEquals(captured.url, "https://api.mailjet.com/v3.1/send");
    assertEquals(captured.method, "POST");
    // `Headers` lower-cases keys, so the captured map is lower-case too.
    assertEquals(captured.headers["authorization"], basicAuthHeader(CREDENTIALS.apiKey, CREDENTIALS.secretKey));
    assertEquals(captured.headers["content-type"], "application/json");
    assertEquals(result.id, "uuid-9");
  });
});

Deno.test("sendMailjetMessage returns the message id used for reply threading", async () => {
  const response = jsonResponse({ Messages: [{ Status: "success", To: [{ MessageUUID: "thread-abc" }] }] });

  await withFetch(response, async () => {
    const result = await sendMailjetMessage(
      { from: "kyc@example.com", to: "user@example.com", subject: "s", text: "t" },
      CREDENTIALS,
    );
    assertEquals(result.id, "thread-abc");
  });
});

Deno.test("sendMailjetMessage forwards the Reply-To to the inbound address", async () => {
  const response = jsonResponse({ Messages: [{ Status: "success", To: [{ MessageUUID: "u" }] }] });

  await withFetch(response, async (captured) => {
    await sendMailjetMessage(
      {
        from: "kyc@example.com",
        to: "admin@example.com",
        subject: "s",
        text: "t",
        replyTo: "reply+token@inbound.example.com",
      },
      CREDENTIALS,
    );
    const messages = captured.body.Messages as Array<Record<string, unknown>>;
    assertEquals(messages[0].ReplyTo, { Email: "reply+token@inbound.example.com" });
  });
});

Deno.test("sendMailjetMessage rejects when Mailjet answers HTTP 200 with Status error", async () => {
  // The critical case: Mailjet reports refusal in the body, not the HTTP code.
  const response = jsonResponse({
    Messages: [{
      Status: "error",
      Errors: [{ ErrorCode: "send-0008", StatusCode: 403, ErrorMessage: "sender not authorized" }],
    }],
  });

  await withFetch(response, async () => {
    await assertRejects(
      () => sendMailjetMessage({ from: "kyc@example.com", to: "u@example.com", subject: "s", text: "t" }, CREDENTIALS),
      Error,
      "Email provider rejected the message",
    );
  });
});

Deno.test("sendMailjetMessage rejects on a non-2xx HTTP status", async () => {
  const response = jsonResponse({ error: "unauthorized" }, 401);

  await withFetch(response, async () => {
    await assertRejects(
      () => sendMailjetMessage({ from: "kyc@example.com", to: "u@example.com", subject: "s", text: "t" }, CREDENTIALS),
      Error,
      "Email provider rejected the message",
    );
  });
});

Deno.test("sendMailjetMessage rejects when no message id comes back", async () => {
  const response = jsonResponse({ Messages: [{ Status: "success", To: [] }] });

  await withFetch(response, async () => {
    await assertRejects(
      () => sendMailjetMessage({ from: "kyc@example.com", to: "u@example.com", subject: "s", text: "t" }, CREDENTIALS),
      Error,
      "Email provider returned no message id",
    );
  });
});

Deno.test("sendMailjetMessage rejects when the transport fails", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = (() => Promise.reject(new Error("connection reset"))) as typeof fetch;
  try {
    await assertRejects(
      () => sendMailjetMessage({ from: "kyc@example.com", to: "u@example.com", subject: "s", text: "t" }, CREDENTIALS),
      Error,
      "Email provider unreachable",
    );
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("a transport failure message never contains the credentials", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = (() => Promise.reject(new Error("boom"))) as typeof fetch;
  try {
    const error = await assertRejects(
      () => sendMailjetMessage({ from: "k@example.com", to: "u@example.com", subject: "s", text: "t" }, CREDENTIALS),
    );
    const text = `${(error as Error).message} ${(error as Error).stack ?? ""}`;
    assertEquals(text.includes(CREDENTIALS.secretKey), false);
    assertEquals(text.includes(CREDENTIALS.apiKey), false);
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("describeFailure surfaces provider errors without dumping the body", () => {
  const response = {
    Messages: [{ Status: "error", Errors: [{ ErrorCode: "mj-0004", ErrorMessage: "Type mismatch." }] }],
  };
  assertStringIncludes(describeFailure(response, "raw"), "mj-0004");
});

Deno.test("describeFailure bounds an unrecognised body", () => {
  const described = describeFailure(null, "x".repeat(2000));
  assertEquals(described.length, 500);
});
