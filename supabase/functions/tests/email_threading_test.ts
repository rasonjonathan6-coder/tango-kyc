/**
 * Tests for the USER -> SOCIÉTÉ email threading rule.
 *
 * The société's mail client (Gmail) files a message under an existing
 * conversation only from the real `In-Reply-To` / `References` headers. Those
 * must reference the actual RFC Message-ID of the last outbound mail stored on
 * the ticket - never an invented value, never the ticket code or uuid.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/email_threading_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.6";
import { threadingHeaders } from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

const ticket: TicketForAdminNotification = {
  id: "11111111-1111-1111-1111-111111111111",
  user_id: "22222222-2222-2222-2222-222222222222",
  ticket_code: "TNG-KYC-8F42A91C",
  tango_profile_link: "https://tango.me/user/7",
  register_type: "email",
  register_value: "requester@example.com",
  reply_token: "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f",
};

const COMPANY_MESSAGE_ID = "<tng-abc123@tango-kyc.local>";
const COMPANY_REPLY_ID = "<tng-def456@tango-kyc.local>";

Deno.test("In-Reply-To is the real Message-ID of the last outbound mail", () => {
  const headers = threadingHeaders({ ...ticket, last_outbound_message_id: COMPANY_MESSAGE_ID });
  assertEquals(headers?.["In-Reply-To"], COMPANY_MESSAGE_ID);
});

Deno.test("References carries the existing thread id and the last outbound id", () => {
  const headers = threadingHeaders({
    ...ticket,
    last_outbound_message_id: COMPANY_MESSAGE_ID,
    email_thread_id: COMPANY_REPLY_ID,
  });
  assertEquals(headers?.["References"], `${COMPANY_REPLY_ID} ${COMPANY_MESSAGE_ID}`);
});

Deno.test("References falls back to the last outbound id when no thread id exists", () => {
  const headers = threadingHeaders({ ...ticket, last_outbound_message_id: COMPANY_MESSAGE_ID });
  assertEquals(headers?.["References"], COMPANY_MESSAGE_ID);
});

Deno.test("a bare Message-ID is wrapped in angle brackets", () => {
  const headers = threadingHeaders({
    ...ticket,
    last_outbound_message_id: "tng-abc123@tango-kyc.local",
  });
  assertEquals(headers?.["In-Reply-To"], "<tng-abc123@tango-kyc.local>");
});

Deno.test("no header is produced when no real Message-ID is stored", () => {
  assertEquals(threadingHeaders({ ...ticket }), undefined);
  assertEquals(threadingHeaders({ ...ticket, last_outbound_message_id: "" }), undefined);
  assertEquals(threadingHeaders({ ...ticket, last_outbound_message_id: null }), undefined);
});

Deno.test("a provider uuid is never wrapped into a false Message-ID", () => {
  // Resend returns a bare uuid; that is not an RFC Message-ID, so it must not
  // be turned into one.
  const headers = threadingHeaders({
    ...ticket,
    last_outbound_message_id: "5c8f1b2e-9a4d-4c6f-8e2a-1b3c4d5e6f70",
  });
  assertEquals(headers, undefined);
});

Deno.test("the ticket code and uuid never appear in the threading headers", () => {
  const headers = threadingHeaders({
    ...ticket,
    last_outbound_message_id: COMPANY_MESSAGE_ID,
    email_thread_id: COMPANY_REPLY_ID,
  });
  const serialised = JSON.stringify(headers);
  assert(!serialised.includes("TNG-KYC-8F42A91C"));
  assert(!serialised.includes(ticket.id));
  assertStringIncludes(serialised, COMPANY_MESSAGE_ID);
});
