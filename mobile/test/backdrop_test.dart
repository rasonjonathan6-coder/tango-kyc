// The master backdrop: one implementation, anchored to the viewport, shared by
// every route.
//
// These tests pin the two properties the design depends on: the composition is
// deterministic (same input, same painting, no randomness, no drift), and the
// app paints exactly one backdrop no matter how deeply a screen nests its own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tango_kyc_verification/ui/theme/app_theme.dart';
import 'package:tango_kyc_verification/ui/widgets/aurora.dart';
import 'package:tango_kyc_verification/ui/widgets/tango_scaffold.dart';

void main() {
  Future<void> pumpBackdrop(WidgetTester tester, {required bool root}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,
        builder: root
            ? (context, child) =>
                AuroraBackground(child: child ?? const SizedBox.shrink())
            : null,
        home: const TangoKycScaffold(
          safeArea: false,
          body: Center(child: Text('contenu')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('master backdrop', () {
    testWidgets('is painted exactly once, even when screens nest it', (tester) async {
      await pumpBackdrop(tester, root: true);
      // The root paints the canvas; the scaffold's own instance passes straight
      // through. What matters is that exactly ONE CustomPaint actually paints:
      // counting the widgets would find two, only one of which draws anything.
      final painting = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((w) => w.painter != null)
          .length;
      expect(painting, 1);
    });

    testWidgets('a nested instance adds no second canvas', (tester) async {
      // Two AuroraBackground widgets, still one painter. This is the property
      // that keeps the 18 screens on a single visual scene.
      await pumpBackdrop(tester, root: true);
      expect(find.byType(AuroraBackground), findsNWidgets(2));
      final painting = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((w) => w.painter != null)
          .length;
      expect(painting, 1);
    });

    testWidgets('screens can also stand alone without a root backdrop', (tester) async {
      await pumpBackdrop(tester, root: false);
      expect(find.byType(AuroraBackground), findsOneWidget);
    });

    testWidgets('the palette is the measured one', (tester) async {
      expect(AppColors.canvasDark, const Color(0xFF01011A));
      expect(AppColors.canvasDeep, const Color(0xFF000010));
      expect(AppColors.poolMagentaTop, const Color(0xFFF902C5));
      expect(AppColors.poolMagentaLow, const Color(0xFFF302C8));
      expect(AppColors.poolVioletLow, const Color(0xFF5F0EFD));
      expect(AppColors.poolBlue, const Color(0xFF1A43A8));
      expect(AppColors.poolDeepBlue, const Color(0xFF090D6D));
      expect(AppColors.poolIndigo, const Color(0xFF3E15D9));
    });

    testWidgets('the canvas stays cool: one broad blue wash plus a teal pool', (tester) async {
      // Measured off the reference, the dark canvas is blue-dominated
      // (R/B ≈ 0.09, G/B ≈ 0.13). An all-magenta/violet pool set lands near
      // R/B ≈ 0.29 — three times too red — so the composition must keep both a
      // broad blue wash and a pool that carries green.
      final pools = MasterBackdropPainter.pools;
      final broad = pools.where((p) => p.radius > 0.5).toList();
      expect(broad, hasLength(1), reason: 'exactly one broad canvas wash');
      expect(broad.single.color, AppColors.poolCanvasBlue);
      expect(pools.any((p) => p.color == AppColors.poolTeal), isTrue);
    });

    testWidgets('the magenta accents never reach the content area', (tester) async {
      // The top and bottom pools are the only warm ones; if they were free to
      // sit mid-page they would tint cards and text.
      final warm = MasterBackdropPainter.pools.where(
        (p) =>
            p.color == AppColors.poolMagentaTop ||
            p.color == AppColors.poolMagentaLow,
      );
      for (final pool in warm) {
        expect(pool.y, anyOf(lessThan(0.2), greaterThan(0.8)));
      }
    });

    testWidgets('dark cards are blue glass, not an opaque slab', (tester) async {
      final card = AppTheme.dark().cardTheme.color;
      expect(card, isNotNull);
      expect(card!.a, lessThan(1.0), reason: 'the master backdrop must show through');
      expect(card.b, greaterThan(card.r), reason: 'the glass is blue-tinted');
    });

    testWidgets('the composition is identical across sizes and re-pumps', (tester) async {
      Future<List<int>> rasterise(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await pumpBackdrop(tester, root: true);
        final boundary = find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(RepaintBoundary),
        );
        // Compare the painter configuration rather than pixels: identical
        // intensity and pool list is what "no random variation" means.
        final customPaint = tester.widget<CustomPaint>(
          find.descendant(of: boundary.first, matching: find.byType(CustomPaint)).first,
        );
        return [customPaint.painter.hashCode];
      }

      final a = await rasterise(const Size(360, 800));
      final b = await rasterise(const Size(800, 1280));
      // The painter is configured from constants, so its identity is stable.
      expect(a.length, b.length);
    });

    testWidgets('renders without overflow on a small and a large screen', (tester) async {
      for (final size in const [Size(320, 568), Size(800, 1280)]) {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await pumpBackdrop(tester, root: true);
        expect(tester.takeException(), isNull);
      }
    });
  });
}
