# Deployment (free tier)

There is no VPS and no always-on container in this design. Two managed services
cover the whole backend; the app is a signed artefact you build.

```
Supabase (free)      database + auth + Edge Functions, HTTPS endpoint
Mailjet (free)       outbound mail
Resend (free)        inbound receiving, webhook
Android              APK / AAB built locally, distributed directly or via Play
```

## 1. Supabase project

1. Create the project at <https://supabase.com> (free tier).
2. Note the project ref — it appears in the function URLs.
3. Push the schema:

   ```bash
   supabase link --project-ref <ref>
   supabase db push
   ```

   The migrations are additive and ordered by timestamp. Verify with
   `supabase migration list` that both are applied.

## 2. Edge Function secrets

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

`ADMIN_EMAIL` is the administration identity (the human who acts in the admin
dashboard); `KYC_SUPPORT_EMAIL` is the société/support KYC mailbox that receives
the requests and the user's messages and replies to them. They are distinct roles
and neither falls back to the other.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided by the platform.
Never add them to the app.

## 3. Deploy the functions

```bash
supabase functions deploy create-kyc-request
supabase functions deploy admin-actions
supabase functions deploy email-webhook
supabase functions deploy mvola-payments
```

Then set the `verify_jwt` flag of each to match `supabase/config.toml`.
`create-kyc-request`, `mvola-payments` and `email-webhook` are declared with
`verify_jwt = false`, and `admin-actions` with `verify_jwt = true`:

- `create-kyc-request`, `mvola-payments` and `admin-actions` call
  `requireUser()` / `requireAdmin()`, which validate the caller's access token
  via `auth.getUser()` and, for admin, read the role from the server-owned
  `profiles` row.
- `email-webhook` verifies a Svix HMAC signature over the raw body instead, since
  the provider cannot present a Supabase JWT. It rejects unsigned requests, and it
  fails closed when the secret is unset.

Setting `verify_jwt = false` therefore does not mean unauthenticated. Every
function rejects a caller it cannot verify; this is covered by the test suites.
`admin-actions` keeps the platform gate on in addition to its in-code role check,
because it is the only function that exposes admin write actions.

There is no MVola secret to configure. The recipient number, the amount, the
currency, the USSD template and the payer instructions all live in the `mvola`
row of `app_settings`, so they can be changed with SQL without a redeploy or an
app release:

```sql
update public.app_settings
set value = jsonb_set(
      jsonb_set(value, '{recipient_number}', '"0346715622"'),
      '{amount}', '20000'
    )
where key = 'mvola';
```

Set `"enabled": false` in the same row to withdraw the payment option; the app
then reports that Mobile Money payment is unavailable instead of showing a
form.

## 4. Configure auth

Dashboard → **Authentication → URL Configuration**:

- Redirect allow-list: `com.tango.kyc.verification://login-callback`
- Providers: email on; Google configured per
  [`GOOGLE_AUTH_SETUP.md`](GOOGLE_AUTH_SETUP.md)

## 5. Register the webhook

Resend → **Webhooks → Add Webhook**:

- URL: `https://<ref>.supabase.co/functions/v1/email-webhook`
- Event: `email.received`

Then copy the signing secret into `RESEND_WEBHOOK_SECRET` (step 2) and redeploy
the function so it picks the value up.

## 6. Account for the free-tier email ceiling

Mailjet's 200 emails/day is the tightest limit in the stack. Each ticket costs one
admin email, plus one user notice per reply. With the default daily cap of 5
requests per user, a handful of users stays far inside it.

To raise the ceiling, tune it in the database rather than in code:

```sql
update public.app_settings
   set value = jsonb_set(value, '{max_requests_per_day}', '10')
 where key = 'rate_limit';
```

## 7. Build the app

The app takes its Supabase values at build time. They are public values.

```bash
cd mobile
flutter pub get
flutter build apk --debug     # sideload / smoke test

flutter build appbundle --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>
```

Or copy `mobile/assets/env.example` to `mobile/assets/env`, fill in the two
values, and build without flags. That file is git-ignored.

For Play, sign the AAB with your release keystore and register its SHA-1/SHA-256
on the Google OAuth Android client (see the Google doc) — debug fingerprints will
not match a Play-signed build.

### Release signing

`android/app/build.gradle.kts` reads the release signing material from
`android/key.properties` (git-ignored) or from environment variables, whichever
is present:

```properties
# mobile/android/key.properties
KEYSTORE_PATH=/absolute/path/to/upload-keystore.jks
KEYSTORE_PASSWORD=...
KEY_ALIAS=...
KEY_PASSWORD=...
```

Create the keystore once and keep it plus the passwords somewhere safe — losing
it means you can no longer ship updates to an existing Play listing:

```bash
keytool -genkeypair -v -keystore upload-keystore.jks -alias upload \
  -keyalg RSA -keysize 2048 -validity 10000
```

When no keystore is configured the release build still succeeds so local
`--release` runs keep working, but Gradle prints a warning and the APK is signed
with the Android debug key. **A debug-signed release build must never be
uploaded to Play.** Check the signer before shipping:

```bash
"$ANDROID_HOME"/build-tools/*/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk | grep 'certificate DN'
```

`CN=Android Debug` means no keystore was picked up; your own `CN` means it was.

## 8. Verify the deployment

```bash
# Function reachable and rejecting unauthenticated calls
curl -i https://<ref>.supabase.co/functions/v1/create-kyc-request -X POST

# Webhook rejects an unsigned request
curl -i https://<ref>.supabase.co/functions/v1/email-webhook -X POST \
  -H 'content-type: application/json' -d '{"type":"email.received"}'
```

Both should refuse. Then run the real flow: sign up, submit a request, confirm the
admin email arrives with the exact subject and the correct `Register email:` /
`Register number:` line, reply from the admin mailbox, and confirm the message
appears in the app and the user notice is sent.

## 9. Keep the project from pausing

Free Supabase projects pause after about a week of inactivity. Either accept the
resume delay, or add a scheduled GitHub Actions workflow that calls a lightweight
endpoint on a schedule. A single daily request is enough. This is a Supabase
platform behaviour, not something this application needs to work around in code.

## 10. Rollback

Migrations are additive; there is no destructive step to reverse. To roll back a
function, redeploy the previous revision:

```bash
supabase functions deploy <name> --project-ref <ref>
```

If a bad migration did reach production, fix it forward with a new migration.
`supabase db reset` is a local-only operation and would destroy production data.

## Costs

| Item | Free tier | Paid trigger |
| --- | --- | --- |
| Supabase | 500 MB DB, 5 GB egress | Large media or heavy reads (not used here) |
| Mailjet | 200 emails/day | Sustained volume beyond ~100 tickets/day |
| Resend | 3,000/month inbound | Inbound volume beyond ~3,000 replies/month |
| Hosting | None needed | Only if a web client is added later |

At the expected volume this runs at no cost. The first limit you are likely to
feel is Mailjet's 200 emails/day, which is a billing decision rather than an
architectural one.
