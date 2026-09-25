# Google sign-in setup

> **Status:** the client code and the deep-link plumbing are implemented, but
> Google sign-in has **not** been tested against a real Google OAuth client,
> because that requires an account only you can create. Do not consider it
> working until you have completed the steps below and signed in on a device.
> Every other auth method is verified.

The app's identity, used in all three systems below, is:

| Setting | Value |
| --- | --- |
| Android package name / application ID | `com.tango.kyc.tango_kyc_verification` |
| Deep link scheme + host | `com.tango.kyc.tango_kyc_verification://login-callback` |
| Supabase provider | Google |

These three values must agree everywhere. A mismatch is what most often makes
the browser appear to succeed while the app stays on the login screen.

## 1. Create the Google Cloud OAuth client

1. Go to <https://console.cloud.google.com> and create or select a project.
2. **APIs & Services → OAuth consent screen**: choose *External*, fill in the app
   name, support email and developer contact. Add your own Google account under
   **Test users** while the app is unpublished.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
4. Application type: **Android**.
   - Package name: `com.tango.kyc.tango_kyc_verification`
   - SHA-1: see step 2 below.

   Create a second client for web/OAuth:
5. **Create credentials → OAuth client ID → Web application**.
   - Authorized redirect URI: `https://<your-project-ref>.supabase.co/auth/v1/callback`

   Supabase performs the token exchange, so it needs a **Web** client; the
   Android client is what lets Google verify the app's signature. You need both.

Record the **Web** client's *Client ID* and *Client secret*.

## 2. Get the signing certificate fingerprints

Debug keystore (development builds):

```bash
keytool -list -v \
  -alias androiddebugkey \
  -keystore ~/.android/debug.keystore \
  -storepass android -keypass android
```

Read `SHA1:` and `SHA256:` from the output.

Release keystore (Play Store builds) — use your own keystore and alias:

```bash
keytool -list -v -alias <your-alias> -keystore <path-to-keystore.jks>
```

If the app is distributed through Play App Signing, also copy the SHA-1/SHA-256
from **Play Console → Release → Setup → App signing**. Devices receive the
Play-signed build, so those are the fingerprints Google will present.

Add the SHA-1 to the Android OAuth client created above
(**Credentials → your Android client → edit**). You may register several
fingerprints under one client: debug, upload and Play signing.

## 3. Configure Supabase

Dashboard → **Authentication → Providers → Google**: enable it and paste the
**Web** client ID and secret from step 1.

Dashboard → **Authentication → URL Configuration → Redirect URLs**: add

```
com.tango.kyc.tango_kyc_verification://login-callback
```

This exact string is `AppConfig.oauthRedirectUrl` and the `intent-filter` in
`mobile/android/app/src/main/AndroidManifest.xml`. All three must match.

## 4. Why no `google-services.json`

This app uses Supabase's OAuth flow, not the Firebase/Google Sign-In SDK, so
there is no `google-services.json` and no Google Services Gradle plugin. Adding
one is not required and would not be used. `.gitignore` excludes it anyway so it
cannot be committed by accident if a future change introduces it.

## 5. Test

```bash
cd mobile
flutter run                                   # on a physical device or emulator
```

Then tap **Continue with Google**. A browser opens, you pick an account, and the
app should return to the home screen.

Checklist when it fails:

| Symptom | Likely cause |
| --- | --- |
| Stays on the login screen after choosing an account | Redirect URL not in the Supabase allow-list, or it does not match the manifest exactly |
| `redirect_uri_mismatch` from Google | The redirect URI in the Google client is not `https://<ref>.supabase.co/auth/v1/callback` |
| `DEVELOPER_ERROR` / signature error | SHA-1 of the signing key not registered on the Android client |
| Works in debug, not in release | Play App Signing SHA-1 missing |

## 6. Reporting status honestly

Until the steps above are done and a real sign-in has succeeded on a device,
treat Google sign-in as unconfigured. The app surfaces the provider error
returned by Supabase rather than pretending the login worked, and the README
lists this as needing configuration.
