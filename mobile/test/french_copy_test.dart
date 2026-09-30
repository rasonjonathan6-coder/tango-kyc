// The product copy is French. The reference artwork is French, the emails are
// French and the whole app targets a French-speaking audience, so an English
// string that reaches a user is a defect rather than a style choice.
//
// These tests pin the user-visible wording of every screen that renders without
// a backend, which covers the auth flow plus the screens added with the UI
// overhaul. They are intentionally about *words*: if a label is reworded, update
// the expectation here, but an English label should never come back silently.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/ui/screens/forgot_password_screen.dart';
import 'package:tango_kyc_verification/ui/screens/help_support_screen.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/onboarding_screen.dart';
import 'package:tango_kyc_verification/ui/screens/register_screen.dart';
import 'package:tango_kyc_verification/ui/screens/request_sent_screen.dart';
import 'package:tango_kyc_verification/ui/screens/splash_screen.dart';

import 'fakes.dart';

void main() {
  Widget wrap(Widget child, {AuthController? auth}) {
    if (auth == null) return MaterialApp(home: child);
    return ChangeNotifierProvider<AuthController>.value(
      value: auth,
      child: MaterialApp(home: child),
    );
  }

  Future<void> expectAll(WidgetTester tester, List<String> texts) async {
    for (final text in texts) {
      expect(find.text(text), findsOneWidget, reason: 'missing copy: "$text"');
    }
  }

  group('French copy', () {
    testWidgets('splash screen', (tester) async {
      await tester.pumpWidget(wrap(const SplashScreen()));
      await expectAll(tester, [
        'Tango KYC',
        'Votre compte, notre priorité',
        'Simple · Rapide · Sécurité',
        'Chargement...',
      ]);

      // The caption is overridable while a restore is in flight.
      await tester.pumpWidget(wrap(const SplashScreen(message: 'Chargement…')));
      await expectAll(tester, ['Chargement…']);
    });

    testWidgets('onboarding screen', (tester) async {
      await tester.pumpWidget(wrap(OnboardingScreen(onFinished: () {})));
      await tester.pumpAndSettle();
      await expectAll(tester, [
        'Bienvenue sur',
        'Tango KYC',
        'Commencer  →',
        'Nous sommes là pour vous aider\n'
            'à résoudre vos problèmes de compte\n'
            'rapidement et en toute sécurité.',
      ]);
      // The old introduction chrome is gone: no skip link, no pagination.
      expect(find.text('Passer'), findsNothing);
    });

    testWidgets('login screen', (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(const LoginScreen(), auth: auth));
      await tester.pumpAndSettle();
      await expectAll(tester, [
        'Se connecter',
        'Mot de passe oublié ?',
        'Continuer avec Google',
        'Créer un compte',
        'Se connecter avec un code',
      ]);
    });

    testWidgets('register screen form', (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(const RegisterScreen(), auth: auth));
      await tester.pumpAndSettle();
      await expectAll(tester, [
        'Créer votre',
        'compte',
        'Créer mon compte',
        'Nom complet',
        'Confirmez le mot de passe',
      ]);
    });

    testWidgets('forgot password screen', (tester) async {
      final auth = AuthController(FakeAuthService());
      await tester.pumpWidget(wrap(const ForgotPasswordScreen(), auth: auth));
      await tester.pumpAndSettle();
      await expectAll(tester, ['Mot de passe', 'oublié ?', 'Envoyer le lien']);

      // Submitting reveals the confirmation state and its follow-up actions.
      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tester.tap(find.text('Envoyer le lien'));
      await tester.pumpAndSettle();
      await expectAll(tester, [
        'Email envoyé',
        'Recevoir un code à la place',
        'Retour à la connexion',
      ]);
    });

    testWidgets('request sent screen', (tester) async {
      await tester.pumpWidget(
        wrap(RequestSentScreen(ticketCode: 'TK-2026-001', onPrimary: () {}, onSecondary: () {})),
      );
      await tester.pumpAndSettle();
      await expectAll(tester, ['Demande envoyée !', 'Voir la demande', 'Retour à l’accueil']);
    });

    testWidgets('pending-payment screen never claims the request was sent', (tester) async {
      await tester.pumpWidget(
        wrap(
          RequestSentScreen(
            ticketCode: 'TK-2026-001',
            awaitingPayment: true,
            onPrimary: () {},
            onSecondary: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectAll(tester, [
        'Paiement en attente',
        'Reprendre le paiement MVola',
        'Voir la demande',
      ]);
      expect(find.textContaining('Demande envoyée'), findsNothing);
    });

    testWidgets('help and support screen', (tester) async {
      await tester.pumpWidget(wrap(const HelpSupportScreen()));
      await tester.pumpAndSettle();
      await expectAll(tester, [
        'Aide & support',
        'Comment pouvons-nous vous aider ?',
        'Contacter le support',
      ]);

      // The policy row sits below the fold; scroll it into view.
      await tester.scrollUntilVisible(
        find.text('Politique de confidentialité'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Politique de confidentialité'), findsOneWidget);
    });
  });
}
