/**
 * Mailjet transactional sending (Send API v3.1) - OUTBOUND ONLY.
 *
 * Inbound replies are still received through Resend; see `fetchReceivedEmail`
 * in ./email-provider.ts. Nothing here touches the inbound path.
 *
 * Docs verified against:
 *   https://dev.mailjet.com/docs/email-api/send-api-v31/send-basic-email
 *   https://dev.mailjet.com/docs/email-api/send-api-v31/send-api-errors
 *   https://dev.mailjet.com/docs/email-api/send-api-v31/add-email-headers
 *
 * Authentication is HTTP Basic with the API key as username and the secret key
 * as password. Mailjet offers no idempotency-key facility, so a caller's
 * idempotency key travels as `CustomID` for correlation only; duplicate
 * suppression remains a database concern.
 */
import { AppError } from "./http.ts";

export const MAILJET_SEND_ENDPOINT = "https://api.mailjet.com/v3.1/send";

/** Bounded so a slow provider cannot hold an Edge Function open. */
const MAILJET_TIMEOUT_MS = 10_000;

/** Mailjet caps `CustomID` at 255 characters. */
const CUSTOM_ID_MAX = 255;

/** How much of an unrecognised provider body may reach the logs. */
const LOG_BODY_MAX = 500;

/**
 * Headers Mailjet refuses because the API sets them itself. Passing one would
 * fail the whole message, so they are dropped rather than forwarded.
 */
const FORBIDDEN_HEADERS = new Set([
  "from",
  "sender",
  "subject",
  "to",
  "cc",
  "bcc",
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
  "x-mailjet-prio",
  "x-mailjet-debug",
  "x-mj-customid",
  "x-mj-eventpayload",
  "x-mj-vars",
]);

export interface MailjetAddress {
  Email: string;
  Name?: string;
}

export interface MailjetMessage {
  From: MailjetAddress;
  To: MailjetAddress[];
  Subject: string;
  TextPart?: string;
  HTMLPart?: string;
  ReplyTo?: MailjetAddress;
  Headers?: Record<string, string>;
  CustomID?: string;
}

export interface MailjetPayload {
  Messages: MailjetMessage[];
}

export interface MailjetCredentials {
  apiKey: string;
  secretKey: string;
}

export interface MailjetSendArgs {
  from: string;
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  headers?: Record<string, string>;
  /** Correlation id; Mailjet does not enforce it as an idempotency key. */
  customId?: string;
}

/**
 * Splits `Display Name <user@example.com>`, `<user@example.com>` or a bare
 * address into Mailjet's `{ Email, Name }` shape.
 */
export function parseAddress(value: string): MailjetAddress {
  const trimmed = (value ?? "").trim();
  const angled = /^(.*?)\s*<([^>]+)>\s*$/.exec(trimmed);
  if (angled) {
    const name = angled[1].replace(/^"(.*)"$/, "$1").trim();
    const email = angled[2].trim();
    return name ? { Email: email, Name: name } : { Email: email };
  }
  return { Email: trimmed };
}

/** Flattens recipients, tolerating a comma-separated string and blank entries. */
export function toRecipients(to: string | string[]): MailjetAddress[] {
  const entries = Array.isArray(to) ? to : [to];
  const recipients: MailjetAddress[] = [];
  for (const entry of entries) {
    for (const part of String(entry ?? "").split(",")) {
      const address = parseAddress(part);
      if (address.Email) recipients.push(address);
    }
  }
  return recipients;
}

/** Drops the headers Mailjet reserves for itself. */
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
    console.warn("Mailjet reserved headers dropped: %s", dropped.join(", "));
  }
  return Object.keys(kept).length > 0 ? kept : undefined;
}

export function buildMailjetMessage(args: MailjetSendArgs): MailjetMessage {
  const message: MailjetMessage = {
    From: parseAddress(args.from),
    To: toRecipients(args.to),
    Subject: args.subject,
    TextPart: args.text,
  };
  if (args.html) message.HTMLPart = args.html;
  if (args.replyTo) message.ReplyTo = parseAddress(args.replyTo);
  const headers = filterHeaders(args.headers);
  if (headers) message.Headers = headers;
  if (args.customId) message.CustomID = args.customId.slice(0, CUSTOM_ID_MAX);
  return message;
}

export function buildMailjetPayload(args: MailjetSendArgs): MailjetPayload {
  return { Messages: [buildMailjetMessage(args)] };
}

/** Basic auth header value. Must never be logged. */
export function basicAuthHeader(apiKey: string, secretKey: string): string {
  return `Basic ${btoa(`${apiKey}:${secretKey}`)}`;
}

interface RawMessage {
  Status?: string;
  Errors?: Array<{ ErrorCode?: string; StatusCode?: number; ErrorMessage?: string }>;
  To?: Array<{ MessageUUID?: string; MessageID?: number | string }>;
  Cc?: Array<{ MessageUUID?: string; MessageID?: number | string }>;
  Bcc?: Array<{ MessageUUID?: string; MessageID?: number | string }>;
}

function rawMessages(response: unknown): RawMessage[] {
  const messages = (response as { Messages?: unknown } | null)?.Messages;
  return Array.isArray(messages) ? (messages as RawMessage[]) : [];
}

/**
 * Mailjet answers HTTP 200 even when it refused a message, so the per-message
 * `Status` is the real outcome and must be inspected.
 */
export function extractErrors(response: unknown): string[] {
  const errors: string[] = [];
  for (const message of rawMessages(response)) {
    if (message.Status !== "error") continue;
    if (!Array.isArray(message.Errors) || message.Errors.length === 0) {
      errors.push("unspecified Mailjet error");
      continue;
    }
    for (const error of message.Errors) {
      const code = error?.ErrorCode ?? error?.StatusCode ?? "error";
      errors.push(`${code}: ${error?.ErrorMessage ?? "no message"}`);
    }
  }
  return errors;
}

/**
 * Returns the provider message id used for reply threading. `MessageUUID` is
 * preferred; `MessageID` is the legacy numeric id.
 */
export function extractMessageId(response: unknown): string | null {
  for (const message of rawMessages(response)) {
    if (message.Status !== "success") continue;
    for (const group of [message.To, message.Cc, message.Bcc]) {
      if (!Array.isArray(group)) continue;
      for (const recipient of group) {
        if (recipient?.MessageUUID) return String(recipient.MessageUUID);
        if (recipient?.MessageID !== undefined && recipient?.MessageID !== null) {
          return String(recipient.MessageID);
        }
      }
    }
  }
  return null;
}

/**
 * Builds a log-safe description of a failure. Provider error bodies never
 * contain our credentials, but the payload is still bounded.
 */
export function describeFailure(response: unknown, raw: string): string {
  const errors = extractErrors(response);
  if (errors.length > 0) return errors.join("; ");
  return raw.slice(0, LOG_BODY_MAX);
}

/**
 * Sends one transactional message. Throws an `AppError` the HTTP layer already
 * maps to a generic, non-leaking client message.
 */
export async function sendMailjetMessage(
  args: MailjetSendArgs,
  credentials: MailjetCredentials,
): Promise<{ id: string }> {
  const payload = buildMailjetPayload(args);
  const authorization = basicAuthHeader(credentials.apiKey, credentials.secretKey);

  let response: Response;
  try {
    response = await fetch(MAILJET_SEND_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: authorization,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(MAILJET_TIMEOUT_MS),
    });
  } catch (error) {
    // Only the transport error is logged: never the Authorization header.
    console.error("Mailjet request failed:", error instanceof Error ? error.message : error);
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
    console.error(`Mailjet send failed (HTTP ${response.status}):`, describeFailure(parsed, raw));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider rejected the message", 502);
  }

  const errors = extractErrors(parsed);
  if (errors.length > 0) {
    console.error("Mailjet refused the message:", errors.join("; "));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider rejected the message", 502);
  }

  const id = extractMessageId(parsed);
  if (!id) {
    console.error("Mailjet response had no message id:", describeFailure(parsed, raw));
    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider returned no message id", 502);
  }

  return { id };
}
