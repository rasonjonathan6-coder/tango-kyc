import { filterHeaders } from "./supabase/functions/_shared/gmail-outbound.ts";
import { buildResendPayload } from "./supabase/functions/_shared/resend-outbound.ts";

const headers = {
  "In-Reply-To": "<parent@tango-kyc.local>",
  "References": "<parent@tango-kyc.local>",
};

const kept = filterHeaders(headers);
console.log("GMAIL kept:", JSON.stringify(kept));

const payload = buildResendPayload({
  from: "Tango KYC <no-reply@tango-kyc.local>",
  to: ["tangoturq@gmail.com"],
  subject: "Nouveau message d'un utilisateur - vérification de compte",
  text: "x",
  headers,
});
console.log("RESEND headers:", JSON.stringify((payload as { headers?: unknown }).headers));
