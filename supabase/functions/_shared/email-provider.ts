/**
 * Email delivery through Resend.
 *
 * Resend's free tier covers this project's volume (3,000 emails/month, 100/day)
 * and supports both sending and inbound receiving with an `email.received`
 * webhook. The API key lives only in Edge Function secrets.
 *
 * Docs verified against:
 *   https://resend.com/docs/api-reference/emails/send-email
 *   https://resend.com/docs/dashboard/receiving/introduction
 *   https://resend.com/docs/dashboard/webhooks/verify-webhooks-requests
 */
import { AppError } from "./http.ts";
import { env, requireEnv } from "./clients.ts";

const RESEND_API = "https://api.resend.com";

export interface SendEmailArgs {
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  headers?: Record<string, string>;
  /** Stable key so provider retries cannot send the same email twice. */
  idempotencyKey?: string;
}

export interface SendEmailResult {
  /** Provider message id, used for threading inbound replies back to a ticket. */
  id: string;
}

export function emailApiKeyConfigured(): boolean {
  return env("EMAIL_API_KEY").length > 0;
}

/**
 * Resend rejects `onboarding@resend.dev` as a sender to arbitrary recipients on
 * the free tier, so the From address is configurable. Replies are routed to the
 * inbound address instead of the Gmail mailbox.
 */
export function fromAddress(): string {
  return env("EMAIL_FROM") || "Tango KYC Verification <onboarding@resend.dev>";
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

export async function sendEmail(args: SendEmailArgs): Promise<SendEmailResult> {
  const apiKey = requireEnv("EMAIL_API_KEY");

  const payload: Record<string, unknown> = {
    from: fromAddress(),
    to: args.to,
    subject: args.subject,
    text: args.text,
  };
  if (args.html) payload.html = args.html;
  if (args.replyTo) payload.reply_to = args.replyTo;
  if (args.headers) payload.headers = args.headers;

  const headers: Record<string, string> = {
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": "application/json",
  };
  if (args.idempotencyKey) {
    headers["Idempotency-Key"] = args.idempotencyKey.slice(0, 256);
  }

  let response: Response;
  try {
    response = await fetch(`${RESEND_API}/emails`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
  } catch (error) {
    console.error("Resend request failed:", error instanceof Error ? error.message : error);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider unreachable", 502);
  }

  const raw = await response.text();
  if (!response.ok) {
    console.error(`Resend send failed (${response.status}):`, raw);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider rejected the message", 502);
  }

  let parsed: { id?: string };
  try {
    parsed = JSON.parse(raw);
  } catch {
    console.error("Resend returned malformed JSON:", raw);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider returned an invalid response", 502);
  }

  if (!parsed.id) {
    console.error("Resend response had no id:", raw);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider returned no message id", 502);
  }

  return { id: parsed.id };
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
