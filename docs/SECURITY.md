# Security

## Trust boundaries

```
Untrusted                    │ Verified at the boundary           │ Trusted
─────────────────────────────┼────────────────────────────────────┼──────────────────
Flutter client               │ Supabase Auth JWT + RLS            │ Postgres
request body / query         │ server-side validation             │ SQL functions
inbound webhook              │ Svix HMAC over the raw body       │ Edge Function
email HTML                   │ extractCleanReplyBody + escaping   │ messages table
```

Nothing above the line is believed. The client supplies *what* it wants, never
*who it is* or *what it may do*.

## Row Level Security

RLS is enabled on every table. The default is deny: a new table with no policy is
unreadable rather than open.

| Table | User | Admin |
| --- | --- | --- |
| `profiles` | Read own; update own `display_name` / `avatar_url` | Read and update all |
| `kyc_requests` | Read own only; **no** insert/update/delete | Read and update all |
| `messages` | Read own tickets' messages | Read all |
| `email_events` | No access | Read via functions |
| `unmatched_replies` | No access | Read and resolve |
| `app_settings` | No access | Read |
| `mvola_payments` | Read own only; **no** insert/update/delete | Read all |

`app_settings` holds the rate-limit values, so it is admin-only for reads as
well. The client never reads it: the app is given the limits it needs through the
functions' error responses, and the settings are consumed server-side. No
mailbox is stored here: the administration identity comes from the `ADMIN_EMAIL`
Edge Function secret and the société/support KYC mailbox from `KYC_SUPPORT_EMAIL`.

The properties the test suite asserts directly:

- user A cannot see user B's tickets or messages
- user A cannot reassign a ticket's `user_id`
- a user cannot change `status`
- a user cannot insert a ticket at all (creation is a `security definer` function)
- a user cannot set their own `role`
- a non-admin cannot call `admin_stats`, `admin_ticket_list`, `admin_post_message`,
  `admin_resolve_unmatched_reply` or `admin_mvola_set_decision`
- a user cannot post a message on another user's ticket
- a user cannot see another user's payment
- a user cannot start a payment on another user's ticket
- a user cannot submit another user's payment
- a normal user cannot call `admin_mvola_set_decision`
- a ticket can never hold two live payments (one `pending` or `approved`) at once

The client has no write path to these tables at all: writes go through functions
that check the caller and set the security-relevant fields themselves. The one
exception is `profiles`, where a user may edit their own row — and there
column-level privileges restrict the grant to `display_name`, `avatar_url` and
`updated_at`, so `role`, `email` and `id` are not writable even though the row is.
That column grant is the deliberate belt to the RLS row policy's braces.

## Roles

`profiles.role` is derived from `raw_app_meta_data.role`, which only the service
role can write. A client cannot set it, and the promotion path is a documented
service-side operation. `is_admin()` reads the database, not the token, so a
stale claim cannot grant access and a revoked role takes effect immediately.

Admin UI is a convenience, not the control. Even a client that forged its way to
the admin screens would see nothing, because every admin read and write is
gated in SQL.

## Secrets

| Secret | Flutter | Edge Function | Repository |
| --- | --- | --- | --- |
| `SUPABASE_ANON_KEY` | Yes (public by design) | Yes | Example only |
| `SUPABASE_SERVICE_ROLE_KEY` | **Never** | Yes | Example only |
| `MAILJET_API_KEY` | **Never** | Yes | Example only |
| `MAILJET_SECRET_KEY` | **Never** | Yes | Example only |
| `EMAIL_API_KEY` | **Never** | Yes (inbound only) | Example only |
| `RESEND_WEBHOOK_SECRET` | **Never** | Yes | Example only |
| `ADMIN_EMAIL` | No | Yes | Example (it is a published address) |
| `KYC_SUPPORT_EMAIL` | No | Yes | Example (it is a published address) |

`.gitignore` excludes `.env`, `mobile/assets/env`, `google-services.json`,
keystores and `key.properties`. Verified with `git check-ignore` before the first
commit. The anon key is safe to ship precisely because RLS constrains it: it is a
*capability to act as a signed-in user*, not an administrative credential.

## Input validation

Validation runs on the server regardless of what the client did. The Flutter
validators exist to give fast feedback, not to be trusted.

- **Profile link** — must match `https?://` followed by a host containing a dot,
  which rejects `javascript:`, `data:` and bare strings. Rejecting the scheme is
  what stops a stored link from later becoming a `javascript:` URI. The length is
  capped at 2048. This is enforced in three places: the Edge Function, the
  `create_kyc_request` function, and a table `check` constraint, so a schema
  change cannot quietly widen it.
- **Register value** — classified as email or phone by the server, then
  normalised (email lowercased and trimmed; phone reduced to `+`/digits).
  A malformed value is rejected rather than stored as typed.
- **Lengths** — bounded at the column level as well as in the function, so an
  oversized payload cannot be persisted even if a function is changed later.
- **Webhook payload** — the JSON body is parsed only after the signature check.

## SQL injection

Every database access is a parameterised RPC call through the Supabase client, or
a `plpgsql` function using parameters. No SQL is assembled from user input
anywhere in the codebase.

The test harness does build SQL strings with `format(... %L)` when it constructs
calls to assert on. That is `%L`-quoted *and* confined to
`tests/db/run_tests.sql`, which is a developer-run script and never reachable from
the application. It is worth being explicit about, because a grep for `format(`
will find it.

Functions declare `set search_path = public`, which prevents a caller from
shadowing a built-in or a `pg_temp` object to change what a `security definer`
function resolves.

## XSS

Admin replies are HTML. The dashboard never renders that HTML.

`extractCleanReplyBody()` converts HTML to text, removes headers and quoted
history, and the result is what is stored. The raw markup is discarded before it
reaches the database, so there is no sanitised-HTML-so-far window and no reliance
on the renderer. Untrusted values that *are* interpolated into outbound email
(the profile link, the register value) are escaped with `escapeHtml()` for HTML
parts and control-character-stripped for text parts.

## Webhook authenticity

Svix HMAC-SHA256 over the raw request body, compared in constant time, with a
timestamp tolerance to reject replays. The raw body is used verbatim because any
re-serialisation changes the bytes and breaks the MAC. Verification happens
before parsing and before any database access. The function only touches the
database through `serviceClient()` after that point, and it refuses to run at all
if no secret is configured — an unset secret fails closed rather than open.

The handler does not trust the event body's routing fields: the ticket is decided
by `resolve_ticket_for_reply()` against the database, not by anything the payload
claims.

## Anti-spam and abuse

Two server-side limits, tunable in `app_settings` without a deploy:

- a cooldown between distinct requests (default 10 minutes)
- a daily ceiling per user (default 5)

An *exact* re-submission inside the cooldown is deduplicated to the existing
ticket instead of erroring, so a double-tap is not punished while a flood still
is. Duplicate detection is on the normalised (profile link, register value) pair.

User messages are capped at 5 per minute per ticket, and message bodies at
20 000 characters.

MVola payments add no new client-writable surface. The client may only name a
ticket when starting a payment, and the amount, currency, recipient and USSD code
are read from `app_settings` at that moment — a tampered request cannot change
the price. A partial unique index on `(ticket_id) where status in ('pending',
'approved')` prevents a second live payment for one ticket, and a decided
payment cannot be decided again. Approving or refusing checks `is_admin()` inside
the SQL function and again in the admin Edge Function, so a user cannot approve
their own payment at either layer. The reference is length- and charset-checked
in Postgres (`^[A-Za-z0-9][A-Za-z0-9 ._/-]*$`) and rendered only as plain text in
the app.

## Error handling

Edge Functions return a stable machine code plus a message safe for display.
Internal details — stack traces, SQL errors, provider responses — are logged
server-side and never returned. The client maps codes to its own copy, so an
unexpected code degrades to "Something went wrong. Please try again." rather than
surfacing whatever the server said.

## Transport

All traffic is HTTPS: Supabase, Mailjet and Resend are TLS-only, and the Android
manifest requires no cleartext exception. There is no plaintext fallback to
disable.

## Notifications

Deliberately out of scope for the first version: push notifications and badges.
The data model supports them (tickets carry status and `last_reply_at`), but
adding a push provider would mean another credential and a device-token table.
The in-app dashboard and the email notice are the notification path today.

## Reporting a problem

This is a small application with a single support mailbox. Security issues should
go to the address configured in `KYC_SUPPORT_EMAIL`. Do not open a public issue
for a vulnerability that could be exploited before it is fixed.
