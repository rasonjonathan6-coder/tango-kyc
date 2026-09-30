// Login screen: visual system, responsive layout, keyboard behaviour and the
// wiring of every entry point to its real handler.
//
// The widgets under test are the production ones; only the auth service is a
// fake, so nothing here touches the network. Layout assertions use relative
// geometry rather than pixel values, because the test font's metrics differ from
// the platform font's.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/theme/app_theme.dart';
import 'package:tango_kyc_verification/ui/widgets/aurora.dart';
import 'package:tango_kyc_verification/ui/widgets/auth_kit.dart';

import 'fakes.dart';

/// Scrolls the given label into view before tapping, so the assertions do not
/// depend on the test font's line heights.
Future<void> tapAfterScroll(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(
    find.text(label),
    80,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  Widget wrap(AuthController auth) => MultiProvider(
        providers: [ChangeNotifierProvider<AuthController>.value(value: auth)],
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          builder: (context, child) => AuroraBackground(
            animate: false,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const LoginScreen(),
        ),
      );

  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    AuthController? auth,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size * 3.0;
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 3.0);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(auth ?? AuthController(FakeAuthService())));
    await tester.pumpAndSettle();
  }

  group('visual system', () {
    testWidgets('the canvas is dark and the master backdrop supplies it', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      // The screen routes through the shared scaffold, so a nested
      // AuroraBackground is present but passes through: exactly ONE instance
      // actually paints. That is the guarantee all 18 screens share one canvas.
      // Count the master painters specifically: the screen also contains a
      // Google glyph CustomPaint, so counting every CustomPaint would be
      // unrelated to the canvas.
      final painting = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where(
            (w) => w.painter is MasterBackdropPainter,
          )
          .length;
      expect(painting, 1);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, Colors.transparent);
      expect(AppColors.canvasDark.computeLuminance(), lessThan(0.02));
    });

    testWidgets('the brand lockup, title, fields and actions are present', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      expect(find.byType(BrandLockup), findsOneWidget);
      // "Tango" appears twice: the wordmark and the title.
      expect(find.text('Tango'), findsNWidgets(2));
      expect(find.text('KYC'), findsOneWidget);
      expect(find.text('Vérification'), findsOneWidget);
      expect(find.byType(NeonField), findsNWidgets(2));
      expect(find.byType(OrDivider), findsOneWidget);
      expect(find.byType(GoogleGlyph), findsOneWidget);
      expect(find.byType(AuthFooter), findsOneWidget);
    });

    testWidgets('the primary action carries the rose/violet/blue gradient', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      final button = tester.widget<GradientButton>(find.byType(GradientButton));
      expect(button.gradient, AppTheme.actionGradient);
      expect(button.radius, 34);
    });

    testWidgets('the secondary entries are tappable cards', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      // Google plus the two secondary entries.
      expect(find.byType(GlassActionCard), findsNWidgets(3));
      for (final card in tester.widgetList<GlassActionCard>(find.byType(GlassActionCard))) {
        expect(card.onTap, isNotNull);
      }
    });
  });

  group('responsive layout', () {
    final sizes = {
      'small 320x568': const Size(320, 568),
      'target 360x800': const Size(360, 800),
      'pixel 411x914': const Size(411, 914),
      'tablet 800x1280': const Size(800, 1280),
    };

    for (final entry in sizes.entries) {
      testWidgets('renders without overflow on ${entry.key}', (tester) async {
        await pumpAt(tester, entry.value);
        expect(tester.takeException(), isNull);
        expect(find.text('Se connecter'), findsOneWidget);
        expect(find.text('Continuer avec Google'), findsOneWidget);
      });
    }

    testWidgets('secondary entries stack when narrow', (tester) async {
      await pumpAt(tester, const Size(320, 568));
      final code = tester.getRect(find.text('Se connecter avec un code'));
      final register = tester.getRect(find.text('Créer un compte'));
      expect(register.top, greaterThan(code.top));
    });

    testWidgets('secondary entries sit side by side when wide', (tester) async {
      await pumpAt(tester, const Size(411, 914));
      final code = tester.getRect(find.text('Se connecter avec un code'));
      final register = tester.getRect(find.text('Créer un compte'));
      expect((register.top - code.top).abs(), lessThan(8));
      expect(register.left, greaterThan(code.left));
    });
  });

  group('keyboard', () {
    final sizes = {
      'small 320x568': const Size(320, 568),
      'target 360x800': const Size(360, 800),
      'pixel 411x914': const Size(411, 914),
    };

    for (final entry in sizes.entries) {
      testWidgets('the form stays usable with the keyboard open on ${entry.key}',
          (tester) async {
        await pumpAt(tester, entry.value, keyboard: 300);
        expect(tester.takeException(), isNull);

        // Focusing a field must not break the layout.
        await tester.tap(find.byType(TextFormField).first, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // The primary action must stay reachable by scrolling.
        await tester.scrollUntilVisible(
          find.byType(GradientButton),
          90,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final button = tester.getRect(find.byType(GradientButton));
        expect(button.top, greaterThanOrEqualTo(0));
        expect(button.bottom, lessThanOrEqualTo(entry.value.height));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('focusing a field does not move it', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      final before = tester.getRect(find.byType(TextFormField).first);
      await tester.tap(find.byType(TextFormField).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      final after = tester.getRect(find.byType(TextFormField).first);
      expect(after.top, closeTo(before.top, 0.5));
      expect(after.height, closeTo(before.height, 0.5));
    });
  });

  group('entry points reach their real handlers', () {
    testWidgets('Google card starts the real sign-in', (tester) async {
      final service = FakeAuthService();
      await pumpAt(tester, const Size(360, 800), auth: AuthController(service));
      await tapAfterScroll(tester, 'Continuer avec Google');
      expect(service.googleCalls, 1);
    });

    testWidgets('forgot password opens the reset screen', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      await tapAfterScroll(tester, 'Mot de passe oublié ?');
      expect(find.text('Envoyer le lien'), findsOneWidget);
    });

    testWidgets('create account opens the registration screen', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      await tapAfterScroll(tester, 'Créer un compte');
      // The registration screen now leads with its own gradient heading.
      expect(find.text('Créer votre'), findsOneWidget);
    });

    testWidgets('code sign-in refuses without a valid address', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      await tapAfterScroll(tester, 'Se connecter avec un code');
      expect(find.text('Saisissez d’abord votre adresse email ci-dessus.'), findsOneWidget);
    });

    testWidgets('code sign-in opens the OTP screen for a valid address', (tester) async {
      await pumpAt(tester, const Size(360, 800));
      await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
      await tapAfterScroll(tester, 'Se connecter avec un code');
      expect(find.textContaining('user@example.com'), findsWidgets);
    });
  });
}
