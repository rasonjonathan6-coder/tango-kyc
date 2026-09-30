# Email setup (Mailjet outbound, Resend inbound)

Two providers, split by direction:

| Direction | Provider | Purpose |
| --- | --- | --- |
| Outbound | **Mailjet** (Send API v3.1) | Admin notification on ticket creation, user notice when support replies |
| Inbound | **Resend** (`email.received` webhook) | Receives the support reply and resolves it back to a ticket |

Mailjet sends the mail, but the `Reply-To` still points at the Resend inbound
address, so replies keep flowing through the existing webhook and the ticket
association is unchanged.

## Free-tier limits

| Provider | Limit | Free tier | Consequence here |
| --- | --- | --- | --- |
| Mailjet | Emails per day | 200 | Plenty: 2 emails per ticket plus one per reply |
| Mailjet | Contacts | 1,500 | Irrelevant: transactional sending does not need contact lists |
| Resend | Emails per month | 3,000 | Inbound only now, so effectively unused |
| Resend | Inbound email | Included | Required for reply capture |
| Resend | Verified domains | 1 | Used for `EMAIL_INBOUND_DOMAIN` |

Resend's inbound webhook delivers **metadata only** — the message body is fetched
with a follow-up API call using `email_id`. The webhook handler does exactly
that, so no configuration is needed for it beyond `EMAIL_API_KEY`.

## 1. Create the Mailjet keys (outbound)

1. Sign up at <https://app.mailjet.com>.
2. **Account → API Key Management** (<https://app.mailjet.com/account/apikeys>).
   A *Send-only* key is enough; the Master key also works.
3. Put the pair in your Edge Function secrets as `MAILJET_API_KEY` (username)
   and `MAILJET_SECRET_KEY` (password).

## 2. Validate the Mailjet sender (outbound)

1. **Account → Sender domains & addresses**
   (<https://app.mailjet.com/account/sender>).
2. Validate the domain (add the SPF/DKIM records Mailjet shows) or the single
   address.
3. Set `MAILJET_FROM_EMAIL` to that validated sender, e.g.
   `Tango KYC Verification <notifications@your-domain.com>`.

Mailjet rejects any `From` that is not a validated sender, so there is no
fallback: outbound sending stays disabled until this is set.

## 3. Create the Resend API key (inbound)

1. Sign up at <https://resend.com>.
2. **API Keys → Create API Key**, permission *Sending access*.
3. Put it in your Edge Function secrets as `EMAIL_API_KEY`.

This key is a backend secret. It must never appear in the Flutter app or in a
commit.

## 4. Verify the Resend domain (inbound)

1. **Domains → Add Domain**, then enter a domain you control.
2. Add the DNS records Resend shows (SPF, DKIM, and DMARC if you use it).
3. Wait for verification to go green.

On the free tier this single verified domain serves inbound receiving. It is no
longer used for outbound sending, which Mailjet now handles, but `EMAIL_FROM` is
kept for reference and for any Resend-side tooling.

## 5. Enable inbound receiving

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

## 6. Register the webhook

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

## 7. Set the Edge Function secrets

Dashboard → **Project Settings → Edge Functions → Secrets**, or via the CLI:

```bash
supabase secrets set \
  MAILJET_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  MAILJET_SECRET_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  MAILJET_FROM_EMAIL="Tango KYC Verification <notifications@your-domain.com>" \
  EMAIL_API_KEY=re_xxxxxxxx \
  EMAIL_INBOUND_DOMAIN=your-domain.com \
  EMAIL_INBOUND_MAILBOX=reply \
  RESEND_WEBHOOK_SECRET=whsec_xxxxxxxx \
  ADMIN_EMAIL=customerservicefor032@gmail.com \
  KYC_SUPPORT_EMAIL=tangoturq@gmail.com
```

`EMAIL_FROM` is retained for the Resend side but is no longer used for outbound
sending. `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically for functions in the project.

### Sending through Gmail instead of Mailjet

`EMAIL_TRANSPORT=gmail` switches outbound sending to the Gmail REST API. This is
needed wherever the runtime cannot open SMTP ports (25/465/587) — Supabase Edge
Functions run on Deno Deploy, where those are blocked, so the REST API over 443
is the only workable Gmail transport.

```bash
supabase secrets set \
  EMAIL_TRANSPORT=gmail \
  GMAIL_CLIENT_ID=xxxxxxxx.apps.googleusercontent.com \
  GMAIL_CLIENT_SECRET=xxxxxxxx \
  GMAIL_REFRESH_TOKEN=xxxxxxxx \
  GMAIL_FROM_EMAIL=customerservicefor032@gmail.com \
  GMAIL_SENDER_NAME="Tango KYC"
```

`GMAIL_FROM_EMAIL` must be the authenticated account itself; Gmail rejects a
`From` the token is not authorised for. `GMAIL_SENDER_NAME` is the display name,
and the messages go out as `Tango KYC <customerservicefor032@gmail.com>`. Inbound
is unchanged: replies keep flowing through Resend and the `email.received`
webhook, so the `Reply-To` wiring is untouched.

## 8. What the société/support KYC inbox receives

The support mailbox (`KYC_SUPPORT_EMAIL`) is **only** emailed once an admin has
approved the request's MVola payment. An unpaid or rejected request never reaches
it, so nothing here fires on ticket creation.

Subject, exactly:

```
Nouvelle demande de vérification de compte
```

Neither the subject nor the body carries the ticket code or the ticket uuid: the
code is an internal routing handle. Replies are matched server-side through the
tokenised `Reply-To` and the recorded thread ids, so the recipient never has to
read or preserve an identifier.

Body:

```
Hello support tango team,

A new KYC verification request is ready for manual review.

My account information:

Tango profile ID: https://tango.me/user
Register email: user@example.com        <-- or "Register number: +261…"

Payment status: approved
Payment amount: 20000 MGA
Received: 2026-09-25T11:00:00.000Z

Send me the link for my verification.

Please restart a manual review of my verification status.

Thank you.
```

`Reply-To` is the tokenised inbound address, so support simply hits Reply and
routing is automatic. `Register email:` and `Register number:` are mutually
exclusive — exactly one line is emitted, matching the value the user actually
provided.

When the user writes in the app, the same mailbox receives the message as a
separate email ("Nouveau message d'un utilisateur - vérification de compte") with
the same tokenised `Reply-To`, so the société's answer lands on the same ticket.

## 9. How a reply is matched

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

## 10. The user notification

Sent only when the ticket's `register_type` is `email`:

```
Your Tango KYC verification request has received a new response.

Ticket ID: TNG-KYC-8F42A91C

Please open the Tango KYC Verification application to view the response.
```

No sensitive content, no verification link — just a pointer to the app, which
requires authentication. A phone-only requester is never assigned an invented
address; their reply appears in the dashboard only.

## 11. The Supabase Auth templates

The app triggers **three** Auth emails. All three share one themed design, and
all three are sent by **Supabase Auth** — not by Mailjet or Resend — so they are
independent of everything above.

| File | Triggered by | Subject |
| --- | --- | --- |
| `templates/confirmation.html` | `signUp()` — the register screen | `Confirmez votre adresse email Tango KYC` |
| `templates/recovery.html` | `resetPasswordForEmail()` — forgot password | `Réinitialisez votre mot de passe Tango KYC` |
| `templates/magic_link.html` | `signInWithOtp()` — sign in with a code | `Votre code de vérification Tango KYC` |

`confirmation` and `recovery` carry a **button** to `{{ .ConfirmationURL }}`.
`magic_link` carries a **code** (`{{ .Token }}`) and deliberately no link, because
`OtpScreen` only accepts a code.

They are wired up in `supabase/config.toml`:

```toml
[auth.email.template.confirmation]
subject = "Confirmez votre adresse email Tango KYC"
content_path = "./supabase/templates/confirmation.html"

[auth.email.template.recovery]
subject = "Réinitialisez votre mot de passe Tango KYC"
content_path = "./supabase/templates/recovery.html"

[auth.email.template.magic_link]
subject = "Votre code de vérification Tango KYC"
content_path = "./supabase/templates/magic_link.html"
```

`config.toml` only drives the **local** stack. The hosted project keeps its own
copies, so the same HTML must also be pasted into the dashboard (see
`SUPABASE_SETUP.md`). Editing a file here does not change what the live project
sends.

### Theming only one template is a common trap

Registering with an email and password sends `confirmation`, **not**
`magic_link`. Restyling only the code template therefore leaves the signup email
looking like Supabase's generic default. All three are themed here for that
reason.

### Sender

Auth mail is **not** sent by the shared Supabase SMTP on this project. A custom
SMTP is configured, pointing at Resend:

| Setting | Value |
| --- | --- |
| `smtp_host` | `smtp.resend.com` |
| `smtp_port` | `465` |
| `smtp_admin_email` | `no-reply@jo67.dpdns.org` |
| `smtp_sender_name` | `Tango KYC` |
| `smtp_max_frequency` | `60` |

Because Resend is already verified for inbound, the same domain covers Auth mail.
The SMTP **password** is held only by Supabase; it is not in this repository.

### Why this template is not a plain link

`signInWithOtp` posts to `/otp` and renders the **magic link** template, not the
recovery one. The template therefore has to carry `{{ .Token }}`. Without it the
mail is delivered with no code in it and the code-entry screen can never succeed.
There is deliberately no fallback link: this screen only accepts a code.

There is no separate "OTP" entry in the Supabase dashboard — the template list is
`confirmation`, `recovery`, `magic_link`, `email_change`, `invite` and
`reauthentication`. Magic link **is** the template an email OTP uses, which is
why it has to be edited for the code flow.

### Keeping the send a code, not a link

Supabase decides between "magic link" and "code" from the request, not from the
template alone. Two conditions have to hold:

1. `signInWithOtp` must **not** be given `emailRedirectTo`. Passing one makes
   Supabase treat the request as a magic-link request.
2. The template must render `{{ .Token }}`.

`AuthService.sendEmailOtp` therefore passes only `email` and
`shouldCreateUser: false`. Removing `emailRedirectTo` is what keeps the send a
pure code send; a deep link would serve no purpose here because `OtpScreen` only
accepts a code.

### Design constraints that shaped the markup

Email clients are not browsers. The choices below are load-bearing, not style
preferences:

- **The code is text, never an image.** Images are blocked by default in Gmail
  and Outlook, so a code rendered as an image would be invisible on first open.
- **No base64 `data:` images.** Gmail strips them outright.
- **Table layout, not flex or grid.** Outlook's renderer has no support for
  either. The MSO conditional comment pins the 580px width.
- **No webfonts.** They are unsupported or silently substituted, so the code uses
  a monospace stack likely to exist locally.
- **The code is at 32px with 6px letter-spacing below 420px wide.** At the
  desktop size of 40px/10px, eight digits measure 273px, but a 320px-wide client
  only offers about 242px inside the panel — it overflowed. At 32px/6px it
  measures 202px, leaving roughly a 20% margin for clients lacking the intended
  monospace face.
- **Colours come from the app.** `mobile/lib/ui/theme/app_theme.dart` uses a
  teal seed (`#2F6B5F`) with a `#2F6B5F`→`#46947D` hero gradient. The template
  matches it so mail and app look like one product.

### Logo

There is currently **no logo file in this repository** — the Android launcher
icon is still Flutter's default, and no hosted logo URL exists. The template
therefore draws the brand identity in CSS (a rounded teal tile with a `T` next
to the wordmark). This has one real advantage: it renders even when images are
blocked, which is the default state of most inboxes.

To use a bitmap logo instead:

1. Upload the image to Supabase Storage as a **public** bucket object. The free
   tier covers this.
2. Copy its public URL — it will look like
   `https://<project-ref>.supabase.co/storage/v1/object/public/<bucket>/<file>.png`.
3. In `supabase/templates/magic_link.html`, uncomment the `<img>` block in the
   header and replace `LOGO_URL` with that URL.
4. Keep the `alt` text and the explicit `width`/`height`, and keep the CSS
   fallback underneath. While images are blocked the `alt` shows instead of a
   broken frame, and the layout does not collapse.

Serve the logo at 2x the display size (about 84px for a 42px slot) so it stays
sharp on high-density screens. Do not hotlink an image you do not control.

## 12. Local development

The local Supabase stack runs Mailpit at <http://127.0.0.1:54324>. Every outbound
email is captured there. This works with no Mailjet account, but it is delivery
to a local inbox — not a claim that real mail was sent.

When the `MAILJET_*` secrets are not all set the backend logs an explicit warning
and reports `admin_email_sent: false` (or skips the user notice). It never
reports success for a message it did not send.

## 13. Outbound idempotency

Resend accepted an `Idempotency-Key` header; Mailjet's Send API has no equivalent.
The guarantee is kept in the database instead: a successful send is recorded in
`email_events` under `(provider='mailjet', external_id=<key>,
event_type='outbound.send')`, and a repeat call within 24 hours is skipped rather
than sent again. Callers pass:

| Caller | Key |
| --- | --- |
| `create-kyc-request` | `kyc-admin-<TICKET_CODE>` |
| `email-webhook`, `admin-actions` | `kyc-user-reply-<TICKET_CODE>-<REGISTER_VALUE>` |

The user-notice key is per ticket and recipient, not per message, so a burst of
admin replies within 24 hours sends one notification rather than one per reply.
This matches the behaviour the Resend `Idempotency-Key` produced.

The key also travels as Mailjet's `CustomID`, but that is for correlation in the
Mailjet dashboard only — it does not deduplicate anything.

A suppressed send carries no provider message id, so callers leave the ticket's
`last_outbound_message_id` untouched rather than overwriting it with an empty
value, which would break thread-based reply matching.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Webhook secret is not configured` | `RESEND_WEBHOOK_SECRET` missing; the function refuses to trust the request |
| `Webhook signature did not match` | Wrong secret, or a proxy altered the body before it reached the function |
| 401 from Mailjet when sending | `MAILJET_API_KEY` / `MAILJET_SECRET_KEY` wrong or swapped |
| 403 from Mailjet when sending | `MAILJET_FROM_EMAIL` is not a validated sender (see step 2) |
| `Email provider rejected the message` in logs | Mailjet refused the message; the log line carries its `ErrorCode` and `ErrorMessage` |
| `Email provider unreachable` | Network failure or the 10 s Mailjet timeout elapsed |
| Replies never arrive | Receiving not enabled, MX records missing, or the webhook not subscribed to `email.received` |
| Reply stored but no user email | The request was phone-only, or the `MAILJET_*` secrets are incomplete — check the logs |
| Same notification twice | Expected only if the retry happened more than 24 h after the first send |
