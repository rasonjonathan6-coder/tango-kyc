/// Authentication and profile state shared across screens.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import '../services/auth_service.dart';

/// How long a profile read may take before the session's own user is used
/// instead. Keeps a slow or unreachable backend from blocking the first screen.
const Duration kProfileLoadTimeout = Duration(seconds: 10);

class AuthController extends ChangeNotifier {
  AuthController(this._auth);

  final AuthService _auth;

  Session? _session;
  Profile? _profile;
  bool _busy = false;
  bool _initialized = false;
  String? _lastError;
  StreamSubscription<AuthState>? _subscription;

  Session? get session => _session;
  Profile? get profile => _profile;
  bool get isSignedIn => _session != null;

  /// Only ever reflects the server-reported role. The backend re-checks it on
  /// every admin call, so this is a UI hint, not a security boundary.
  bool get isAdmin => _profile?.isAdmin ?? false;

  bool get busy => _busy;
  bool get initialized => _initialized;
  String? get lastError => _lastError;

  /// Loads the persisted session and starts listening for auth changes.
  ///
  /// [initialized] is set even when the profile read fails, stalls or throws, so
  /// this method can never leave the splash screen waiting forever. The profile
  /// is best-effort: a network hiccup must not block the first screen.
  Future<void> initialize() async {
    try {
      _session = _auth.session;
      if (_session != null) {
        await _loadProfile();
      }
      _subscription = _auth.authStateChanges.listen(_onAuthStateChange);
    } catch (error) {
      _lastError = error.toString();
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> _onAuthStateChange(AuthState state) async {
    _session = state.session;
    if (_session == null) {
      _profile = null;
      notifyListeners();
      return;
    }
    await _loadProfile();
    notifyListeners();
  }

  /// Reads the profile row, capped so a hanging request cannot freeze the UI.
  /// On any failure the session's own user is used as the profile, which is
  /// enough to route the user and never blocks sign-in.
  Future<void> _loadProfile() async {
    try {
      _profile = await _auth.loadProfile().timeout(kProfileLoadTimeout);
    } catch (_) {
      final user = _auth.currentUser;
      _profile = user == null ? null : Profile(id: user.id, email: user.email, role: 'user');
    }
  }

  Future<void> refreshProfile() async {
    await _loadProfile();
    notifyListeners();
  }

  /// Runs an auth action with consistent busy/error handling.
  Future<bool> run(Future<void> Function() action) async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on AuthException catch (error) {
      _lastError = error.message;
      return false;
    } catch (error) {
      _lastError = error.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> signIn({required String email, required String password}) =>
      run(() => _auth.signInWithPassword(email: email, password: password));

  Future<bool> signUp({
    required String email,
    required String password,
    String? displayName,
  }) =>
      run(() => _auth.signUp(email: email, password: password, displayName: displayName));

  Future<bool> sendPasswordReset(String email) => run(() => _auth.sendPasswordReset(email));

  Future<bool> updatePassword(String password) => run(() => _auth.updatePassword(password));

  Future<bool> resendConfirmation(String email) => run(() => _auth.resendConfirmation(email));

  /// Requests a one-time code. Sends a real email; nothing is simulated.
  Future<bool> sendEmailOtp({required String email, required EmailOtpPurpose purpose}) =>
      run(() => _auth.sendEmailOtp(email, purpose));

  /// Exchanges a code for a session. Returns false (with `lastError` set) on an
  /// invalid or expired code so the UI can offer a retry.
  Future<bool> verifyEmailOtp({
    required String email,
    required String token,
    required EmailOtpPurpose purpose,
  }) =>
      run(() => _auth.verifyEmailOtp(email: email, token: token, purpose: purpose));

  /// Re-sends a code. The server enforces its own per-hour limit; a rejection
  /// surfaces through `lastError`.
  ///
  /// Implemented without `signInWithOtp`, so it cannot overwrite the PKCE code
  /// verifier that a pending confirmation link depends on.
  Future<bool> resendEmailOtp({required String email, required EmailOtpPurpose purpose}) =>
      run(() => _auth.resendEmailOtp(email, purpose));

  /// True while a deep link is being consumed. Guards against a second delivery
  /// of the same link triggering a concurrent token exchange: the PKCE verifier
  /// is single-use, so a duplicate exchange would fail and could surface a
  /// spurious error.
  bool _handlingCallback = false;

  /// Consumes an OAuth or confirmation deep link exactly once.
  ///
  /// Delegates to the auth library, which exchanges the `?code=` using the
  /// stored PKCE verifier. A delivery that overlaps an in-flight exchange, and
  /// a link that carries no auth parameters, both return
  /// [AuthCallbackOutcome.notAuthenticated] without throwing, so the caller
  /// never has to special-case either.
  Future<AuthCallbackOutcome> handleCallback(Uri uri) async {
    if (_handlingCallback) {
      return AuthCallbackOutcome.notAuthenticated;
    }
    _handlingCallback = true;
    try {
      final outcome = await _auth.handleAuthCallback(uri);
      if (outcome != AuthCallbackOutcome.notAuthenticated) {
        // The exchange already stored the session; reflect it here so routing
        // does not depend on the auth-state event arriving first.
        _session = _auth.session;
        if (_session != null) await _loadProfile();
        notifyListeners();
      }
      return outcome;
    } finally {
      _handlingCallback = false;
    }
  }

  Future<bool> signInWithGoogle() => run(() async {
        final started = await _auth.signInWithGoogle();
        if (!started) {
          throw const AuthException('La connexion Google n’a pas pu démarrer.');
        }
      });

  Future<void> signOut() async {
    await _auth.signOut();
    _profile = null;
    _session = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
