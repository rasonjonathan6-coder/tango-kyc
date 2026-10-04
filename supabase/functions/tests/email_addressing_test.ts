/**
 * Tests for the outbound addressing helpers.
 *
 * Two rules are pinned here, both of which exist to keep KYC mail from being
 * delivered to the wrong place:
 *
 *  - the Reply-To carries only the opaque reply token, so a reply is matched
 *    server side without the ticket code ever being shown;
 *  - the admin address has no hard-coded fallback: an unconfigured deployment
 *    must fail loudly rather than send to a literal nobody owns.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/email_addressing_test.ts
 */
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1.0.6";
import {
  adminEmail,
  replyToAddress,
  supportRecipient,
  userMessageToSupportEmailContent,
} from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

const TOKEN = "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f";

/** Runs `fn` with the given env applied, then restores the previous values. */
function withEnv(vars: Record<string, string | undefined>, fn: () => void): void {
  const previous = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(vars)) {
    previous.set(key, Deno.env.get(key));
    if (value === undefined) Deno.env.delete(key);
    else Deno.env.set(key, value);
  }
  try {
    fn();
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

Deno.test("the Reply-To carries the opaque token, never the ticket code", () => {
  withEnv({ EMAIL_INBOUND_DOMAIN: "inbound.example.com", EMAIL_INBOUND_MAILBOX: undefined }, () => {
    const address = replyToAddress(TOKEN);
    assertEquals(address, `reply+${TOKEN}@inbound.example.com`);
    assert(!address.includes("TNG-KYC"), "the ticket code must never appear");
  });
});

Deno.test("the Reply-To honours a configured mailbox", () => {
  withEnv({ EMAIL_INBOUND_DOMAIN: "inbound.example.com", EMAIL_INBOUND_MAILBOX: "support" }, () => {
    assertEquals(replyToAddress(TOKEN), `support+${TOKEN}@inbound.example.com`);
  });
});

Deno.test("an unconfigured inbound domain is an explicit error, not a fallback address", () => {
  withEnv({ EMAIL_INBOUND_DOMAIN: undefined, ADMIN_EMAIL: "admin@example.com" }, () => {
    assertThrows(
      () => replyToAddress(TOKEN),
      Error,
      "EMAIL_REPLY_NOT_CONFIGURED",
    );
  });
});

Deno.test("the admin address is read from ADMIN_EMAIL", () => {
  withEnv({ ADMIN_EMAIL: "kyc-admin@example.com" }, () => {
    assertEquals(adminEmail(), "kyc-admin@example.com");
  });
});

Deno.test("an unset ADMIN_EMAIL raises instead of sending to a hard-coded address", () => {
  withEnv({ ADMIN_EMAIL: undefined }, () => {
    assertThrows(() => adminEmail(), Error, "ADMIN_EMAIL_NOT_CONFIGURED");
  });
});

Deno.test("the support mailbox is a distinct role from the admin address", () => {
  withEnv(
    {
      ADMIN_EMAIL: "admin-only@example.com",
      KYC_SUPPORT_EMAIL: "support@example.com",
      KYC_RECIPIENT_EMAIL: undefined,
    },
    () => {
      assertEquals(supportRecipient(), "support@example.com");
      assert(
        supportRecipient() !== adminEmail(),
        "the support mailbox must never silently become the admin address",
      );
    },
  );
});

Deno.test("KYC_RECIPIENT_EMAIL is accepted as an alias for the support mailbox", () => {
  withEnv({ KYC_SUPPORT_EMAIL: undefined, KYC_RECIPIENT_EMAIL: "alias@example.com" }, () => {
    assertEquals(supportRecipient(), "alias@example.com");
  });
});

Deno.test("ADMIN_KYC_RECIPIENT is accepted as a legacy alias for the support mailbox", () => {
  withEnv(
    {
      KYC_SUPPORT_EMAIL: undefined,
      KYC_RECIPIENT_EMAIL: undefined,
      ADMIN_KYC_RECIPIENT: "tangoturq@gmail.com",
    },
    () => {
      assertEquals(supportRecipient(), "tangoturq@gmail.com");
    },
  );
});

Deno.test("KYC_SUPPORT_EMAIL wins over the legacy ADMIN_KYC_RECIPIENT alias", () => {
  withEnv(
    {
      KYC_SUPPORT_EMAIL: "support@example.com",
      KYC_RECIPIENT_EMAIL: undefined,
      ADMIN_KYC_RECIPIENT: "tangoturq@gmail.com",
    },
    () => {
      assertEquals(supportRecipient(), "support@example.com");
    },
  );
});

Deno.test("an unset support mailbox fails loudly instead of falling back to ADMIN_EMAIL", () => {
  withEnv(
    {
      ADMIN_EMAIL: "admin-only@example.com",
      KYC_SUPPORT_EMAIL: undefined,
      KYC_RECIPIENT_EMAIL: undefined,
      ADMIN_KYC_RECIPIENT: undefined,
    },
    () => {
      assertThrows(() => supportRecipient(), Error, "KYC_SUPPORT_EMAIL_NOT_CONFIGURED");
    },
  );
});

const TICKET: TicketForAdminNotification = {
  id: "11111111-1111-1111-1111-111111111111",
  user_id: "22222222-2222-2222-2222-222222222222",
  ticket_code: "TNG-KYC-8F42A91C",
  tango_profile_link: "https://tango.me/user/7",
  register_type: "email",
  register_value: "requester@example.com",
  reply_token: TOKEN,
};

Deno.test("the user message email carries the message but never the ticket code or uuid", () => {
  const { subject, text, html } = userMessageToSupportEmailContent(
    TICKET,
    "Voici le document demandé.",
  );
  assert(subject.length > 0);
  for (const part of [subject, text, html]) {
    assert(!part.includes("TNG-KYC-8F42A91C"), "the ticket code must not appear");
    assert(!part.includes("Ticket ID"), "no 'Ticket ID' label must appear");
    assert(!part.includes(TICKET.id), "the ticket uuid must not appear");
  }
  assert(text.includes("Voici le document demandé."), "the user message must be included");
});

Deno.test("the user message email body is exactly the user's message", () => {
  const { text } = userMessageToSupportEmailContent(TICKET, "comment");
  assertEquals(text, "comment");
  assert(!text.includes("Bonjour"), "no greeting must be added");
  assert(!text.includes("Détails de la demande"), "no request details block must be added");
  assert(!text.includes("Merci"), "no footer must be added");
});

Deno.test("the user message email escapes markup in the HTML body", () => {
  const { html } = userMessageToSupportEmailContent(TICKET, "<script>alert(1)</script>");
  assert(!html.includes("<script>"), "raw markup must not survive into the HTML body");
});
