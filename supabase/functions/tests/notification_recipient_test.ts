/**
 * Integration tests for the two notification destinations.
 *
 * These exercise the real send paths (`sendAdminRequestNotification`,
 * `sendUserRequestSubmittedEmail`) with only the network stubbed, so the
 * transport selection, the addressing and the internal tracking all run.
 *
 * Rules under test:
 *  - the société/support notification goes to `KYC_SUPPORT_EMAIL` and is decided
 *    server side, never from the address typed into the KYC form;
 *  - the user notification goes to the account address (`profiles.email`, kept in
 *    sync with `auth.users.email`), never to the address typed into the form;
 *  - the ticket code stays an internal handle: absent from the visible subject
 *    and body, while the reply token and thread id are preserved.
 *
 * Run with:  deno test --allow-env --allow-net supabase/functions/tests/notification_recipient_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.6";
import {
  sendAdminRequestNotification,
  sendUserRequestSubmittedEmail,
} from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

const TOKEN = "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f";
const SUPABASE_URL = "http://127.0.0.1:54321";
const SUPPORT = "tangoturq@gmail.com";
const ACCOUNT_EMAIL = "account@example.com";
const REQUEST_EMAIL = "fake-request@example.com";

const ticket: TicketForAdminNotification = {
  id: "11111111-1111-1111-1111-111111111111",
  user_id: "22222222-2222-2222-2222-222222222222",
  ticket_code: "TNG-KYC-8F42A91C",
  tango_profile_link: "https://tango.me/user/7",
  register_type: "email",
  register_value: REQUEST_EMAIL,
  reply_token: TOKEN,
};

interface Capture {
  resendPayloads: Record<string, unknown>[];
  recordedMessageIds: Record<string, string>[];
  ledgerQueries: string[];
}

/**
 * Runs `fn` with a stubbed network. `accountEmail` answers with the given
 * account email so the user destination can be checked without a database.
 */
async function withStubbedNetwork(
  account: string | null,
  fn: (capture: Capture) => Promise<void>,
): Promise<void> {
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
    KYC_SUPPORT_EMAIL: SUPPORT,
    ADMIN_EMAIL: "admin-only@example.com",
  };
  const previous = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(env)) {
    previous.set(key, Deno.env.get(key));
    Deno.env.set(key, value);
  }

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const json = (body: string) =>
      Promise.resolve(
        new Response(body, { status: 200, headers: { "content-type": "application/json" } }),
      );
    if (url.includes("/rest/v1/profiles")) {
      return json(JSON.stringify({ email: account }));
    }
    if (url.startsWith("https://api.resend.com/emails")) {
      capture.resendPayloads.push(JSON.parse(String(init?.body ?? "{}")));
      return json(JSON.stringify({ id: "resend-msg-1" }));
    }
    if (url.includes("/rest/v1/email_events")) {
      capture.ledgerQueries.push(decodeURIComponent(url));
      return json("[]");
    }
    if (url.includes("/rest/v1/rpc/record_email_event")) {
      return json("null");
    }
    if (url.includes("/rest/v1/rpc/record_outbound_email")) {
      capture.recordedMessageIds.push(JSON.parse(String(init?.body ?? "{}")));
      return json("null");
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

// Test 3 — the société notification is addressed server side, to the fixed mailbox.
Deno.test("the société notification goes to tangoturq@gmail.com, never the request email", async () => {
  await withStubbedNetwork(ACCOUNT_EMAIL, async (capture) => {
    const sent = await sendAdminRequestNotification(ticket);
    assert(sent, "the send must be reported as successful");

    assertEquals(capture.resendPayloads.length, 1);
    const payload = capture.resendPayloads[0];
    assertEquals(payload.to, ["tangoturq@gmail.com"]);
    assertEquals(payload.to, [SUPPORT]);
    assert(
      !JSON.stringify(payload.to).includes(REQUEST_EMAIL),
      "the address typed into the KYC form must never receive the société mail",
    );
    // The request email may still appear in the body as request data.
    assertStringIncludes(String(payload.text), `Register email: ${REQUEST_EMAIL}`);
  });
});

// Test 4 — the user notification goes to the account email, never the request email.
Deno.test("the user notification goes to profiles.email, not register_value", async () => {
  assert(ACCOUNT_EMAIL !== REQUEST_EMAIL, "the two addresses must differ for this test");
  await withStubbedNetwork(ACCOUNT_EMAIL, async (capture) => {
    const sent = await sendUserRequestSubmittedEmail(ticket);
    assert(sent, "the send must be reported as successful");

    assertEquals(capture.resendPayloads.length, 1);
    const payload = capture.resendPayloads[0];
    assertEquals(payload.to, [ACCOUNT_EMAIL]);
    assert(
      !JSON.stringify(payload.to).includes(REQUEST_EMAIL),
      "the address typed into the KYC form must never receive the user mail",
    );
    assert(
      !JSON.stringify(payload).includes(REQUEST_EMAIL),
      "register_value must not appear anywhere in the user notification",
    );
  });
});

Deno.test("a user whose account has no email is not notified", async () => {
  await withStubbedNetwork(null, async (capture) => {
    const sent = await sendUserRequestSubmittedEmail(ticket);
    assertEquals(sent, false);
    assertEquals(capture.resendPayloads.length, 0);
  });
});

// Test C — the ticket code never reaches the visible subject or body.
Deno.test("the user notification subject and body never show the ticket code or 'Ticket ID'", async () => {
  await withStubbedNetwork(ACCOUNT_EMAIL, async (capture) => {
    await sendUserRequestSubmittedEmail(ticket);
    const payload = capture.resendPayloads[0];
    for (const part of [payload.subject, payload.text, payload.html]) {
      const text = String(part ?? "");
      assert(!text.includes("TNG-KYC-8F42A91C"), "the ticket code must not appear");
      assert(!text.includes("Ticket ID"), "no 'Ticket ID' label must appear");
    }
    assertStringIncludes(String(payload.subject), "vérification de compte");
  });
});

// Test D — the internal tracking is preserved without stealing the thread anchor.
Deno.test("the user confirmation keeps the tokenised Reply-To and does not overwrite the thread anchor", async () => {
  await withStubbedNetwork(ACCOUNT_EMAIL, async (capture) => {
    await sendUserRequestSubmittedEmail(ticket);
    const payload = capture.resendPayloads[0];
    assertEquals(payload.reply_to, `reply+${TOKEN}@inbound.example.com`);
    // The confirmation is a COMPANY -> USER mail outside the request thread, so
    // it must not record its id: doing so would move `last_outbound_message_id`
    // off the request email and break the user's next threaded message.
    assertEquals(capture.recordedMessageIds.length, 0);
  });
});
