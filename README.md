# Tango KYC Verification

A Flutter (Android) app backed by Supabase that lets a user request a manual
review of their Tango KYC verification, then follow the conversation with the
support team in the app. Support keeps answering from the ordinary mailbox; the
backend matches each reply back to the right ticket automatically.

## What actually works today

This section is deliberately explicit. Everything marked *verified* was executed
against the local Supabase stack during development; anything that needs an
external account is marked *needs configuration* and is never faked.

| Capability | State |
| --- | --- |
| Email + password sign-up / sign-in / sign-out | Verified against the local Auth API; wrong password rejected |
| Password reset request (email sent, redirect reaches the app's deep link) | Verified that the reset email is emitted, that its link redirects to the app's deep-link scheme, and that recovery routing is unit-tested. Setting the new password is exercised manually — see note below |
| Google sign-in | Implemented, **needs configuration** (see `docs/GOOGLE_AUTH_SETUP.md`) |
| KYC request creation, unique ticket code, dedup, rate limiting | Verified |
| Server-side validation (link scheme, email/phone detection and normalisation) | Verified |
| Row Level Security: users see only their own tickets and messages | Verified |
| Admin gate by role, enforced in RLS and in SQL | Verified |
| Admin email on request creation (exact required subject/body) | Verified against local Mailpit; needs a Resend key to send real mail |
| Inbound reply webhook, Svix signature verification | Verified (22 unit tests) |
| Reply → ticket matching (ticket code → reply token → thread id) | Verified |
| Idempotent webhook handling (no duplicate messages) | Verified |
| Quarantine for unmatched replies, admin-only | Verified |
| Clean reply body extraction (HTML → text, headers/quotes stripped) | Verified |
| User notification email on a new reply | Implemented; needs a Resend key and a verified domain |
| Flutter UI: splash, login, register, forgot/reset, home, create request, my requests, details, profile, settings, admin dashboard | Verified (`flutter analyze` clean, 69 tests pass) |
| Debug APK build | Verified |

Nothing in this repository fabricates a result. Where a provider is not
configured the backend fails loudly rather than reporting success.

**Note on password reset.** The automated suite confirms the reset email is sent,
that its link redirects to the app's deep-link scheme, and that the recovery
routing decision is correct. It does not click the link inside a running app —
that requires a device. Treat the final "type a new password" step as needing a
manual pass until you have done one.

**Note on the deep-link scheme.** The scheme is `com.tango.kyc.verification`
(dots, no underscores). Dart's `Uri` parser rejects underscores in a scheme, and
`app_links` parses incoming links with `Uri.tryParse` and silently discards
anything it cannot parse, so an underscore there would have made every OAuth and
recovery callback fail to arrive. A unit test now guards this.

**Note on Google sign-in.** Implemented in the client, but it cannot work until
you create a Google OAuth client. It is not claimed as verified anywhere in these
docs, and `docs/GOOGLE_AUTH_SETUP.md` says so at the top.

## Repository layout

```
.
├── mobile/                     Flutter Android application
│   ├── lib/
│   │   ├── config/             Build-time configuration (public values only)
│   │   ├── core/               Validators shared with the UI
│   │   ├── models/             Ticket, message, profile, stats models
│   │   ├── services/           Auth and KYC/admin service interfaces + Supabase impls
│   │   ├── state/              Controllers (ChangeNotifier)
│   │   └── ui/                 Theme, shared widgets, screens, shell
│   └── test/                   Widget, controller and service tests
├── supabase/
│   ├── migrations/             Schema, RLS policies, SQL functions
│   └── functions/
│       ├── create-kyc-request/ Authenticated ticket creation + admin email
│       ├── email-webhook/      Inbound provider webhook (signature verified)
│       ├── admin-actions/      Admin-only operations
│       ├── _shared/            HTTP helpers, email provider, body cleaning, Svix
│       └── tests/              Deno tests for signature and body extraction
├── tests/
│   ├── db/run_tests.sql        Backend correctness + RLS + security suite
│   └── scripts/                End-to-end and webhook HTTP scripts
├── docs/                       Architecture, setup, security, deployment
└── .env.example                Every backend secret, with where to get it
```

## Quick start (local, no external account needed)

Prerequisites: Docker, the Supabase CLI, Flutter 3.x with the Android SDK.

```bash
# 1. Backend
supabase start                     # first run pulls images
supabase db reset                  # applies migrations

# 2. Edge Function secrets for the local stack
cp .env.example supabase/functions/.env
supabase status -o env             # copy SUPABASE_URL / keys into .env as needed

# 3. Flutter
cd mobile
cp assets/env.example assets/env   # then fill in SUPABASE_URL + SUPABASE_ANON_KEY
flutter pub get
flutter run
```

The local stack includes Mailpit at <http://127.0.0.1:54324>, where every
outgoing email can be inspected without sending anything externally.

## Configuration

Every secret lives in `.env.example` with a comment naming exactly where to
obtain it. The only values Flutter ever sees are `SUPABASE_URL` and
`SUPABASE_ANON_KEY`, which are public by design and protected by Row Level
Security. The service-role key, the email API key and the webhook signing secret
are Edge Function secrets and are never bundled into the app.

Deep dives: [`docs/SUPABASE_SETUP.md`](docs/SUPABASE_SETUP.md),
[`docs/GOOGLE_AUTH_SETUP.md`](docs/GOOGLE_AUTH_SETUP.md),
[`docs/EMAIL_SETUP.md`](docs/EMAIL_SETUP.md).

## Verification

Actual results from the local stack, so you can compare after your own run:

| Suite | Command | Result |
| --- | --- | --- |
| Flutter analyzer | `flutter analyze` | No issues found |
| Flutter tests | `flutter test` | 63 passed |
| Backend SQL | see below | 74 assertions passed |
| Edge Functions | `deno test tests/` | 22 passed |
| End-to-end | `bash tests/scripts/e2e_local.sh` | 35 passed |

```bash
# Flutter
cd mobile
flutter analyze
flutter test
flutter build apk --debug

# Backend SQL suite (requires `supabase start`)
docker exec -i supabase_db_<project> psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/db/run_tests.sql

# Edge Function unit tests
cd supabase/functions && deno test --allow-env --allow-net --allow-read tests/

# End-to-end (create -> admin email -> reply -> webhook -> dashboard)
bash tests/scripts/e2e_local.sh
```

The SQL suite runs inside a transaction and rolls back, and it clears its own
fixtures first so it can be re-run against a database an end-to-end run has
already touched.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components, data flow, decisions
- [`docs/SUPABASE_SETUP.md`](docs/SUPABASE_SETUP.md) — project, schema, RLS, deployment
- [`docs/GOOGLE_AUTH_SETUP.md`](docs/GOOGLE_AUTH_SETUP.md) — OAuth setup, package name, SHA-1/256
- [`docs/EMAIL_SETUP.md`](docs/EMAIL_SETUP.md) — Resend sending, inbound, webhook, free-tier limits
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, RLS, secrets, XSS/SQLi/injection
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — free-tier deployment path

## Status and remaining external setup

The application is functional end-to-end on the local stack. To run it against
real users, three things need accounts that only you can create:

1. A Supabase project (free tier) — for the database, auth and Edge Functions.
2. A Resend account (free tier) with a verified domain — for real outbound mail
   and inbound replies.
3. A Google Cloud OAuth client — for Google sign-in.

Each is a step-by-step task in the corresponding doc above. Until those exist,
email sending and Google sign-in are not claimed to work.
