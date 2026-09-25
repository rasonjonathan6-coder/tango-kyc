/**
 * POST /functions/v1/mvola-payments
 *
 * User-facing MVola payment operations. MVola is a *manual* flow: the user
 * transfers money themselves and submits the transaction reference, then an
 * admin verifies it. Nothing here can mark a payment as settled.
 *
 * Actions:
 *   config  - the payer-facing configuration (recipient, amount, USSD, notes)
 *   start   - open, or return, the active payment for one of the caller's tickets
 *   submit  - confirm payment and supply the transaction reference
 *   mine    - the caller's own payments
 *
 * The amount, recipient number and USSD code always come from server-side
 * configuration. The client sends a ticket id and, at most, a reference; it can
 * never propose a price or a status.
 *
 * Ownership is enforced in SQL from `auth.uid()`, so a user cannot act on a
 * ticket or payment belonging to somebody else.
 */
import { AppError, errorResponse, handlePreflight, jsonResponse, translateDbError } from "../_shared/http.ts";
import { requireUser, userClient } from "../_shared/clients.ts";

interface Body {
  action?: string;
  ticket_id?: string;
  payment_id?: string;
  transaction_reference?: unknown;
  payer_number?: unknown;
}

/** Reads an optional string field, rejecting non-strings rather than coercing. */
function optionalString(value: unknown, field: string, maxLength: number): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") {
    throw new AppError(field, "Expected a string value", 422);
  }
  if (value.length > maxLength) {
    throw new AppError(field, "Value too long", 422);
  }
  return value;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    const caller = await requireUser(req);

    let payload: Body;
    try {
      payload = await req.json();
    } catch {
      throw new AppError("INTERNAL", "Malformed JSON body", 422);
    }

    // Runs as the caller so `auth.uid()` resolves and the SQL ownership checks
    // and RLS policies apply to this user rather than to the service role.
    const asUser = userClient(caller.token);

    switch (payload.action) {
      case "config": {
        const { data, error } = await asUser.rpc("mvola_config");
        if (error) throw translateDbError(error);
        return jsonResponse({ config: data });
      }

      case "start": {
        if (!payload.ticket_id) throw new AppError("TICKET_NOT_FOUND", "Missing ticket_id", 422);
        const { data, error } = await asUser.rpc("mvola_start_payment", {
          p_ticket_id: payload.ticket_id,
        });
        if (error) throw translateDbError(error);
        return jsonResponse({ payment: data });
      }

      case "submit": {
        if (!payload.payment_id) throw new AppError("PAYMENT_NOT_FOUND", "Missing payment_id", 422);
        const reference = optionalString(payload.transaction_reference, "MVOLA_REFERENCE_REQUIRED", 128);
        const payer = optionalString(payload.payer_number, "MVOLA_PAYER_INVALID", 64);
        const { data, error } = await asUser.rpc("mvola_submit_payment", {
          p_payment_id: payload.payment_id,
          p_transaction_reference: reference,
          p_payer_number: payer,
        });
        if (error) throw translateDbError(error);
        return jsonResponse({ payment: data });
      }

      case "mine": {
        const { data, error } = await asUser
          .from("mvola_payments")
          .select(
            "id, ticket_id, amount, currency, recipient_number, payer_number, " +
              "transaction_reference, ussd_code, status, rejection_reason, " +
              "created_at, updated_at, submitted_at, reviewed_at",
          )
          .order("created_at", { ascending: false });
        if (error) throw translateDbError(error);
        return jsonResponse({ payments: data ?? [] });
      }

      default:
        throw new AppError("INTERNAL", `Unknown action: ${payload.action ?? "none"}`, 400);
    }
  } catch (error) {
    return errorResponse(error);
  }
});
