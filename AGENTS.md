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
