/**
 * Svix webhook signature verification.
 *
 * Resend signs webhook deliveries with Svix. The scheme is:
 *   signedContent = `${svix-id}.${svix-timestamp}.${rawBody}`
 *   signature     = base64(HMAC-SHA256(base64Decoded(secret), signedContent))
 * and the `svix-signature` header is a space-separated list of `v1,<sig>`
 * entries. A request must be rejected unless one entry matches and the
 * timestamp is recent, which blocks replay attacks.
 *
 * Docs: https://docs.svix.com/receiving/verifying-payloads/how-manual
 */
import { AppError } from "./http.ts";

const TOLERANCE_SECONDS = 5 * 60;

function base64Decode(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Constant-time comparison so signature checks do not leak timing. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function secretBytes(secret: string): Uint8Array<ArrayBuffer> {
  // Svix secrets are prefixed with `whsec_` and base64 encoded.
  const raw = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  try {
    return base64Decode(raw);
  } catch {
    return new TextEncoder().encode(secret) as Uint8Array<ArrayBuffer>;
  }
}

export interface VerifyArgs {
  rawBody: string;
  svixId: string | null;
  svixTimestamp: string | null;
  svixSignature: string | null;
  secret: string;
  now?: number;
}

/**
 * Returns true when the signature is valid. Throws AppError('INVALID_WEBHOOK')
 * on any verification failure so callers can answer 400 without leaking details.
 */
export async function verifySvixSignature(args: VerifyArgs): Promise<boolean> {
  const { rawBody, svixId, svixTimestamp, svixSignature, secret } = args;

  if (!secret) {
    console.error("Webhook secret is not configured; refusing to trust the request.");
    throw new AppError("INVALID_WEBHOOK", "Webhook secret not configured", 400);
  }
  if (!svixId || !svixTimestamp || !svixSignature) {
    console.error("Webhook is missing Svix headers.");
    throw new AppError("INVALID_WEBHOOK", "Missing signature headers", 400);
  }

  const timestamp = Number(svixTimestamp);
  if (!Number.isFinite(timestamp)) {
    throw new AppError("INVALID_WEBHOOK", "Malformed timestamp", 400);
  }

  const now = args.now ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - timestamp) > TOLERANCE_SECONDS) {
    console.error("Webhook timestamp outside tolerance:", timestamp, now);
    throw new AppError("INVALID_WEBHOOK", "Stale timestamp", 400);
  }

  const signedContent = `${svixId}.${svixTimestamp}.${rawBody}`;
  const key = await crypto.subtle.importKey(
    "raw",
    secretBytes(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedContent) as BufferSource),
  );
  const expected = base64Encode(digest);

  for (const part of svixSignature.split(" ")) {
    const [version, signature] = part.split(",");
    if (version === "v1" && signature && timingSafeEqual(signature, expected)) {
      return true;
    }
  }

  console.error("Webhook signature did not match any provided v1 signature.");
  throw new AppError("INVALID_WEBHOOK", "Signature mismatch", 400);
}
