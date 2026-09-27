/**
 * Brevo transactional sending (v3 API) - OUTBOUND ONLY.
 *
 * Inbound replies still arrive through Resend: `fetchReceivedEmail` and the
 * `email.received` webhook live in ./email-provider.ts and are untouched. This
 * module only replaces the outbound transport.
 *
 * Docs verified against:
 *   https://developers.brevo.com/reference/send-transac-email
 *   https://developers.brevo.com/docs/send-a-transactional-email
 *
 * Authentication is the `api-key` header. Brevo has no idempotency-key header,
 * so duplicate suppression relies entirely on this codebase's `email_events`
 * ledger, which is the same guarantee that already protected the other
 * providers.
 */
import { AppError } from "./http.ts";

export const BREVO_SEND_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

/** Bounded so a slow provider cannot hold an Edge Function open. */
const BREVO_TIMEOUT_MS = 10_000;

/** How much of an unrecognised provider body may reach the logs. */
const LOG_BODY_MAX = 500;

/**
 * Headers Brevo manages itself. Its `headers` field is documented as being for
 * custom headers, so anything that would collide with a standard one is dropped
 * rather than forwarded.
 */
const FORBIDDEN_HEADERS = new Set([
  "from",
  "sender",
  "to",
  "cc",
  "bcc",
  "subject",
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

export interface BrevoAddress {
  email: string;
  name?: string;
}

export interface BrevoSendArgs {
  from: string;
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  headers?: Record<string, string>;
  /** Ledger-only: Brevo exposes no idempotency header, so this is not sent. */
  idempotencyKey?: string;
}

export interface BrevoPayload {
  sender: BrevoAddress;
  to: BrevoAddress[];
  subject: string;
  textContent?: string;
  htmlContent?: string;
  replyTo?: BrevoAddress;
  headers?: Record<string, string>;
}

/**
 * Splits a `Display Name <local@domain>` value into Brevo's address object.
 *
 * Brevo rejects a sender it has not verified, so the address is passed through
 * exactly as configured: no default is invented here.
 */
export function parseAddress(value: string): BrevoAddress {
  const raw = String(value ?? "").trim();
  const angled = /^(.*?)<([^>]+)>\s*$/.exec(raw);
  if (angled) {
    const name = angled[1].trim().replace(/^"|"$/g, "");
    const email = angled[2].trim();
    return name ? { email, name } : { email };
  }
  return { email: raw };
}

/** Flattens recipients, tolerating a comma-separated string and blank entries. */
export function toRecipients(to: string | string[]): BrevoAddress[] {
  const entries = Array.isArray(to) ? to : [to];
  const recipients: BrevoAddress[] = [];
  for (const entry of entries) {
    for (const part of String(entry ?? "").split(",")) {
      const trimmed = part.trim();
      if (trimmed) recipients.push(parseAddress(trimmed));
    }
  }
  return recipients;
}

/** Drops the headers Brevo reserves for itself. */
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
    console.warn("Brevo reserved headers dropped: %s", dropped.join(", "));
  }
  return Object.keys(kept).length > 0 ? kept : undefined;
}

export function buildBrevoPayload(args: BrevoSendArgs): BrevoPayload {
  const payload: BrevoPayload = {
    sender: parseAddress(args.from),
    to: toRecipients(args.to),
    subject: args.subject,
  };
  // Brevo names the text part `textContent`, not `text`.
  if (args.text) payload.textContent = args.text;
  if (args.html) payload.htmlContent = args.html;
  if (args.replyTo) payload.replyTo = parseAddress(args.replyTo);
  const headers = filterHeaders(args.headers);
  if (headers) payload.headers = headers;
  return payload;
}

interface RawError {
  code?: string;
  message?: string;
  error?: string;
}

/**
 * Brevo answers `{ code, message }` on refusal. The message names the
 * configuration problem (for example an unverified sender) and never echoes the
 * API key, so it is safe to log.
 */
export function describeFailure(response: unknown, raw: string): string {
  const body = response as RawError | null;
  const parts: string[] = [];
  if (body?.code) parts.push(String(body.code));
  if (body?.message) parts.push(String(body.message));
  if (parts.length > 0) return parts.join(": ");
  return raw.slice(0, LOG_BODY_MAX) || "no response body";
}

/**
 * Brevo answers `{ messageId: "<...@smtp-relay...>" }`. Batch sends answer
 * `{ messageIds: [...] }`, so the first entry is used.
 */
export function extractMessageId(response: unknown): string | null {
  const body = response as { messageId?: unknown; messageIds?: unknown } | null;
  const single = body?.messageId;
  if (typeof single === "string" && single.trim().length > 0) return single;
  if (typeof single === "number") return String(single);
  const many = body?.messageIds;
  if (Array.isArray(many) && typeof many[0] === "string" && many[0].trim().length > 0) {
    return many[0];
  }
  return null;
}

export async function sendBrevoMessage(
  args: BrevoSendArgs,
  apiKey: string,
): Promise<{ id: string }> {
  const payload = buildBrevoPayload(args);

  const headers: Record<string, string> = {
    "api-key": apiKey,
    accept: "application/json",
    "content-type": "application/json",
  };

  let response: Response;
  try {
    response = await fetch(BREVO_SEND_ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(BREVO_TIMEOUT_MS),
    });
  } catch (error) {
    // Only the transport error is logged: never the api-key header.
    console.error("Brevo request failed:", error instanceof Error ? error.message : error);
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
    console.error(`Brevo send failed (HTTP ${response.status}):`, describeFailure(parsed, raw));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider rejected the message", 502);
  }

  const id = extractMessageId(parsed);
  if (!id) {
    console.error("Brevo response had no message id:", describeFailure(parsed, raw));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider returned no message id", 502);
  }

  return { id };
}
