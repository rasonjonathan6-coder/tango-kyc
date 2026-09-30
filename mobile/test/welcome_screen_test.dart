// Tests for the premium welcome / introduction screen.
//
// The screen is pure presentation over two real assets, so these tests pin what
// the user actually sees: the referenced artwork is bundled and decodes, the
// layout never overflows at real phone sizes (including notch/rounded-inset
// paddings), the action is inside the viewport, and tapping it keeps the
// existing functional path by calling `onFinished`.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tango_kyc_verification/ui/screens/onboarding_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WelcomeScreen assets', () {
    test('both referenced assets are bundled and decode', () async {
      for (final asset in const [
        kWelcomeBackgroundAsset,
        kWelcomeLogoAsset,
      ]) {
        final data = await rootBundle.load(asset);
        expect(data.lengthInBytes, greaterThan(0), reason: asset);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0), reason: asset);
        expect(frame.image.height, greaterThan(0), reason: asset);
      }
    });

    test('the background carries the 9:19.5 portrait ratio', () async {
      final data = await rootBundle.load(kWelcomeBackgroundAsset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final ratio = frame.image.width / frame.image.height;
      // 9 / 19.5 = 0.4615; the artwork is measured at 0.4626.
      expect(ratio, closeTo(9 / 19.5, 0.01));
    });

    test('the logo artwork is portrait, so a height-driven box keeps its ratio',
        () async {
      final data = await rootBundle.load(kWelcomeLogoAsset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      // 1069x1119: slightly taller than wide, and never square.
      expect(frame.image.height, greaterThan(frame.image.width));
      expect(frame.image.width / frame.image.height, closeTo(0.955, 0.02));
    });

    test('the transparent logo asset really carries an alpha channel',
        () async {
      final data = await rootBundle.load(kWelcomeLogoAsset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final bytes = (await frame.image
              .toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();

      var transparent = 0;
      for (var i = 3; i < bytes.length; i += 4) {
        if (bytes[i] == 0) transparent++;
      }
      // A real alpha channel with a large transparent field: no white plate.
      expect(transparent, greaterThan(0));
      expect(transparent / (bytes.length / 4), greaterThan(0.3));
    });
  });

  group('WelcomeScreen layout', () {
    Widget app(VoidCallback onFinished) => MaterialApp(
          home: OnboardingScreen(onFinished: onFinished),
        );

    Future<void> pumpAt(
      WidgetTester tester,
      Size size, {
      EdgeInsets padding = EdgeInsets.zero,
      double dpr = 3.0,
    }) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = size * dpr;
      // Insets are given in physical pixels, matching the physical size above.
      tester.view.viewPadding = FakeViewPadding(
        left: padding.left * dpr,
        top: padding.top * dpr,
        right: padding.right * dpr,
        bottom: padding.bottom * dpr,
      );
      tester.view.padding = FakeViewPadding(
        left: padding.left * dpr,
        top: padding.top * dpr,
        right: padding.right * dpr,
        bottom: padding.bottom * dpr,
      );
      addTearDown(tester.view.reset);
    }

    testWidgets('renders the reference composition', (tester) async {
      await tester.pumpWidget(app(() {}));
      await tester.pumpAndSettle();

      expect(find.text('Bienvenue sur'), findsOneWidget);
      expect(find.text('Tango KYC'), findsOneWidget);
      expect(find.text('Commencer  →'), findsOneWidget);
      expect(
        find.text(
          'Nous sommes là pour vous aider\n'
          'à résoudre vos problèmes de compte\n'
          'rapidement et en toute sécurité.',
        ),
        findsOneWidget,
      );
      // Removed chrome must stay removed.
      expect(find.text('Passer'), findsNothing);
      expect(find.text('2. Introduction'), findsNothing);
    });

    testWidgets('does not overflow on common Android sizes', (tester) async {
      const sizes = <Size>[
        Size(320, 568), // small
        Size(360, 640), // short
        Size(360, 800), // standard
        Size(412, 915), // large
        Size(480, 1000), // very large
      ];
      for (final size in sizes) {
        await pumpAt(tester, size);
        await tester.pumpWidget(app(() {}));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'overflow at $size');
      }
    });

    testWidgets('does not overflow with a notch or punch-hole inset',
        (tester) async {
      const insets = <EdgeInsets>[
        EdgeInsets.only(top: 44, bottom: 34), // notch
        EdgeInsets.only(top: 24), // punch-hole
        EdgeInsets.only(top: 30, bottom: 48), // gesture bar
      ];
      for (final inset in insets) {
        await pumpAt(tester, const Size(360, 800), padding: inset);
        await tester.pumpWidget(app(() {}));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'overflow with $inset');
      }
    });

    testWidgets('the background covers and the logo keeps a slim, contained box',
        (tester) async {
      await tester.pumpWidget(app(() {}));
      await tester.pumpAndSettle();

      final bg = tester.widget<Image>(
        find.byWidgetPredicate(
          (w) => w is Image &&
              (w.image as AssetImage).assetName == kWelcomeBackgroundAsset,
        ),
      );
      expect(bg.fit, BoxFit.cover);

      final logoBox = tester.getSize(find.byKey(const Key('welcome-logo-box')));
      // Slim and discreet: clearly smaller than the splash logo, and never
      // wide enough to reach the middle of the screen.
      expect(logoBox.height, lessThanOrEqualTo(72.01));
      expect(logoBox.height, greaterThan(50));
      expect(logoBox.width, lessThan(360 / 2));
    });

    testWidgets('the logo sits top-left, under the status bar', (tester) async {
      await pumpAt(tester, const Size(360, 800),
          padding: const EdgeInsets.only(top: 44));
      await tester.pumpWidget(app(() {}));
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byKey(const Key('welcome-logo-box')));
      final screen = tester.getRect(find.byType(MaterialApp));

      // Left side, and below the status-bar inset rather than under it.
      expect(rect.left, lessThan(screen.width / 2));
      expect(rect.top, greaterThanOrEqualTo(44));
      expect(rect.top, lessThan(screen.height / 3));
    });

    testWidgets('the action stays inside the viewport and above the bottom',
        (tester) async {
      for (final size in const [Size(320, 568), Size(360, 800), Size(412, 915)]) {
        await pumpAt(tester, size);
        await tester.pumpWidget(app(() {}));
        await tester.pumpAndSettle();

        final button = tester.getRect(find.text('Commencer  →'));
        expect(button.left, greaterThanOrEqualTo(0));
        expect(button.right, lessThanOrEqualTo(size.width + 0.5));
        expect(button.bottom, lessThanOrEqualTo(size.height + 0.5));
      }
    });

    testWidgets('tapping "Commencer" keeps the existing functional path',
        (tester) async {
      var finished = 0;
      await tester.pumpWidget(app(() => finished++));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Commencer  →'));
      await tester.pumpAndSettle();

      expect(finished, 1);
    });
  });
}
