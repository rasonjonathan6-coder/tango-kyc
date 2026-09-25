# Supabase setup

## 1. Create the project

1. Sign in at <https://supabase.com> and create a project. The free tier is
   enough for this application.
2. Choose a region close to your users and save the database password.
3. Wait for provisioning to finish.

## 2. Collect the values

Supabase Dashboard → **Project Settings → API**:

| Dashboard field | Environment variable | Where it is used |
| --- | --- | --- |
| Project URL | `SUPABASE_URL` | Edge Functions, Flutter |
| `anon` / publishable key | `SUPABASE_ANON_KEY` | Edge Functions, Flutter |
| `service_role` / secret key | `SUPABASE_SERVICE_ROLE_KEY` | Edge Functions only |

The `service_role` key bypasses Row Level Security. It must never appear in the
Flutter app, in a commit, or in any file under `mobile/`.

## 3. Apply the schema

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

Against a local stack instead: `supabase start && supabase db reset`.

The migrations create:

- `profiles`, `kyc_requests`, `messages`, `email_events`, `unmatched_replies`,
  `app_settings`
- Row Level Security policies on each
- SQL functions: `create_kyc_request`, `resolve_ticket_for_reply`,
  `record_inbound_reply`, `record_unmatched_reply`, `record_email_event`,
  `admin_stats`, `admin_ticket_list`, `admin_set_status`, `admin_post_message`,
  `admin_resolve_unmatched_reply`, `user_post_message`, plus the validation and
  `is_admin` helpers
- A trigger that creates a `profiles` row on sign-up and derives `role` from
  `app_metadata` so the role cannot be self-assigned

## 4. Server-tunable configuration

Behaviour that should change without a redeploy lives in `app_settings`:

```sql
select public.setting_int('rate_limit', 'max_requests_per_day', 5);

update public.app_settings
   set value = jsonb_set(value, '{max_requests_per_day}', '10')
 where key = 'rate_limit';
```

The anti-spam limits are the live values here. Note that the `admin_email` row is
**not** read by the functions: the support address comes from the `ADMIN_EMAIL`
environment variable (an Edge Function secret). Change it with
`supabase secrets set ADMIN_EMAIL=...`, not with SQL.

Anti-spam has two independent limits, both stored in the `rate_limit` row of
`public.app_settings` (not in environment variables): a cooldown between distinct
requests (`min_seconds_between_requests`, default 300 seconds) and a daily
ceiling (`max_requests_per_day`, default 5). An exact re-submission inside the
deduplication window (`duplicate_window_hours`, default 24) is deduplicated to
the same ticket rather than rejected, so a user who double-taps does not get an
error.

## 5. Auth settings

Dashboard → **Authentication → Providers**:

- **Email**: enabled. For development, turning off "Confirm email" speeds up
  testing; leave it on for production.
- **Google**: see [`GOOGLE_AUTH_SETUP.md`](GOOGLE_AUTH_SETUP.md).

Dashboard → **Authentication → URL Configuration**:

- **Site URL**: your web origin, if you add one.
- **Redirect URLs**: add the app's deep link exactly as registered in
  `AppConfig.oauthRedirectUrl`:
  `com.tango.kyc.verification://login-callback`

The password-reset email deep-links back into the app through the same scheme.

## 6. Make yourself an admin

The role is derived from `raw_app_meta_data`, which only the service role can
write. Promote an account with:

```sql
update auth.users
   set raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
 where email = 'rasonjonathan6@gmail.com';

update public.profiles set role = 'admin'
 where id = (select id from auth.users where email = 'rasonjonathan6@gmail.com');
```

Then sign out and back in so the new token carries the claim. Role checks run in
SQL (`is_admin()`), not in the client, so a tampered client cannot gain access.

## 7. Verify

```bash
# Local stack only
docker exec -i supabase_db_<project> psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/db/run_tests.sql
```

The suite asserts the security properties directly: a user cannot read another
user's tickets or messages, cannot reassign ownership, cannot change status,
cannot insert tickets, cannot escalate their own role, and cannot reach any
admin-only function or table.

## 8. Free-tier limits worth knowing

| Resource | Free tier | Relevance here |
| --- | --- | --- |
| Database | 500 MB | Ample; message bodies are capped at 20 000 characters |
| Egress | 5 GB/month | The app reads only the signed-in user's rows |
| Edge Function invocations | Included allowance | Only writes go through functions |
| Projects paused | After 7 days idle | Configure a scheduled ping if needed |

## Troubleshooting

**`AUTH_REQUIRED` from an Edge Function** — the request had no valid JWT. Confirm
the app is signed in and that the anon key is correct.

**A user cannot see a ticket that exists** — RLS is working if the row belongs to
someone else. Compare `kyc_requests.user_id` with the signed-in user's id.

**Admin functions return `FORBIDDEN`** — the account's `profiles.role` is not
`admin`, or the token predates the promotion. Sign out and in.

**Emails are not delivered** — see [`EMAIL_SETUP.md`](EMAIL_SETUP.md). On the
local stack, read them in Mailpit instead.
