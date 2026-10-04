/**
 * Unit tests for the payment-gated notification emails.
 *
 * The rule under test: the admin is only ever told about a request that has been
 * paid for, and the requester is only told their request is "submitted" once the
 * payment has been validated. The wording is built by pure functions so it can
 * be checked without a network, a provider credential or a database.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/submission_email_test.ts
 */
import { assert, assertStringIncludes, assertEquals } from "jsr:@std/assert@1.0.6";
import {
  adminRequestEmailContent,
  userSubmittedEmailContent,
} from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

const ticket: TicketForAdminNotification = {
  id: "11111111-1111-1111-1111-111111111111",
  user_id: "22222222-2222-2222-2222-222222222222",
  ticket_code: "TNG-KYC-8F42A91C",
  tango_profile_link: "https://tango.me/user/7",
  register_type: "email",
  register_value: "requester@example.com",
  reply_token: "tok",
};

// Test 1 — the société subject carries the real profile link, dynamically.
Deno.test("the société email subject is the required format with the dynamic profile link", () => {
  const { subject } = adminRequestEmailContent({
    ...ticket,
    tango_profile_link: "https://tango.me/e2e-a",
    register_type: "email",
    register_value: "user+a-mvola-e2e-1@example.com",
  });
  assertEquals(
    subject,
    "Manual KYC Verification request - Profil Creator: (https://tango.me/e2e-a)",
  );
  // A different link must produce a different subject: nothing is hard-coded.
  const { subject: other } = adminRequestEmailContent({
    ...ticket,
    tango_profile_link: "https://tango.me/e2e-b",
  });
  assertEquals(
    other,
    "Manual KYC Verification request - Profil Creator: (https://tango.me/e2e-b)",
  );
});

// Test 1 — the body uses the exact required model for an email registration.
Deno.test("the société email body follows the model with the register email", () => {
  const { text } = adminRequestEmailContent({
    ...ticket,
    tango_profile_link: "https://tango.me/e2e-a",
    register_type: "email",
    register_value: "user+a-mvola-e2e-1@example.com",
  });
  const expected = [
    "Hello support tango team,",
    "",
    "I am requesting a manual review of my identity verification (KYC).",
    "",
    "I have valid official government documents ready for submission to prove my identity.",
    "",
    "My account information:",
    "",
    "Tango profile ID: https://tango.me/e2e-a",
    "Register email: user+a-mvola-e2e-1@example.com",
    "",
    "Send me the link for my verification.",
    "",
    "Please restart a manual review of my verification status.",
    "",
    "Thank you.",
  ].join("\n");
  assertEquals(text, expected);
});

// Test 2 — a phone registration shows "Register number", never an email field.
Deno.test("the société email body follows the model with the register number", () => {
  const { subject, text } = adminRequestEmailContent({
    ...ticket,
    tango_profile_link: "https://tango.me/e2e-b",
    register_type: "phone",
    register_value: "0346754333",
  });
  assertEquals(
    subject,
    "Manual KYC Verification request - Profil Creator: (https://tango.me/e2e-b)",
  );
  assertStringIncludes(text, "Tango profile ID: https://tango.me/e2e-b");
  assertStringIncludes(text, "Register number: 0346754333");
  assert(!text.includes("Register email"), "no email field for a phone registration");
  assert(!text.includes("null"), "no 'null' placeholder must ever be shown");
});

// Test 5 — the ticket code stays internal: absent from subject and body.
Deno.test("the société email never leaks the ticket code, the uuid or 'Ticket ID'", () => {
  const { subject, text, html } = adminRequestEmailContent({
    ...ticket,
    payment_amount: 20000,
    payment_currency: "MGA",
    payment_status: "approved",
    payment_reviewed_at: "2026-09-25T11:00:00.000Z",
  });
  for (const part of [subject, text, html]) {
    assert(!part.includes("TNG-KYC-8F42A91C"), "the ticket code must not appear");
    assert(!part.includes("TNG-KYC-"), "no ticket code prefix must appear");
    assert(!part.includes("Ticket ID"), "no 'Ticket ID' label must appear");
    assert(!part.includes(ticket.id), "the ticket uuid must not appear");
    assert(!part.includes("Payment status"), "no payment block must appear");
    assert(!part.includes("Received:"), "no received block must appear");
  }
});

Deno.test("the admin email escapes markup in the HTML body", () => {
  const { html } = adminRequestEmailContent({
    ...ticket,
    tango_profile_link: "https://tango.me/u/<script>alert(1)</script>",
    register_value: "evil@example.com<img src=x>",
  });
  assert(!html.includes("<script>"));
  assertStringIncludes(html, "&lt;script&gt;");
  assert(!html.includes("<img src=x>"));
});

Deno.test("the requester email confirms submission after the payment is validated", () => {
  const { subject, text, html } = userSubmittedEmailContent(ticket);
  assertStringIncludes(subject, "Votre demande de vérification de compte a bien été envoyée");
  assertStringIncludes(text, "envoyée");
  assertStringIncludes(text, "validation de votre paiement");
  assertStringIncludes(html, "bien été envoyée");
});

Deno.test("the requester email never leaks the ticket code or the uuid", () => {
  const { subject, text, html } = userSubmittedEmailContent(ticket);
  for (const part of [subject, text, html]) {
    assert(!part.includes("TNG-KYC-8F42A91C"), "the ticket code must not appear");
    assert(!part.includes("Ticket ID"), "no 'Ticket ID' label must appear");
    assert(!part.includes(ticket.id), "the ticket uuid must not appear");
  }
});

Deno.test("the requester email keeps the French copy and the ticket code out of the subject", () => {
  const { subject, text } = userSubmittedEmailContent(ticket);
  assert(!subject.includes("TNG-KYC"), "the subject must not carry the code");
  assert(!text.includes("TNG-KYC"), "the body must not carry the code");
});

Deno.test("a hostile ticket code cannot be injected into the requester email", () => {
  // The escaping rule still holds for whatever reaches the body: the code is no
  // longer interpolated at all, so even a markup payload cannot appear.
  const { subject, text, html } = userSubmittedEmailContent({ ...ticket, ticket_code: "<b>x</b>" });
  for (const part of [subject, text, html]) {
    assert(!part.includes("<b>x</b>"));
    assert(!part.includes("&lt;b&gt;x&lt;/b&gt;"));
  }
});
