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
import { fetchReceivedEmail, emailSendingConfigured, sendEmail } from "../_shared/email-provider.ts";

const PROVIDER = "resend";

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

    // Notify the user only for a genuinely new reply.
    let userNotified = false;
    if (!duplicated) {
      userNotified = await notifyUser(ticketId);
    }

    return jsonResponse({
      matched: true,
      duplicated,
      ticket_id: ticketId,
      user_notified: userNotified,
    });
  } catch (error) {
    return errorResponse(error);
  }
});

/**
 * Emails the ticket owner when they supplied an email address. A phone-only
 * requester is never assigned an invented address; the message stays in the
 * dashboard.
 */
async function notifyUser(ticketId: string): Promise<boolean> {
  const admin = serviceClient();

  const { data: ticket, error } = await admin
    .from("kyc_requests")
    .select("ticket_code, register_type, register_value")
    .eq("id", ticketId)
    .maybeSingle();

  if (error || !ticket) {
    console.error("Could not load ticket %s for user notification: %s", ticketId, error?.message);
    return false;
  }

  if (ticket.register_type !== "email") {
    return false;
  }

  if (!emailSendingConfigured()) {
    console.warn(
      "Mailjet is not fully configured: reply for %s was stored but the user was NOT emailed.",
      ticket.ticket_code,
    );
    return false;
  }

  const text = [
    "Your Tango KYC verification request has received a new response.",
    "",
    `Ticket ID: ${ticket.ticket_code}`,
    "",
    "Please open the Tango KYC Verification application to view the response.",
  ].join("\n");

  await sendEmail({
    to: ticket.register_value,
    subject: `Tango KYC Verification - new response for ${ticket.ticket_code}`,
    text,
    idempotencyKey: `kyc-user-reply-${ticket.ticket_code}-${ticket.register_value}`,
  });

  return true;
}
