/**
 * Unit tests for the Brevo outbound transport.
 *
 * The live send is never exercised here: `sendBrevoMessage` is tested through an
 * injected `fetch` stub so the request shape and the failure handling are
 * verified without touching the network.
 */
import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  BREVO_SEND_ENDPOINT,
  buildBrevoPayload,
  describeFailure,
  extractMessageId,
  filterHeaders,
  parseAddress,
  sendBrevoMessage,
  toRecipients,
} from "../_shared/brevo-outbound.ts";
import { AppError } from "../_shared/http.ts";

const BASE_ARGS = {
  from: "Tango KYC Verification <kyc@example.com>",
  to: "tangoturq@gmail.com",
  subject: "Nouvelle demande de vérification de compte",
  text: "hello",
};

Deno.test("the send endpoint is Brevo's official one", () => {
  assertEquals(BREVO_SEND_ENDPOINT, "https://api.brevo.com/v3/smtp/email");
});

Deno.test("parseAddress reads a plain address", () => {
  assertEquals(parseAddress("kyc@example.com"), { email: "kyc@example.com" });
});

Deno.test("parseAddress reads a display name form", () => {
  assertEquals(parseAddress("Tango KYC <kyc@example.com>"), {
    email: "kyc@example.com",
    name: "Tango KYC",
  });
});

Deno.test("parseAddress strips quotes around the display name", () => {
  assertEquals(parseAddress('"Tango KYC" <kyc@example.com>'), {
    email: "kyc@example.com",
    name: "Tango KYC",
  });
});

Deno.test("toRecipients produces Brevo address objects", () => {
  assertEquals(toRecipients("a@example.com"), [{ email: "a@example.com" }]);
  assertEquals(toRecipients(["a@example.com", "b@example.com"]), [
    { email: "a@example.com" },
    { email: "b@example.com" },
  ]);
});

Deno.test("toRecipients splits a comma-separated string and drops blanks", () => {
  assertEquals(toRecipients("a@example.com, b@example.com"), [
    { email: "a@example.com" },
    { email: "b@example.com" },
  ]);
  assertEquals(toRecipients(["a@example.com", "", "   "]), [{ email: "a@example.com" }]);
  assertEquals(toRecipients(""), []);
});

Deno.test("buildBrevoPayload uses sender/to objects and textContent", () => {
  const payload = buildBrevoPayload({
    ...BASE_ARGS,
    html: "<p>hello</p>",
    replyTo: "reply+abc@inbound.example.com",
  });
  assertEquals(payload.sender, { email: "kyc@example.com", name: "Tango KYC Verification" });
  assertEquals(payload.to, [{ email: "tangoturq@gmail.com" }]);
  assertEquals(payload.textContent, "hello");
  assertEquals(payload.htmlContent, "<p>hello</p>");
  assertEquals(payload.replyTo, { email: "reply+abc@inbound.example.com" });
});

Deno.test("buildBrevoPayload omits replyTo and htmlContent when absent", () => {
  const payload = buildBrevoPayload(BASE_ARGS);
  assertEquals(payload.replyTo, undefined);
  assertEquals(payload.htmlContent, undefined);
});

Deno.test("buildBrevoPayload never invents a sender", () => {
  // An unverified sender must be reported, not silently replaced.
  const payload = buildBrevoPayload({ ...BASE_ARGS, from: "" });
  assertEquals(payload.sender, { email: "" });
});

Deno.test("filterHeaders drops the headers Brevo reserves for itself", () => {
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

Deno.test("extractMessageId reads Brevo's messageId field", () => {
  assertEquals(
    extractMessageId({ messageId: "<201798300811.5787683@relay.domain.com>" }),
    "<201798300811.5787683@relay.domain.com>",
  );
});

Deno.test("extractMessageId reads the first of a batch messageIds array", () => {
  assertEquals(
    extractMessageId({ messageIds: ["a@smtp-relay.mailin.fr", "b@smtp-relay.mailin.fr"] }),
    "a@smtp-relay.mailin.fr",
  );
});

Deno.test("extractMessageId rejects a blank or missing id", () => {
  assertEquals(extractMessageId({ messageId: "  " }), null);
  assertEquals(extractMessageId({}), null);
  assertEquals(extractMessageId(null), null);
});

Deno.test("describeFailure surfaces Brevo's code and message", () => {
  const described = describeFailure(
    { code: "invalid_parameter", message: "sender is not valid" },
    "",
  );
  assertStringIncludes(described, "invalid_parameter");
  assertStringIncludes(described, "sender is not valid");
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
  "sendBrevoMessage authenticates with the api-key header",
  withFetchStub(
    (input, init) => {
      assertEquals(String(input), BREVO_SEND_ENDPOINT);
      const headers = (init?.headers ?? {}) as Record<string, string>;
      assertEquals(headers["api-key"], "xkeysib-test");
      assert(
        !JSON.stringify(headers).includes("Bearer"),
        "Brevo must not receive a Bearer header",
      );
      return new Response(JSON.stringify({ messageId: "<1@relay>" }), { status: 201 });
    },
    async () => {
      const result = await sendBrevoMessage(BASE_ARGS, "xkeysib-test");
      assertEquals(result.id, "<1@relay>");
    },
  ),
);

Deno.test(
  "sendBrevoMessage posts the Brevo payload shape",
  withFetchStub(
    (_input, init) => {
      const body = JSON.parse(String(init?.body));
      assertEquals(body.sender.email, "kyc@example.com");
      assertEquals(body.to[0].email, "tangoturq@gmail.com");
      assertEquals(body.textContent, "hello");
      assert(!("from" in body), "Brevo uses `sender`, not `from`");
      assert(!("text" in body), "Brevo uses `textContent`, not `text`");
      return new Response(JSON.stringify({ messageId: "<1@relay>" }), { status: 201 });
    },
    async () => {
      await sendBrevoMessage(BASE_ARGS, "xkeysib-test");
    },
  ),
);

Deno.test(
  "sendBrevoMessage reports an unreachable provider as 502",
  withFetchStub(
    () => {
      throw new TypeError("network down");
    },
    async () => {
      const error = await assertRejects(() => sendBrevoMessage(BASE_ARGS, "xkeysib-test"));
      assert(error instanceof AppError);
      assertEquals((error as AppError).status, 502);
    },
  ),
);

Deno.test(
  "sendBrevoMessage reports an unverified sender as 502 without leaking the key",
  withFetchStub(
    () =>
      new Response(
        JSON.stringify({
          code: "invalid_parameter",
          message: "sender is not valid",
        }),
        { status: 400 },
      ),
    async () => {
      const error = await assertRejects(() => sendBrevoMessage(BASE_ARGS, "xkeysib-secret"));
      assert(error instanceof AppError);
      assertEquals((error as AppError).status, 502);
      assert(
        !String((error as AppError).message).includes("xkeysib-secret"),
        "the API key must never reach the error message",
      );
    },
  ),
);

Deno.test(
  "sendBrevoMessage rejects a success response with no message id",
  withFetchStub(
    () => new Response(JSON.stringify({}), { status: 201 }),
    async () => {
      const error = await assertRejects(() => sendBrevoMessage(BASE_ARGS, "xkeysib-test"));
      assertEquals((error as AppError).status, 502);
    },
  ),
);

Deno.test(
  "sendBrevoMessage tolerates a non-JSON error body",
  withFetchStub(
    () => new Response("<html>gateway error</html>", { status: 502 }),
    async () => {
      const error = await assertRejects(() => sendBrevoMessage(BASE_ARGS, "xkeysib-test"));
      assertEquals((error as AppError).status, 502);
    },
  ),
);
