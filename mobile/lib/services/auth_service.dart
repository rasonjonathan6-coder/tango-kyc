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
  @override
  Future<void> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    await _auth.signUp(
      email: email,
      password: password,
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
  Future<void> resendConfirmation(String email) =>
      _auth.resend(type: OtpType.signup, email: email);

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
