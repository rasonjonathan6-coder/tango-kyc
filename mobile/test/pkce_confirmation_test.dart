// Email-confirmation (PKCE) flow tests.
//
// The observed device bug was `400 bad_code_verifier`: a second code request
// minted a new PKCE verifier and overwrote the one the emailed confirmation
// link depends on. These tests pin the corrected contract:
//
//   signup -> wait for the link -> single PKCE exchange -> session -> AppShell
//
// They drive the production widgets (`RootGate`), controller
// (`AuthController`) and service guard (`SupabaseAuthService`); only
// `FakeAuthService` stands in for the network.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:tango_kyc_verification/main.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/app_shell.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/reset_password_screen.dart';

import 'fakes.dart';

/// A realistic session, the shape `Session.fromJson`/`User.fromJson` produce.
Session fakeSession({String id = 'cb-user', String email = 'user@example.com'}) => Session(
      accessToken: 'access-token',
      tokenType: 'bearer',
      refreshToken: 'refresh-token',
      expiresIn: 3600,
      user: User(
        id: id,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        email: email,
        createdAt: '2026-09-27T00:00:00Z',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final confirmationLink =
      Uri.parse('com.tango.kyc.verification://login-callback?code=valid-code');

  group('AuthController PKCE callback', () {
    test('a valid callback establishes and exposes the session', () async {
      final service = FakeAuthService(callbackSession: fakeSession());
      final auth = AuthController(service);

      final outcome = await auth.handleCallback(confirmationLink);

      expect(outcome, AuthCallbackOutcome.signedIn);
      expect(service.callbackCalls, 1);
      expect(service.lastCallbackUri, confirmationLink);
      expect(auth.isSignedIn, isTrue);
      expect(auth.session?.user.id, 'cb-user');
    });

    test('an overlapping duplicate delivery is not exchanged twice', () async {
      // The PKCE verifier is single-use; a concurrent exchange would fail with
      // `bad_code_verifier`. The second delivery must be dropped, not raced.
      final service = FakeAuthService(
        callbackSession: fakeSession(),
        callbackDelay: const Duration(milliseconds: 50),
      );
      final auth = AuthController(service);

      final first = auth.handleCallback(confirmationLink);
      final second = await auth.handleCallback(confirmationLink);

      expect(second, AuthCallbackOutcome.notAuthenticated);
      expect(service.callbackCalls, 1);
      expect(await first, AuthCallbackOutcome.signedIn);
      expect(auth.isSignedIn, isTrue);
    });

    test('an invalid or consumed code throws and leaves no session', () async {
      final service = FakeAuthService(
        callbackError: const AuthException('Token has expired or is invalid'),
      );
      final auth = AuthController(service);

      await expectLater(
        auth.handleCallback(confirmationLink),
        throwsA(isA<AuthException>()),
      );
      expect(service.callbackCalls, 1);
      expect(auth.isSignedIn, isFalse);
    });

    test('a recovery callback is routed as such', () async {
      final service = FakeAuthService(
        callbackOutcome: AuthCallbackOutcome.passwordRecovery,
        callbackSession: fakeSession(),
      );
      final auth = AuthController(service);

      final outcome = await auth.handleCallback(confirmationLink);

      expect(outcome, AuthCallbackOutcome.passwordRecovery);
    });
  });

  group('resend never overwrites the PKCE verifier', () {
    test('resendEmailOtp uses the resend path, never signInWithOtp', () async {
      final service = FakeAuthService();
      final auth = AuthController(service);

      final ok = await auth.resendEmailOtp(
        email: 'user@example.com',
        purpose: EmailOtpPurpose.signup,
      );

      expect(ok, isTrue);
      expect(service.otpResendCalls, 1);
      // The regression that caused the device bug: a code request here.
      expect(service.otpSendCalls, 0);
    });

    test('a rate-limited resend surfaces an error without a session', () async {
      final service = FakeAuthService(
        resendError: const AuthException('over_email_send_rate_limit'),
      );
      final auth = AuthController(service);

      final ok = await auth.resendEmailOtp(
        email: 'user@example.com',
        purpose: EmailOtpPurpose.signup,
      );

      expect(ok, isFalse);
      expect(auth.lastError, isNotNull);
      expect(auth.isSignedIn, isFalse);
    });
  });

  group('SupabaseAuthService guard', () {
    test('a link without auth parameters is not consumed and needs no network',
        () async {
      // A real client, but the guard returns before any request is made.
      final service = SupabaseAuthService(
        SupabaseClient('https://example.supabase.co', 'public-anon-key'),
      );

      final outcome = await service.handleAuthCallback(
        Uri.parse('com.tango.kyc.verification://login-callback'),
      );

      expect(outcome, AuthCallbackOutcome.notAuthenticated);
    });
  });

  group('RootGate deep-link routing', () {
    Future<SettingsController> readySettings() async {
      FlutterSecureStorage.setMockInitialValues({});
      final settings = SettingsController(const FlutterSecureStorage());
      await settings.load();
      await settings.completeOnboarding();
      return settings;
    }

    Widget wrap({
      required AuthController auth,
      required SettingsController settings,
      required Stream<Uri> links,
      required FakeKycService kyc,
      Uri? initialLink,
    }) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthController>.value(value: auth),
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<KycController>.value(value: KycController(kyc)),
          ChangeNotifierProvider<NotificationsController>.value(
            value: NotificationsController(kyc),
          ),
        ],
        child: MaterialApp(
          home: RootGate(linkStream: links, initialLink: initialLink),
        ),
      );
    }

    testWidgets('a valid confirmation callback lands on the app shell',
        (tester) async {
      final service = FakeAuthService(callbackSession: fakeSession());
      final auth = AuthController(service);
      await auth.initialize();
      final settings = await readySettings();
      final links = StreamController<Uri>.broadcast();

      await tester.pumpWidget(
        wrap(auth: auth, settings: settings, links: links.stream, kyc: FakeKycService()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      links.add(confirmationLink);
      await tester.pumpAndSettle();

      expect(service.callbackCalls, 1);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('an initial (cold-start) link is honoured', (tester) async {
      final service = FakeAuthService(callbackSession: fakeSession());
      final auth = AuthController(service);
      await auth.initialize();
      final settings = await readySettings();

      await tester.pumpWidget(
        wrap(
          auth: auth,
          settings: settings,
          links: const Stream<Uri>.empty(),
          kyc: FakeKycService(),
          initialLink: confirmationLink,
        ),
      );
      await tester.pumpAndSettle();

      expect(service.callbackCalls, 1);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('a replayed link is not processed twice', (tester) async {
      final service = FakeAuthService(
        callbackSession: fakeSession(),
        callbackDelay: const Duration(milliseconds: 80),
      );
      final auth = AuthController(service);
      await auth.initialize();
      final settings = await readySettings();
      final links = StreamController<Uri>.broadcast();

      await tester.pumpWidget(
        wrap(auth: auth, settings: settings, links: links.stream, kyc: FakeKycService()),
      );
      await tester.pumpAndSettle();

      links.add(confirmationLink);
      links.add(confirmationLink);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();

      expect(service.callbackCalls, 1);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('an invalid code shows a clear message and is not retried',
        (tester) async {
      final service = FakeAuthService(
        callbackError: const AuthException(
          'code challenge does not match previously saved code verifier',
        ),
      );
      final auth = AuthController(service);
      await auth.initialize();
      final settings = await readySettings();
      final links = StreamController<Uri>.broadcast();

      await tester.pumpWidget(
        wrap(auth: auth, settings: settings, links: links.stream, kyc: FakeKycService()),
      );
      await tester.pumpAndSettle();

      links.add(confirmationLink);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Ce lien de confirmation n\'est plus valide. '
          'Demandez un nouvel email de confirmation.',
        ),
        findsOneWidget,
      );
      expect(service.callbackCalls, 1);
      expect(find.byType(AppShell), findsNothing);
    });

    testWidgets('a recovery callback opens the reset screen', (tester) async {
      final service = FakeAuthService(
        callbackOutcome: AuthCallbackOutcome.passwordRecovery,
        callbackSession: fakeSession(),
      );
      final auth = AuthController(service);
      await auth.initialize();
      final settings = await readySettings();
      final links = StreamController<Uri>.broadcast();

      await tester.pumpWidget(
        wrap(auth: auth, settings: settings, links: links.stream, kyc: FakeKycService()),
      );
      await tester.pumpAndSettle();

      links.add(confirmationLink);
      await tester.pumpAndSettle();

      expect(find.byType(ResetPasswordScreen), findsOneWidget);
    });
  });
}
