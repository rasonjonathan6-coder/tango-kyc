/**
 * POST /functions/v1/admin-actions
 *
 * Admin-only operations for the dashboard. The admin role is checked twice:
 * once here from the server-owned profile row, and again inside the SQL
 * function, so a compromised client cannot bypass it.
 */
import { AppError, errorResponse, handlePreflight, jsonResponse, translateDbError } from "../_shared/http.ts";
import { requireAdmin, serviceClient, userClient } from "../_shared/clients.ts";
import {
  emailSendingConfigured,
  sendAdminRequestNotification,
  sendEmail,
  ticketPaymentApproved,
  userReplyRecipient,
} from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

const STATUSES = ["pending", "in_review", "replied", "closed"] as const;
type Status = (typeof STATUSES)[number];

interface Body {
  action?: string;
  ticket_id?: string;
  status?: string;
  body?: string;
  /** Quarantine row id, for `resolve_unmatched`. */
  unmatched_id?: string;
  reason?: string;
  /** MVola payment id, for `mvola_decision`. */
  payment_id?: string;
  /** "approved" | "rejected", for `mvola_decision`. */
  decision?: string;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    const caller = await requireAdmin(req);

    let payload: Body;
    try {
      payload = await req.json();
    } catch {
      throw new AppError("INTERNAL", "Malformed JSON body", 422);
    }

    // Admin functions assert `public.is_admin()`, which reads auth.uid(). They
    // must therefore run with the caller's own token rather than the service
    // key, so the admin check is enforced by the database, not just here.
    const asAdmin = userClient(caller.token);

    switch (payload.action) {
      case "stats": {
        const { data, error } = await asAdmin.rpc("admin_stats");
        if (error) throw translateDbError(error);
        return jsonResponse({ stats: data });
      }

      case "list": {
        const { data, error } = await asAdmin.rpc("admin_ticket_list");
        if (error) throw translateDbError(error);
        const { data: unmatched, error: unmatchedError } = await asAdmin
          .from("unmatched_replies")
          .select("*")
          .is("resolved_at", null)
          .order("created_at", { ascending: false });
        if (unmatchedError) console.error("unmatched_replies read failed:", unmatchedError.message);
        return jsonResponse({ tickets: data ?? [], unmatched: unmatched ?? [] });
      }

      case "set_status": {
        if (!payload.ticket_id) throw new AppError("TICKET_NOT_FOUND", "Missing ticket_id", 422);
        if (!payload.status || !STATUSES.includes(payload.status as Status)) {
          throw new AppError("INTERNAL", "Invalid status", 422);
        }
        const { data, error } = await asAdmin.rpc("admin_set_status", {
          p_ticket_id: payload.ticket_id,
          p_status: payload.status,
        });
        if (error) throw translateDbError(error);
        return jsonResponse({ ticket: data });
      }

      case "post_message": {
        if (!payload.ticket_id) throw new AppError("TICKET_NOT_FOUND", "Missing ticket_id", 422);
        const message = (payload.body ?? "").trim();
        if (!message) throw new AppError("MESSAGE_REQUIRED", "Empty message", 422);
        if (message.length > 20000) throw new AppError("INTERNAL", "Message too long", 422);

        const { data, error } = await asAdmin.rpc("admin_post_message", {
          p_ticket_id: payload.ticket_id,
          p_body: message,
        });
        if (error) throw translateDbError(error);

        const notified = await notifyOwner(payload.ticket_id);
        return jsonResponse({ message: data, user_notified: notified });
      }

      case "messages": {
        if (!payload.ticket_id) throw new AppError("TICKET_NOT_FOUND", "Missing ticket_id", 422);
        const { data, error } = await asAdmin
          .from("messages")
          .select("id, ticket_id, sender_type, body, external_message_id, created_at")
          .eq("ticket_id", payload.ticket_id)
          .order("created_at", { ascending: true });
        if (error) throw translateDbError(error);
        return jsonResponse({ messages: data ?? [] });
      }

      case "resolve_unmatched": {
        if (!payload.unmatched_id) throw new AppError("TICKET_NOT_FOUND", "Missing unmatched id", 422);
        if (!payload.ticket_id) throw new AppError("TICKET_NOT_FOUND", "Missing ticket_id", 422);

        const { data, error } = await asAdmin.rpc("admin_resolve_unmatched_reply", {
          p_unmatched_id: payload.unmatched_id,
          p_ticket_id: payload.ticket_id,
        });
        if (error) {
          if (error.message?.includes("UNMATCHED_NOT_FOUND")) {
            throw new AppError("TICKET_NOT_FOUND", "Unknown quarantine entry", 404);
          }
          throw translateDbError(error);
        }

        const notified = await notifyOwner(payload.ticket_id);
        return jsonResponse({ resolved: data, user_notified: notified });
      }

      // --- MVola ---------------------------------------------------------
      // The admin role was already verified by requireAdmin above, and the SQL
      // functions assert public.is_admin() again, so a non-admin token cannot
      // reach a decision even if it got past this switch.
      case "mvola_list": {
        const { data, error } = await asAdmin.rpc("admin_mvola_list");
        if (error) throw translateDbError(error);
        return jsonResponse({ payments: data ?? [] });
      }

      case "mvola_decision": {
        if (!payload.payment_id) throw new AppError("PAYMENT_NOT_FOUND", "Missing payment_id", 422);
        if (payload.decision !== "approved" && payload.decision !== "rejected") {
          throw new AppError("MVOLA_DECISION_INVALID", "Invalid decision", 422);
        }
        const reason = (payload.reason ?? "").trim();
        if (reason.length > 500) throw new AppError("MVOLA_REASON_INVALID", "Reason too long", 422);

        const { data, error } = await asAdmin.rpc("admin_mvola_set_decision", {
          p_payment_id: payload.payment_id,
          p_decision: payload.decision,
          p_reason: reason || null,
        });
        if (error) throw translateDbError(error);

        // An approval is the moment the request becomes authorised for KYC
        // processing, so this is where the administration is finally notified.
        // A rejection sends nothing.
        let adminNotified = false;
        if (payload.decision === "approved") {
          adminNotified = await notifyAdminOfApprovedRequest(data.ticket_id as string);
        }

        return jsonResponse({ payment: data, admin_notified: adminNotified });
      }

      default:
        throw new AppError("INTERNAL", `Unknown action: ${payload.action ?? "none"}`, 400);
    }
  } catch (error) {
    return errorResponse(error);
  }
});

/**
 * Sends the approved request to the administration mailbox.
 *
 * Called only after an admin approved the payment. The approval is re-read from
 * the database rather than trusted from the request, so the email gate cannot be
 * bypassed by a caller that merely claims the payment was approved.
 */
async function notifyAdminOfApprovedRequest(ticketId: string): Promise<boolean> {
  const admin = serviceClient();

  if (!await ticketPaymentApproved(ticketId)) {
    console.warn("KYC request for ticket %s is not payment-approved; no email sent.", ticketId);
    return false;
  }

  const { data: ticket, error } = await admin
    .from("kyc_requests")
    .select("id, ticket_code, tango_profile_link, register_type, register_value, reply_token")
    .eq("id", ticketId)
    .maybeSingle();

  if (error || !ticket) {
    console.error("Could not load ticket %s for admin notification: %s", ticketId, error?.message);
    return false;
  }

  try {
    return await sendAdminRequestNotification(ticket as TicketForAdminNotification);
  } catch (error) {
    // The payment decision is already committed, so a failed notification must
    // not fail the admin's action: reporting 502 here would tell the admin the
    // approval did not happen when it did. The failure is surfaced as
    // `admin_notified: false` instead.
    console.error(
      "Could not notify the admin for ticket %s: %s",
      ticket.ticket_code,
      error instanceof Error ? error.message : error,
    );
    return false;
  }
}

/**
 * Emails the ticket owner when an admin posts a reply.
 *
 * The recipient is `kyc_requests.register_value` — the Tango registration email
 * the user supplied in the KYC form (`tango_registration_email`), and the address
 * the external company was told about. It is deliberately NOT `profiles.email`,
 * which is only the account/login address for this application.
 *
 * A phone-only requester is never sent mail: `register_value` also accepts a
 * phone number, and no address is invented from it.
 */
async function notifyOwner(ticketId: string): Promise<boolean> {
  const admin = serviceClient();
  const { data: ticket, error } = await admin
    .from("kyc_requests")
    .select("ticket_code, register_type, register_value")
    .eq("id", ticketId)
    .maybeSingle();

  if (error || !ticket) {
    console.error("Could not load ticket %s for owner notification: %s", ticketId, error?.message);
    return false;
  }

  const { recipient, reason } = userReplyRecipient(ticket);
  if (!recipient) {
    console.warn(
      "Ticket %s: %s; the owner was not emailed.",
      ticket.ticket_code,
      reason,
    );
    return false;
  }

  if (!emailSendingConfigured()) {
    console.warn("Resend is not configured: owner of %s was not emailed.", ticket.ticket_code);
    return false;
  }

  try {
    await sendEmail({
      to: recipient,
      subject: `Tango KYC Verification - new response for ${ticket.ticket_code}`,
      text: [
        "Your Tango KYC verification request has received a new response.",
        "",
        `Ticket ID: ${ticket.ticket_code}`,
        "",
        "Please open the Tango KYC Verification application to view the response.",
      ].join("\n"),
      idempotencyKey: `kyc-user-reply-${ticket.ticket_code}-${recipient}`,
    });
  } catch (error) {
    // The reply is already stored and visible in the dashboard, so a failed
    // notification must not fail the admin's action. It is reported instead.
    console.error(
      "Could not notify the owner of %s: %s",
      ticket.ticket_code,
      error instanceof Error ? error.message : error,
    );
    return false;
  }

  return true;
}
