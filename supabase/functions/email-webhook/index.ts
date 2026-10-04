/**
 * POST /functions/v1/email-webhook
 *
 * Receives Resend `email.received` events, resolves which ticket the reply
 * belongs to, stores the cleaned body and notifies the user.
 *
 * Security posture:
 *  - the Svix signature is verified against the raw body before anything else;
 *  - processing is idempotent, because providers redeliver events;
 *  - a reply that cannot be attributed with certainty is quarantined as an
 *    `unmatched_reply` and never forwarded to a guessed user.
 */
import { AppError, errorResponse, handlePreflight, jsonResponse } from "../_shared/http.ts";
import { env, serviceClient } from "../_shared/clients.ts";
import { verifySvixSignature } from "../_shared/svix.ts";
import { extractCleanReplyBody, sanitizeForStorage } from "../_shared/email-body.ts";
import {
  accountEmail,
  emailSendingConfigured,
  fetchReceivedEmail,
  replyToAddress,
  sendEmail,
  userReplyRecipient,
} from "../_shared/email-provider.ts";
import { sendPushToUser } from "../_shared/push.ts";

const PROVIDER = "resend";

/// Notification wording. Identical to the client's foreground fallback so the
/// user sees one message regardless of app state. Contains no sensitive data.
const PUSH_TITLE = "Nouvelle réponse à votre demande";
const PUSH_BODY = "Vous avez reçu une nouvelle réponse concernant votre demande KYC.";

interface ResendReceivedEvent {
  type?: string;
  created_at?: string;
  data?: {
    email_id?: string;
    message_id?: string;
    from?: string;
    to?: string[];
    cc?: string[];
    bcc?: string[];
    received_for?: string[];
    subject?: string;
  };
}

/** Extracts `local@domain` from values like `Name <local@domain>`. */
function extractAddress(value: string | null | undefined): string | null {
  if (!value) return null;
  const angled = /<([^>]+)>/.exec(value);
  const candidate = (angled ? angled[1] : value).trim().toLowerCase();
  return /^[^@\s]+@[^@\s]+$/.test(candidate) ? candidate : null;
}

/** Stable content hash used to detect provider-level duplicates. */
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    // The raw body must be used verbatim: re-serialising JSON breaks the HMAC.
    const rawBody = await req.text();

    await verifySvixSignature({
      rawBody,
      svixId: req.headers.get("svix-id"),
      svixTimestamp: req.headers.get("svix-timestamp"),
      svixSignature: req.headers.get("svix-signature"),
      secret: env("RESEND_WEBHOOK_SECRET"),
    });

    let event: ResendReceivedEvent;
    try {
      event = JSON.parse(rawBody);
    } catch {
      throw new AppError("INVALID_WEBHOOK", "Malformed JSON body", 400);
    }

    if (event.type !== "email.received") {
      return jsonResponse({ ignored: true, reason: `unsupported event type: ${event.type ?? "none"}` });
    }

    const emailId = event.data?.email_id;
    if (!emailId) {
      throw new AppError("INVALID_WEBHOOK", "Event has no email_id", 400);
    }

    const admin = serviceClient();
    const payloadHash = await sha256Hex(rawBody);

    // Idempotency guard: the provider may deliver the same event repeatedly.
    const { data: eventRow, error: eventError } = await admin.rpc("record_email_event", {
      p_provider: PROVIDER,
      p_external_id: emailId,
      p_event_type: "email.received",
      p_payload_hash: payloadHash,
      p_ticket_id: null,
    });
    if (eventError) {
      console.error("record_email_event failed:", eventError.message);
      throw new AppError("INTERNAL", "Could not record the email event", 500);
    }

    const alreadyLinked = Boolean(
      (eventRow as { ticket_id?: string | null } | null)?.ticket_id,
    );

    const email = await fetchReceivedEmail(emailId);

    const recipients = [
      ...(email.to ?? []),
      ...(email.cc ?? []),
      ...(email.received_for ?? []),
      ...(event.data?.to ?? []),
      ...(event.data?.cc ?? []),
      ...(event.data?.received_for ?? []),
    ].filter((v): v is string => typeof v === "string");

    const subject = email.subject || event.data?.subject || "";
    const inReplyTo = email.headers?.["in-reply-to"] ?? email.headers?.["In-Reply-To"] ?? null;
    const references = email.headers?.["references"] ?? email.headers?.["References"] ?? null;

    const cleanBody = sanitizeForStorage(
      extractCleanReplyBody({ html: email.html, text: email.text }),
    );

    // Resolve the ticket server side using the documented order:
    // ticket code -> reply token -> recorded thread ids.
    const { data: ticketId, error: resolveError } = await admin.rpc("resolve_ticket_for_reply", {
      p_subject: subject,
      p_body: cleanBody || email.text || "",
      p_recipients: recipients,
      p_in_reply_to: inReplyTo,
      p_references: references,
    });
    if (resolveError) {
      console.error("resolve_ticket_for_reply failed:", resolveError.message);
      throw new AppError("INTERNAL", "Could not resolve the ticket", 500);
    }

    if (!ticketId) {
      const fromEmail = extractAddress(email.from);
      const toEmail = extractAddress(recipients[0] ?? null);
      await admin.rpc("record_unmatched_reply", {
        p_provider: PROVIDER,
        p_external_id: emailId,
        p_from_email: fromEmail,
        p_to_email: toEmail,
        p_subject: subject,
        p_body_excerpt: cleanBody,
        p_reason: "no_confident_ticket_match",
      });
      console.warn("Unmatched reply quarantined: %s", emailId);
      // Acknowledge so the provider does not retry forever; the reply is safe in
      // the admin quarantine queue.
      return jsonResponse({ matched: false, quarantined: true });
    }

    if (alreadyLinked) {
      // The event was already fully processed on an earlier delivery.
      return jsonResponse({ matched: true, duplicated: true, ticket_id: ticketId });
    }

    const { data: stored, error: storeError } = await admin.rpc("record_inbound_reply", {
      p_ticket_id: ticketId,
      p_clean_body: cleanBody,
      p_external_message_id: email.message_id || event.data?.message_id || emailId,
      p_from_email: extractAddress(email.from),
    });
    if (storeError) {
      // A reply that arrives after the ticket was closed must not reopen it or
      // add a message. This is an expected outcome, not a server error: the
      // event is acknowledged so the provider stops retrying, and the reply is
      // not forwarded to the user.
      if (storeError.message?.includes("TICKET_CLOSED")) {
        console.warn("Reply for closed ticket %s ignored.", ticketId);
        return jsonResponse({ matched: true, ticket_closed: true, stored: false });
      }
      console.error("record_inbound_reply failed:", storeError.message);
      throw new AppError("INTERNAL", "Could not store the reply", 500);
    }

    await admin.rpc("record_email_event", {
      p_provider: PROVIDER,
      p_external_id: emailId,
      p_event_type: "email.received",
      p_payload_hash: payloadHash,
      p_ticket_id: ticketId,
    });

    const duplicated = Boolean((stored as { duplicate?: boolean } | null)?.duplicate);

    // Notify the user only for a genuinely new reply. Both the email and the
    // Android push are driven from the resolved ticket, so a duplicate delivery
    // produces neither a second message, nor a second push, nor a second email.
    let userNotified = false;
    let pushSent = 0;
    if (!duplicated) {
      userNotified = await notifyUser(ticketId);
      pushSent = await notifyPush(ticketId);
    }

    return jsonResponse({
      matched: true,
      duplicated,
      ticket_id: ticketId,
      user_notified: userNotified,
      push_sent: pushSent,
    });
  } catch (error) {
    return errorResponse(error);
  }
});

/**
 * Sends the Android push for a resolved reply and returns how many devices it
 * reached.
 *
 * The recipient is the *owner of the ticket*, read from `kyc_requests.user_id`,
 * which is derived from the signature-verified webhook - never from anything the
 * caller supplied. The data carries only the opaque ticket id, so a notification
 * never exposes the reply body or an address.
 *
 * Push is best effort: the reply is already stored and the persistent
 * notification already exists, so a Firebase outage must not fail the webhook
 * (which would make the provider retry the whole event).
 */
async function notifyPush(ticketId: string): Promise<number> {
  const admin = serviceClient();

  const { data: ticket, error } = await admin
    .from("kyc_requests")
    .select("user_id")
    .eq("id", ticketId)
    .maybeSingle();

  if (error || !ticket?.user_id) {
    console.error("Could not load the owner of ticket %s for push: %s", ticketId, error?.message);
    return 0;
  }

  try {
    const result = await sendPushToUser(admin, env, ticket.user_id as string, {
      title: PUSH_TITLE,
      body: PUSH_BODY,
      ticketId,
    });
    if (result.sent === 0) {
      console.warn("No device received the push for ticket %s.", ticketId);
    }
    return result.sent;
  } catch (error) {
    console.error(
      "Push for ticket %s failed: %s",
      ticketId,
      error instanceof Error ? error.message : error,
    );
    return 0;
  }
}

/**
 * Emails the ticket owner when a reply arrives by email.
 *
 * The recipient is the address of the user's account in the application
 * (`profiles.email`), resolved server side from the ticket owner. It is
 * deliberately NOT `register_value`, the address typed into the KYC form: that
 * value stays a request datum and never decides where the mail goes.
 *
 * A user with no account address is never sent mail: an address is never
 * invented, and the reply stays in the dashboard.
 */
async function notifyUser(ticketId: string): Promise<boolean> {
  const admin = serviceClient();

  const { data: ticket, error } = await admin
    .from("kyc_requests")
    .select("user_id, ticket_code, register_type, register_value, reply_token")
    .eq("id", ticketId)
    .maybeSingle();

  if (error || !ticket) {
    console.error("Could not load ticket %s for user notification: %s", ticketId, error?.message);
    return false;
  }

  const { recipient, reason } = userReplyRecipient({ email: await accountEmail(ticket.user_id) });
  if (!recipient) {
    console.warn(
      "Ticket %s: %s; the reply stays in the dashboard.",
      ticket.ticket_code,
      reason,
    );
    return false;
  }

  if (!emailSendingConfigured()) {
    console.warn(
      "Resend is not configured: reply for %s was stored but the user was NOT emailed.",
      ticket.ticket_code,
    );
    return false;
  }

  // No ticket code in the subject or the body: the code is an internal routing
  // handle. The answer is matched server side from the tokenised Reply-To and
  // the thread ids, so the mail stays clean for the recipient.
  const text = [
    "Bonjour,",
    "",
    "Votre demande de vérification de compte a reçu une nouvelle réponse.",
    "",
    "Vous pouvez répondre directement à cet email, ou ouvrir l'application Tango KYC Verification pour consulter la réponse.",
    "",
    "Merci d'utiliser Tango KYC Verification.",
  ].join("\n");

  try {
    const result = await sendEmail({
      to: recipient,
      subject: "Réponse à votre demande de vérification de compte",
      text,
      replyTo: replyToAddress(ticket.reply_token as string),
      idempotencyKey: `kyc-user-reply-${ticket.ticket_code}-${recipient}`,
    });

    // Record the outbound provider id so a reply to this very mail is matched
    // back to the same ticket by thread id even if the address is rewritten.
    if (!result.suppressed && result.id) {
      const { error: recordError } = await admin.rpc("record_outbound_email", {
        p_ticket_id: ticketId,
        p_provider_message_id: result.id,
      });
      if (recordError) {
        console.error(
          "Could not record outbound email id for %s: %s",
          ticket.ticket_code,
          recordError.message,
        );
      }
    }
  } catch (error) {
    // The reply is already stored, so a failed notification must not fail the
    // webhook: the provider would retry the whole event otherwise.
    console.error(
      "Could not notify the owner of %s: %s",
      ticket.ticket_code,
      error instanceof Error ? error.message : error,
    );
    return false;
  }

  return true;
}
