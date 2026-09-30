/**
 * POST /functions/v1/reply-to-ticket
 *
 * The authenticated user's reply on their own ticket. This is the in-app
 * counterpart of an inbound email reply: both end up as a `user` row in
 * `public.messages` on the same ticket.
 *
 * It adds no message storage of its own. It calls `public.user_post_message`,
 * which is the single write path for a user reply and now enforces, in the
 * database, that the caller owns the ticket and that the ticket is not closed.
 * Keeping the rule there means this endpoint cannot be bypassed by calling the
 * RPC directly, and a closed ticket is read-only however the request arrives.
 */
import { AppError, errorResponse, handlePreflight, jsonResponse, translateDbError } from "../_shared/http.ts";
import { requireUser, serviceClient, userClient } from "../_shared/clients.ts";
import { sendUserMessageToSupport } from "../_shared/email-provider.ts";
import type { TicketForAdminNotification } from "../_shared/email-provider.ts";

interface Body {
  ticket_id?: unknown;
  body?: unknown;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    // Verifies the access token and rejects an anonymous caller before SQL.
    const caller = await requireUser(req);

    let payload: Body;
    try {
      payload = await req.json();
    } catch {
      throw new AppError("MESSAGE_REQUIRED", "Malformed JSON body", 422);
    }

    const ticketId = typeof payload.ticket_id === "string" ? payload.ticket_id.trim() : "";
    if (!ticketId) throw new AppError("TICKET_NOT_FOUND", "Missing ticket_id", 422);

    const message = typeof payload.body === "string" ? payload.body.trim() : "";
    if (!message) throw new AppError("MESSAGE_REQUIRED", "Empty message", 422);
    if (message.length > 20000) throw new AppError("MESSAGE_REQUIRED", "Message too long", 422);

    // Runs as the caller, not as the service role: `user_post_message` derives
    // the author from `auth.uid()`, and that is null for a service_role client,
    // so the ownership and closed-ticket checks must see the real user.
    const asUser = userClient(caller.token);
    const { data, error } = await asUser.rpc("user_post_message", {
      p_ticket_id: ticketId,
      p_body: message,
    });
    if (error) throw translateDbError(error);

    // The message is stored. Notify the société so the conversation continues by
    // email; the reply is already persisted and visible, so a mail failure is
    // reported rather than failing the user's action.
    let supportNotified = false;
    try {
      const admin = serviceClient();
      const { data: ticket } = await admin
        .from("kyc_requests")
        .select("id, ticket_code, tango_profile_link, register_type, register_value, reply_token")
        .eq("id", ticketId)
        .maybeSingle();
      if (ticket) {
        const storedId = (data as { id?: string } | null)?.id;
        if (storedId) {
          supportNotified = await sendUserMessageToSupport(
            ticket as TicketForAdminNotification,
            message,
            storedId,
          );
        }
      }
    } catch (notifyError) {
      console.error(
        "Could not notify support for ticket %s: %s",
        ticketId,
        notifyError instanceof Error ? notifyError.message : notifyError,
      );
    }

    return jsonResponse({ message: data, support_notified: supportNotified }, 201);
  } catch (error) {
    return errorResponse(error);
  }
});
