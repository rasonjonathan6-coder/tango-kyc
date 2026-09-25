/**
 * POST /functions/v1/create-kyc-request
 *
 * Authenticated endpoint that creates a manual KYC verification ticket and
 * notifies the admin by email.
 *
 * The client only ever supplies the profile link and the register value.
 * Ownership, ticket code, status and rate limiting are all decided server side.
 */
import { AppError, errorResponse, handlePreflight, jsonResponse, translateDbError } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/clients.ts";
import {
  adminEmail,
  emailApiKeyConfigured,
  escapeHtml,
  plain,
  replyToAddress,
  sendEmail,
} from "../_shared/email-provider.ts";

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

    // Whether this call created a new ticket or returned an existing duplicate,
    // the admin email is only sent for genuinely new tickets. A deduplicated
    // response within a few seconds of creation means this is the same intent.
    const isFresh = Date.now() - new Date(ticket.created_at).getTime() < 10_000;
    const emailSent = isFresh ? await notifyAdmin(ticket) : false;

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
      email_sent: emailSent,
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

/**
 * Sends the admin notification. Returns false when email is not configured so
 * the caller can be explicit about it rather than pretending it was delivered.
 */
async function notifyAdmin(ticket: Ticket): Promise<boolean> {
  if (!emailApiKeyConfigured()) {
    console.warn(
      "EMAIL_API_KEY is not configured: ticket %s was created but the admin email was NOT sent.",
      ticket.ticket_code,
    );
    return false;
  }

  const registerLine = ticket.register_type === "email"
    ? `Register email: ${plain(ticket.register_value)}`
    : `Register number: ${plain(ticket.register_value)}`;

  const subject =
    `Manual KYC Verification request - Profil Creator (${plain(ticket.tango_profile_link)}) [${ticket.ticket_code}]`;

  const text = [
    "Hello support tango team,",
    "",
    "I am requesting a manual review of my identity verification (KYC).",
    "",
    "I have valid official government documents ready for submission to prove my identity.",
    "",
    "My account information:",
    "",
    `Tango profile ID: ${plain(ticket.tango_profile_link)}`,
    registerLine,
    "",
    "Send me the link for my verification.",
    "",
    "Please restart a manual review of my verification status.",
    "",
    "Thank you.",
    "",
    `Ticket ID: ${ticket.ticket_code}`,
  ].join("\n");

  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.6;color:#1a1a1a">
<p>Hello support tango team,</p>
<p>I am requesting a manual review of my identity verification (KYC).</p>
<p>I have valid official government documents ready for submission to prove my identity.</p>
<p><strong>My account information:</strong></p>
<p>Tango profile ID: ${escapeHtml(ticket.tango_profile_link)}<br>
${ticket.register_type === "email" ? "Register email" : "Register number"}: ${escapeHtml(ticket.register_value)}</p>
<p>Send me the link for my verification.</p>
<p>Please restart a manual review of my verification status.</p>
<p>Thank you.</p>
<hr style="border:none;border-top:1px solid #e5e7eb;margin:20px 0">
<p style="color:#6b7280"><strong>Ticket ID:</strong> ${escapeHtml(ticket.ticket_code)}</p>
</div>`;

  const result = await sendEmail({
    to: adminEmail(),
    subject,
    text,
    html,
    replyTo: replyToAddress(ticket.ticket_code, ticket.reply_token),
    idempotencyKey: `kyc-admin-${ticket.ticket_code}`,
  });

  // Store the outbound provider id so a threaded reply can be matched even when
  // the admin removes the ticket code from the subject.
  const admin = serviceClient();
  const { error } = await admin.rpc("record_outbound_email", {
    p_ticket_id: ticket.id,
    p_provider_message_id: result.id,
  });
  if (error) {
    console.error("Could not record outbound email id for %s: %s", ticket.ticket_code, error.message);
  }

  return true;
}
