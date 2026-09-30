/**
 * Gmail API transactional sending (REST over HTTPS 443) - OUTBOUND ONLY.
 *
 * Why the REST API and not SMTP: Supabase Edge Functions run on Deno Deploy,
 * where outbound connections to SMTP ports (25/465/587) are not allowed, and
 * Gmail offers no other SMTP port. The Gmail REST API travels over 443, which
 * is permitted, so it is the only workable transport for this runtime.
 *
 * Inbound replies are untouched: they keep flowing through Resend Inbound and
 * the `email.received` webhook (see ./email-provider.ts). This module only
 * replaces the outbound transport, not the Reply-To wiring.
 *
 * Authentication is OAuth2 `refresh_token` grant. The refresh token is a
 * long-lived credential: it is only ever read from the environment and must
 * never be logged, echoed, or embedded in source.
 *
 * Docs verified against:
 *   https://developers.google.com/identity/protocols/oauth2/web-server
 *   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/send
 */
import { AppError } from "./http.ts";
import { env } from "./clients.ts";

export const GMAIL_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
export const GMAIL_SEND_ENDPOINT =
  "https://gmail.googleapis.com/gmail/v1/users/me/messages/send";

/** Bounded so a slow provider cannot hold an Edge Function open. */
const GMAIL_TIMEOUT_MS = 10_000;

/** How much of an unrecognised provider body may reach the logs. */
const LOG_BODY_MAX = 500;

/** Initial send + one expired-token retry + one throttling backoff. */
const MAX_SEND_ATTEMPTS = 3;

/** Refresh the access token this long before it actually expires. */
const TOKEN_SAFETY_MS = 60_000;

/** Default display name, matching the project's sender identity. */
const DEFAULT_SENDER_NAME = "Tango KYC";

/**
 * Headers the transport sets itself. Supplied values that would collide are
 * dropped rather than allowed to corrupt the message.
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
  "message-id",
  "mime-version",
  "content-type",
  "content-transfer-encoding",
  "date",
  "dkim-signature",
  "received",
]);

export interface GmailCredentials {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
  fromEmail: string;
  senderName: string;
}

export interface GmailSendArgs {
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  headers?: Record<string, string>;
  /**
   * Accepted for signature symmetry with the other transports. Gmail has no
   * native idempotency key, so duplicate suppression remains the `email_events`
   * ledger's job in ./email-provider.ts and is not re-implemented here.
   */
  idempotencyKey?: string;
}

export interface GmailSendDeps {
  /** Injected for tests; defaults to the platform `fetch`. */
  fetchImpl?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  /**
   * Best-effort read-back of the RFC `Message-ID` Gmail actually recorded.
   * Failure is ignored: the locally generated id is then returned instead.
   */
  verifyMessageId?: boolean;
  /** Fixed MIME boundary, for deterministic tests. */
  boundary?: string;
  /** Domain of the generated RFC `Message-ID`. */
  messageIdDomain?: string;
}

/**
 * Reads the Gmail transport configuration from the environment.
 *
 * Returns `null` when any required value is missing, so callers can report a
 * configuration problem instead of failing deep inside a request.
 */
export function gmailCredentialsFromEnv(): GmailCredentials | null {
  const clientId = env("GMAIL_CLIENT_ID");
  const clientSecret = env("GMAIL_CLIENT_SECRET");
  const refreshToken = env("GMAIL_REFRESH_TOKEN");
  const fromEmail = env("GMAIL_FROM_EMAIL");
  if (!clientId || !clientSecret || !refreshToken || !fromEmail) return null;
  return {
    clientId,
    clientSecret,
    refreshToken,
    fromEmail,
    senderName: env("GMAIL_SENDER_NAME") || DEFAULT_SENDER_NAME,
  };
}

/** True when the Gmail transport has everything it needs to send. */
export function gmailConfigured(): boolean {
  return gmailCredentialsFromEnv() !== null;
}

/** Strips CR/LF so a value can never inject an extra header. */
function sanitizeHeader(value: string): string {
  return String(value ?? "").replace(/[\r\n]+/g, " ").trim();
}

/** Encodes a non-ASCII header value as an RFC 2047 encoded word. */
export function encodeHeaderValue(value: string): string {
  const clean = sanitizeHeader(value);
  // Printable ASCII needs no encoding; anything else goes out as UTF-8.
  if (/^[\x20-\x7E]*$/.test(clean)) return clean;
  return `=?UTF-8?B?${bytesToBase64(new TextEncoder().encode(clean))}?=`;
}

/** Formats a display name: bare when safe, quoted or encoded otherwise. */
export function encodeDisplayName(name: string): string {
  const clean = sanitizeHeader(name);
  if (/^[A-Za-z0-9 _.-]+$/.test(clean)) return clean;
  if (/^[\x20-\x7E]*$/.test(clean)) return `"${clean.replace(/"/g, "")}"`;
  return encodeHeaderValue(clean);
}

/** Standard base64 of arbitrary UTF-8 text. */
function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Gmail expects the whole message as base64url without padding. */
export function base64UrlEncode(input: string): string {
  return bytesToBase64(new TextEncoder().encode(input))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/** Base64 body content, wrapped at 76 columns as MIME requires. */
function base64Body(input: string): string {
  const encoded = bytesToBase64(new TextEncoder().encode(input));
  return (encoded.match(/.{1,76}/g) ?? [encoded]).join("\r\n");
}

/** Flattens recipients, tolerating arrays, commas, and blank entries. */
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

/** Drops headers the transport reserves for itself. */
export function filterHeaders(
  headers: Record<string, string> | undefined,
): Record<string, string> {
  if (!headers) return {};
  const kept: Record<string, string> = {};
  const dropped: string[] = [];
  for (const [name, value] of Object.entries(headers)) {
    if (FORBIDDEN_HEADERS.has(name.toLowerCase())) {
      dropped.push(name);
      continue;
    }
    kept[name] = sanitizeHeader(value);
  }
  if (dropped.length > 0) {
    console.warn("Gmail reserved headers dropped: %s", dropped.join(", "));
  }
  return kept;
}

export interface GmailMimeArgs {
  from: string;
  senderName: string;
  to: string[];
  subject: string;
  text: string;
  html?: string;
  replyTo?: string;
  messageId: string;
  headers?: Record<string, string>;
  boundary?: string;
}

/**
 * Builds the RFC 5322 / MIME message Gmail will transmit.
 *
 * A `Message-ID` is always supplied explicitly: Gmail's own id is internal and
 * is not the RFC header, and `resolve_ticket_for_reply` matches on the RFC
 * value, so it has to be known before the send.
 */
export function buildMimeMessage(args: GmailMimeArgs): string {
  const headers: string[] = [
    `From: ${encodeDisplayName(args.senderName)} <${sanitizeHeader(args.from)}>`,
    `To: ${args.to.map(sanitizeHeader).join(", ")}`,
  ];
  if (args.replyTo) headers.push(`Reply-To: ${sanitizeHeader(args.replyTo)}`);
  headers.push(`Subject: ${encodeHeaderValue(args.subject)}`);
  headers.push(`Message-ID: ${sanitizeHeader(args.messageId)}`);
  headers.push("MIME-Version: 1.0");

  for (const [name, value] of Object.entries(filterHeaders(args.headers))) {
    headers.push(`${name}: ${value}`);
  }

  const boundary = args.boundary ?? `tng-${crypto.randomUUID()}`;

  if (!args.html) {
    headers.push('Content-Type: text/plain; charset="UTF-8"');
    headers.push("Content-Transfer-Encoding: base64");
    return `${headers.join("\r\n")}\r\n\r\n${base64Body(args.text)}`;
  }

  headers.push(`Content-Type: multipart/alternative; boundary="${boundary}"`);

  const parts = [
    `--${boundary}`,
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    base64Body(args.text),
    `--${boundary}`,
    'Content-Type: text/html; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    base64Body(args.html),
    `--${boundary}--`,
  ];

  return `${headers.join("\r\n")}\r\n\r\n${parts.join("\r\n")}`;
}

/** Safe rendering of a Google error body: no credentials are ever included. */
export function describeGoogleFailure(response: unknown, raw: string): string {
  const root = response as
    | { error?: unknown; error_description?: unknown }
    | null;
  const error = root?.error;
  const parts: string[] = [];

  if (typeof error === "string") parts.push(error);
  if (error && typeof error === "object") {
    const inner = error as { status?: unknown; message?: unknown };
    if (inner.status) parts.push(String(inner.status));
    if (inner.message) parts.push(String(inner.message));
  }
  if (root?.error_description) parts.push(String(root.error_description));

  if (parts.length > 0) return parts.join(": ").slice(0, LOG_BODY_MAX);
  return raw.slice(0, LOG_BODY_MAX) || "no response body";
}

/** Normalises a `Message-ID` header value to the bracketed form. */
export function normalizeMessageId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.startsWith("<") && trimmed.endsWith(">")) return trimmed;
  return `<${trimmed.replace(/^<+|>+$/g, "")}>`;
}

let cachedAccessToken: string | null = null;
let cachedTokenExpiry = 0;

/** Clears the in-memory access-token cache. Intended for tests. */
export function resetGmailTokenCache(): void {
  cachedAccessToken = null;
  cachedTokenExpiry = 0;
}

/** Exchanges the refresh token for a short-lived access token. */
export async function fetchGmailAccessToken(
  creds: GmailCredentials,
  fetchImpl: typeof fetch,
  now: () => number = Date.now,
): Promise<{ accessToken: string; expiresAt: number }> {
  const body = new URLSearchParams({
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    refresh_token: creds.refreshToken,
    grant_type: "refresh_token",
  });

  let response: Response;
  try {
    response = await fetchImpl(GMAIL_TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
      signal: AbortSignal.timeout(GMAIL_TIMEOUT_MS),
    });
  } catch (error) {
    // Only the transport message is logged; never the request body.
    console.error(
      "Gmail OAuth request failed:",
      error instanceof Error ? error.message : error,
    );
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
    const described = describeGoogleFailure(parsed, raw);
    console.error(`Gmail OAuth token request failed (HTTP ${response.status}):`, described);
    const code = (parsed as { error?: unknown } | null)?.error;
    if (code === "invalid_grant") {
      // The refresh token was revoked or is wrong: a configuration problem,
      // not a transient delivery failure.
      throw new AppError(
        "SERVICE_NOT_CONFIGURED",
        "Gmail refresh token is invalid or revoked",
        503,
      );
    }
    throw new AppError("EMAIL_DELIVERY_FAILED", "Gmail authentication failed", 502);
  }

  const accessToken = (parsed as { access_token?: unknown } | null)?.access_token;
  const expiresIn = Number((parsed as { expires_in?: unknown } | null)?.expires_in ?? 3600);
  if (typeof accessToken !== "string" || accessToken.trim().length === 0) {
    console.error(
      "Gmail OAuth response had no access token:",
      describeGoogleFailure(parsed, raw),
    );
    throw new AppError("EMAIL_DELIVERY_FAILED", "Gmail authentication response was invalid", 502);
  }

  const ttlMs = Number.isFinite(expiresIn) && expiresIn > 0 ? expiresIn * 1000 : 3_600_000;
  return { accessToken, expiresAt: now() + ttlMs };
}

/**
 * Returns a usable access token, reusing the cached one until it nears expiry.
 * `force` skips the cache, for the retry after a 401.
 */
export async function getGmailAccessToken(
  creds: GmailCredentials,
  fetchImpl: typeof fetch,
  opts: { force?: boolean; now?: () => number } = {},
): Promise<string> {
  const now = opts.now ?? Date.now;
  if (!opts.force && cachedAccessToken && now() < cachedTokenExpiry) {
    return cachedAccessToken;
  }
  const { accessToken, expiresAt } = await fetchGmailAccessToken(creds, fetchImpl, now);
  cachedAccessToken = accessToken;
  cachedTokenExpiry = expiresAt - TOKEN_SAFETY_MS;
  return accessToken;
}

/**
 * Reads back the `Message-ID` Gmail actually recorded for a sent message.
 *
 * Best effort: any failure returns `null` and the caller keeps the locally
 * generated id. The access token is never logged.
 */
export async function fetchGmailMessageId(
  gmailId: string,
  accessToken: string,
  fetchImpl: typeof fetch,
): Promise<string | null> {
  const url =
    `https://gmail.googleapis.com/gmail/v1/users/me/messages/${encodeURIComponent(gmailId)}` +
    "?format=metadata&metadataHeaders=Message-ID";
  try {
    const response = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
      signal: AbortSignal.timeout(GMAIL_TIMEOUT_MS),
    });
    if (!response.ok) {
      await response.text();
      return null;
    }
    const parsed = JSON.parse(await response.text()) as {
      payload?: { headers?: Array<{ name?: string; value?: string }> };
    };
    const header = parsed?.payload?.headers?.find(
      (h) => String(h?.name ?? "").toLowerCase() === "message-id",
    );
    return normalizeMessageId(header?.value);
  } catch {
    return null;
  }
}

/** Bounded exponential backoff for throttling and transient 5xx. */
function backoffMs(attempt: number): number {
  return Math.min(2_000, 250 * 2 ** (attempt - 1));
}

/**
 * Sends one message through the Gmail API.
 *
 * Returns the RFC `Message-ID` (not Gmail's internal id), because that is what
 * the inbound reply resolver matches against. Duplicate suppression is not
 * handled here: it lives in the `email_events` ledger in ./email-provider.ts.
 */
export async function sendGmailMessage(
  args: GmailSendArgs,
  creds: GmailCredentials,
  deps: GmailSendDeps = {},
): Promise<{ id: string }> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const verify = deps.verifyMessageId ?? true;

  if (!creds.clientId || !creds.clientSecret || !creds.refreshToken || !creds.fromEmail) {
    console.error("Gmail transport is missing required configuration");
    throw new AppError("SERVICE_NOT_CONFIGURED", "Gmail transport is not configured", 503);
  }

  const recipients = toRecipients(args.to);
  if (recipients.length === 0) {
    throw new AppError("EMAIL_DELIVERY_FAILED", "No recipient address was provided", 502);
  }

  const messageId = `<tng-${crypto.randomUUID()}@${deps.messageIdDomain ?? "tango-kyc.local"}>`;
  const raw = base64UrlEncode(
    buildMimeMessage({
      from: creds.fromEmail,
      senderName: creds.senderName,
      to: recipients,
      subject: args.subject,
      text: args.text,
      html: args.html,
      replyTo: args.replyTo,
      messageId,
      headers: args.headers,
      boundary: deps.boundary,
    }),
  );

  let forceRefresh = false;
  let lastError: AppError | null = null;

  for (let attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++) {
    const wantForce = forceRefresh;
    forceRefresh = false;

    const accessToken = await getGmailAccessToken(creds, fetchImpl, { force: wantForce, now });

    let response: Response;
    try {
      response = await fetchImpl(GMAIL_SEND_ENDPOINT, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ raw }),
        signal: AbortSignal.timeout(GMAIL_TIMEOUT_MS),
      });
    } catch (error) {
      console.error(
        "Gmail send request failed:",
        error instanceof Error ? error.message : error,
      );
      lastError = new AppError("EMAIL_DELIVERY_FAILED", "Email provider unreachable", 502);
      if (attempt < MAX_SEND_ATTEMPTS) {
        await sleep(backoffMs(attempt));
        continue;
      }
      throw lastError;
    }

    const body = await response.text();
    let parsed: unknown = null;
    try {
      parsed = JSON.parse(body);
    } catch {
      parsed = null;
    }

    if (response.ok) {
      const gmailId = (parsed as { id?: unknown } | null)?.id;
      if (typeof gmailId !== "string" || gmailId.trim().length === 0) {
        console.error("Gmail response had no message id:", describeGoogleFailure(parsed, body));
        throw new AppError(
          "EMAIL_DELIVERY_FAILED",
          "Email provider returned no message id",
          502,
        );
      }

      let finalId = messageId;
      if (verify) {
        const confirmed = await fetchGmailMessageId(gmailId.trim(), accessToken, fetchImpl);
        if (confirmed) finalId = confirmed;
      }
      return { id: finalId };
    }

    console.error(
      `Gmail send failed (HTTP ${response.status}):`,
      describeGoogleFailure(parsed, body),
    );

    if (response.status === 401 && attempt < MAX_SEND_ATTEMPTS) {
      forceRefresh = true;
      continue;
    }
    if ((response.status === 429 || response.status >= 500) && attempt < MAX_SEND_ATTEMPTS) {
      await sleep(backoffMs(attempt));
      continue;
    }

    throw new AppError("EMAIL_DELIVERY_FAILED", "Email provider rejected the message", 502);
  }

  throw lastError ?? new AppError("EMAIL_DELIVERY_FAILED", "Email send failed", 502);
}
