# Architecture

## Overview

Three components, no server to operate:

```
Flutter (Android)  ──HTTPS──▶  Supabase
                                 ├── Auth            email/password, Google OAuth
                                 ├── Postgres + RLS  all reads and writes
                                 └── Edge Functions   privileged operations
                                          ▲
                                          │ signed webhook
                                 Email provider (Resend)
                                          │
                                 Admin replies from Gmail
```

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
```

`sender_type` is `user`, `admin` or `system`. A `system` row records the original
submission so the conversation reads as a real thread.

`register_type` is `email` or `phone`, decided on the server by
`detect_register_type()`. It is stored rather than inferred at read time so the
admin email wording and the notification policy stay stable even if the
detection rules are later refined.

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
- Resend free tier: 3,000 emails/month, 100/day, one custom domain.
- No VPS, no always-on container, no paid compute.

Embedded images in an admin reply are not inlined into the app; only the cleaned
text is stored. That keeps storage and bandwidth well inside the free tier.
