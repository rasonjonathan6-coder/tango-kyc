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

export function replyToAddress(ticketCode: string, replyToken: string): string {
  const domain = env("EMAIL_INBOUND_DOMAIN");
  const mailbox = env("EMAIL_INBOUND_MAILBOX") || "reply";
  if (!domain) {
    // No inbound domain configured: let the admin reply straight to the
    // ticket code address only when a domain exists, otherwise fall back to
    // the admin mailbox so nothing is silently lost.
    return adminEmail();
  }
  return `${mailbox}+${replyToken}@${domain}`;
}

export function adminEmail(): string {
  return env("ADMIN_EMAIL") || "rasonjonathan6@gmail.com";
}

/**
 * The mailbox that receives the KYC request itself, once a payment is approved.
 *
 * This is a distinct role from `ADMIN_EMAIL`: that address is the administration
 * identity (the human who replies), while this one is the intake inbox for KYC
 * requests. They are frequently the same address, so the value falls back to
 * `ADMIN_EMAIL` when unset, and either can be replaced in production through
 * configuration alone — no code change.
 */
export function adminKycRecipient(): string {
  return env("ADMIN_KYC_RECIPIENT") || adminEmail();
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
}

/**
 * Sends the KYC request to the administration mailbox.
 *
 * Only ever called once a payment is approved, so an unpaid request never
 * reaches the admin inbox. The Tango profile link and the Tango registration
 * value are informational fields in the body; the recipient is the configured
 * admin address, never the user.
 */
export async function sendAdminRequestNotification(
  ticket: TicketForAdminNotification,
): Promise<boolean> {
  if (!emailSendingConfigured()) {
    console.warn(
      "Resend is not configured: ticket %s was not sent to the admin.",
      ticket.ticket_code,
    );
    return false;
  }

  const registerLine = ticket.register_type === "email"
    ? `Register email: ${plain(ticket.register_value)}`
    : `Register number: ${plain(ticket.register_value)}`;

  const subject =
    `Manual KYC Verification request - Profil Creator (${plain(ticket.tango_profile_link)}) [${ticket.ticket_code}]`;

  const text = [
    "Hello support tango team,",
    "",
    "I am requesting a manual review of my identity verification (KYC).",
    "",
    "I have valid official government documents ready for submission to prove my identity.",
    "",
    "My account information:",
    "",
    `Tango profile ID: ${plain(ticket.tango_profile_link)}`,
    registerLine,
    "",
    "Send me the link for my verification.",
    "",
    "Please restart a manual review of my verification status.",
    "",
    "Thank you.",
    "",
    `Ticket ID: ${ticket.ticket_code}`,
  ].join("\n");

  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.6;color:#1a1a1a">
<p>Hello support tango team,</p>
<p>I am requesting a manual review of my identity verification (KYC).</p>
<p>I have valid official government documents ready for submission to prove my identity.</p>
<p><strong>My account information:</strong></p>
<p>Tango profile ID: ${escapeHtml(ticket.tango_profile_link)}<br>
${ticket.register_type === "email" ? "Register email" : "Register number"}: ${escapeHtml(ticket.register_value)}</p>
<p>Send me the link for my verification.</p>
<p>Please restart a manual review of my verification status.</p>
<p>Thank you.</p>
<hr style="border:none;border-top:1px solid #e5e7eb;margin:20px 0">
<p style="color:#6b7280"><strong>Ticket ID:</strong> ${escapeHtml(ticket.ticket_code)}</p>
</div>`;

  const result = await sendEmail({
    to: adminKycRecipient(),
    subject,
    text,
    html,
    replyTo: replyToAddress(ticket.ticket_code, ticket.reply_token),
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
