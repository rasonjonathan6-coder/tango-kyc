# AGENTS.md

Repository notes for future sessions. Keep this factual and current; it is not a
substitute for the docs in `docs/`.

## Scope discipline (read this first)

These rules exist because an agent once shipped an unrequested migration that
broke the user/admin reply flow in production. Follow them strictly.

- Do exactly what was asked, and nothing more. No refactors, no "while I am
  here" cleanups, no new migrations and no dependency bumps unless explicitly
  requested.
- If a task seems to require a change outside the request, stop and ask first.
- Never change the model or the agent profile on your own initiative.
- Any schema change must be a requested, versioned migration. If a migration
  turns out to be wrong, add a corrective migration instead of rewriting
  history.
- Prefer the smallest change that fixes the reported problem, and prove it with
  the existing test suites before claiming success.

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

The user -> admin reply path was removed once, then deliberately restored, so
the DB suite now pins the *restored* contract rather than the removal:

- `tests/db/run_tests.sql` section 11 asserts `user_post_message` is callable by
  `authenticated` and enforces, in the function body, the four rules that make
  that grant safe: `auth.uid()` present (`AUTH_REQUIRED` otherwise), ticket
  ownership (`FORBIDDEN`), ticket status (`TICKET_CLOSED` for the owner of a
  closed ticket) and the 5-per-minute limit (`RATE_LIMITED`). It also asserts
  the 20 000-character cap truncates rather than fails, that `anon` still has no
  execute grant, and that a refused reply writes no row. `public.messages` has
  no author column, so "the author is the caller" is asserted via
  `sender_type = 'user'` plus ownership of the ticket.
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
  onboarding. The French strings are asserted in mobile/test/screens_test.dart,
  mobile/test/otp_test.dart and mobile/test/french_copy_test.dart.

## Product copy is French — 2026-09-28

The reference artwork is French and the audience is French-speaking, so an
English string that reaches a user is a defect, not a style choice. A sweep of
`mobile/lib/ui/` found the older auth, MVola and admin screens had English
labels while the newer screens (onboarding, request-sent, help/support,
support-chat) were already French; those are now localised too.

`mobile/test/french_copy_test.dart` pins the user-visible wording of every
screen that renders without a backend (splash, onboarding, login, register,
forgot-password, request-sent, help/support). When a label is reworded, update
the expectation there; an English label should never come back silently.

Three things that look like English strings but are **not** copy — leave them
alone:

- `'WELCOME'` / `'TK-…'` are backend data sentinels compared against
  `registerValue` / `ticketCode`, never rendered as a label.
- `'admin'` / `'user'` / `'welcome'` are `role` and notification-`type` keys
  mapped to French in `switch` expressions.
- `'Email'`, `'Support'` and `'Tango KYC Verification'` are correct French
  (and the product name).

## Master backdrop measurement — 2026-09-27

The reference mockups live at `/workspace/artifacts/mockup/screens/` (18 PNGs,
small: 72–211 px wide). Compare renders to them **after resizing the render to
the mockup's pixel size** — the mockups are low-res, and comparing a 360 px
render against them directly manufactures a false brightness gap.

Method that worked: mask to the darkest pixels (`luma < 22`), then average per
cell of a 6x6 grid. That isolates the canvas from cards and text.

- The canvas is **cool**. Over the dark background the mockup measures
  R/B ≈ 0.09 and G/B ≈ 0.13. An all-magenta/violet pool set cannot reach that:
  it lands near R/B ≈ 0.29, i.e. three times too red. The fix is a broad, low
  blue wash (`AppColors.poolCanvasBlue`, radius > viewport width, halo only)
  plus a teal pool (`AppColors.poolTeal`) for the green channel, with the
  magenta pools kept **small and inside the top/bottom bands** so they cannot
  tint the content area.
- A pool whose `radius` fraction exceeds 0.5 skips the bright core pass (the
  painter does this) — a core that wide reads as a hotspot in mid-page.
- Dark-mode cards are **blue glass**, not neutral grey: the mockup reads
  `rgb(0, 8, 44)`. `AppColors.glassFill` carries that tint; a white wash
  desaturates the composition and raises the red channel.
- Remaining per-screen deltas (home hero, loading, profile) are **content**
  weight — the mockup thumbnails carry fewer/lighter widgets than the real
  screens — not backdrop error. Do not chase them by dimming the canvas.

`AuthHalo` no longer exists (it was removed with the auth-kit rewrite); the
backdrop is the single `AuroraBackground` at the root.

### Reading the mockups without vision — 2026-09-28

An agent session may have no vision: image reads return a text description and
browser screenshots are written to disk as a path, never as pixels. Do not
claim a visual comparison was done when it was not. Two things *do* work and
are worth using instead:

- **Text**: `tesseract` is installed with `fra`+`eng`. Upscale the thumbnail 6x
  with LANCZOS, then
  `tesseract /tmp/ocr.png - -l fra+eng --psm 6`. That recovered every mockup's
  title, labels and button text, which is how the English-copy gaps above were
  found. OCR is unreliable on tiny text, so treat it as strong evidence for
  wording, not for exact glyphs.
- **Colour/geometry**: measure pixels numerically (PIL/numpy) rather than
  eyeballing — see the method above.

## Login screen (premium auth pass) — 2026-09-28

- mobile/lib/ui/widgets/auth_kit.dart owns the auth visual kit: BrandLockup
  (mark + "Tango" + gradient "Live" badge), NeonField
  (glass field framed by a 1.6dp gradient hairline, large leading icon, lavender
  label, focus bloom), GlassActionCard (tappable glass surface), GoogleGlyph
  (the four-colour ring, painted — the project ships no Google asset),
  OrDivider and AuthFooter.
- mobile/lib/ui/screens/login_screen.dart is presentation-only. Every handler is
  the pre-existing one: same AuthController calls, same Validators, same routes
  to ForgotPasswordScreen / RegisterScreen / OtpScreen. Do not re-implement any
  auth flow here.
- AppTheme.actionGradient (rose #FF0A8A → violet #A000FF → electric #168CFF) is
  the primary action fill; AppTheme.neonHairline frames the fields. New neon
  tokens: AppColors.rose / .electric / .cyan.
- GradientButton now takes optional radius, gradient and textStyle; existing
  call sites are unaffected.
- Layout targets 1080x2400 (360x800 logical). The secondary entries go two-column
  at >= 300dp of available width and stack below that. The body is a
  SingleChildScrollView so the keyboard never traps the user; the primary action
  stays reachable by scrolling on every tested viewport.
- Avoid CrossAxisAlignment.stretch inside a scroll view: it forces an infinite
  height. Use IntrinsicHeight when two cards must share a row height.
- mobile/test/login_screen_test.dart asserts the visual system, responsive
  behaviour, keyboard behaviour and that each entry point reaches its real
  handler. Its layout assertions are relative (top/left ordering) because the
  test font's metrics differ from the platform font's.

## Verification commands

- cd mobile && flutter analyze && flutter test must stay at 0 issues and all
  tests green. Baseline after the premium auth pass: 166 tests.
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

## Supabase build config must be injected, or the app boots blank — 2026-10-01

`AppConfig` (`mobile/lib/config/app_config.dart`) reads `SUPABASE_URL` and
`SUPABASE_ANON_KEY` from **two** sources only, in this order: `String.fromEnvironment`
(`--dart-define`) first, then the bundled `assets/env` loaded by `flutter_dotenv`.
There is **no** `.env`, no root file, no runtime lookup, and `mobile/assets/env`
is gitignored and normally absent — only `assets/env.example` (placeholders) is
tracked. So a plain `flutter build apk --release` / `--debug` embeds **neither**
value and the app stops at `_ConfigurationMissingApp`:

    Application configuration required — SUPABASE_URL / SUPABASE_ANON_KEY are not set

`main.dart` checks `AppConfig.isConfigured` **before** `Supabase.initialize`, so
this screen also hides any Firebase/FCM problem until it is fixed.

Build with the values passed explicitly (both are public client values; the anon
key is RLS-protected, never use the service-role key here):

    cd mobile && flutter build apk --release \
      --dart-define=SUPABASE_URL="$SUPABASE_URL" \
      --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

Verify the values really landed **without printing them**: unzip the artifact and
`grep -qF "$SUPABASE_URL"` against `strings` of `assets/flutter_assets/kernel_blob.bin`
(debug) or `lib/<abi>/libapp.so` (release). Do not pattern-match a hardcoded JWT
prefix — `strings` splits the token and it reads as a false MISSING.

Two more traps seen in this session:
- The release build **silences `debugPrint`**, so `[fcm]` logs are invisible
  there. Use the **debug** APK to observe FCM on a device.
- This sandbox's toolchain is at `/opt/flutter` and `/opt/android-sdk` (not
  `/workspace/sdk/...`); export `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64`
  and `ANDROID_HOME=/opt/android-sdk`, and put `build-tools/<ver>` on PATH for
  `aapt2`/`apksigner`.

## Recovering the app in a fresh conversation — 2026-10-01

A new conversation starts with an empty `/workspace/project`, so the source and
the signing material have to be brought back before anything can be built or
served. The source is on GitHub; the keystore is not.

- Source of truth: `github.com/<owner>/tango-kyc`, branch `main`. `git clone`
  (or `git fetch origin main && git checkout -B main origin/main`) is enough.
- Signing material is gitignored and lives only in the sandbox that built the
  APK: `mobile/android/app/upload-keystore.jks` (alias `tango-kyc-upload`,
  certificate SHA-256 `5ae5f7a4...`) plus `mobile/android/key.properties`. The
  keystore has been copied into this workspace, and `key.properties` was written
  from the `TANGO_KEYSTORE_PASSWORD` / `TANGO_KEY_PASSWORD` secrets. Never
  regenerate the keystore: a different key breaks upgrades for installed users.
- Rebuild with `flutter build apk --release`, then copy the artifact to
  `/workspace/public_apk/` and serve it on port 12000. The reachable URL is
  `https://work-1-<runtime-host>/<file>.apk` (work-1 maps to 12000, work-2 to
  12001). The `<runtime-host>` changes every session, so a previously shared APK
  link stops working as soon as its sandbox is gone — that is why an old link
  can 502 while the file still exists elsewhere.
- A still-running sandbox keeps its build output. Fetch a file straight from it
  with `GET {conversation_url base}/api/file/download?path=<abs path>` and the
  conversation's `X-Session-API-Key`, which `GET /api/v1/app-conversations?ids=`
  returns. The path must be in the query string; a path segment returns 404.

### Reinstalling the wiped toolchain — 2026-10-01

`/opt` (Flutter, Android SDK) and the JDK are gone on a fresh sandbox. Reinstall
before building:

    sudo apt-get install -y openjdk-21-jdk-headless
    # Android cmdline-tools must live in a writable dir; /opt is root-owned and
    # the agent cannot execute the SDK binaries from there.
    mkdir -p /workspace/android-sdk/cmdline-tools
    # unzip commandlinetools-linux-<latest>_latest.zip, move to .../cmdline-tools/latest
    sdkmanager --install "platform-tools" "platforms;android-36" \
      "build-tools;36.0.0" "ndk;28.2.13676358"

The platform/build-tools/NDK versions must match what
`flutter.compileSdkVersion` / `flutter.ndkVersion` report for the installed
Flutter, or the Gradle build fails on a missing platform. Point
`android/local.properties` `sdk.dir` at the new SDK and export `JAVA_HOME`.

The exact Supabase build config (URL + publishable/anon key) is recoverable from
an already-built APK without retyping it: the debug artifact embeds both strings
in `assets/flutter_assets/kernel_blob.bin` (the release one in `lib/<abi>/libapp.so`).
This is the same public, RLS-protected pair the app shipped with — never a secret
key. Pass them back through `--dart-define`; do not commit them.

## Firebase Android config — 2026-09-28

`mobile/android/app/google-services.json` is the **real** config for the
`tango-kyc` Firebase project (package `com.tango.kyc.tango_kyc_verification`).
It is gitignored (root `.gitignore` and `mobile/android/.gitignore`) and must
never be committed or printed.

A release build **is** a valid Firebase check: the Google Services Gradle plugin
bakes `project_info` into `resources.arsc` as `google_app_id`,
`gcm_defaultSenderId`, `google_api_key` and the project id. After a build,
confirm the config actually landed rather than trusting the on-disk file:

```bash
python3 - <<'PY'
import zipfile
z=zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk')
arsc=z.read('resources.arsc')
for k in (b'gcm_defaultSenderId', b'google_app_id', b'google_api_key'):
    assert k in arsc, k
PY
```

Caveat: this proves the config was packaged, not that FCM delivers. Delivery,
project liveness and API-key authorisation need a real device and a real send.

The upload flow drops user-supplied files under `/home/openhands/workspace/`;
they do **not** land at their target path automatically. Check there when a file
is reported uploaded but missing.

Release signing reads `android/key.properties` (KEYSTORE_PATH/PASSWORD, KEY_ALIAS,
KEY_PASSWORD) with `upload-keystore.jks` resolved relative to the app module —
i.e. `android/app/upload-keystore.jks`. `apksigner verify --print-certs` should
show `CN=Tango KYC Verification, OU=Release`; a debug-signed artifact is not
publishable.

## User replies on a ticket (in-app discussion) — 2026-09-29

The in-app reply is the counterpart of an inbound email reply: both land as a
`user` row in `public.messages` on the same ticket. The write path is
`reply-to-ticket` Edge Function -> `public.user_post_message`.

The trap: `user_post_message` is `security definer` and derives the author from
`auth.uid()`. An Edge Function that calls it with `serviceClient()` sends the
service-role key, whose JWT has **no `sub` claim**, so `auth.uid()` is NULL and
the RPC fails with `AUTH_REQUIRED` — even for a legitimately authenticated user.
Every function that calls a user-scoped SQL function must use
`userClient(caller.token)` (see `mvola-payments`), never `serviceClient()`.

The closed-ticket rule is enforced in SQL, not only in the UI: a ticket whose
status is `closed` raises `TICKET_CLOSED`, mapped in `_shared/http.ts` and shown
in French by `ErrorMessages`. The Flutter composer is hidden for a closed ticket
and reloads the ticket when the server answers `TICKET_CLOSED`, so a ticket
closed mid-session flips to read-only.

`verify_jwt = false` is correct for `reply-to-ticket` (like the other functions):
`requireUser` verifies the token in code, and `verify_jwt = true` would reject
the CORS preflight. The call still carries the user's JWT because
`client.functions.invoke` attaches the session token.

### Brand mark

Use `BrandMark` (`lib/ui/widgets/brand_mark.dart`), which renders
`assets/logo_transparent.png`. `LogoMark` in `aurora.dart` is the legacy
gradient-plate-with-Material-icon mark; do not reintroduce it for brand identity.

### Four-tab shell

`AppShell` exposes Accueil | Historique | Profil | Paramètres. All four are built
inside an `IndexedStack`, so every tab's providers must be present even when
another tab is shown (the settings tab needs `SettingsController`). Widget tests
that mount `AppShell` must provide `AuthController`, `KycController`,
`NotificationsController` **and** `SettingsController`.

### Email roles and ticket-id exposure

Two mail roles are distinct and neither falls back to the other:

- `ADMIN_EMAIL` — the administration identity (the human who acts in the admin
  dashboard). Read by `adminEmail()`; unset raises `ADMIN_EMAIL_NOT_CONFIGURED`.
- `KYC_SUPPORT_EMAIL` (alias `KYC_RECIPIENT_EMAIL`) — the société/support KYC
  mailbox. It receives the approved KYC request and the user's in-app messages,
  and replies to them. Read by `supportRecipient()`; unset raises
  `KYC_SUPPORT_EMAIL_NOT_CONFIGURED`, deliberately not falling back to
  `ADMIN_EMAIL`, so KYC data is never mailed to the wrong mailbox.

No outbound email exposes the ticket code or uuid. The `Reply-To` is always the
tokenised inbound address (`reply+<reply_token>@…`), so replies are matched
server-side by token and thread id. `record_inbound_reply` refuses a reply on a
`closed` ticket with `TICKET_CLOSED` (no message stored, ticket never reopened);
`email-webhook` acknowledges such an event instead of returning 500, so the
provider stops retrying.

Inbound thread resolution (`resolve_ticket_for_reply` step 3) builds the id array
with a subquery, not by assigning set-returning `regexp_matches(..., 'g')` to a
`text[]` scalar — a real `References` chain carries several ids, and the scalar
assignment raised `query returned more than one row`.

When a user replies in-app, `reply-to-ticket` emails the support mailbox through
`sendUserMessageToSupport`; the idempotency key is the stored message row id, so
a retried call is suppressed while a genuinely new message is always sent.


## Email threading rule: USER -> SOCIÉTÉ (KYC conversation) — 2026-10-01

Gmail files a message under an existing conversation from **two** things
together: the threading headers (`In-Reply-To` / `References`) **and** the
subject. Both must stay consistent with the KYC request conversation; keeping
only one of them is not enough, and a mismatch silently starts a **new**
conversation. This rule applies to every USER -> SOCIÉTÉ email, in particular
the in-app user message sent by `sendUserMessageToSupport`.

1. **The subject must stay the request's subject.** The USER -> SOCIÉTÉ message
   reuses the original request subject, prefixed with `Re: `
   (`userMessageToSupportEmailContent` builds
   `Re: ${adminRequestEmailContent(ticket).subject}`). Do **not** introduce an
   independent generic subject such as
   `Nouveau message d'un utilisateur - vérification de compte`: a distinct
   subject breaks the thread even when the headers are correct.

2. **Thread with the real headers, never invented ones.** The message carries
   `In-Reply-To` and `References`, produced by `threadingHeaders(ticket)`.

3. **`In-Reply-To` points at a genuine Message-ID.** It must reference the
   actual RFC `Message-ID` of the last COMPANY -> USER email that belongs to the
   KYC conversation concerned — the value stored in `last_outbound_message_id`.

4. **`last_outbound_message_id` is the request email's anchor.** A COMPANY -> USER
   confirmation that does **not** belong to the request conversation (e.g. the
   "Votre demande … a bien été envoyée" submission mail from
   `sendUserRequestSubmittedEmail`) must **not** overwrite this anchor.
   Overwriting it makes `In-Reply-To` point at a message the société never
   received, so Gmail starts a new conversation.

5. **Every function that shares `_shared/email-provider.ts` must honour this
   distinction.** Before adding or changing any `record_outbound_email` call,
   ask whether the new email should really become the threading anchor of the
   KYC conversation. Only an email the société is expected to reply to belongs
   on the anchor.

6. **Never fabricate a `Message-ID`** from a ticket uuid, a user uuid, a
   `ticket_code`, or a reply token. `asMessageId` only accepts a value that looks
   like a real `Message-ID` (it must contain `@`); a provider uuid (Resend) is
   never wrapped into a false one.

7. **If no usable real `Message-ID` exists, send no threading header at all.**
   `threadingHeaders` returns `undefined` rather than emitting a fake
   `In-Reply-To` / `References`.

8. **Any future change to `email-provider.ts` must check, at the same time:**
   subject; `Message-ID`; `In-Reply-To`; `References`; `last_outbound_message_id`;
   `email_thread_id`; the message type/direction; the effect on COMPANY -> USER;
   and the effect on USER -> COMPANY.

9. **Both halves of Gmail threading must be preserved:** the threading headers
   **and** subject/conversation consistency.

Context of the bug this rule fixes (2026-10-01). The threading break had **two**
causes: (A) the USER -> SOCIÉTÉ message used a subject different from the request
email; (B) `last_outbound_message_id` was overwritten by a COMPANY -> USER
confirmation that was not part of the request conversation. The fix shipped as
`reply-to-ticket` **v5**, `admin-actions` **v48**, `email-webhook` **v45**
(unchanged). Do not change these versions as part of documentation work.

## Finalization pass — 2026-10-03

Continuation of the "final testable version" work. What was verified and built:

- `icone.png` is **still absent** from the repository, its git history (all
  branches) and the whole filesystem. Feature #9/#10 (replace the launcher icon
  with `icone.png`) therefore remains **NOT DONE** by design: the brief says
  "cherche d'abord le fichier réel, ne crée pas une fausse icône". The only
  image assets present are the brand marks (`logo_transparent.png`,
  `logo_home_cropped.png`) and unrelated screenshots. The launcher icon is still
  the Flutter template default (byte-identical to the SDK's `ic_launcher.png`),
  and the notification glyph is the intentional monochrome `ic_stat_tango`
  (Android discards colour for status-bar icons, so a full-colour logo would
  render as a white square — the current vector is correct).
- Chatbot hardening: `_shared/chatbot.ts` now (a) documents Tango.me explicitly,
  (b) forbids disclosing any email/contact in the system prompt, and (c) the
  `replyLeaksInternals` backstop rejects **any** email address. Deno suite:
  18/18 chatbot tests, 192/192 overall.
- New French error strings for `LLM_NOT_CONFIGURED` / `LLM_UPSTREAM_ERROR` /
  `METHOD_NOT_ALLOWED` in `lib/core/validators.dart`.
- Verified as already implemented and correct: OTP login flow (8-digit code,
  resend + cooldown), robust startup (`_SupabaseUnavailableApp`, auth-stream
  `onError`, capped profile load, splash floor+ceiling), clickable links
  (`url_detector.dart` + `LinkifiedText`), read-only request detail (no
  composer), dark mode ON/OFF persisted via `SettingsController`, and the
  assistant Edge Function `chat-assistant` (provider key stays server-side).
- Flutter: `flutter analyze` clean, `flutter test` 486/486.

### Building and serving the final APK (this sandbox)

    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
    export ANDROID_HOME=/workspace/android-sdk ANDROID_SDK_ROOT=$ANDROID_HOME
    export PATH=/workspace/flutter/bin:$JAVA_HOME/bin:$PATH
    cd mobile && flutter pub get
    SUPABASE_URL=$(cat /tmp/sb_url) SUPABASE_ANON_KEY=$(cat /tmp/sb_key) \
      flutter build apk --release \
      --dart-define=SUPABASE_URL="$SUPABASE_URL" \
      --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

The two public build values (project ref `hbvjpawnszzcbcjmbkuf` and the anon
key) are recoverable from any prior APK: extract `lib/arm64-v8a/libapp.so` and
grep for `https://<ref>.supabase.co` and the first `eyJ…` JWT (payload role is
`anon`). They are public, RLS-protected client values — never a secret key.

Artifacts are published on the two work ports:
- `https://work-1-<runtime-host>/tango-kyc-final.apk` (port 12000, APK download)
- `https://work-2-<runtime-host>/` (port 12001, web build)
- The web build also carries `/tango-kyc-final.apk` (copied into `build/web/`).
The `<runtime-host>` changes every session — an old shared link 502s once its
sandbox is gone, even though the file still exists. This is why the previous
link stopped working.

### Launcher icon

The real source is the repository file
`377FB271-870A-4503-BA19-0541DA3D7DE6.png` (1254x1254 RGB, white background),
added on `origin/main` in commit `fc32e19`. It is the only icon source: do not
redraw or substitute it. From it, `mobile/android/app/src/main/res/` carries:

- `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` — legacy square icon
  (48/72/96/144/192), a straight LANCZOS downscale of the whole image;
- `mipmap-{…}dpi/ic_launcher_foreground.png` — adaptive foreground
  (108/162/216/324/432), the content cropped to its bbox, near-white made
  transparent, the logo centred at ~62% of the 108dp canvas;
- `mipmap-anydpi-v26/ic_launcher.xml` — adaptive icon (background + foreground);
- `values/ic_launcher_background.xml` — `#FDFDFD`, sampled from the corners.

`AndroidManifest.xml` sets both `android:icon` and `android:roundIcon` to
`@mipmap/ic_launcher`. The notification icon stays the monochrome vector
`drawable/ic_stat_tango` (a launcher photo is unusable as a status-bar icon).

To verify what actually shipped: `aapt2 dump resources` on the APK maps each
density to a `res/*.png`; those files are pixel-identical to the generated
sources. `unzip -l` will not show them — AAPT2 compiles resources into
`resources.arsc`, so the PNGs live under obfuscated `res/` names.

### Known production gap: chat-assistant is not deployed

As of this pass, `POST /functions/v1/chat-assistant` returns HTTP 404
`NOT_FOUND` on the production project, while `create-kyc-request`,
`mvola-payments` and `admin-actions` return 401 (deployed, auth-guarded). The
assistant is a signed-in feature, so its cost cannot be driven anonymously; the
app degrades gracefully (an error is shown, no crash). Deploy it with
`supabase functions deploy chat-assistant` and set a provider key
(`LLM_API_KEY` or a provider-specific one) as an Edge Function secret. Do not
deploy from here without explicit instruction.

### The request detail screen: the reply composer is payment-gated

`mobile/lib/ui/screens/request_details_screen.dart` is no longer strictly
read-only. It pins a footer below the conversation: a composer (a `LabeledField`
plus a `GradientButton` "Envoyer") when `_canReply` is true, otherwise the
read-only explanation. `_canReply` is true only when:

- the synthetic welcome ticket (`register_value == 'WELCOME'`) never shows one;
- a closed ticket never shows one;
- a request with `paymentRequired` whose payment is not approved
  (`isSubmitted` false) stays read-only, with the notice "La réponse sera
  disponible après confirmation de votre paiement."

The gate is UX only. The authoritative rule is `public.user_post_message`
(migration `20260930000200_gate_user_reply_on_payment.sql`), which re-derives
`is_submitted` inside the same `select ... for update` and raises
`PAYMENT_NOT_CONFIRMED` otherwise; the `reply-to-ticket` Edge Function only
forwards to it. `PAYMENT_NOT_CONFIRMED` is mapped in `core/validators.dart` and
surfaced as a SnackBar, then the screen reloads so it reflects the server state.
`mobile/test/ticket_reply_test.dart` pins this contract — update it with any
change to the composer rule.

### APK delivery: the download servers are ephemeral

The shared `work-1` / `work-2` URLs are only alive while a
`python3 -m http.server` is running in `/workspace/public_apk`. After a restart
the old link 404s; relaunch both ports (12000 and 12001) and re-copy the built
APK to `tango-kyc-final.apk`, then refresh `tango-kyc-final.apk.sha256`
(`sha256sum`). The SHA-256 must match the file actually served.

The host name in the URL is itself session-specific: it embeds the runtime id
(e.g. `work-1-<runtime>.prod-runtime.all-hands.dev`) and changes when the
environment is recreated, so a previously shared link can 404 even while the
server runs. Always build the link from the runtime's current `work-1`/`work-2`
host and confirm it with a `HEAD` request before sharing. `tango-kyc-final.apk`
is the release build of `main` and must stay byte-identical to
`mobile/build/app/outputs/flutter-apk/app-release.apk`.

### Notification routing: the form address never decides the destination

Two outbound mails leave the system, and neither destination may come from the
KYC form. `register_value` (`tango_registration_email`) stays a request datum
that is displayed in the request, and nothing else.

- The société/support notification goes to `supportRecipient()`, read from
  `KYC_SUPPORT_EMAIL`, then `KYC_RECIPIENT_EMAIL`, then the legacy
  `ADMIN_KYC_RECIPIENT`. There is no fallback to `ADMIN_EMAIL`: an unconfigured
  deployment throws `KYC_SUPPORT_EMAIL_NOT_CONFIGURED` rather than mailing KYC
  data to the wrong mailbox.
- Every user-facing notification (submission confirmation, admin reply, inbound
  email reply) goes to the account address, resolved server side by
  `accountEmail(kyc_requests.user_id)` from `profiles.email` (kept in sync with
  `auth.users.email` by `on_auth_user_created`). `userReplyRecipient` accepts
  only that account email, so the form value cannot influence it. A user whose
  account has no address is never mailed: no address is invented.

`supabase/functions/tests/reply_recipient_test.ts` and
`notification_recipient_test.ts` pin these rules; update them with any change.

### Société email format and the registered-number rule

`adminRequestEmailContent` (`_shared/email-provider.ts`) is the only generator
of the société email. Its subject is exactly
`Manual KYC Verification request - Profil Creator: (<profile link>)`, where the
link is the request's own `tango_profile_link` (never a fixed value). The body
lists only the field the user actually supplied: `Register email:` for an email
registration or `Register number:` for a number, never both and never `null`.
The ticket code (`TNG-KYC-…`), the ticket uuid, `Ticket ID`, and the payment
block stay out of both the subject and the body; the code remains in the
database for reply correlation via the tokenised Reply-To and thread ids.

The registered number (the KYC form value, **not** the MVola payer number,
which is unchanged) must be exactly ten digits starting with 032/033/034/037/038.
The rule lives in `_shared/register.ts` (`isValidRegisterNumber`) and
`mobile/lib/core/validators.dart`, and the user-facing message is
`Veuillez vérifier votre numéro.` (`REGISTER_PHONE_INVALID`). Tests:
`tests/register_number_test.ts`, `tests/submission_email_test.ts`,
`mobile/test/validators_test.dart`.
