/**
 * Email delivery and receipt for the Tango KYC Edge Functions.
 *
 * OUTBOUND: Mailjet (Send API v3.1). See ./mailjet.ts.
 * INBOUND:  Resend. `fetchReceivedEmail` below is unchanged and still uses
 *           EMAIL_API_KEY; the `email.received` webhook keeps working as before.
 *
 * `replyToAddress` deliberately keeps routing replies to the Resend inbound
 * address, so the existing reply-to-ticket association is untouched even though
 * the outbound message is now sent by a different provider.
 *
 * Docs verified against:
 *   https://dev.mailjet.com/docs/email-api/send-api-v31/send-basic-email
 *   https://resend.com/docs/dashboard/receiving/introduction
 */
import { AppError } from "./http.ts";
import { env, requireEnv, serviceClient } from "./clients.ts";
import { sendMailjetMessage } from "./mailjet.ts";

const RESEND_API = "https://api.resend.com";

/** Provider tag for the outbound idempotency ledger. */
const OUTBOUND_PROVIDER = "mailjet";
const OUTBOUND_EVENT = "outbound.send";

/**
 * How long a caller-supplied key suppresses a repeat send. Matches the 24 hour
 * window Resend applied to `Idempotency-Key`, which Mailjet does not offer.
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
   * `email_events` ledger, because Mailjet has no idempotency-key facility; it
   * is also forwarded as Mailjet's `CustomID` for correlation.
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

/** True when outbound email (Mailjet) is fully configured. */
export function emailSendingConfigured(): boolean {
  return (
    env("MAILJET_API_KEY").length > 0 &&
    env("MAILJET_SECRET_KEY").length > 0 &&
    env("MAILJET_FROM_EMAIL").length > 0
  );
}

/**
 * The validated Mailjet sender. There is deliberately no fallback: Mailjet
 * refuses any address that is not a validated sender, so a placeholder would
 * only turn a configuration mistake into a confusing delivery failure.
 */
export function fromAddress(): string {
  return env("MAILJET_FROM_EMAIL");
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
 * Sends a transactional email through Mailjet.
 *
 * When `idempotencyKey` is supplied, a send already recorded within the
 * suppression window is skipped, so a retried call cannot produce a second
 * notification. Mailjet itself provides no idempotency-key facility, so the
 * guarantee is kept here through the `email_events` ledger.
 */
export async function sendEmail(args: SendEmailArgs): Promise<SendEmailResult> {
  const apiKey = requireEnv("MAILJET_API_KEY");
  const secretKey = requireEnv("MAILJET_SECRET_KEY");
  const from = fromAddress();
  if (!from) {
    console.error("MAILJET_FROM_EMAIL is not configured");
    throw new AppError("SERVICE_NOT_CONFIGURED", "MAILJET_FROM_EMAIL is not configured", 503);
  }

  if (args.idempotencyKey) {
    const recent = await findRecentSend(args.idempotencyKey);
    if (recent?.id) {
      console.warn("Outbound email suppressed by idempotency key: %s", args.idempotencyKey);
      return { id: "", suppressed: true };
    }
  }

  const result = await sendMailjetMessage(
    {
      from,
      to: args.to,
      subject: args.subject,
      text: args.text,
      html: args.html,
      replyTo: args.replyTo,
      headers: args.headers,
      customId: args.idempotencyKey,
    },
    { apiKey, secretKey },
  );

  if (args.idempotencyKey) {
    await recordOutboundSend(args.idempotencyKey);
  }

  return { id: result.id };
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
