# Architecture

## Overview

Three components, no server to operate:

```
Flutter (Android)  ──HTTPS──▶  Supabase
                                 ├── Auth            email/password, Google OAuth
                                 ├── Postgres + RLS  all reads and writes
                                 └── Edge Functions   privileged operations
                                          │  ▲
                            outbound mail │  │ signed webhook
                                          ▼  │
                                 Resend ─┘  └─ Resend (inbound)
                                          ▲
                                 Admin replies from Gmail
```

Mail is split by direction, and both directions are Resend. The outbound side
sends the admin notification and the user notice; the inbound side receives the
support reply and hands it to the `email-webhook` function. The `Reply-To` on
outbound mail points at the Resend inbound address, so the reply path does not
depend on which provider sent the mail.

The Flutter app holds the publishable anon key only. That key is not a secret in
the usual sense: every row it can reach is filtered by Row Level Security. Any
operation needing more privilege than a normal signed-in user has — creating a
ticket, sending mail, reading another user's data — goes through an Edge
Function that authenticates the caller itself and uses the service-role key
inside the function only.

## Why Edge Functions for writes

A ticket must be created with a server-generated code, a server-chosen status
and server-side validation. If the client could insert into `kyc_requests`
directly, it could also choose its own `status`, `user_id` or `ticket_code`.
Rather than grant a wide INSERT policy and then try to constrain every column in
a `WITH CHECK`, the schema grants no INSERT at all: creation is a
`security definer` SQL function executed by the Edge Function. The RLS suite
asserts that a direct client insert is refused.

Reads are different. Listing your own tickets and their messages is a plain
`select` from the client and is governed entirely by RLS, which keeps the read
path simple and lets the app paginate.

## Ticket identity and reply matching

The hard part is that support replies from an ordinary mailbox. Nothing in a
Gmail reply is guaranteed except what we put there ourselves, so the design
gives three independent handles and uses them in a fixed order of confidence:

1. **Ticket code in the subject or body** — `TNG-KYC-8F42A91C`. Support is told
   not to remove it, and replying keeps the subject intact.
2. **Reply-token address** — the admin email's `Reply-To` is
   `<mailbox>+<reply_token>@<inbound_domain>`. Replying hits that address, and
   the 32-hex-character token identifies the ticket exactly. This is the fallback
   when a mail client rewrites or truncates the subject.
3. **Thread id** — the provider message id of our outbound mail, matched against
   `In-Reply-To` / `References`. This recovers the ticket when both of the above
   are stripped.

`resolve_ticket_for_reply()` tries these in order and returns `NULL` rather than
guessing. A `NULL` result is not dropped: the reply is written to
`unmatched_replies`, visible only to admins, who can attach it to the right
ticket by hand. Sending an admin reply to the wrong user's dashboard would be a
far worse failure than asking an admin to click once.

The reply token is stored separately from the ticket code on purpose. The ticket
code is shown to the user and travels in email; the token is the quieter
credential and is never displayed.

## Data model

```
profiles         id (= auth.users.id), email, display_name, avatar_url, role,
                 created_at, updated_at
kyc_requests     id, user_id, ticket_code, tango_profile_link, register_type,
                 register_value, status, reply_token, email_thread_id,
                 last_outbound_message_id, created_at, updated_at, last_reply_at
messages         id, ticket_id, sender_type, body, external_message_id, created_at
email_events     id, ticket_id, provider, external_id, event_type, payload_hash,
                 created_at
unmatched_replies id, provider, external_id, from_email, to_email, subject,
                 body_excerpt, reason, resolved_ticket_id, resolved_at, created_at
app_settings     key, value (jsonb)   -- rate limits; server-tunable
mvola_payments   id, user_id, ticket_id, amount, currency, recipient_number,
                 payer_number, transaction_reference, ussd_code, status,
                 rejection_reason, created_at, updated_at, submitted_at,
                 reviewed_at, reviewed_by
```

`sender_type` is `user`, `admin` or `system`. A `system` row records the original
submission so the conversation reads as a real thread.

`register_type` is `email` or `phone`, decided on the server by
`detect_register_type()`. It is stored rather than inferred at read time so the
admin email wording and the notification policy stay stable even if the
detection rules are later refined.

## Manual MVola payments

Payment and ticket creation are independent; the admin notification is not.

A ticket is created whether or not a payment exists, and a payment is created
against an existing ticket. Neither step requires the other. The one place the
two meet is the email to the administration:

- **Ticket creation never waits for a payment.** Submitting the form creates the
  ticket in `pending` and returns immediately. No mail is sent from
  `create-kyc-request`.
- **The admin notification is gated on an approved payment.** The request is
  emailed to the administration only after an admin approves the MVola payment.
- **The gate is re-read from the database.** `notifyAdminOfApprovedRequest()`
  calls `ticketPaymentApproved()`, which queries `mvola_payments` for a row with
  `status = 'approved'` for that ticket. The decision in the request body is
  never trusted, so a caller cannot unlock the email by claiming approval.
- **A failed send changes nothing else.** If the provider refuses the mail, the
  payment stays approved and the ticket stays as it was. The failure is reported
  as `admin_notified: false` rather than raising, so an admin is never told an
  approval failed when it in fact succeeded.

```
User submits the KYC form
        │
        ▼
create-kyc-request  →  create_kyc_request()  →  ticket: pending
        │              (MVola enabled → ticket is marked payment_required and
        │               the user is told to pay; the request is NOT yet submitted)
        │              no email is sent
        ▼
User picks the ticket and pays
        │
        ▼
POST mvola-payments { action: start, ticket_id }
        │  mvola_start_payment()  (security definer)
        │  reads amount, recipient and USSD from app_settings
        ▼
pending  ── user sends the transfer themselves, from their own phone ──
        │
        ▼
POST mvola-payments { action: submit, payment_id, transaction_reference }
        │  mvola_submit_payment()  (security definer)
        ▼
pending + submitted_at          the app now shows "awaiting verification"
        │                          still no email: a submission is not an approval
        ▼
admin opens the queue, checks the reference against the MVola statement
        │
        ▼
POST admin-actions { action: mvola_decision }   admin_mvola_set_decision()
        │
        ├── approved   final; the ticket can never open another payment, and the
        │              request is now *officially submitted*
        │              → ticketPaymentApproved() re-reads the row
        │              → sendAdminRequestNotification() emails the administration
        │              → sendUserRequestSubmittedEmail() confirms to the requester
        │              → the `request_submitted` notification fires (SQL trigger)
        │              → a send failure is reported, never raised
        └── rejected   records a reason; the user may start a corrected payment
                       → no email is sent, the request stays unsubmitted
```

The ticket's own `status` is untouched by any of this: an approved payment does
not move the ticket out of `pending`. Payment state and KYC state are separate
columns that happen to be read together when deciding whether to notify the
administration.

"Officially submitted" is derived, not stored: `kyc_submission_state(ticket)`
reports `payment_status` and `is_submitted`, where `is_submitted` is true only
when payments are disabled or an approved `mvola_payments` row exists. Approval
is the single moment the admin is emailed, the user is emailed and the
`request_submitted` notification is produced.

Three properties are enforced in the database rather than in the client:

1. **The price is never a client input.** `mvola_start_payment` copies the
   amount, currency, recipient and USSD code from `app_settings` at creation
   time. The client sends only a ticket id, so a tampered request cannot buy a
   verification for one ariary.
2. **One live payment per ticket.** A partial unique index on
   `(ticket_id) where status in ('pending', 'approved')` blocks a second active
   payment at the database level. A rejected row falls outside the index, which
   is exactly what allows a corrected resubmission while keeping an approved
   payment final. `start` on a ticket that already has an approved payment
   returns that payment instead of erroring.
3. **Only an admin decides.** `mvola_payments` grants no INSERT, UPDATE or
   DELETE to `authenticated`; the decision function calls `is_admin()` and the
   admin Edge Function calls it again. A user approving their own payment is
   refused at both layers.

The USSD code is composed by `mvola_ussd_code()` from the template in
`app_settings` (`#111*1*2*{recipient}*{amount}*2#`), so the operator can change
the dial string without an app release. The app presents it as a `tel:` URI;
on Android 11+ the manifest declares the matching `<queries>` intents, without
which the dialer cannot be resolved. When no dialer accepts the URI the app says
so and tells the user to compose the code manually rather than failing silently.

Nothing here is a payment gateway. MVola has no public self-serve API for this
kind of transfer, so the money moves person to person and a human confirms it.
The app automates the bookkeeping and the verification queue, not the transfer,
and it never displays a payment as settled before an admin has approved it.

## Idempotency

Email providers retry. Every inbound delivery is keyed on
`(provider, external_id)` and the insert is `on conflict do nothing`: a replay
returns the existing message id and `duplicate: true` instead of appending a
second message. `email_events` provides the same guarantee for the audit log.

## Email body cleaning

Admin replies arrive as HTML or text with headers, quoted history and signatures
attached. `extractCleanReplyBody()` in `_shared/email-body.ts`:

- decodes HTML entities and converts markup to text
- drops header blocks (`From:`, `Received:`, `DKIM-Signature`, …)
- truncates quoted history (leading `>`, `On … wrote:`)
- strips common signature delimiters (`-- `, `Sent from my …`)

The cleaned text is what gets stored. The raw HTML is never persisted and never
reaches the dashboard, which removes the XSS vector at the source rather than
relying on escaping at render time. When it cannot confidently clean a body it
returns a safe truncated fallback instead of passing markup through.

## Flutter structure

Services are interfaces (`AuthService`, `KycService`, `AdminService`) with a
Supabase implementation and, in tests, an in-memory fake. Controllers depend on
the interface, never on `SupabaseClient`, which is what makes the controller
tests run without a network or a database.

Edge Function failures surface as `FunctionException`; `kycExceptionFor()` maps
the backend's stable error codes to typed `KycServiceException`s. The UI renders
its own copy from the code, so an internal server string can never reach a user.

## Status lifecycle

`pending → in_review → replied → closed`, plus the admin-only transitions. Only
`admin_set_status()` may move a ticket, and it checks `is_admin()` first. The
initial status is always `pending` and is set by the server.

## Free-tier fit

- Supabase free tier: 500 MB database, 5 GB egress, Edge Functions included.
- Resend free tier: 3,000 emails/month, 100/day, inbound receiving included.
  Both directions use this one provider and one key.
- No VPS, no always-on container, no paid compute.

With the default `onboarding@resend.dev` sender, Resend only delivers to the
address that owns the Resend account; any other recipient is refused with HTTP
403. Until a domain is verified, outbound mail reaches the account owner only.
Sending to arbitrary addresses needs a verified domain on the sending side.

Embedded images in an admin reply are not inlined into the app; only the cleaned
text is stored. That keeps storage and bandwidth well inside the free tier.
