/**
 * Integration test for the "user message -> support inbox" send path.
 *
 * `sendUserMessageToSupport` is exercised for real: transport selection, the
 * Resend payload, the Reply-To, and the idempotency ledger lookups all run. Only
 * the network is stubbed, by replacing `globalThis.fetch`, so no mail is sent and
 * no credential is needed. The Supabase REST calls the provider makes for its
 * idempotency ledger are answered by the same stub.
 *
 * Run with:  deno test --allow-env --allow-net supabase/functions/tests/user_message_support_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.6";
import { adminRequestEmailContent, sendUserMessageToSupport } from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

const TOKEN = "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f";
const SUPABASE_URL = "http://127.0.0.1:54321";

const ticket: TicketForAdminNotification = {
  id: "11111111-1111-1111-1111-111111111111",
  user_id: "22222222-2222-2222-2222-222222222222",
  ticket_code: "TNG-KYC-8F42A91C",
  tango_profile_link: "https://tango.me/user/7",
  register_type: "email",
  register_value: "requester@example.com",
  reply_token: TOKEN,
};

interface Capture {
  resendPayloads: Record<string, unknown>[];
  recordedMessageIds: Record<string, string>[];
  ledgerQueries: string[];
}

/**
 * Runs `fn` with a stubbed network and the environment the provider needs. The
 * stub answers the Resend send and the Supabase ledger calls; anything else is a
 * hard failure so a surprise call is visible rather than silently swallowed.
 */
async function withStubbedNetwork(fn: (capture: Capture) => Promise<void>): Promise<void> {
  const capture: Capture = { resendPayloads: [], recordedMessageIds: [], ledgerQueries: [] };
  const originalFetch = globalThis.fetch;
  const env = {
    SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY: "test-service-key",
    EMAIL_TRANSPORT: "resend",
    RESEND_API_KEY: "test-resend-key",
    RESEND_FROM_EMAIL: "onboarding@resend.dev",
    EMAIL_INBOUND_DOMAIN: "inbound.example.com",
    EMAIL_INBOUND_MAILBOX: "reply",
    KYC_SUPPORT_EMAIL: "support@example.com",
    ADMIN_EMAIL: "admin-only@example.com",
  };
  const previous = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(env)) {
    previous.set(key, Deno.env.get(key));
    Deno.env.set(key, value);
  }

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.startsWith("https://api.resend.com/emails")) {
      capture.resendPayloads.push(JSON.parse(String(init?.body ?? "{}")));
      return Promise.resolve(
        new Response(JSON.stringify({ id: "resend-msg-1" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      );
    }
    if (url.includes("/rest/v1/email_events")) {
      capture.ledgerQueries.push(decodeURIComponent(url));
      // No prior send recorded, so the idempotency check lets this one through.
      return Promise.resolve(
        new Response("[]", { status: 200, headers: { "content-type": "application/json" } }),
      );
    }
    if (url.includes("/rest/v1/rpc/record_email_event")) {
      return Promise.resolve(
        new Response("null", { status: 200, headers: { "content-type": "application/json" } }),
      );
    }
    if (url.includes("/rest/v1/rpc/record_outbound_email")) {
      capture.recordedMessageIds.push(JSON.parse(String(init?.body ?? "{}")));
      return Promise.resolve(
        new Response("null", { status: 200, headers: { "content-type": "application/json" } }),
      );
    }
    return Promise.reject(new Error(`unexpected fetch in test: ${url}`));
  }) as typeof fetch;

  try {
    await fn(capture);
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

Deno.test("a user message is sent to the support mailbox, not the admin address", async () => {
  await withStubbedNetwork(async (capture) => {
    const sent = await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    assert(sent, "the send must be reported as successful");

    assertEquals(capture.resendPayloads.length, 1);
    const payload = capture.resendPayloads[0];
    assertEquals(payload.to, ["support@example.com"]);
    assert(
      !JSON.stringify(payload.to).includes("admin-only@example.com"),
      "the admin address must never receive the user message",
    );
  });
});

Deno.test("the user message email is replyable on the same ticket via the token", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    const payload = capture.resendPayloads[0];
    assertEquals(payload.reply_to, `reply+${TOKEN}@inbound.example.com`);
  });
});

Deno.test("the outbound provider id is recorded so a threaded reply still matches", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    assertEquals(capture.recordedMessageIds.length, 1);
    assertEquals(capture.recordedMessageIds[0].p_ticket_id, ticket.id);
    assertEquals(capture.recordedMessageIds[0].p_provider_message_id, "resend-msg-1");
  });
});

Deno.test("the user message continues the same Gmail thread via In-Reply-To", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(
      { ...ticket, last_outbound_message_id: "<tng-abc123@tango-kyc.local>" },
      "Voici mon document.",
      "msg-1",
    );
    const headers = capture.resendPayloads[0].headers as Record<string, string>;
    assertEquals(headers["In-Reply-To"], "<tng-abc123@tango-kyc.local>");
    assertEquals(headers["References"], "<tng-abc123@tango-kyc.local>");
  });
});

Deno.test("the user message subject stays the request subject so Gmail keeps one thread", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    // Gmail threads by subject plus the reference headers: a different subject
    // starts a new conversation even when the headers are correct.
    const expected = `Re: ${adminRequestEmailContent(ticket).subject}`;
    assertEquals(capture.resendPayloads[0].subject, expected);
  });
});

Deno.test("no threading headers are sent when no real Message-ID is stored", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    assertEquals(capture.resendPayloads[0].headers, undefined);
  });
});

Deno.test("the user message email never exposes the ticket code or uuid", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    const payload = capture.resendPayloads[0];
    const serialised = JSON.stringify(payload);
    assert(!serialised.includes("TNG-KYC-8F42A91C"), "the ticket code must not appear");
    assert(!serialised.includes(ticket.id), "the ticket uuid must not appear");
    // The subject is the request subject prefixed with "Re:", so it threads.
    assertStringIncludes(String(payload.subject), "Re: Manual KYC Verification request");
    assertStringIncludes(String(payload.text), "Voici mon document.");
  });
});

Deno.test("the idempotency key is the stored message id, not the message length", async () => {
  await withStubbedNetwork(async (capture) => {
    await sendUserMessageToSupport(ticket, "aaa", "msg-1");
    await sendUserMessageToSupport(ticket, "bbb", "msg-2");
    assertEquals(capture.resendPayloads.length, 2, "a second distinct message must be sent");
    assert(
      capture.ledgerQueries.some((q) => q.includes("kyc-user-message-msg-1")),
      "the first message id must be the ledger key",
    );
    assert(
      capture.ledgerQueries.some((q) => q.includes("kyc-user-message-msg-2")),
      "the second message id must be the ledger key",
    );
  });
});

Deno.test("an unset support mailbox fails the send instead of using the admin address", async () => {
  await withStubbedNetwork(async () => {
    Deno.env.delete("KYC_SUPPORT_EMAIL");
    Deno.env.delete("KYC_RECIPIENT_EMAIL");
    let threw = false;
    try {
      await sendUserMessageToSupport(ticket, "Voici mon document.", "msg-1");
    } catch (error) {
      threw = true;
      assertStringIncludes(String(error), "KYC_SUPPORT_EMAIL_NOT_CONFIGURED");
    }
    assert(threw, "an unconfigured support mailbox must fail loudly");
  });
});
