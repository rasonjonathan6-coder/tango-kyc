/// Authentication contract and its Supabase implementation.
///
/// The interface keeps controllers testable without touching the network while
/// the production implementation delegates to Supabase Auth.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../models/models.dart';

/// Result of consuming an OAuth or password-recovery deep link.
///
/// Recovery cannot be detected from the callback URL itself: under the PKCE
/// flow (the default) it arrives as a bare `?code=...` with no `type=recovery`
/// parameter. The discriminator is recorded in the stored code verifier when
/// the reset is requested and surfaced here by the auth library.
enum AuthCallbackOutcome {
  /// No auth parameters in the link, or no session could be established.
  notAuthenticated,

  /// A session was established by an ordinary sign-in (OAuth or email link).
  signedIn,

  /// A session was established by a password-recovery link. The user must be
  /// taken to the reset-password screen.
  passwordRecovery,
}

/// The two email-OTP flows the application supports.
///
/// Kept deliberately narrow: Supabase exposes many `OtpType` values, but only
/// these two are meaningful to this app, and an accidental third would be a bug
/// rather than a feature.
enum EmailOtpPurpose {
  /// Confirming ownership of a freshly created account.
  signup,

  /// Proving ownership of an existing account before setting a new password.
  recovery,
}

/// Maps the narrow app purpose onto the auth library's `OtpType`.
OtpType otpTypeFor(EmailOtpPurpose purpose) => switch (purpose) {
      EmailOtpPurpose.signup => OtpType.email,
      EmailOtpPurpose.recovery => OtpType.recovery,
    };

/// Maps the auth library's `redirectType` to a routing outcome.
///
/// `redirectType` is `'passwordRecovery'` for a reset link and `null` for an
/// ordinary sign-in, so anything other than an explicit recovery marker is
/// treated as a normal sign-in.
AuthCallbackOutcome outcomeForRedirectType(String? redirectType) =>
    redirectType == AuthChangeEvent.passwordRecovery.name
        ? AuthCallbackOutcome.passwordRecovery
        : AuthCallbackOutcome.signedIn;

abstract class AuthService {
  Session? get session;
  User? get currentUser;
  Stream<AuthState> get authStateChanges;

  Future<void> signInWithPassword({required String email, required String password});
  Future<void> signUp({required String email, required String password, String? displayName});
  Future<void> sendPasswordReset(String email);

  /// Emails a one-time code for [purpose]. Does not create or change a session.
  Future<void> sendEmailOtp(String email, EmailOtpPurpose purpose);

  /// Exchanges the emailed code for a session. Throws on an invalid or expired
  /// code, so callers must surface the failure rather than assume success.
  Future<void> verifyEmailOtp({
    required String email,
    required String token,
    required EmailOtpPurpose purpose,
  });

  /// Re-sends a code. Subject to the project's per-hour email rate limit.
  Future<void> resendEmailOtp(String email, EmailOtpPurpose purpose);
  Future<void> updatePassword(String newPassword);
  Future<void> resendConfirmation(String email);
  Future<void> signOut();

  /// Starts Google OAuth. Returns false when the flow could not be launched.
  Future<bool> signInWithGoogle();

  /// Finalises an OAuth or recovery deep link.
  Future<AuthCallbackOutcome> handleAuthCallback(Uri uri);

  /// Loads the signed-in user's own profile row. `role` is server-owned and
  /// must never be inferred on the client.
  Future<Profile> loadProfile();
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  @override
  Session? get session => _auth.currentSession;

  @override
  User? get currentUser => _auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => _auth.onAuthStateChange;

  @override
  Future<void> signInWithPassword({required String email, required String password}) async {
    await _auth.signInWithPassword(email: email, password: password);
  }

  /// Creates an account. When email confirmation is enabled in Supabase the
  /// session remains null until the user confirms; callers must handle that.
  ///
  /// `emailRedirectTo` is passed explicitly so the confirmation link always
  /// carries the app's deep link. Without it the link falls back to the
  /// project's `SiteURL`, which works only while that value stays pointed at the
  /// deep link; passing it here keeps the target with the client that issued the
  /// request and is a no-op when `SiteURL` already matches.
  @override
  Future<void> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    await _auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: AppConfig.oauthRedirectUrl,
      data: displayName == null || displayName.trim().isEmpty
          ? null
          : {'full_name': displayName.trim()},
    );
  }

  @override
  Future<void> sendPasswordReset(String email) =>
      _auth.resetPasswordForEmail(email, redirectTo: AppConfig.oauthRedirectUrl);

  /// Completes a recovery link by setting the new password on the session
  /// established from the emailed token.
  @override
  Future<void> updatePassword(String newPassword) =>
      _auth.updateUser(UserAttributes(password: newPassword));

  @override
  Future<void> resendConfirmation(String email) => _auth.resend(
        type: OtpType.signup,
        email: email,
        emailRedirectTo: AppConfig.oauthRedirectUrl,
      );

  /// Sends the one-time code.
  ///
  /// `signInWithOtp` is used rather than the password-reset endpoint because it
  /// is the only flow that mails a *code*. It renders the project's "magic link"
  /// email template — Supabase has no separate "OTP" template slot — which is why
  /// that template must contain `{{ .Token }}` (see docs/EMAIL_SETUP.md).
  ///
  /// It shares one endpoint for both purposes, so the `purpose` is carried by the
  /// verification call instead of the send.
  ///
  /// `emailRedirectTo` is deliberately omitted: Supabase treats a request that
  /// carries one as a magic-link request, so leaving it out is what keeps this a
  /// pure code send. `OtpScreen` only accepts a code, and the template for this
  /// path carries `{{ .Token }}` and no link, so a deep link would serve no purpose.
  ///
  /// `shouldCreateUser: false` is deliberate: registration already inserted the
  /// (unconfirmed) user, and a recovery request must never mint an account for an
  /// address that has none. Supabase still answers 200 either way, which also
  /// avoids leaking whether an address is registered.
  @override
  Future<void> sendEmailOtp(String email, EmailOtpPurpose purpose) =>
      _auth.signInWithOtp(
        email: email,
        shouldCreateUser: false,
      );

  @override
  Future<void> verifyEmailOtp({
    required String email,
    required String token,
    required EmailOtpPurpose purpose,
  }) =>
      _auth.verifyOTP(
        email: email,
        token: token,
        type: otpTypeFor(purpose),
      );

  /// Re-sends the pending email for [purpose].
  ///
  /// This must never call [sendEmailOtp]: `signInWithOtp` mints a *new* PKCE
  /// code verifier and overwrites the stored one, which breaks every link that
  /// was already emailed (`bad_code_verifier` on exchange). Re-sending through
  /// `resend` uses the server's existing token instead and leaves any pending
  /// verification code untouched.
  ///
  /// `signup` maps to `OtpType.signup`; `recovery` maps to `OtpType.recovery`,
  /// which re-sends the link/code minted by the password-reset request. The
  /// project's per-hour email limit still applies.
  @override
  Future<void> resendEmailOtp(String email, EmailOtpPurpose purpose) => _auth.resend(
        type: purpose == EmailOtpPurpose.signup ? OtpType.signup : OtpType.recovery,
        email: email,
        emailRedirectTo: AppConfig.oauthRedirectUrl,
      );

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<bool> signInWithGoogle() => _auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: AppConfig.oauthRedirectUrl,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );

  @override
  Future<Profile> loadProfile() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('No signed-in user.');
    }

    // RLS restricts this row to the caller, and the role column can only be
    // written server side.
    final row = await _client
        .from('profiles')
        .select('id, email, display_name, avatar_url, role')
        .eq('id', user.id)
        .maybeSingle();

    if (row == null) {
      // The profile trigger may not have run yet; fall back to a user-level
      // profile so sign-in is never blocked.
      return Profile(id: user.id, email: user.email, role: 'user');
    }
    return Profile.fromMap(row);
  }

  @override
  Future<AuthCallbackOutcome> handleAuthCallback(Uri uri) async {
    final value = uri.toString();
    final hasAuthParams = value.contains('access_token') ||
        value.contains('code=') ||
        value.contains('error=');
    // Only links that carry auth parameters are ours to consume.
    if (!hasAuthParams) return AuthCallbackOutcome.notAuthenticated;

    final response = await _auth.getSessionFromUrl(uri);
    if (_auth.currentSession == null) {
      return AuthCallbackOutcome.notAuthenticated;
    }
    // `redirectType` is derived from the stored PKCE code verifier, so it is
    // correct in both the PKCE and implicit flows.
    return outcomeForRedirectType(response.redirectType);
  }
}
