# AGENTS.md

Repository notes for future sessions. Keep this factual and current; it is not a
substitute for the docs in `docs/`.

## Layout

- `mobile/` — Flutter (Android) client. Only ever holds the Supabase URL and the
  **anon** key. No secret, service-role key or SMTP/Resend credential belongs here.
- `supabase/migrations/` — schema, RLS policies and SQL functions.
- `supabase/functions/` — Deno Edge Functions: `create-kyc-request`,
  `admin-actions`, `email-webhook`, plus `_shared/` and `tests/`.
- `tests/scripts/e2e_local.sh` — end-to-end script against the local stack.
- `docs/` — setup, architecture, security and deployment guides.

## Commands

```bash
# Flutter
cd mobile && flutter analyze && flutter test && flutter build apk --debug

# Edge Functions (Deno)
cd supabase/functions && deno test --allow-all --no-check tests/

# End-to-end against the local stack (requires `supabase start`)
bash tests/scripts/e2e_local.sh
```

`flutter analyze` must be clean before committing. All three suites should pass.

## Environment constraints

- There is **no `/dev/kvm`**, so the Android emulator cannot run usefully. Do not
  claim an on-device smoke test was performed; APK builds and widget tests are
  what actually get validated here.
- Mailpit (`http://127.0.0.1:54324`) captures auth emails. Mail sent through
  Resend is *not* captured locally, because no real Resend key is configured — do
  not read "no message in Mailpit" as proof an admin email failed.

## Gotchas that have already caused real bugs

- **Deep-link scheme must be valid DNS syntax.** It is
  `com.tango.kyc.verification`. Dart's `Uri` parser rejects underscores in a
  scheme and `app_links` uses `Uri.tryParse`, so an underscore in the scheme makes
  every OAuth and password-recovery callback silently vanish. A unit test in
  `mobile/test/auth_callback_test.dart` guards this.
- **Password-recovery detection must not read the callback URL.** Under the PKCE
  flow (supabase_flutter's default) a recovery link arrives as a bare `?code=...`
  with no `type=recovery`. Route on the auth library's `redirectType`, not on a
  URL substring.
- **The `recover` endpoint only honours `redirect_to` as a query parameter.** Sending
  it in the JSON body is silently ignored and Supabase falls back to `site_url`.
- **Local redirect allow-list lives in `supabase/config.toml`**
  (`additional_redirect_urls`), and the auth container must be restarted before a
  change there takes effect.
- **Anti-spam limits are not environment variables.** They live in the
  `rate_limit` row of `app_settings` and are edited with SQL. `.env.example` no
  longer advertises env vars for them; don't reintroduce that.
- **Auth is configured on the cloud project, not in `supabase/config.toml`.**
  `config.toml` describes the local stack only. The live project
  (`hbvjpawnszzcbcjmbkuf`) has `mailer_autoconfirm = false`, so sign-up returns no
  session; the app must complete confirmation. Read the real values with
  `GET https://api.supabase.com/v1/projects/$REF/config/auth` using
  `SUPABASE_ACCESS_TOKEN` instead of assuming the local defaults.
- **The email OTP length is 8, not 6.** `mailer_otp_length = 8` on the project.
  `kEmailOtpLength` in `otp_screen.dart` mirrors it; changing one without the other
  breaks code entry.
- **Codes render the Magic Link template, not the recovery template.**
  `gotrue`'s `signInWithOtp` posts to `/otp` with no `type` parameter and uses the
  magiclink email; `verifyOTP` then takes the `type`. Verified by reading
  `gotrue-2.27.2/lib/src/gotrue_client.dart`, not assumed. The magiclink template
  must contain `{{ .Token }}` or the code never reaches the user.
- **`resend` rejects `OtpType.recovery` for an email** (it asserts `signup` or
  `emailChange`), so the recovery resend re-uses the send path.
- **Auth email is limited to 30 per hour per address** (`rate_limit_email_sent`,
  read from the live project — an earlier note claiming 2 was wrong). Supabase also
  sits behind a separate platform-wide send cap, so a burst of test signups can
  still be throttled for reasons unrelated to your code.
- **Release signing** reads `mobile/android/key.properties` or `KEYSTORE_PATH` &
  friends. With no keystore the release build still succeeds but is signed with
  the Android debug key and must not be shipped.

## Conventions

- Server-side validation and RLS are authoritative; client checks are UX only.
- Never trust a webhook; verify its Svix signature and keep handling idempotent.
- Never display raw email bodies. `extractCleanReplyBody` + `sanitizeForStorage`
  in `supabase/functions/_shared/email-body.ts` produce the stored, safe text. If
  you test the sanitizer, exercise the pair — checking only the inner function
  gives a false negative.
- Do not fabricate results. If an external service is unconfigured, fail loudly
  and say so rather than reporting success.

## Production state (verified)

- **Cloud project**: `hbvjpawnszzcbcjmbkuf`. Both migrations applied, all six
  tables present with RLS enabled, the three Edge Functions deployed.
- **`create-kyc-request` returns HTTP 201** on success — not 200.
- **Duplicate submissions are deduplicated before the rate limit is applied**, so
  an exact re-submission returns the existing ticket (201) and never 429. Any
  test that expects 429 for a duplicate is wrong.
- **The `ADMIN_EMAIL` value lives in an Edge Function secret, not in
  `app_settings`.** The `admin_email` row is seeded but read by no code; editing
  it by SQL changes nothing.
- **Rejected requests are validated before the rate-limit check**, so they consume
  no rate budget.
- **`^https?://` accepts plain `http://`.** This matches the spec ("a valid URL");
  https is not forced.
- **A project access token unlocks the Management API SQL endpoint**
  (`POST /v1/projects/<ref>/database/query`), which is how RLS and schema were
  verified when the direct DB host was unreachable. The direct host
  `db.<ref>.supabase.co` does not resolve in this sandbox, but the poolers
  (`aws-0-<region>.pooler.supabase.com`) are reachable on 5432 and 6543.
- **`supabase status -o env` emits `ANON_KEY` / `SERVICE_ROLE_KEY`**, but
  `tests/scripts/e2e_local.sh` expects `SUPABASE_ANON_KEY` /
  `SUPABASE_SERVICE_ROLE_KEY`. Map them explicitly when exporting.
- **`admin-actions` runs with `verify_jwt = true`** (see `supabase/config.toml`).
  Do not deploy it with `--no-verify-jwt`: that would drop the platform gate and
  leave the admin surface guarded by in-code checks alone. The other two
  functions do their own auth (user JWT / Svix signature), so they stay `false`.
- **`handle_new_user` only fires on INSERT into `auth.users`.** Any user created
  before the trigger existed has no `profiles` row, and `is_admin()` reads
  `profiles`, so such a user is locked out of the admin dashboard even when their
  `app_metadata.role` is `admin`. Backfill with the trigger's own mapping
  (`full_name` → `name` → email local part, role from `app_metadata`). The real
  admin account needed this after migrations were applied to the cloud project.

## Mobile UI (2026 modernization pass)

- **The design system lives in mobile/lib/ui/theme/app_theme.dart.** It exports
  AppSpacing, AppRadius, AppTheme.heroGradient(brightness), AppTheme.onHero and
  AppTheme.statusColor(context, status). New UI must use these tokens rather than
  hard-coded paddings or colours, so light/dark stay consistent.
- **mobile/lib/ui/widgets/modern.dart holds the reusable modern pieces:**
  SkeletonBox / SkeletonCard / SkeletonList (shimmer via one AnimationController,
  no extra dependency), StatusHero, JourneyTimeline, NotificationTile, SectionHeader.
- **Notifications are derived, never fetched.** NotificationsController.sync()
  builds them from KycController.requests - data already RLS-scoped to the caller -
  so no new endpoint or table is involved. Read state persists in
  flutter_secure_storage under notifications.seen_replies. A reply is unread when
  request.lastReplyAt is newer than the stored timestamp.
- **mobile/lib/core/kyc_journey.dart is pure Dart** (no Flutter import) so it can be
  unit tested directly. It is the single source of truth for the four-step journey
  wording: submitted -> MVola payment -> manual review -> answer.
- **Onboarding runs once.** SettingsController.onboardingDone gates it in _RootGate
  (mobile/lib/main.dart); the flag persists under settings.onboarding_done.
- **Widget tests assert exact strings and icons.** Examples: Tango KYC Verification,
  Continue with Google, Sign in, Forgot password?, No requests yet, Reply received,
  Icons.visibility_rounded. Preserve these labels when restyling, or update
  test/screens_test.dart in the same change. Baseline after the UI pass:
  flutter analyze clean, 107 tests pass.
- **Build with the sandbox JDK explicitly:** export JAVA_HOME=/workspace/tools/jdk17
  and prepend /workspace/tools/flutter/bin:/workspace/tools/jdk17/bin to PATH. The
  default shell JAVA_HOME is unset, and Gradle fails with "Please set the JAVA_HOME
  variable" if you skip it. Release build: flutter build apk --release ->
  build/app/outputs/flutter-apk/app-release.apk.
- **No Android emulator is available in this environment** (flutter devices shows
  only the Linux desktop target, emulator -list-avds finds nothing). APK smoke
  testing on a device must be done by the user. Do not claim the app was smoke
  tested on Android here.

## Welcome ticket and submission rate limiting

Account creation seeds a synthetic, hidden, closed "welcome" ticket
(`register_type = 'phone'`, `register_value = 'WELCOME'`) that carries the
welcome system message and the `welcome` notification. Two rules follow from it:

- It must never trip `create_kyc_request`'s per-user rate limit. Its `created_at`
  is anchored at `2000-01-01` (see `20260928000400_welcome_ticket_rate_limit.sql`)
  so `max(created_at)` and the 24h count ignore it. If you ever re-seed welcome
  tickets, keep that anchoring, otherwise a fresh account is wrongly told to
  "wait a few minutes" before its first real request.
- The Flutter UI filters it out (`register_value != 'WELCOME'`) on the home and
  history screens; it is only reachable through the `welcome` notification, where
  it renders as a read-only system message with no reply box.

## Payment gating and the user journey wording

MVola is part of every submission while the `mvola` setting is `enabled: true`:
creating a request marks it `payment_required` and the user is told to pay
instead of being told it was submitted. `admin_request_payment` remains
available as an explicit admin signal, but it is no longer the only way the flag
is set.

"Officially submitted" is *derived*, never stored: `kyc_submission_state(ticket)`
returns `payment_status` plus `is_submitted`, where `is_submitted` is true only
when payments are off or an `mvola_payments` row for the ticket is `approved`.
The admin email, the user confirmation email and the `request_submitted`
notification are all produced by that approval — the only moment the request
becomes real, and the only moment the admin mailbox is contacted.

The UI must follow the same rule: `nextActionHint`, `currentStep` and
`journeyFor` in `mobile/lib/core/kyc_journey.dart` all take `paymentRequired`
(and `nextActionHint`/`currentStep` also take `isSubmitted`), so a request
awaiting payment reads "pay with MVola / not yet submitted" and a validated one
reads "received / under review". Pass `request.paymentRequired` and
`request.isSubmitted` when calling them. `mvola_start_payment` raises
`MVOLA_NOT_REQUIRED` only when the flag is off (payments disabled).

## Keeping the backend test suites honest

Two suites encode security expectations that changed with the removal of the
user -> admin reply path:

- `tests/db/run_tests.sql` asserts `user_post_message` is *refused* for every
  authenticated caller (`permission denied`, because execute is revoked). It no
  longer asserts a user can post.
- The MVola sections set `payment_required` (`test_harness.new_ticket(..., true)`)
  before opening a payment directly, while `create_kyc_request` sets it itself
  when MVola is enabled. Sections 14b/14c and 20/21 pin the create-time gate, the
  payments-off branch and the derived submission state.

`tests/scripts/mvola_e2e.py` drives the deployed project and covers the gate: a
start when the flag is off must return 409 `MVOLA_NOT_REQUIRED`, and an admin
`request_payment` must flip `payment_required`. Run it with the cloud `.env`
when the MVola migration is deployed; it provisions and deletes its own
throwaway users.

## Android push notifications (FCM)

A reply from `tangoturq@gmail.com` reaches the app in every state:

- **While open** — Realtime refreshes the list/badge (migration
  `20260928000600_push_tokens_and_realtime.sql` adds `notifications` and
  `kyc_requests` to the `supabase_realtime` publication). RLS still scopes
  delivery, so only the owner's rows arrive.
- **Background / closed** — the `email-webhook` Edge Function sends an FCM
  HTTP v1 message to the ticket owner's devices after storing the reply.
  `_shared/push.ts` holds the Firebase credential; the APK never does. The
  payload carries only a generic title/body and the opaque `ticket_id`.

Recipient rule: the push target is `kyc_requests.user_id`, resolved from the
signature-verified webhook — never from the client. `device_tokens` is RLS-scoped
(`user_id = auth.uid()`); registration goes through `register_device_token`,
a SECURITY DEFINER helper so a shared device can move its token to the account
that just signed in.

Setup to make push live (both are deliberate external steps, not code):

1. Create a Firebase Android app for `com.tango.kyc.tango_kyc_verification` and
   place `google-services.json` at `mobile/android/app/` (git-ignored). The
   Gradle build applies the `google-services` plugin only when that file exists,
   so a checkout without it still builds; without it `FirebasePushService`
   initialises to a harmless no-op.
2. Set the Edge Function secrets `FIREBASE_SERVICE_ACCOUNT` (full JSON,
   recommended) or `FIREBASE_PROJECT_ID` + `FIREBASE_CLIENT_EMAIL` +
   `FIREBASE_PRIVATE_KEY`. With neither, `pushConfigured` is false and the
   webhook stores the reply without a push — it never fails.

`flutter_local_notifications` requires core-library desugaring; it is enabled in
`mobile/android/app/build.gradle.kts`. Android 13+ needs `POST_NOTIFICATIONS`,
requested at sign-in.



## UI design system (dark neon) — 2026-09-27

- mobile/lib/ui/theme/app_theme.dart is the single source of truth: near-black
  navy canvas (AppColors.canvasDark), violet/magenta auras, brandGradient,
  glassy dark input fields. Both brightnesses derive from the same tokens.
- mobile/lib/ui/widgets/aurora.dart holds AuroraBackground, LogoMark,
  GradientButton and the press-scale wrapper. AuroraBackground is a no-op when
  the app-level backdrop is already active, and it only animates when explicitly
  asked (animate: true). The app opts in once via MaterialApp.builder in
  main.dart (animate: !kIsWeb); a nested backdrop is static so pumpAndSettle()
  in widget tests always settles.
- Screens mount their own Scaffold (for AppBar/back) but set
  backgroundColor: Colors.transparent so the single root aurora shows through.
- Copy is French across auth, OTP, home, requests, settings, profile, admin and
  onboarding. The French strings are asserted in mobile/test/screens_test.dart
  and mobile/test/otp_test.dart.

## Verification commands

- cd mobile && flutter analyze && flutter test must stay at 0 issues and all
  tests green.
- cd supabase/functions && deno test --no-check --allow-env --allow-net tests/
  --no-check skips two pre-existing Deno 2.x type errors (crypto.subtle
  importKey Uint8Array variance, and a std helper); runtime behaviour is
  unaffected.


## Building the release APK (verified 2026-09-28)

The toolchain is not on PATH and the JDK is not preinstalled. Full recipe:

    sudo apt-get install -y openjdk-21-jdk-headless     # only if `java` is missing
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
    export ANDROID_HOME=/workspace/sdk/android
    export ANDROID_SDK_ROOT=$ANDROID_HOME
    export PATH=/workspace/sdk/flutter/bin:$JAVA_HOME/bin:$PATH
    cd mobile && flutter pub get && flutter build apk --release

Notes:
- Flutter lives at /workspace/sdk/flutter (not on PATH by default).
- The Android SDK lives at /workspace/sdk/android; android/local.properties may
  still point at /tmp/android-sdk, so export ANDROID_HOME explicitly.
- .dart_tool/package_config.json can hold stale absolute paths after an
  environment move (/tmp/sdk/flutter, a wiped pub cache). `flutter pub get`
  rewrites it and re-downloads the app packages; the cache reset only leaves the
  Flutter SDK packages behind.
- Output: mobile/build/app/outputs/flutter-apk/app-release.apk (~56 MB).
- Published for download by copying it to /workspace/public_apk/ and serving that
  directory: python3 -m http.server 12000 --bind 0.0.0.0.
