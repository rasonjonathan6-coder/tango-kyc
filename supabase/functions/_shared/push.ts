/**
 * Server-side Firebase Cloud Messaging sender (HTTP v1).
 *
 * Only the Edge Function holds the Firebase credentials; the app never does.
 * Credentials come from one of two environment secrets, neither of which is
 * committed:
 *
 *   FIREBASE_SERVICE_ACCOUNT      the full service-account JSON (recommended)
 *   FIREBASE_PROJECT_ID + FIREBASE_CLIENT_EMAIL + FIREBASE_PRIVATE_KEY
 *
 * The recipient is decided here, from `device_tokens.user_id`, which the caller
 * resolves from the ticket owner. A client can never choose who a push is for.
 *
 * The payload is deliberately minimal and non-sensitive: a generic title/body
 * and the opaque `ticket_id` needed to open the right screen. Email content,
 * addresses and the reply body are never placed in a notification.
 */

/** A parsed service account. Kept internal so no credential leaks via exports. */
interface ServiceAccount {
  projectId: string;
  clientEmail: string;
  privateKey: string;
}

export interface PushMessage {
  title: string;
  body: string;
  /** Opaque ticket id; the only datum the notification carries. */
  ticketId?: string | null;
}

export interface PushResult {
  sent: number;
  failed: number;
  /** Tokens FCM reported as permanently invalid; they should be pruned. */
  staleTokens: string[];
}

const ANDROID_CHANNEL_ID = "kyc_replies";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/** Normalises a PEM private key that may arrive with escaped newlines. */
export function normalizePrivateKey(raw: string): string {
  return raw.includes("\\n") ? raw.replace(/\\n/g, "\n") : raw;
}

/**
 * Reads the service account from the environment. Returns null when push is not
 * configured, which callers treat as "no push", never as a hard failure.
 */
export function loadServiceAccount(env: (key: string) => string | undefined): ServiceAccount | null {
  const json = env("FIREBASE_SERVICE_ACCOUNT");
  if (json && json.trim().startsWith("{")) {
    try {
      const parsed = JSON.parse(json) as Record<string, unknown>;
      const projectId = String(parsed.project_id ?? "").trim();
      const clientEmail = String(parsed.client_email ?? "").trim();
      const privateKey = normalizePrivateKey(String(parsed.private_key ?? ""));
      if (projectId && clientEmail && privateKey) {
        return { projectId, clientEmail, privateKey };
      }
    } catch {
      // Fall through to the discrete variables.
    }
  }

  const projectId = (env("FIREBASE_PROJECT_ID") ?? "").trim();
  const clientEmail = (env("FIREBASE_CLIENT_EMAIL") ?? "").trim();
  const rawKey = env("FIREBASE_PRIVATE_KEY") ?? "";
  const privateKey = normalizePrivateKey(rawKey);
  if (projectId && clientEmail && privateKey) {
    return { projectId, clientEmail, privateKey };
  }
  return null;
}

export function pushConfigured(env: (key: string) => string | undefined): boolean {
  return loadServiceAccount(env) !== null;
}

/** The exact FCM HTTP v1 message body. Pure, so it is unit-tested directly. */
export function buildFcmMessage(token: string, message: PushMessage): Record<string, unknown> {
  const data: Record<string, string> = {};
  if (message.ticketId) data.ticket_id = message.ticketId;

  return {
    message: {
      token,
      notification: { title: message.title, body: message.body },
      data,
      android: {
        priority: "HIGH",
        notification: {
          channel_id: ANDROID_CHANNEL_ID,
          sound: "default",
          default_vibrate_timings: true,
          notification_count: 1,
        },
      },
    },
  };
}

/**
 * Classifies an FCM error response. Only `UNREGISTERED` and a 404 mean the token
 * is dead; anything else (quota, transient 5xx) is retried by the next event
 * rather than silently dropping a live device.
 */
export function isStaleTokenError(status: number, body: string): boolean {
  if (status === 404) return true;
  return body.includes("UNREGISTERED") || body.includes("registration-token-not-registered");
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function signJwt(account: ServiceAccount, now: number): Promise<string> {
  const header = base64Url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = base64Url(
    new TextEncoder().encode(
      JSON.stringify({
        iss: account.clientEmail,
        scope: FCM_SCOPE,
        aud: "https://oauth2.googleapis.com/token",
        iat: now,
        exp: now + 3600,
      }),
    ),
  );
  const signingInput = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(account.privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

/** Module-level cache so a burst of pushes shares one access token. */
let cachedToken: { value: string; expiresAt: number } | null = null;

async function accessToken(account: ServiceAccount, now: number): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > now + 60) return cachedToken.value;

  const assertion = await signJwt(account, now);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) {
    throw new Error(`Could not obtain a Firebase access token (HTTP ${response.status})`);
  }
  const payload = (await response.json()) as { access_token?: string; expires_in?: number };
  if (!payload.access_token) throw new Error("Firebase access token response had no token");
  cachedToken = {
    value: payload.access_token,
    expiresAt: now + (payload.expires_in ?? 3600),
  };
  return cachedToken.value;
}

/** Sends one message to one device token. */
export async function sendToToken(
  account: ServiceAccount,
  token: string,
  message: PushMessage,
): Promise<{ ok: boolean; stale: boolean }> {
  const now = Math.floor(Date.now() / 1000);
  const bearer = await accessToken(account, now);
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${account.projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${bearer}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(buildFcmMessage(token, message)),
    },
  );
  if (response.ok) return { ok: true, stale: false };
  const body = await response.text();
  return { ok: false, stale: isStaleTokenError(response.status, body) };
}

/**
 * Sends [message] to every device of [userId].
 *
 * Failure is contained: an unreachable FCM, an unconfigured secret or a stale
 * token never throws, so the inbound-email webhook still acknowledges and the
 * stored reply is preserved. Returns what actually happened, for the response.
 */
export async function sendPushToUser(
  admin: { from: (table: string) => any },
  env: (key: string) => string | undefined,
  userId: string,
  message: PushMessage,
): Promise<PushResult> {
  const result: PushResult = { sent: 0, failed: 0, staleTokens: [] };
  const account = loadServiceAccount(env);
  if (!account) {
    console.warn("Firebase is not configured; no push was sent.");
    return result;
  }

  const { data: tokens, error } = await admin
    .from("device_tokens")
    .select("token")
    .eq("user_id", userId);

  if (error) {
    console.error("Could not load device tokens for %s: %s", userId, error.message);
    return result;
  }

  for (const row of (tokens ?? []) as Array<{ token: string }>) {
    try {
      const outcome = await sendToToken(account, row.token, message);
      if (outcome.ok) {
        result.sent += 1;
      } else {
        result.failed += 1;
        if (outcome.stale) result.staleTokens.push(row.token);
      }
    } catch (error) {
      result.failed += 1;
      console.error(
        "Push to a device of %s failed: %s",
        userId,
        error instanceof Error ? error.message : error,
      );
    }
  }

  // Prune only tokens FCM explicitly declared dead.
  for (const token of result.staleTokens) {
    await admin.from("device_tokens").delete().eq("token", token);
  }

  return result;
}
