/**
 * Email delivery and receipt for the Tango KYC Edge Functions.
 *
 * OUTBOUND: selected by `EMAIL_TRANSPORT` — Resend (REST API,
 *           ./resend-outbound.ts) or Gmail (REST API, ./gmail-outbound.ts).
 *           Defaults to Resend so existing deployments are unchanged; the
 *           Gmail path is opt-in and Resend stays available for rollback.
 * INBOUND:  Resend, always. `fetchReceivedEmail` below is unchanged and still
 *           uses EMAIL_API_KEY; the `email.received` webhook keeps working as
 *           before regardless of which transport sends the outbound mail.
 *
 * `replyToAddress` deliberately keeps routing replies to the Resend inbound
 * address, so the existing reply-to-ticket association is untouched.
 *
 * Docs verified against:
 *   https://resend.com/docs/api-reference/emails/send-email
 *   https://resend.com/docs/dashboard/receiving/introduction
 *   https://resend.com/docs/knowledge-base/403-error-resend-dev-domain
 */
import { AppError } from "./http.ts";
import { env, requireEnv, serviceClient } from "./clients.ts";
import { sendResendMessage } from "./resend-outbound.ts";
import {
  gmailConfigured,
  gmailCredentialsFromEnv,
  sendGmailMessage,
} from "./gmail-outbound.ts";

const RESEND_API = "https://api.resend.com";

/**
 * Default sender used when RESEND_FROM_EMAIL is not set.
 *
 * This is Resend's shared sandbox sender. It needs no domain and no DNS
 * records, but Resend only allows it to deliver to the address that owns the
 * Resend account. Sending anywhere else returns HTTP 403 and the provider says
 * so explicitly. Set RESEND_FROM_EMAIL to override it.
 */
const DEFAULT_RESEND_FROM = "onboarding@resend.dev";

/** Provider tag for the outbound idempotency ledger. */
const OUTBOUND_PROVIDER = "resend";
const OUTBOUND_EVENT = "outbound.send";

/**
 * How long a caller-supplied key suppresses a repeat send. Resend applies the
 * same 24 hour window to its `Idempotency-Key`, and the ledger mirrors it so the
 * guarantee also holds when the provider is unreachable.
 */
const IDEMPOTENCY_WINDOW_MS = 24 * 60 * 60 * 1000;

export interface SendEmailArgs {
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  headers?: Record<string, string>;
  /**
   * Caller-supplied dedup key. Enforced by this module through the
   * `email_events` ledger; it is also forwarded as Resend's `Idempotency-Key`.
   */
  idempotencyKey?: string;
}

export interface SendEmailResult {
  /** Provider message id, used for threading inbound replies back to a ticket. */
  id: string;
  /**
   * True when the send was skipped because the idempotency key was already used
   * within the suppression window. `id` is empty in that case, and callers must
   * not overwrite stored provider ids with it.
   */
  suppressed?: boolean;
}

/** The outbound transports this module can drive. */
export type EmailTransport = "resend" | "gmail";

/**
 * Which outbound transport to use.
 *
 * Defaults to `resend`, so a deployment that sets nothing keeps its previous
 * behaviour and the Gmail path is strictly opt-in. Rollback is therefore a
 * configuration change (`EMAIL_TRANSPORT=resend`), not a code change, and the
 * Resend transport stays present and usable throughout.
 */
export function emailTransport(): EmailTransport {
  return env("EMAIL_TRANSPORT").trim().toLowerCase() === "gmail" ? "gmail" : "resend";
}

/**
 * Resolves the Resend API key used for outbound sending.
 *
 * `RESEND_API_KEY` is preferred so outbound can later be scoped to its own
 * credential. When it is absent the existing `EMAIL_API_KEY` is reused: it is
 * already a Resend key (the inbound path uses it), so no new secret is invented
 * and no value is ever hardcoded here. This path is retained for rollback.
 */
function outboundApiKey(): string {
  return env("RESEND_API_KEY") || env("EMAIL_API_KEY");
}

/** True when the selected outbound transport is fully configured. */
export function emailSendingConfigured(): boolean {
  return emailTransport() === "gmail"
    ? gmailConfigured()
    : outboundApiKey().length > 0;
}

/**
 * The outbound sender for the selected transport.
 *
 * Resend uses `RESEND_FROM_EMAIL` (or its sandbox sender when unset). Gmail
 * uses the authenticated account from `GMAIL_FROM_EMAIL`; the display name is
 * composed by the Gmail MIME builder from `GMAIL_SENDER_NAME`.
 */
export function fromAddress(): string {
  if (emailTransport() === "gmail") {
    const creds = gmailCredentialsFromEnv();
    if (creds) return creds.fromEmail;
  }
  return env("RESEND_FROM_EMAIL") || DEFAULT_RESEND_FROM;
}

/**
 * The tokenised inbound address a reply must be sent to.
 *
 * Only the opaque `reply_token` identifies the ticket: the ticket code is never
 * part of the address, and the token is never shown to the recipient. When no
 * inbound domain is configured the reply path cannot exist, so the address is
 * not invented — an explicit error tells the operator what is missing.
 */
export function replyToAddress(replyToken: string): string {
  const domain = env("EMAIL_INBOUND_DOMAIN");
  const mailbox = env("EMAIL_INBOUND_MAILBOX") || "reply";
  if (!domain) {
    throw new AppError(
      "EMAIL_REPLY_NOT_CONFIGURED",
      "Inbound email is not configured; set EMAIL_INBOUND_DOMAIN",
      503,
    );
  }
  return `${mailbox}+${replyToken}@${domain}`;
}

/**
 * The administration identity: the human who replies to requests.
 *
 * `ADMIN_EMAIL` is the single source of truth and lives in an Edge Function
 * secret, not in `app_settings` (see docs/SUPABASE_SETUP.md). There is no
 * fallback address on purpose: sending a request to a hard-coded mailbox would
 * silently deliver KYC data to whoever owns that literal, so an unconfigured
 * deployment fails loudly instead.
 */
export function adminEmail(): string {
  const configured = env("ADMIN_EMAIL");
  if (!configured) {
    throw new AppError(
      "ADMIN_EMAIL_NOT_CONFIGURED",
      "ADMIN_EMAIL is not configured",
      503,
    );
  }
  return configured;
}

/**
 * The mailbox that receives KYC mail and answers it: the "société / support
 * KYC" role.
 *
 * This is deliberately a separate role from `ADMIN_EMAIL`. `ADMIN_EMAIL` is the
 * administration identity (the human who can act in the dashboard); this one is
 * the support inbox the user's messages are sent to and that replies from.
 *
 * There is no fallback to `ADMIN_EMAIL`: silently using the administration
 * address here would deliver KYC data to the wrong mailbox, so an unconfigured
 * deployment fails loudly instead. `KYC_RECIPIENT_EMAIL` is accepted as an
 * alias so either name can be used in configuration.
 */
export function supportRecipient(): string {
  const configured = env("KYC_SUPPORT_EMAIL") || env("KYC_RECIPIENT_EMAIL");
  if (!configured) {
    throw new AppError(
      "KYC_SUPPORT_EMAIL_NOT_CONFIGURED",
      "KYC_SUPPORT_EMAIL is not configured",
      503,
    );
  }
  return configured;
}

/** Escape a value for safe interpolation into a text email body. */
export function plain(value: string): string {
  return String(value ?? "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "")
    .replace(/\r\n?/g, "\n");
}

/** Escape a value for safe interpolation into an HTML email body. */
export function escapeHtml(value: string): string {
  return plain(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

interface LedgerRow {
  id?: string;
  created_at?: string;
}

/**
 * Returns the ledger row when this key was used within the suppression window.
 * A lookup failure fails open: losing a notification is worse than a possible
 * duplicate, and the failure is logged.
 */
async function findRecentSend(key: string): Promise<LedgerRow | null> {
  const admin = serviceClient();
  const since = new Date(Date.now() - IDEMPOTENCY_WINDOW_MS).toISOString();
  const { data, error } = await admin
    .from("email_events")
    .select("id")
    .eq("provider", OUTBOUND_PROVIDER)
    .eq("external_id", key)
    .eq("event_type", OUTBOUND_EVENT)
    .gte("created_at", since)
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error("Outbound idempotency lookup failed:", error.message);
    return null;
  }
  return (data as LedgerRow | null) ?? null;
}

/**
 * Records a successful send. `record_email_event` is itself idempotent, so a
 * duplicate insert is a no-op; when the stored marker is older than the window
 * its timestamp is slid forward to reproduce a provider-side 24 hour key.
 */
async function recordOutboundSend(key: string): Promise<void> {
  const admin = serviceClient();
  const { data, error } = await admin.rpc("record_email_event", {
    p_provider: OUTBOUND_PROVIDER,
    p_external_id: key,
    p_event_type: OUTBOUND_EVENT,
    p_payload_hash: null,
    p_ticket_id: null,
  });

  if (error) {
    console.error("Could not record outbound email marker:", error.message);
    return;
  }

  const row = data as LedgerRow | null;
  if (!row?.id) return;

  const age = Date.now() - new Date(row.created_at ?? 0).getTime();
  if (age <= IDEMPOTENCY_WINDOW_MS) return;

  const { error: refreshError } = await admin
    .from("email_events")
    .update({ created_at: new Date().toISOString() })
    .eq("id", row.id);
  if (refreshError) {
    console.error("Could not refresh outbound email marker:", refreshError.message);
  }
}

/**
 * Sends a transactional email through the configured transport.
 *
 * When `idempotencyKey` is supplied, a send already recorded within the
 * suppression window is skipped, so a retried call cannot produce a second
 * notification. That guarantee lives here, in the provider-agnostic
 * `email_events` ledger, so it holds for both Resend and Gmail — Gmail offers
 * no native idempotency key, while Resend's is forwarded as defence in depth.
 *
 * The selected transport is chosen by `EMAIL_TRANSPORT` (see `emailTransport`).
 */
export async function sendEmail(args: SendEmailArgs): Promise<SendEmailResult> {
  const transport = emailTransport();

  if (transport === "gmail") {
    const creds = gmailCredentialsFromEnv();
    if (!creds) {
      console.error("EMAIL_TRANSPORT=gmail but the GMAIL_* secrets are incomplete");
      throw new AppError("SERVICE_NOT_CONFIGURED", "Gmail transport is not configured", 503);
    }
    return sendViaGmail(args, creds);
  }

  const apiKey = outboundApiKey();
  if (!apiKey) {
    console.error("No Resend API key is configured (RESEND_API_KEY / EMAIL_API_KEY)");
    throw new AppError("SERVICE_NOT_CONFIGURED", "Resend API key is not configured", 503);
  }
  return sendViaResend(args, apiKey);
}

/**
 * Runs the shared idempotency check, the transport call, and the ledger write.
 * `dispatch` returns the provider message id to record.
 */
async function deliver(
  args: SendEmailArgs,
  dispatch: () => Promise<{ id: string }>,
): Promise<SendEmailResult> {
  if (args.idempotencyKey) {
    const recent = await findRecentSend(args.idempotencyKey);
    if (recent?.id) {
      console.warn("Outbound email suppressed by idempotency key: %s", args.idempotencyKey);
      return { id: "", suppressed: true };
    }
  }

  const result = await dispatch();

  if (args.idempotencyKey) {
    await recordOutboundSend(args.idempotencyKey);
  }

  return { id: result.id };
}

function sendViaResend(args: SendEmailArgs, apiKey: string): Promise<SendEmailResult> {
  const from = fromAddress();
  return deliver(args, () =>
    sendResendMessage(
      {
        from,
        to: args.to,
        subject: args.subject,
        text: args.text,
        html: args.html,
        replyTo: args.replyTo,
        headers: args.headers,
        idempotencyKey: args.idempotencyKey,
      },
      apiKey,
    ),
  );
}

function sendViaGmail(
  args: SendEmailArgs,
  creds: ReturnType<typeof gmailCredentialsFromEnv> & object,
): Promise<SendEmailResult> {
  return deliver(args, () =>
    sendGmailMessage(
      {
        to: args.to,
        subject: args.subject,
        text: args.text,
        html: args.html,
        replyTo: args.replyTo,
        headers: args.headers,
        idempotencyKey: args.idempotencyKey,
      },
      creds,
    ),
  );
}

/**
 * The recipient of a user-facing reply notification.
 *
 * The single source of truth for this rule: the Tango registration email the
 * user typed into the KYC form (`register_value`, also called
 * `tango_registration_email`). That is the address the external company was
 * told about, so it is where a reply belongs.
 *
 * It is explicitly NOT `profiles.email` — that is only the account/login
 * address for Tango KYC Verification itself, and it must never receive these
 * replies. `register_value` also accepts a phone number, in which case there is
 * no address to mail: nothing is sent and no address is invented.
 */
export function userReplyRecipient(ticket: {
  register_type?: string | null;
  register_value?: string | null;
}): { recipient: string | null; reason: string } {
  if (ticket.register_type !== "email") {
    return {
      recipient: null,
      reason: `registered with a ${ticket.register_type ?? "unknown"} value, not an email`,
    };
  }
  const email = String(ticket.register_value ?? "").trim();
  if (!email) {
    return { recipient: null, reason: "no registration email on the ticket" };
  }
  return { recipient: email, reason: "registration email" };
}

/**
 * True only once an admin has *approved* a payment for the ticket.
 *
 * A submitted-but-unreviewed payment does not count. KYC processing mail stays
 * silent until an admin has actually verified the transfer, so the gate is the
 * `approved` status and never merely the existence of a payment row.
 */
export async function ticketPaymentApproved(ticketId: string): Promise<boolean> {
  const admin = serviceClient();
  const { data, error } = await admin
    .from("mvola_payments")
    .select("id")
    .eq("ticket_id", ticketId)
    .eq("status", "approved")
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error("Could not read the payment state for ticket %s: %s", ticketId, error.message);
    return false;
  }
  return Boolean((data as { id?: string } | null)?.id);
}

/** The ticket fields the admin notification needs. */
export interface TicketForAdminNotification {
  id: string;
  ticket_code: string;
  tango_profile_link: string;
  register_type: "email" | "phone";
  register_value: string;
  reply_token: string;
  /** Payment amount in the configured currency, when a payment was validated. */
  payment_amount?: number | null;
  payment_currency?: string | null;
  payment_status?: string | null;
  payment_reviewed_at?: string | null;
}

/**
 * Builds the admin KYC email. Pure, so the wording is unit-tested without a
 * network or a provider credential.
 */
export function adminRequestEmailContent(
  ticket: TicketForAdminNotification,
): { subject: string; text: string; html: string } {
  const registerLine = ticket.register_type === "email"
    ? `Register email: ${plain(ticket.register_value)}`
    : `Register number: ${plain(ticket.register_value)}`;

  // The ticket code is deliberately absent from the subject and body: it is a
  // routing handle, not something the recipient needs to read. The reply is
  // matched server side through the tokenised Reply-To and the thread ids.
  const subject = "Nouvelle demande de vérification de compte";

  const amountLine = ticket.payment_amount != null
    ? `${ticket.payment_amount} ${plain(ticket.payment_currency ?? "")}`.trim()
    : null;
  const managedAt = ticket.payment_reviewed_at ?? new Date().toISOString();

  const text = [
    "Hello support tango team,",
    "",
    "A new KYC verification request is ready for manual review.",
    "",
    "My account information:",
    "",
    `Tango profile ID: ${plain(ticket.tango_profile_link)}`,
    registerLine,
    "",
    `Payment status: ${plain(ticket.payment_status ?? "approved")}`,
    ...(amountLine ? [`Payment amount: ${amountLine}`] : []),
    `Received: ${managedAt}`,
    "",
    "Send me the link for my verification.",
    "",
    "Please restart a manual review of my verification status.",
    "",
    "Thank you.",
  ].join("\n");

  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.6;color:#1a1a1a">
<p>Hello support tango team,</p>
<p>A new KYC verification request is ready for manual review.</p>
<p><strong>My account information:</strong></p>
<p>Tango profile ID: ${escapeHtml(ticket.tango_profile_link)}<br>
${ticket.register_type === "email" ? "Register email" : "Register number"}: ${escapeHtml(ticket.register_value)}</p>
<p><strong>Request details</strong></p>
<p>Payment status: ${escapeHtml(ticket.payment_status ?? "approved")}${amountLine ? `<br>Payment amount: ${escapeHtml(amountLine)}` : ""}<br>
Received: ${escapeHtml(managedAt)}</p>
<p>Send me the link for my verification.</p>
<p>Please restart a manual review of my verification status.</p>
<p>Thank you.</p>
</div>`;

  return { subject, text, html };
}

/**
 * Builds the "officially submitted" confirmation sent to the requester.
 *
 * The ticket code is never shown: it is an internal routing handle. The reply
 * is matched server side from the tokenised Reply-To and the thread ids.
 */
export function userSubmittedEmailContent(
  ticket: TicketForAdminNotification,
): { subject: string; text: string; html: string } {
  const text = [
    "Bonjour,",
    "",
    "Votre demande de vérification de compte a bien été envoyée après validation de votre paiement.",
    "",
    "Notre équipe va maintenant la traiter. Vous serez informé à chaque étape.",
    "",
    "Merci d'utiliser Tango KYC Verification.",
  ].join("\n");

  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.6;color:#1a1a1a">
<p>Bonjour,</p>
<p>Votre demande de vérification de compte a bien été envoyée après validation de votre paiement.</p>
<p>Notre équipe va maintenant la traiter. Vous serez informé à chaque étape.</p>
<p>Merci d'utiliser Tango KYC Verification.</p>
</div>`;

  return { subject: "Votre demande de vérification de compte a bien été envoyée", text, html };
}

/**
 * Builds the email sent to the support inbox when the user writes in the app.
 *
 * This is the counterpart of the user's reply inside the conversation: it tells
 * the société that the ticket owner answered, without exposing the ticket code
 * or uuid. Support replies straight to the tokenised `Reply-To`, so the answer
 * lands on the same ticket.
 */
export function userMessageToSupportEmailContent(
  ticket: TicketForAdminNotification,
  message: string,
): { subject: string; text: string; html: string } {
  const registerLine = ticket.register_type === "email"
    ? `Register email: ${plain(ticket.register_value)}`
    : `Register number: ${plain(ticket.register_value)}`;

  const subject = "Nouveau message d'un utilisateur - vérification de compte";

  const text = [
    "Bonjour,",
    "",
    "Le demandeur a écrit un nouveau message dans la conversation de sa demande de vérification de compte.",
    "",
    "Message:",
    plain(message),
    "",
    "Détails de la demande:",
    `Tango profile ID: ${plain(ticket.tango_profile_link)}`,
    registerLine,
    "",
    "Vous pouvez répondre directement à cet email: votre réponse sera ajoutée à la conversation et le demandeur en sera informé.",
    "",
    "Merci.",
  ].join("\n");

  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.6;color:#1a1a1a">
<p>Bonjour,</p>
<p>Le demandeur a écrit un nouveau message dans la conversation de sa demande de vérification de compte.</p>
<p><strong>Message:</strong></p>
<p style="white-space:pre-wrap">${escapeHtml(message)}</p>
<p><strong>Détails de la demande:</strong></p>
<p>Tango profile ID: ${escapeHtml(ticket.tango_profile_link)}<br>
${ticket.register_type === "email" ? "Register email" : "Register number"}: ${escapeHtml(ticket.register_value)}</p>
<p>Vous pouvez répondre directement à cet email: votre réponse sera ajoutée à la conversation et le demandeur en sera informé.</p>
<p>Merci.</p>
</div>`;

  return { subject, text, html };
}

/**
 * Sends the user's in-app message to the support inbox, on the same ticket.
 *
 * The `Reply-To` is the tokenised inbound address, so a reply from the société
 * is resolved back to this ticket by token, never by the ticket code. The
 * outbound provider id is recorded so a reply is matched by thread id too. The
 * recipient is `KYC_SUPPORT_EMAIL`, never the admin address.
 *
 * `messageId` is the stored `public.messages` row id and is used as the
 * idempotency key: a retried call for the same stored message is suppressed,
 * while a genuinely new message (a different row) is always sent.
 */
export async function sendUserMessageToSupport(
  ticket: TicketForAdminNotification,
  message: string,
  messageId: string,
): Promise<boolean> {
  if (!emailSendingConfigured()) {
    console.warn(
      "Email is not configured: user message on %s was not sent to support.",
      ticket.ticket_code,
    );
    return false;
  }

  const recipient = supportRecipient();
  const { subject, text, html } = userMessageToSupportEmailContent(ticket, message);

  const result = await sendEmail({
    to: recipient,
    subject,
    text,
    html,
    replyTo: replyToAddress(ticket.reply_token),
    idempotencyKey: `kyc-user-message-${messageId}`,
  });

  if (result.suppressed || !result.id) {
    return true;
  }

  const admin = serviceClient();
  const { error } = await admin.rpc("record_outbound_email", {
    p_ticket_id: ticket.id,
    p_provider_message_id: result.id,
  });
  if (error) {
    console.error(
      "Could not record outbound email id for %s: %s",
      ticket.ticket_code,
      error.message,
    );
  }

  return true;
}

/**
 * Sends the KYC request to the administration mailbox.
 *
 * Only ever called once a payment is approved, so an unpaid request never
 * reaches the admin inbox. The Tango profile link and the Tango registration
 * value are informational fields in the body; the recipient is the configured
 * admin address, never the user. No secret, token or password is ever included.
 */
export async function sendAdminRequestNotification(
  ticket: TicketForAdminNotification,
): Promise<boolean> {
  if (!emailSendingConfigured()) {
    console.warn(
      "Email is not configured: ticket %s was not sent to the support inbox.",
      ticket.ticket_code,
    );
    return false;
  }

  const { subject, text, html } = adminRequestEmailContent(ticket);

  const recipient = supportRecipient();
  const result = await sendEmail({
    to: recipient,
    subject,
    text,
    html,
    replyTo: replyToAddress(ticket.reply_token),
    idempotencyKey: `kyc-admin-${ticket.ticket_code}`,
  });

  // Store the outbound provider id so a threaded reply can be matched even when
  // the admin removes the ticket code from the subject. A suppressed send
  // carries no id, so the previously recorded one is left untouched.
  if (result.suppressed || !result.id) {
    return true;
  }

  const admin = serviceClient();
  const { error } = await admin.rpc("record_outbound_email", {
    p_ticket_id: ticket.id,
    p_provider_message_id: result.id,
  });
  if (error) {
    console.error("Could not record outbound email id for %s: %s", ticket.ticket_code, error.message);
  }

  return true;
}

/**
 * Emails the ticket owner the confirmation that their request is officially
 * submitted, after the payment has been validated.
 *
 * Sent to the Tango registration address the user supplied (`register_value`),
 * matching the existing owner-notification rule. A phone-only requester is never
 * emailed, and the call is idempotent on the ticket code so a replayed approval
 * cannot produce a second message. No secret is included.
 */
export async function sendUserRequestSubmittedEmail(
  ticket: TicketForAdminNotification,
): Promise<boolean> {
  const { recipient, reason } = userReplyRecipient(ticket);
  if (!recipient) {
    console.warn("Ticket %s: %s; no submission email sent.", ticket.ticket_code, reason);
    return false;
  }

  if (!emailSendingConfigured()) {
    console.warn("Email is not configured: owner of %s was not emailed.", ticket.ticket_code);
    return false;
  }

  const { subject, text, html } = userSubmittedEmailContent(ticket);

  const result = await sendEmail({
    to: recipient,
    subject,
    text,
    html,
    replyTo: replyToAddress(ticket.reply_token),
    idempotencyKey: `kyc-user-submitted-${ticket.ticket_code}`,
  });

  // Store the outbound provider id so the user can reply straight to this mail
  // and have the answer matched back to the same ticket by thread id.
  if (result.suppressed || !result.id) {
    return true;
  }

  const admin = serviceClient();
  const { error } = await admin.rpc("record_outbound_email", {
    p_ticket_id: ticket.id,
    p_provider_message_id: result.id,
  });
  if (error) {
    console.error("Could not record outbound email id for %s: %s", ticket.ticket_code, error.message);
  }

  return true;
}

export interface ReceivedEmail {
  id: string;
  from: string;
  to: string[];
  cc: string[];
  received_for: string[];
  subject: string;
  message_id: string;
  html: string | null;
  text: string | null;
  headers: Record<string, string>;
}

/**
 * Fetches the full content of a received email. The `email.received` webhook
 * payload is metadata only, so the body must be retrieved separately.
 */
export async function fetchReceivedEmail(emailId: string): Promise<ReceivedEmail> {
  const apiKey = requireEnv("EMAIL_API_KEY");

  let response: Response;
  try {
    response = await fetch(`${RESEND_API}/emails/receiving/${encodeURIComponent(emailId)}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (error) {
    console.error("Resend receiving fetch failed:", error instanceof Error ? error.message : error);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider unreachable", 502);
  }

  const raw = await response.text();
  if (!response.ok) {
    console.error(`Resend receiving fetch failed (${response.status}):`, raw);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Could not load the received email", 502);
  }

  const data = JSON.parse(raw) as Partial<ReceivedEmail>;
  return {
    id: data.id ?? emailId,
    from: data.from ?? "",
    to: data.to ?? [],
    cc: data.cc ?? [],
    received_for: data.received_for ?? [],
    subject: data.subject ?? "",
    message_id: data.message_id ?? "",
    html: data.html ?? null,
    text: data.text ?? null,
    headers: data.headers ?? {},
  };
}
