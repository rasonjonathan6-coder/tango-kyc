/**
 * Tests for the user-notification destination rule.
 *
 * The rule: a user-facing notification goes to the address of the user's
 * account in the application (`profiles.email`, kept in sync with
 * `auth.users.email`), and never to the address typed into the KYC form
 * (`register_value` / `tango_registration_email`).
 *
 * `userReplyRecipient` is the single place this rule lives. It only accepts the
 * account email, so the request email has no way to influence the destination.
 * The account email itself is read server side by `accountEmail` from the
 * server-owned profile row.
 */
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { userReplyRecipient } from "../_shared/email-provider.ts";

const ACCOUNT_EMAIL = "account@example.com"; // profiles.email / auth.users.email
const REQUEST_EMAIL = "fake-request@example.com"; // register_value, from the form

Deno.test("the recipient is the account email", () => {
  const { recipient } = userReplyRecipient({ email: ACCOUNT_EMAIL });
  assertEquals(recipient, ACCOUNT_EMAIL);
});

Deno.test("the request email is never chosen as the recipient", () => {
  // The helper only accepts the account email; a request email cannot reach it.
  const { recipient } = userReplyRecipient({ email: ACCOUNT_EMAIL });
  assertEquals(recipient === REQUEST_EMAIL, false);
  assertEquals(recipient, ACCOUNT_EMAIL);
});

Deno.test("a request email passed alongside the account email is ignored", () => {
  // Even if a caller forwarded extra ticket fields, only `email` decides.
  const { recipient } = userReplyRecipient({
    email: ACCOUNT_EMAIL,
    register_value: REQUEST_EMAIL,
  } as { email?: string | null });
  assertEquals(recipient, ACCOUNT_EMAIL);
});

Deno.test("an account with no email produces no recipient", () => {
  assertEquals(userReplyRecipient({ email: "" }).recipient, null);
  assertEquals(userReplyRecipient({ email: "   " }).recipient, null);
  assertEquals(userReplyRecipient({ email: null }).recipient, null);
  assertEquals(userReplyRecipient({}).recipient, null);
});

Deno.test("surrounding whitespace is trimmed", () => {
  const { recipient } = userReplyRecipient({ email: `  ${ACCOUNT_EMAIL}  ` });
  assertEquals(recipient, ACCOUNT_EMAIL);
});

Deno.test("the recipient is returned verbatim, unescaped", () => {
  // The address is used as an SMTP envelope recipient, so it must not be
  // HTML-escaped or otherwise transformed on the way out.
  const { recipient } = userReplyRecipient({ email: "first.last+tag@sub.example.co.uk" });
  assertEquals(recipient, "first.last+tag@sub.example.co.uk");
});
