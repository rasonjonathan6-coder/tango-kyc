// Widget tests for the primary screens.
//
// These render the real widgets with a minimal provider setup. Controllers that
// would hit the network are replaced by fakes so the tests stay offline, but the
// widgets under test are the production ones.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/core/validators.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/screens/forgot_password_screen.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/splash_screen.dart';
import 'package:tango_kyc_verification/ui/widgets/common.dart';

import 'fakes.dart';

void main() {
  Widget wrap(Widget child, {required AuthController auth, SettingsController? settings}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>.value(value: auth),
        if (settings != null) ChangeNotifierProvider<SettingsController>.value(value: settings),
      ],
      child: MaterialApp(home: child),
    );
  }

  group('SplashScreen', () {
    testWidgets('shows branding and a progress indicator', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
      expect(find.text('Tango KYC Verification'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('surfaces a message when one is supplied', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: SplashScreen(message: 'Restoring your session...')),
      );
      expect(find.text('Restoring your session...'), findsOneWidget);
    });
  });

  group('LoginScreen', () {
    testWidgets('renders both fields and all entry points', (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('Create an account'), findsOneWidget);
    });

    testWidgets('blocks submission when the email is invalid', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter a valid email address.'), findsOneWidget);
      // The invalid form must not reach the network layer.
      expect(service.signInCalls, 0);
    });

    testWidgets('requires a password', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter your password.'), findsOneWidget);
      expect(service.signInCalls, 0);
    });

    testWidgets('submits valid credentials to the auth service', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.enterText(find.byType(TextFormField).last, 'secretpassword');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(service.signInCalls, 1);
      expect(service.lastEmail, 'user@example.com');
    });

    testWidgets('shows a readable message on an auth failure', (tester) async {
      final service = FakeAuthService(failWith: 'Invalid login credentials');
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.enterText(find.byType(TextFormField).last, 'wrongpassword');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect password.'), findsOneWidget);
    });

    testWidgets('toggles password visibility', (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility_off_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
    });
  });

  group('ForgotPasswordScreen', () {
    testWidgets('validates the email before sending', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const ForgotPasswordScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'bad');
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter a valid email address.'), findsOneWidget);
      expect(service.resetCalls, 0);
    });

    testWidgets('confirms the reset email was sent', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const ForgotPasswordScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();

      expect(service.resetCalls, 1);
      expect(find.text('Reset email sent'), findsOneWidget);
    });
  });

  group('shared widgets', () {
    testWidgets('StatusPill shows the human label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: StatusPill(status: KycStatus.replied))),
        ),
      );
      expect(find.text('Reply received'), findsOneWidget);
    });

    testWidgets('EmptyState renders its message and action', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.inbox_rounded,
              title: 'No requests yet',
              message: 'Your requests will appear here.',
              action: FilledButton(onPressed: () {}, child: const Text('Create')),
            ),
          ),
        ),
      );
      expect(find.text('No requests yet'), findsOneWidget);
      expect(find.text('Your requests will appear here.'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
    });

    testWidgets('ErrorState offers a retry and never leaks internals', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorState(
              message: ErrorMessages.from('PostgrestException: connection refused at 5432'),
              onRetry: () => retried = true,
            ),
          ),
        ),
      );

      expect(find.text('No internet connection. Please check your network and try again.'),
          findsOneWidget);
      expect(find.textContaining('PostgrestException'), findsNothing);

      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);
    });

    test('date formatting matches the requested presentation', () {
      expect(formatDate(DateTime(2026, 9, 25)), '25 September 2026');
    });

    test('date and time formatting is stable', () {
      expect(formatDateTime(DateTime(2026, 9, 25, 9, 5)), '25 September 2026 at 09:05');
    });
  });
}
