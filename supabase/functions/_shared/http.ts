/**
 * Shared HTTP helpers for the Tango KYC Edge Functions.
 *
 * Client-facing errors are always generic: internal details (SQL errors,
 * provider messages, stack traces) are logged server side and never returned.
 */

export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, svix-id, svix-timestamp, svix-signature",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

export class AppError extends Error {
  /** Stable machine code the client can branch on. */
  readonly code: string;
  readonly status: number;
  readonly publicMessage: string;

  constructor(code: string, publicMessage: string, status = 400) {
    super(`${code}: ${publicMessage}`);
    this.name = "AppError";
    this.code = code;
    this.status = status;
    this.publicMessage = publicMessage;
  }
}

/** Maps internal error codes to messages a user is allowed to see. */
const PUBLIC_MESSAGES: Record<string, { message: string; status: number }> = {
  AUTH_REQUIRED: { message: "Please sign in and try again.", status: 401 },
  INVALID_TOKEN: { message: "Your session has expired. Please sign in again.", status: 401 },
  PROFILE_LINK_REQUIRED: { message: "Tango Profile Link is required.", status: 422 },
  PROFILE_LINK_INVALID: { message: "Please enter a valid profile link starting with https://", status: 422 },
  PROFILE_LINK_TOO_LONG: { message: "This profile link is too long.", status: 422 },
  REGISTER_REQUIRED: { message: "Please enter your register email or phone number.", status: 422 },
  REGISTER_EMAIL_INVALID: { message: "Please enter a valid email address.", status: 422 },
  REGISTER_PHONE_INVALID: { message: "Please enter a valid phone number.", status: 422 },
  RATE_LIMITED: { message: "You already sent a request recently. Please wait a few minutes.", status: 429 },
  RATE_LIMITED_DAILY: { message: "You have reached the maximum number of requests for today.", status: 429 },
  FORBIDDEN: { message: "You are not allowed to do that.", status: 403 },
  TICKET_NOT_FOUND: { message: "Request not found.", status: 404 },
  TICKET_CLOSED: { message: "This request is closed and can no longer be replied to.", status: 409 },
  PAYMENT_NOT_CONFIRMED: {
    message: "Your payment must be confirmed before you can reply to this request.",
    status: 409,
  },
  MESSAGE_REQUIRED: { message: "Please write a message.", status: 422 },
  // --- MVola ---------------------------------------------------------------
  PAYMENT_NOT_FOUND: { message: "Payment not found.", status: 404 },
  PAYMENT_ALREADY_REVIEWED: { message: "This payment has already been reviewed.", status: 409 },
  MVOLA_NOT_CONFIGURED: { message: "Mobile Money payment is not available right now.", status: 503 },
  MVOLA_DISABLED: { message: "Mobile Money payment is not available right now.", status: 503 },
  MVOLA_UNAVAILABLE: { message: "Mobile Money payment is not available right now.", status: 503 },
  MVOLA_NOT_REQUIRED: { message: "No payment is required for this request.", status: 409 },
  MVOLA_REFERENCE_REQUIRED: { message: "Please enter your MVola transaction reference.", status: 422 },
  MVOLA_REFERENCE_INVALID: { message: "This transaction reference is not valid.", status: 422 },
  MVOLA_PAYER_INVALID: { message: "Please enter a valid phone number.", status: 422 },
  MVOLA_DECISION_INVALID: { message: "Invalid decision.", status: 422 },
  MVOLA_REASON_REQUIRED: { message: "Please explain why the payment is refused.", status: 422 },
  MVOLA_REASON_INVALID: { message: "This explanation is too long.", status: 422 },
  EMAIL_DELIVERY_FAILED: { message: "We could not send the confirmation email. Please try again.", status: 502 },
  SERVICE_NOT_CONFIGURED: { message: "This service is temporarily unavailable.", status: 503 },
  INVALID_WEBHOOK: { message: "Invalid webhook.", status: 400 },
};

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof AppError) {
    const mapped = PUBLIC_MESSAGES[error.code];
    return jsonResponse(
      {
        error: error.code,
        message: mapped?.message ?? error.publicMessage,
      },
      mapped?.status ?? error.status,
    );
  }

  // Never leak internals: log the real cause, answer generically.
  console.error("Unhandled error:", error instanceof Error ? error.stack ?? error.message : error);
  return jsonResponse(
    { error: "INTERNAL", message: "Something went wrong. Please try again." },
    500,
  );
}

/**
 * Translates a Postgres/PostgREST error raised by our stored functions into an
 * AppError carrying the original internal code.
 */
export function translateDbError(error: { message?: string; code?: string } | null): AppError {
  const raw = error?.message ?? "unknown";
  const known = [
    "AUTH_REQUIRED",
    "PROFILE_LINK_REQUIRED",
    "PROFILE_LINK_INVALID",
    "PROFILE_LINK_TOO_LONG",
    "REGISTER_REQUIRED",
    "REGISTER_EMAIL_INVALID",
    "REGISTER_PHONE_INVALID",
    "RATE_LIMITED_DAILY",
    "RATE_LIMITED",
    "FORBIDDEN",
    "TICKET_NOT_FOUND",
    "TICKET_CLOSED",
    "PAYMENT_NOT_CONFIRMED",
    "MESSAGE_REQUIRED",
    // MVola. Longest first is handled by the loop order below; these are all
    // distinct prefixes so no code shadows another.
    "PAYMENT_ALREADY_REVIEWED",
    "PAYMENT_NOT_FOUND",
    "MVOLA_REFERENCE_REQUIRED",
    "MVOLA_REFERENCE_INVALID",
    "MVOLA_REASON_REQUIRED",
    "MVOLA_REASON_INVALID",
    "MVOLA_DECISION_INVALID",
    "MVOLA_PAYER_INVALID",
    "MVOLA_NOT_CONFIGURED",
    "MVOLA_UNAVAILABLE",
    "MVOLA_DISABLED",
    "MVOLA_NOT_REQUIRED",
  ];
  for (const code of known) {
    if (raw.includes(code)) {
      return new AppError(code, raw);
    }
  }
  console.error("Unmapped database error:", raw);
  return new AppError("INTERNAL", "Something went wrong. Please try again.", 500);
}

export function handlePreflight(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  return null;
}
