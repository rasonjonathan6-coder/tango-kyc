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
