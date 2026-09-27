/**
 * Unit tests for the Resend outbound transport.
 *
 * The live send is never exercised here: `sendResendMessage` is tested through
 * an injected `fetch` stub so the request shape and the failure handling are
 * verified without touching the network.
 */
import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildResendPayload,
  describeFailure,
  extractMessageId,
  filterHeaders,
  RESEND_SEND_ENDPOINT,
  sendResendMessage,
  toRecipients,
} from "../_shared/resend-outbound.ts";
import { AppError } from "../_shared/http.ts";

const BASE_ARGS = {
  from: "onboarding@resend.dev",
  to: "tangoturq@gmail.com",
  subject: "Manual KYC Verification request - Profil Creator (https://tango.me/x)",
  text: "hello",
};

Deno.test("the send endpoint is Resend's official one", () => {
  assertEquals(RESEND_SEND_ENDPOINT, "https://api.resend.com/emails");
});

Deno.test("toRecipients flattens arrays and comma-separated strings", () => {
  assertEquals(toRecipients("a@example.com"), ["a@example.com"]);
  assertEquals(toRecipients(["a@example.com", "b@example.com"]), [
    "a@example.com",
    "b@example.com",
  ]);
  assertEquals(toRecipients("a@example.com, b@example.com"), [
    "a@example.com",
    "b@example.com",
  ]);
});

Deno.test("toRecipients drops blanks and trims surrounding spaces", () => {
  assertEquals(toRecipients("  a@example.com  "), ["a@example.com"]);
  assertEquals(toRecipients(["a@example.com", "", "   "]), ["a@example.com"]);
  assertEquals(toRecipients(""), []);
});

Deno.test("buildResendPayload keeps the sender and sets reply_to", () => {
  const payload = buildResendPayload({
    ...BASE_ARGS,
    html: "<p>hello</p>",
    replyTo: "reply+abc@inbound.example.com",
  });
  assertEquals(payload.from, "onboarding@resend.dev");
  assertEquals(payload.to, ["tangoturq@gmail.com"]);
  assertEquals(payload.text, "hello");
  assertEquals(payload.html, "<p>hello</p>");
  assertEquals(payload.reply_to, "reply+abc@inbound.example.com");
});

Deno.test("buildResendPayload omits reply_to and html when absent", () => {
  const payload = buildResendPayload(BASE_ARGS);
  assertEquals(payload.reply_to, undefined);
  assertEquals(payload.html, undefined);
});

Deno.test("filterHeaders drops the headers Resend reserves for itself", () => {
  const kept = filterHeaders({
    "X-Ticket-Code": "TNG-KYC-1234",
    "Message-ID": "<forged@example.com>",
    From: "attacker@example.com",
  });
  assertEquals(kept, { "X-Ticket-Code": "TNG-KYC-1234" });
});

Deno.test("filterHeaders returns undefined when everything is reserved", () => {
  assertEquals(filterHeaders({ From: "a@example.com", Subject: "x" }), undefined);
  assertEquals(filterHeaders(undefined), undefined);
});

Deno.test("extractMessageId reads Resend's id field", () => {
  assertEquals(extractMessageId({ id: "9f1c2d3e-4a5b-6c7d-8e9f-0a1b2c3d4e5f" }), "9f1c2d3e-4a5b-6c7d-8e9f-0a1b2c3d4e5f");
});

Deno.test("extractMessageId rejects a blank or missing id", () => {
  assertEquals(extractMessageId({ id: "  " }), null);
  assertEquals(extractMessageId({}), null);
  assertEquals(extractMessageId(null), null);
});

Deno.test("describeFailure surfaces Resend's error message without the key", () => {
  const described = describeFailure(
    { statusCode: 403, name: "validation_error", message: "domain is not verified" },
    "",
  );
  assertStringIncludes(described, "validation_error");
  assertStringIncludes(described, "domain is not verified");
});

Deno.test("describeFailure falls back to the raw body", () => {
  assertEquals(describeFailure(null, "boom"), "boom");
  assertEquals(describeFailure(null, ""), "no response body");
});

// Transport behaviour, exercised with a stubbed fetch.
function withFetchStub(
  handler: (input: string | URL | Request, init?: RequestInit) => Response | Promise<Response>,
  run: () => Promise<void>,
): () => Promise<void> {
  return async () => {
    const original = globalThis.fetch;
    globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
      return handler(input, init);
    }) as typeof fetch;
    try {
      await run();
    } finally {
      globalThis.fetch = original;
    }
  };
}

Deno.test(
  "sendResendMessage authenticates with the Bearer header",
  withFetchStub(
    (input, init) => {
      assertEquals(String(input), RESEND_SEND_ENDPOINT);
      const headers = (init?.headers ?? {}) as Record<string, string>;
      assertEquals(headers.Authorization, "Bearer re_test_key");
      return new Response(JSON.stringify({ id: "abc-123" }), { status: 200 });
    },
    async () => {
      const result = await sendResendMessage(BASE_ARGS, "re_test_key");
      assertEquals(result.id, "abc-123");
    },
  ),
);

Deno.test(
  "sendResendMessage forwards the idempotency key as a header",
  withFetchStub(
    (_input, init) => {
      const headers = (init?.headers ?? {}) as Record<string, string>;
      assertEquals(headers["Idempotency-Key"], "kyc-admin-TNG-KYC-1234");
      return new Response(JSON.stringify({ id: "abc-123" }), { status: 200 });
    },
    async () => {
      await sendResendMessage(
        { ...BASE_ARGS, idempotencyKey: "kyc-admin-TNG-KYC-1234" },
        "re_test_key",
      );
    },
  ),
);

Deno.test(
  "sendResendMessage posts the Resend payload shape",
  withFetchStub(
    (_input, init) => {
      const body = JSON.parse(String(init?.body));
      assertEquals(body.from, "onboarding@resend.dev");
      assertEquals(body.to, ["tangoturq@gmail.com"]);
      assertEquals(body.text, "hello");
      assert(!("sender" in body), "Resend uses `from`, not `sender`");
      assert(!("textContent" in body), "Resend uses `text`, not `textContent`");
      return new Response(JSON.stringify({ id: "abc-123" }), { status: 200 });
    },
    async () => {
      await sendResendMessage(BASE_ARGS, "re_test_key");
    },
  ),
);

Deno.test(
  "sendResendMessage reports an unreachable provider as 502",
  withFetchStub(
    () => {
      throw new TypeError("network down");
    },
    async () => {
      const error = await assertRejects(() => sendResendMessage(BASE_ARGS, "re_test_key"));
      assert(error instanceof AppError);
      assertEquals((error as AppError).status, 502);
    },
  ),
);

Deno.test(
  "sendResendMessage reports a refused message as 502 without leaking the key",
  withFetchStub(
    () =>
      new Response(
        JSON.stringify({
          statusCode: 403,
          name: "validation_error",
          message: "You can only send testing emails to your own email address",
        }),
        { status: 403 },
      ),
    async () => {
      const error = await assertRejects(() => sendResendMessage(BASE_ARGS, "re_secret_key"));
      assert(error instanceof AppError);
      assertEquals((error as AppError).status, 502);
      assert(
        !String((error as AppError).message).includes("re_secret_key"),
        "the API key must never reach the error message",
      );
    },
  ),
);

Deno.test(
  "sendResendMessage rejects a success response with no message id",
  withFetchStub(
    () => new Response(JSON.stringify({}), { status: 200 }),
    async () => {
      const error = await assertRejects(() => sendResendMessage(BASE_ARGS, "re_test_key"));
      assertEquals((error as AppError).status, 502);
    },
  ),
);

Deno.test(
  "sendResendMessage tolerates a non-JSON error body",
  withFetchStub(
    () => new Response("<html>gateway error</html>", { status: 502 }),
    async () => {
      const error = await assertRejects(() => sendResendMessage(BASE_ARGS, "re_test_key"));
      assertEquals((error as AppError).status, 502);
    },
  ),
);
