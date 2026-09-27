/**
 * POST /functions/v1/create-kyc-request
 *
 * Authenticated endpoint that creates a manual KYC verification ticket.
 *
 * No email is sent from here: the request may still be awaiting payment, and
 * the administration is only notified once an admin approves that payment
 * (see `admin-actions`).
 *
 * The client only ever supplies the profile link and the register value.
 * Ownership, ticket code, status and rate limiting are all decided server side.
 */
import { AppError, errorResponse, handlePreflight, jsonResponse, translateDbError } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/clients.ts";


interface RequestBody {
  tango_profile_link?: unknown;
  register_value?: unknown;
}

/** Last-resort validation so a malformed body is rejected before touching SQL. */
function readString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string") {
    throw new AppError(field, "Expected a string value", 422);
  }
  if (value.length > maxLength) {
    throw new AppError(
      field === "tango_profile_link" ? "PROFILE_LINK_TOO_LONG" : "REGISTER_REQUIRED",
      "Value too long",
      422,
    );
  }
  return value.trim();
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    const user = await requireUser(req);

    let body: RequestBody;
    try {
      body = await req.json();
    } catch {
      throw new AppError("PROFILE_LINK_REQUIRED", "Malformed JSON body", 422);
    }

    const profileLink = readString(body.tango_profile_link, "PROFILE_LINK_REQUIRED", 2048);
    const registerValue = readString(body.register_value, "REGISTER_REQUIRED", 320);

    // The database re-validates everything and enforces rate limits.
    const admin = serviceClient();
    const { data, error } = await admin.rpc("create_kyc_request", {
      p_user_id: user.id,
      p_tango_profile_link: profileLink,
      p_register_value: registerValue,
    });

    if (error) throw translateDbError(error);
    if (!data) throw new AppError("INTERNAL", "Ticket creation returned no row", 500);

    const ticket = data as {
      id: string;
      ticket_code: string;
      tango_profile_link: string;
      register_type: "email" | "phone";
      register_value: string;
      status: string;
      reply_token: string;
      created_at: string;
      last_reply_at: string | null;
    };

    // The administration is deliberately NOT notified here. A new request can
    // still be awaiting payment, and KYC processing mail must not go out until
    // an admin has approved that payment. `admin-actions` sends the request to
    // the admin mailbox at the moment the payment is approved.
    //
    // `duplicated` still reports whether this call reused an existing ticket
    // (the SQL deduplicates an identical re-submission within the window).
    const isFresh = Date.now() - new Date(ticket.created_at).getTime() < 10_000;

    return jsonResponse({
      ticket: {
        id: ticket.id,
        ticket_code: ticket.ticket_code,
        tango_profile_link: ticket.tango_profile_link,
        register_type: ticket.register_type,
        register_value: ticket.register_value,
        status: ticket.status,
        created_at: ticket.created_at,
        last_reply_at: ticket.last_reply_at,
      },
      duplicated: !isFresh,
      email_sent: false,
    }, 201);
  } catch (error) {
    return errorResponse(error);
  }
});

type Ticket = {
  id: string;
  ticket_code: string;
  tango_profile_link: string;
  register_type: "email" | "phone";
  register_value: string;
  reply_token: string;
};
