// Regression tests for the startup hang.
//
// The failure this guards against: on a real device the app stayed on the
// launcher logo because the first screen waited on operations that could never
// complete. These tests drive the real [AuthController] and [RootGate] and prove
// that a stalled or throwing backend can no longer keep the app on the splash.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:tango_kyc_verification/main.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/splash_screen.dart';

import 'fakes.dart';

Session _session() => Session(
      accessToken: 'access-token',
      tokenType: 'bearer',
      refreshToken: 'refresh-token',
      expiresIn: 3600,
      user: const User(
        id: 'stalled-user',
        appMetadata: {},
        userMetadata: {},
        aud: 'authenticated',
        email: 'user@example.com',
        createdAt: '2026-09-27T00:00:00Z',
      ),
    );

/// An auth service with a live session whose profile read never resolves,
/// mimicking a backend that accepted the connection but never answers.
class _StalledProfileAuthService implements AuthService {
  @override
  Session? get session => _session();

  @override
  User? get currentUser => session?.user;

  @override
  Stream<AuthState> get authStateChanges => const Stream<AuthState>.empty();

  @override
  Future<Profile> loadProfile() => Completer<Profile>().future;

  @override
  Future<void> signInWithPassword({required String email, required String password}) async {}
  @override
  Future<void> signUp({required String email, required String password, String? displayName}) async {}
  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<void> sendEmailOtp(String email, EmailOtpPurpose purpose) async {}
  @override
  Future<void> verifyEmailOtp(
      {required String email, required String token, required EmailOtpPurpose purpose}) async {}
  @override
  Future<void> resendEmailOtp(String email, EmailOtpPurpose purpose) async {}
  @override
  Future<void> updatePassword(String newPassword) async {}
  @override
  Future<void> resendConfirmation(String email) async {}
  @override
  Future<void> signOut() async {}
  @override
  Future<bool> signInWithGoogle() async => false;
  @override
  Future<AuthCallbackOutcome> handleAuthCallback(Uri uri) async =>
      AuthCallbackOutcome.notAuthenticated;
}

Future<SettingsController> _settings() async {
  FlutterSecureStorage.setMockInitialValues({});
  final settings = SettingsController(const FlutterSecureStorage());
  await settings.load();
  await settings.completeOnboarding();
  return settings;
}

Widget _host(AuthController auth, SettingsController settings) {
  final kyc = FakeKycService();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthController>.value(value: auth),
      ChangeNotifierProvider<SettingsController>.value(value: settings),
      ChangeNotifierProvider<NotificationsController>(
          create: (_) => NotificationsController(kyc)),
    ],
    child: const MaterialApp(
      home: RootGate(linkStream: Stream.empty(), splashMinimum: Duration(seconds: 2)),
    ),
  );
}

/// An auth controller that never reports itself initialized, mimicking a
/// session restore that hangs forever. Used to prove the splash ceiling.
class _NeverInitializedAuth extends AuthController {
  _NeverInitializedAuth() : super(FakeAuthService());

  @override
  bool get initialized => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize never blocks on a stalled profile read', () async {
    final auth = AuthController(_StalledProfileAuthService());

    // Not awaited to completion on purpose: only the synchronous part runs before
    // the profile timeout would fire. `initialized` must stay false here because
    // the profile read is still pending.
    final pending = auth.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(auth.initialized, isFalse);

    // After the profile timeout the method must resolve and mark itself ready.
    await pending.timeout(const Duration(seconds: 30));
    expect(auth.initialized, isTrue);
    expect(auth.profile, isNotNull);
    expect(auth.profile!.id, 'stalled-user');
  });

  testWidgets('a restore that never completes still leaves the splash',
      (tester) async {
    final auth = _NeverInitializedAuth();
    final settings = await _settings();

    await tester.pumpWidget(_host(auth, settings));
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);

    // Past the hard ceiling the gate must proceed even though the restore never
    // reported back, so the user is not trapped on the logo.
    await tester.pump(kSplashMaximumDuration + const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(SplashScreen), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
