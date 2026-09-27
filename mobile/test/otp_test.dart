// Tests for the email one-time-code flow.
//
// Two layers are exercised:
//
// * `AuthController` against `FakeAuthService`, which asserts the app routes the
//   right purpose and token through to the service, and that a rejected code
//   surfaces an error instead of a session.
// * `OtpScreen` rendered with the production widget, to cover input gating,
//   error copy and the recovery hand-off to the new-password screen.
//
// `FakeAuthService` is the only double; the widgets under test are production.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/core/validators.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/ui/screens/otp_screen.dart';
import 'package:tango_kyc_verification/ui/widgets/aurora.dart';
import 'package:tango_kyc_verification/ui/screens/reset_password_screen.dart';

import 'fakes.dart';

void main() {
  Widget wrap(Widget child, {required AuthController auth}) {
    return MultiProvider(
      providers: [ChangeNotifierProvider<AuthController>.value(value: auth)],
      child: MaterialApp(home: child),
    );
  }

  /// The cooldown is disabled in tests so no periodic timer stays pending.
  Widget otpScreen({required EmailOtpPurpose purpose}) => OtpScreen(
        email: 'user@example.com',
        purpose: purpose,
        resendCooldown: Duration.zero,
      );

  group('AuthController OTP', () {
    test('sendEmailOtp forwards the purpose to the service', () async {
      final service = FakeAuthService();
      final auth = AuthController(service);

      final ok = await auth.sendEmailOtp(
        email: 'user@example.com',
        purpose: EmailOtpPurpose.recovery,
      );

      expect(ok, isTrue);
      expect(service.otpSendCalls, 1);
      expect(service.lastEmail, 'user@example.com');
      expect(service.lastOtpPurpose, EmailOtpPurpose.recovery);
      expect(auth.lastError, isNull);
    });

    test('a send failure is reported without a session', () async {
      final service = FakeAuthService(otpSendFails: true);
      final auth = AuthController(service);

      final ok = await auth.sendEmailOtp(
        email: 'user@example.com',
        purpose: EmailOtpPurpose.signup,
      );

      expect(ok, isFalse);
      expect(auth.lastError, isNotNull);
      expect(auth.isSignedIn, isFalse);
    });

    test('the correct code verifies with the requested purpose', () async {
      final service = FakeAuthService();
      final auth = AuthController(service);

      final ok = await auth.verifyEmailOtp(
        email: 'user@example.com',
        token: '12345678',
        purpose: EmailOtpPurpose.signup,
      );

      expect(ok, isTrue);
      expect(service.otpVerifyCalls, 1);
      expect(service.lastOtpToken, '12345678');
      expect(service.lastOtpPurpose, EmailOtpPurpose.signup);
    });

    test('a wrong code fails and exposes an expiry-style message', () async {
      final service = FakeAuthService();
      final auth = AuthController(service);

      final ok = await auth.verifyEmailOtp(
        email: 'user@example.com',
        token: '00000000',
        purpose: EmailOtpPurpose.recovery,
      );

      expect(ok, isFalse);
      expect(auth.isSignedIn, isFalse);
      expect(
        ErrorMessages.from(auth.lastError ?? ''),
        'This code is incorrect or has expired. Request a new one.',
      );
    });

    test('resend goes through the send path and is counted separately', () async {
      final service = FakeAuthService();
      final auth = AuthController(service);

      await auth.resendEmailOtp(email: 'user@example.com', purpose: EmailOtpPurpose.signup);

      expect(service.otpResendCalls, 1);
      expect(service.lastOtpPurpose, EmailOtpPurpose.signup);
    });
  });

  group('OtpScreen', () {
    testWidgets('renders the code length that the project actually mails',
        (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(otpScreen(purpose: EmailOtpPurpose.signup), auth: auth));
      await tester.pumpAndSettle();

      expect(find.text('Entrez votre code'), findsOneWidget);
      expect(find.textContaining('$kEmailOtpLength chiffres'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('verify stays disabled until the code is complete', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(otpScreen(purpose: EmailOtpPurpose.signup), auth: auth));
      await tester.pumpAndSettle();

      final button = tester.widget<GradientButton>(find.byType(GradientButton));
      expect(button.onPressed, isNull);

      await tester.enterText(find.byType(TextField), '1234');
      await tester.pump();
      expect(tester.widget<GradientButton>(find.byType(GradientButton)).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '12345678');
      await tester.pump();
      expect(tester.widget<GradientButton>(find.byType(GradientButton)).onPressed, isNotNull);
      expect(service.otpVerifyCalls, 0);
    });

    testWidgets('a rejected code shows clean copy and clears the field',
        (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(otpScreen(purpose: EmailOtpPurpose.signup), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '99999999');
      await tester.pump();
      await tester.tap(find.text('Vérifier le code'));
      await tester.pumpAndSettle();

      expect(service.otpVerifyCalls, 1);
      expect(find.text('This code is incorrect or has expired. Request a new one.'),
          findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, isEmpty);
    });

    testWidgets('recovery code success lands on the reset password screen',
        (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(otpScreen(purpose: EmailOtpPurpose.recovery), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '12345678');
      await tester.pump();
      await tester.tap(find.text('Vérifier le code'));
      await tester.pumpAndSettle();

      expect(service.otpVerifyCalls, 1);
      expect(find.byType(ResetPasswordScreen), findsOneWidget);
    });

    testWidgets('the send button is reachable after the cooldown', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(otpScreen(purpose: EmailOtpPurpose.signup), auth: auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Renvoyer le code'));
      await tester.pumpAndSettle();

      expect(service.otpResendCalls, 1);
    });
  });
}
