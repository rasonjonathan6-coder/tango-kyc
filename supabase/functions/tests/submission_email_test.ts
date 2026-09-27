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
  ticket_code: "TNG-KYC-8F42A91C",
  tango_profile_link: "https://tango.me/user/7",
  register_type: "email",
  register_value: "requester@example.com",
  reply_token: "tok",
};

Deno.test("the admin email carries the required subject and both register shapes", () => {
  const { subject, text } = adminRequestEmailContent({
    ...ticket,
    payment_amount: 20000,
    payment_currency: "MGA",
    payment_status: "approved",
    payment_reviewed_at: "2026-09-25T11:00:00.000Z",
  });
  assertStringIncludes(subject, "Manual KYC Verification request - Profil Creator");
  assertStringIncludes(subject, "https://tango.me/user/7");
  assertStringIncludes(subject, "[TNG-KYC-8F42A91C]");
  assertStringIncludes(text, "Register email: requester@example.com");
  assertStringIncludes(text, "Payment status: approved");
  assertStringIncludes(text, "Payment amount: 20000 MGA");
  assertStringIncludes(text, "Ticket ID: TNG-KYC-8F42A91C");
});

Deno.test("the admin email reports a phone registration as a number, not an email", () => {
  const { text } = adminRequestEmailContent({
    ...ticket,
    register_type: "phone",
    register_value: "+261341234567",
  });
  assertStringIncludes(text, "Register number: +261341234567");
  assert(!text.includes("Register email"));
});

Deno.test("the admin email omits the amount line when no payment is attached", () => {
  const { text, html } = adminRequestEmailContent(ticket);
  assert(!text.includes("Payment amount"));
  assert(!html.includes("Payment amount"));
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
  assertStringIncludes(subject, "TNG-KYC-8F42A91C");
  assertStringIncludes(text, "envoyée avec succès");
  assertStringIncludes(text, "validation de votre paiement");
  assertStringIncludes(html, "TNG-KYC-8F42A91C");
});

Deno.test("the requester email escapes the ticket code", () => {
  const { html } = userSubmittedEmailContent({ ...ticket, ticket_code: "<b>x</b>" });
  assert(!html.includes("<b>x</b>"));
  assertStringIncludes(html, "&lt;b&gt;x&lt;/b&gt;");
});
