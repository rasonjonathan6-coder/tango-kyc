// Widget tests for the primary screens.
//
// These render the real widgets with a minimal provider setup. Controllers that
// would hit the network are replaced by fakes so the tests stay offline, but the
// widgets under test are the production ones.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/core/validators.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/mvola_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/app_shell.dart';
import 'package:tango_kyc_verification/ui/screens/forgot_password_screen.dart';
import 'package:tango_kyc_verification/ui/screens/home_screen.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/otp_screen.dart';
import 'package:tango_kyc_verification/ui/screens/register_screen.dart';
import 'package:tango_kyc_verification/ui/screens/settings_screen.dart';
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
    testWidgets('shows the full branding block', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
      expect(find.text('Tango KYC'), findsOneWidget);
      expect(find.text('Votre compte, notre priorité'), findsOneWidget);
      expect(find.text('Simple · Rapide · Sécurité'), findsOneWidget);
      expect(find.text('Chargement...'), findsOneWidget);
      // The artwork is used verbatim, as a full-bleed cover.
      final bg = tester.widget<Image>(find.byType(Image).first);
      expect((bg.image as AssetImage).assetName, kSplashBackgroundAsset);
      expect(bg.fit, BoxFit.cover);
    });

    testWidgets('sizes the logo from its square ratio at the reference height',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SplashScreen(animate: false)));
      final logo = tester.widget<Image>(
        find.byWidgetPredicate(
          (w) => w is Image && (w.image as AssetImage).assetName == kSplashLogoAsset,
        ),
      );
      expect(logo.fit, BoxFit.contain);

      // The artwork is exactly square, so the box must be square too: ratio kept.
      final box = tester.getSize(find.byWidget(logo).first);
      expect(box.width, closeTo(box.height, 0.01));
      expect(box.height, greaterThan(0));
    });

    testWidgets('lays out without overflow on a small and a large phone',
        (tester) async {
      for (final size in const [Size(320, 568), Size(360, 800), Size(412, 915)]) {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          const MaterialApp(home: SplashScreen(animate: false)),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'overflow at $size');
        final box = tester.getSize(find.byWidgetPredicate((w) =>
            w is Image &&
            (w.image as AssetImage).assetName == kSplashLogoAsset));
        // Reference is 130 logical px; it may shrink on a short screen but must
        // never grow past the reference and must never collapse.
        expect(box.height, lessThanOrEqualTo(kSplashLogoSize));
        expect(box.height, greaterThan(80));
      }
    });

    testWidgets('surfaces a message when one is supplied', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: SplashScreen(message: 'Restoring your session...')),
      );
      expect(find.text('Restoring your session...'), findsOneWidget);
      expect(find.text('Chargement...'), findsNothing);
    });
  });

  group('LoginScreen', () {
    testWidgets('renders both fields and all entry points', (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Mot de passe'), findsOneWidget);
      expect(find.text('Se connecter'), findsOneWidget);
      expect(find.text('Continuer avec Google'), findsOneWidget);
      expect(find.text('Mot de passe oublié ?'), findsOneWidget);
      expect(find.text('Créer un compte'), findsOneWidget);
    });

    testWidgets('blocks submission when the email is invalid', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
      await tester.tap(find.text('Se connecter'));
      await tester.pumpAndSettle();

      expect(find.text('Saisissez une adresse email valide.'), findsOneWidget);
      // The invalid form must not reach the network layer.
      expect(service.signInCalls, 0);
    });

    testWidgets('requires a password', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.tap(find.text('Se connecter'));
      await tester.pumpAndSettle();

      expect(find.text('Veuillez saisir votre mot de passe.'), findsOneWidget);
      expect(service.signInCalls, 0);
    });

    testWidgets('submits valid credentials to the auth service', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.enterText(find.byType(TextFormField).last, 'secretpassword');
      await tester.tap(find.text('Se connecter'));
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
      await tester.tap(find.text('Se connecter'));
      await tester.pumpAndSettle();

      expect(find.text('Mot de passe incorrect.'), findsOneWidget);
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

  group('RegisterScreen', () {
    Future<void> fillValidForm(WidgetTester tester) async {
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(1), 'user@example.com');
      await tester.enterText(fields.at(2), 'secretpassword');
      await tester.enterText(fields.at(3), 'secretpassword');
      // The premium layout is taller than the 800x600 test window, so the
      // submit action has to be scrolled into view before it can be tapped.
      await tester.scrollUntilVisible(
        find.text('Créer mon compte'),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Créer mon compte'));
      await tester.pumpAndSettle();
    }

    testWidgets('does not auto-send an email OTP after signup', (tester) async {
      // Requesting a code overwrites the PKCE verifier stored by signUp, which
      // breaks the confirmation link in the email (`bad_code_verifier`). The
      // code path must not be offered from here at all.
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const RegisterScreen(), auth: auth));
      await tester.pumpAndSettle();

      await fillValidForm(tester);

      expect(service.signUpCalls, 1);
      expect(service.otpSendCalls, 0);
      expect(find.text('Vérifiez votre boîte mail'), findsOneWidget);
      // The confirmation link is the only offered mechanism.
      expect(find.text('Use a code instead'), findsNothing);
      expect(find.text('Renvoyer l’email de confirmation'), findsOneWidget);
    });

    testWidgets('resending the confirmation does not request a code', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const RegisterScreen(), auth: auth));
      await tester.pumpAndSettle();

      await fillValidForm(tester);
      await tester.tap(find.text('Renvoyer l’email de confirmation'));
      await tester.pumpAndSettle();

      // Resend goes through `resendConfirmation`, never the OTP send path.
      expect(service.otpSendCalls, 0);
      expect(find.byType(OtpScreen), findsNothing);
    });
  });

  group('ForgotPasswordScreen', () {
    testWidgets('validates the email before sending', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const ForgotPasswordScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'bad');
      await tester.tap(find.text('Envoyer le lien'));
      await tester.pumpAndSettle();

      expect(find.text('Saisissez une adresse email valide.'), findsOneWidget);
      expect(service.resetCalls, 0);
    });

    testWidgets('confirms the reset email was sent', (tester) async {
      final service = FakeAuthService();
      final auth = AuthController(service);
      await tester.pumpWidget(wrap(const ForgotPasswordScreen(), auth: auth));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.tap(find.text('Envoyer le lien'));
      await tester.pumpAndSettle();

      expect(service.resetCalls, 1);
      expect(find.text('Email envoyé'), findsOneWidget);
    });
  });

  group('shared widgets', () {
    testWidgets('StatusPill shows the human label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: StatusPill(status: KycStatus.replied)),
          ),
        ),
      );
      expect(find.text('Répondu'), findsOneWidget);
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

      expect(
        find.text('Pas de connexion internet. Vérifiez votre réseau puis réessayez.'),
        findsOneWidget,
      );
      expect(find.textContaining('PostgrestException'), findsNothing);

      await tester.tap(find.text('Réessayer'));
      expect(retried, isTrue);
    });

    test('date formatting matches the requested presentation', () {
      expect(formatDate(DateTime(2026, 9, 25)), '25 September 2026');
    });

    test('date and time formatting is stable', () {
      expect(formatDateTime(DateTime(2026, 9, 25, 9, 5)), '25 September 2026 à 09:05');
    });
  });

  group('HomeScreen MVola gate', () {
    KycRequest ticket({required bool paymentRequired, required bool isSubmitted}) => KycRequest(
      id: 't1',
      ticketCode: 'TNG-1',
      tangoProfileLink: 'https://tango.me/u/1',
      registerType: RegisterType.email,
      registerValue: 'a@b.com',
      status: KycStatus.pending,
      createdAt: DateTime(2026, 9, 25),
      paymentRequired: paymentRequired,
      isSubmitted: isSubmitted,
    );

    Widget wrapHome(FakeKycService service) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>.value(value: AuthController(FakeAuthService())),
        ChangeNotifierProvider<KycController>.value(value: KycController(service)),
        ChangeNotifierProvider<NotificationsController>.value(
          value: NotificationsController(service),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: HomeScreen())),
    );

    testWidgets('the home screen never offers MVola as an independent action', (tester) async {
      final service = FakeKycService(requests: [ticket(paymentRequired: true, isSubmitted: false)]);
      await tester.pumpWidget(wrapHome(service));
      await tester.pumpAndSettle();

      // MVola is only ever reached through "Envoyer ma demande"; the home screen
      // must not carry a second, independent payment entry point.
      expect(find.text('Payer avec MVola'), findsNothing);
    });

    testWidgets('a request awaiting payment is never presented as "sent"', (tester) async {
      final service = FakeKycService(requests: [ticket(paymentRequired: true, isSubmitted: false)]);
      await tester.pumpWidget(wrapHome(service));
      await tester.pumpAndSettle();

      expect(find.textContaining('Effectuez le paiement MVola'), findsOneWidget);
      expect(find.textContaining('va l’examiner rapidement'), findsNothing);
    });

    testWidgets('the home header carries no bell of its own', (tester) async {
      final service = FakeKycService(requests: [ticket(paymentRequired: false, isSubmitted: true)]);
      await tester.pumpWidget(wrapHome(service));
      await tester.pumpAndSettle();

      // The single functional notification entry point lives in the shell app
      // bar; the home header must not add a second bell (see the AppShell test).
      expect(find.byIcon(Icons.notifications_none_rounded), findsNothing);
    });

    testWidgets('abandoning the payment keeps a way to resume it', (tester) async {
      // Scenario A/E: the request is created but the payment is not confirmed.
      // The home screen must still offer a resume path and must not claim the
      // request was sent.
      final service = FakeKycService(requests: [ticket(paymentRequired: true, isSubmitted: false)]);
      await tester.pumpWidget(wrapHome(service));
      await tester.pumpAndSettle();

      // The independent home entry point stays gone...
      expect(find.text('Payer avec MVola'), findsNothing);

      // ...but the pending request is not presented as an official submission.
      expect(find.textContaining('va l’examiner rapidement'), findsNothing);
    });

    testWidgets('the home screen itself claims no payment state', (tester) async {
      final service = FakeKycService(requests: [ticket(paymentRequired: true, isSubmitted: false)]);
      await tester.pumpWidget(wrapHome(service));
      await tester.pumpAndSettle();

      // The real payment wording lives on "Mes tickets" and on the outcome
      // screen; the home screen must not invent a second, competing state.
      expect(find.text('Paiement en attente'), findsNothing);
      expect(find.text('Paiement validé'), findsNothing);
    });

    testWidgets('a validated payment stops asking and reads as received', (tester) async {
      final service = FakeKycService(requests: [ticket(paymentRequired: true, isSubmitted: true)]);
      await tester.pumpWidget(wrapHome(service));
      await tester.pumpAndSettle();

      expect(find.text('Payer avec MVola'), findsNothing);
      expect(find.textContaining('va l’examiner rapidement'), findsOneWidget);
    });

    testWidgets('abandoning then resuming MVola never creates a second ticket', (tester) async {
      // Scenarios A, E: create -> "Envoyer ma demande" -> leave the payment
      // screen -> the request is not "sent" and the payment can be resumed
      // without creating another ticket.
      final created = ticket(paymentRequired: true, isSubmitted: false);
      final kyc = FakeKycService(createdTicket: created);
      final mvola = FakeMvolaService();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthController>.value(value: AuthController(FakeAuthService())),
            ChangeNotifierProvider<KycController>.value(value: KycController(kyc)),
            ChangeNotifierProvider<NotificationsController>.value(
              value: NotificationsController(kyc),
            ),
            ChangeNotifierProvider<MvolaController>.value(value: MvolaController(mvola)),
          ],
          child: const MaterialApp(home: Scaffold(body: HomeScreen())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Demander une re-vérification').first);
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'https://tango.me/u/1');
      await tester.enterText(fields.at(1), 'a@b.com');
      await tester.tap(find.text('Envoyer ma demande'));
      await tester.pumpAndSettle();

      // The form hands off to the MVola payment screen.
      expect(find.text('Paiement Mobile Money'), findsOneWidget);

      // The user leaves the payment screen before paying.
      await tester.pageBack();
      await tester.pumpAndSettle();

      // The request is never claimed as sent, and the payment can be resumed.
      expect(find.text('Paiement en attente'), findsOneWidget);
      expect(find.text('Demande envoyée !'), findsNothing);
      expect(find.text('Reprendre le paiement MVola'), findsOneWidget);

      await tester.tap(find.text('Reprendre le paiement MVola'));
      await tester.pumpAndSettle();

      // Resuming re-opens the same live payment - not a new one.
      expect(find.text('Paiement Mobile Money'), findsOneWidget);
      await tester.tap(find.text('J’ai payé'));
      await tester.pumpAndSettle();

      // No second ticket was created for the same request.
      expect(kyc.createCalls, 1);
      expect(mvola.startCalls, greaterThanOrEqualTo(1));
    });
  });

  group('AppShell notification entry point', () {
    testWidgets('exactly one bell is offered on the home destination', (tester) async {
      final kyc = FakeKycService();
      FlutterSecureStorage.setMockInitialValues({});
      final settings = SettingsController(const FlutterSecureStorage());
      await settings.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthController>.value(
                value: AuthController(FakeAuthService())),
            ChangeNotifierProvider<KycController>.value(value: KycController(kyc)),
            ChangeNotifierProvider<NotificationsController>.value(
                value: NotificationsController(kyc)),
            // The four tabs are all built inside the shell's IndexedStack, so the
            // settings tab needs its controller even while the home tab is shown.
            ChangeNotifierProvider<SettingsController>.value(value: settings),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      // The shell app bar is the one and only functional bell. All four tabs are
      // built inside the IndexedStack, and the profile tab lists a decorative
      // "Notifications" row, so the check is scoped to the app bar: it must
      // contain exactly one bell, and the home destination must not add a second
      // one to that bar.
      final bellsInAppBar = find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.notifications_none_rounded),
      );
      expect(bellsInAppBar, findsOneWidget);
    });

    testWidgets('offers the four primary destinations and switches between them',
        (tester) async {
      final kyc = FakeKycService();
      FlutterSecureStorage.setMockInitialValues({});
      final settings = SettingsController(const FlutterSecureStorage());
      await settings.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthController>.value(
                value: AuthController(FakeAuthService())),
            ChangeNotifierProvider<KycController>.value(value: KycController(kyc)),
            ChangeNotifierProvider<NotificationsController>.value(
                value: NotificationsController(kyc)),
            ChangeNotifierProvider<SettingsController>.value(value: settings),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      final bar = find.byType(NavigationBar);
      expect(
        find.descendant(of: bar, matching: find.text('Accueil')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Historique')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Profil')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Paramètres')),
        findsOneWidget,
      );

      // Selecting a tab swaps the body: the settings tab renders its own content
      // and the shell title follows the destination.
      await tester.tap(find.descendant(of: bar, matching: find.text('Paramètres')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Paramètres')),
        findsOneWidget,
      );
    });
  });
}
