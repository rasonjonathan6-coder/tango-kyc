# Email setup (Resend)

The backend sends two kinds of mail and receives one: an admin notification when
a request is created, a short notice to the user when support replies, and the
inbound replies themselves.

## Free-tier limits (checked against Resend's published pricing)

| Limit | Free tier | Consequence here |
| --- | --- | --- |
| Emails per month | 3,000 | Plenty: 2 emails per ticket plus one per reply |
| Emails per day | 100 | The daily request cap (default 5/user) keeps this comfortable |
| Verified domains | 1 | Use the same domain for `EMAIL_FROM` and `EMAIL_INBOUND_DOMAIN` |
| Log retention | 30 days | Fine for debugging; nothing depends on it |
| Inbound email | Included | Required for reply capture |

Resend's inbound webhook delivers **metadata only** — the message body is fetched
with a follow-up API call using `email_id`. The webhook handler does exactly
that, so no configuration is needed for it beyond the API key.

Without a verified domain you can only send from `onboarding@resend.dev` and
only to the Resend account owner's own address. That is enough to smoke-test, but
not to serve real users. Verify a domain before going live.

## 1. Create the API key

1. Sign up at <https://resend.com>.
2. **API Keys → Create API Key**, permission *Sending access*.
3. Put it in your Edge Function secrets as `EMAIL_API_KEY`.

This key is a backend secret. It must never appear in the Flutter app or in a
commit.

## 2. Verify a sending domain

1. **Domains → Add Domain**, then enter a domain you control.
2. Add the DNS records Resend shows (SPF, DKIM, and DMARC if you use it).
3. Wait for verification to go green.

Set:

```
EMAIL_FROM=Tango KYC Verification <notifications@your-domain.com>
```

On the free tier the one verified domain serves both sending and receiving.

## 3. Enable inbound receiving

Resend's receiving feature routes mail sent to your domain back into the API and
raises an `email.received` webhook.

1. **Domains → your domain → Receiving**: enable it. Resend sets the MX records;
   apply them at your DNS provider when prompted.
2. Decide the mailbox. Replies are addressed as
   `<mailbox>+<reply_token>@<domain>` — for example
   `reply+9f2c…@your-domain.com`. The `+<reply_token>` suffix is the whole point:
   it is a 32-hex-character credential that identifies the ticket unambiguously,
   and it is the fallback when a mail client mangles the subject.

   Set:

   ```
   EMAIL_INBOUND_DOMAIN=your-domain.com
   EMAIL_INBOUND_MAILBOX=reply
   ```

   Catch-all routing is what makes this work, so keep the domain's receiving
   configuration as catch-all rather than a fixed set of local parts.

## 4. Register the webhook

1. **Webhooks → Add Webhook**.
2. Endpoint URL:
   `https://<project-ref>.supabase.co/functions/v1/email-webhook`
3. Event: `email.received`.
4. Copy the **Signing Secret** (starts with `whsec_`) into
   `RESEND_WEBHOOK_SECRET`.

Every delivery is verified against this secret using Svix HMAC over the raw
request body, with a timestamp tolerance to reject replays. A request with a
missing, malformed or wrong signature is rejected before any database work
happens — including when the secret is unset, in which case the function refuses
rather than trusting the caller.

## 5. Set the Edge Function secrets

Dashboard → **Project Settings → Edge Functions → Secrets**, or via the CLI:

```bash
supabase secrets set \
  EMAIL_API_KEY=re_xxxxxxxx \
  EMAIL_FROM="Tango KYC Verification <notifications@your-domain.com>" \
  EMAIL_INBOUND_DOMAIN=your-domain.com \
  EMAIL_INBOUND_MAILBOX=reply \
  RESEND_WEBHOOK_SECRET=whsec_xxxxxxxx \
  ADMIN_EMAIL=rasonjonathan6@gmail.com
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically for
functions in the project.

## 6. What the admin receives

Subject, exactly:

```
Manual KYC Verification request - Profil Creator (https://tango.me/user) [TNG-KYC-8F42A91C]
```

The ticket code is appended in square brackets so the required subject text
stays intact while the machine-readable identifier is still present.

Body:

```
Hello support tango team,

I am requesting a manual review of my identity verification (KYC).

I have valid official government documents ready for submission to prove my identity.

My account information:

Tango profile ID: https://tango.me/user
Register email: user@example.com        <-- or "Register number: +261…"

Send me the link for my verification.

Please restart a manual review of my verification status.

Thank you.

Ticket ID: TNG-KYC-8F42A91C
```

`Reply-To` is the tokenised inbound address, so support simply hits Reply and
routing is automatic. `Register email:` and `Register number:` are mutually
exclusive — exactly one line is emitted, matching the value the user actually
provided.

## 7. How a reply is matched

In confidence order, server-side:

1. Ticket code in the subject or body.
2. The `+<reply_token>` recipient address.
3. The recorded provider message id, matched against `In-Reply-To` / `References`.

First match wins. If none match, the reply is quarantined as an
`unmatched_reply`, visible only to admins, and is **not** delivered to any user.
Guessing would risk showing one user another's verification link.

Processing is idempotent. Providers retry, so each delivery is keyed on
`(provider, external_id)`; a replay returns the original message id and is
recorded as a duplicate rather than appending a second message.

## 8. The user notification

Sent only when the ticket's `register_type` is `email`:

```
Your Tango KYC verification request has received a new response.

Ticket ID: TNG-KYC-8F42A91C

Please open the Tango KYC Verification application to view the response.
```

No sensitive content, no verification link — just a pointer to the app, which
requires authentication. A phone-only requester is never assigned an invented
address; their reply appears in the dashboard only.

## 9. Local development

The local Supabase stack runs Mailpit at <http://127.0.0.1:54324>. Every outbound
email is captured there. This works with no Resend account, but it is delivery to
a local inbox — not a claim that real mail was sent.

When `EMAIL_API_KEY` is unset the backend logs an explicit warning and reports
`admin_email_sent: false` (or skips the user notice). It never reports success
for a message it did not send.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Webhook secret is not configured` | `RESEND_WEBHOOK_SECRET` missing; the function refuses to trust the request |
| `Webhook signature did not match` | Wrong secret, or a proxy altered the body before it reached the function |
| 403 from Resend when sending | `EMAIL_FROM` domain not verified, or `onboarding@resend.dev` used to mail a non-owner address |
| Replies never arrive | Receiving not enabled, MX records missing, or the webhook not subscribed to `email.received` |
| Reply stored but no user email | The request was phone-only, or `EMAIL_API_KEY` is unset — check the logs |
