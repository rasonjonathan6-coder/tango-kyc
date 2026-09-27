/**
 * Tests for the definitive reply-destination rule.
 *
 * `profiles.email` is the Tango KYC account/login address. `register_value` is
 * the Tango registration email the user typed into the KYC form (also called
 * `tango_registration_email`) and is the address the external company was told
 * about. Replies must go to the latter, never the former.
 *
 * `userReplyRecipient` is the single place this rule lives, so it is the single
 * place it needs testing.
 */
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { userReplyRecipient } from "../_shared/email-provider.ts";

const ACCOUNT_EMAIL = "account@example.com"; // profiles.email
const TANGO_EMAIL = "tango.registration.test@example.com"; // register_value

Deno.test("the recipient is register_value, not profiles.email", () => {
  const { recipient } = userReplyRecipient({
    register_type: "email",
    register_value: TANGO_EMAIL,
  });
  assertEquals(recipient, TANGO_EMAIL);
});

Deno.test("the account email is never chosen as the recipient", () => {
  // The helper only ever sees the ticket, which has no access to profiles.email.
  const { recipient } = userReplyRecipient({
    register_type: "email",
    register_value: TANGO_EMAIL,
  });
  assertEquals(recipient === ACCOUNT_EMAIL, false);
  assertEquals(recipient, TANGO_EMAIL);
});

Deno.test("a phone registration produces no recipient", () => {
  const { recipient, reason } = userReplyRecipient({
    register_type: "phone",
    register_value: "+261341234567",
  });
  assertEquals(recipient, null);
  assertEquals(reason.includes("phone"), true);
});

Deno.test("a phone number is never turned into a recipient", () => {
  // Even if a phone were somehow typed as an email type, it is not an address.
  const { recipient } = userReplyRecipient({
    register_type: "phone",
    register_value: "0321234567",
  });
  assertEquals(recipient, null);
});

Deno.test("surrounding whitespace is trimmed", () => {
  const { recipient } = userReplyRecipient({
    register_type: "email",
    register_value: `  ${TANGO_EMAIL}  `,
  });
  assertEquals(recipient, TANGO_EMAIL);
});

Deno.test("a blank register_value produces no recipient", () => {
  assertEquals(userReplyRecipient({ register_type: "email", register_value: "" }).recipient, null);
  assertEquals(userReplyRecipient({ register_type: "email", register_value: "   " }).recipient, null);
  assertEquals(userReplyRecipient({ register_type: "email", register_value: null }).recipient, null);
  assertEquals(userReplyRecipient({ register_type: "email" }).recipient, null);
});

Deno.test("a missing register_type produces no recipient", () => {
  assertEquals(userReplyRecipient({ register_value: TANGO_EMAIL }).recipient, null);
  assertEquals(userReplyRecipient({}).recipient, null);
});

Deno.test("the recipient is returned verbatim, unescaped", () => {
  // The address is used as an SMTP envelope recipient, so it must not be
  // HTML-escaped or otherwise transformed on the way out.
  const { recipient } = userReplyRecipient({
    register_type: "email",
    register_value: "first.last+tag@sub.example.co.uk",
  });
  assertEquals(recipient, "first.last+tag@sub.example.co.uk");
});
