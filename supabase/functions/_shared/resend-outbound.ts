/**
 * Resend transactional sending (REST API) - OUTBOUND ONLY.
 *
 * Inbound replies are received through Resend as well, but through a different
 * surface (`fetchReceivedEmail` + the `email.received` webhook in
 * ./email-provider.ts). Nothing here touches the inbound path.
 *
 * Docs verified against:
 *   https://resend.com/docs/api-reference/emails/send-email
 *   https://resend.com/docs/knowledge-base/403-error-resend-dev-domain
 *
 * Authentication is `Authorization: Bearer <api key>`. Resend offers a native
 * `Idempotency-Key` header, but duplicate suppression is still enforced by this
 * codebase's `email_events` ledger so the guarantee does not depend on the
 * provider; the key is forwarded as well for defence in depth.
 */
import { AppError } from "./http.ts";

export const RESEND_SEND_ENDPOINT = "https://api.resend.com/emails";

/** Bounded so a slow provider cannot hold an Edge Function open. */
const RESEND_TIMEOUT_MS = 10_000;

/** How much of an unrecognised provider body may reach the logs. */
const LOG_BODY_MAX = 500;

/**
 * Headers Resend refuses because the API sets them itself. Passing one would
 * fail the whole message, so they are dropped rather than forwarded.
 */
const FORBIDDEN_HEADERS = new Set([
  "from",
  "sender",
  "subject",
  "to",
  "cc",
  "bcc",
  "reply-to",
  "return-path",
  "delivered-to",
  "dkim-signature",
  "domainkey-status",
  "received-spf",
  "authentication-results",
  "received",
  "date",
  "message-id",
  "user-agent",
  "x-mailer",
  "content-type",
  "content-transfer-encoding",
  "mime-version",
]);

export interface ResendSendArgs {
  from: string;
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  headers?: Record<string, string>;
  /** Forwarded as Resend's `Idempotency-Key`; duplicate suppression also runs in the DB ledger. */
  idempotencyKey?: string;
}

export interface ResendPayload {
  from: string;
  to: string[];
  subject: string;
  text?: string;
  html?: string;
  reply_to?: string;
  headers?: Record<string, string>;
}

/** Flattens recipients, tolerating a comma-separated string and blank entries. */
export function toRecipients(to: string | string[]): string[] {
  const entries = Array.isArray(to) ? to : [to];
  const recipients: string[] = [];
  for (const entry of entries) {
    for (const part of String(entry ?? "").split(",")) {
      const trimmed = part.trim();
      if (trimmed) recipients.push(trimmed);
    }
  }
  return recipients;
}

/** Drops the headers Resend reserves for itself. */
export function filterHeaders(
  headers: Record<string, string> | undefined,
): Record<string, string> | undefined {
  if (!headers) return undefined;
  const kept: Record<string, string> = {};
  const dropped: string[] = [];
  for (const [name, value] of Object.entries(headers)) {
    if (FORBIDDEN_HEADERS.has(name.toLowerCase())) {
      dropped.push(name);
      continue;
    }
    kept[name] = value;
  }
  if (dropped.length > 0) {
    console.warn("Resend reserved headers dropped: %s", dropped.join(", "));
  }
  return Object.keys(kept).length > 0 ? kept : undefined;
}

export function buildResendPayload(args: ResendSendArgs): ResendPayload {
  const payload: ResendPayload = {
    from: args.from.trim(),
    to: toRecipients(args.to),
    subject: args.subject,
  };
  if (args.text) payload.text = args.text;
  if (args.html) payload.html = args.html;
  if (args.replyTo) payload.reply_to = args.replyTo.trim();
  const headers = filterHeaders(args.headers);
  if (headers) payload.headers = headers;
  return payload;
}

interface RawError {
  statusCode?: number;
  name?: string;
  message?: string;
}

/**
 * Resend returns `{ statusCode, name, message }` on refusal. The message is
 * safe to log: it names the configuration problem (for example that the
 * `resend.dev` sandbox sender may only reach the account owner's address) and
 * never echoes the API key.
 */
export function describeFailure(response: unknown, raw: string): string {
  const error = (response as { error?: RawError } | null)?.error ??
    (response as RawError | null);
  const parts: string[] = [];
  if (error?.name) parts.push(String(error.name));
  if (error?.message) parts.push(String(error.message));
  if (parts.length > 0) return parts.join(": ");
  return raw.slice(0, LOG_BODY_MAX) || "no response body";
}

/** Resend answers `{ id: "<uuid>" }` on success. */
export function extractMessageId(response: unknown): string | null {
  const id = (response as { id?: unknown } | null)?.id;
  if (typeof id === "string" && id.trim().length > 0) return id;
  if (typeof id === "number") return String(id);
  return null;
}

export async function sendResendMessage(
  args: ResendSendArgs,
  apiKey: string,
): Promise<{ id: string }> {
  const payload = buildResendPayload(args);

  const headers: Record<string, string> = {
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": "application/json",
  };
  if (args.idempotencyKey) headers["Idempotency-Key"] = args.idempotencyKey;

  let response: Response;
  try {
    response = await fetch(RESEND_SEND_ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
    });
  } catch (error) {
    // Only the transport error is logged: never the Authorization header.
    console.error("Resend request failed:", error instanceof Error ? error.message : error);
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider unreachable", 502);
  }

  const raw = await response.text();

  let parsed: unknown = null;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = null;
  }

  if (!response.ok) {
    console.error(`Resend send failed (HTTP ${response.status}):`, describeFailure(parsed, raw));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider rejected the message", 502);
  }

  const id = extractMessageId(parsed);
  if (!id) {
    console.error("Resend response had no message id:", describeFailure(parsed, raw));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider returned no message id", 502);
  }

  return { id };
}
