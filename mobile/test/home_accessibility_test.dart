// Accessibility harness for the post-login Home: text scaling and touch targets.
//
// Renders the real [HomeScreen] (and the signed-in shell) at several text
// scalers and phone sizes, in both brightnesses, and asserts the things that
// actually break a screen when the OS font size grows:
//   * no layout overflow / render exception,
//   * the primary call to action and the avatar keep a usable touch target,
//   * the app bar bell stays reachable.
//
// Sizes are driven by the space actually given to the widget, not by a device
// class, matching the responsive approach used in `theme_responsive_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/admin_controller.dart';
import 'package:tango_kyc_verification/state/admin_mvola_controller.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/mvola_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/app_shell.dart';
import 'package:tango_kyc_verification/ui/screens/home_screen.dart';
import 'package:tango_kyc_verification/ui/theme/app_theme.dart';
import 'package:tango_kyc_verification/ui/widgets/home_empty_state.dart';
import 'package:tango_kyc_verification/ui/widgets/home_primary_action.dart';

import 'fakes.dart';

const _sizes = <String, Size>{
  '320x568': Size(320, 568),
  '375x812': Size(375, 812),
  '412x915': Size(412, 915),
};

const _scalers = <String, double>{
  '1.0': 1.0,
  '1.3': 1.3,
  '1.5': 1.5,
  '2.0': 2.0,
};

KycRequest _activeTicket() => KycRequest(
      id: 't1',
      ticketCode: 'TNG-KYC-8F42A91C',
      tangoProfileLink: 'https://tango.me/u/1',
      registerType: RegisterType.email,
      registerValue: 'a@b.com',
      status: KycStatus.pending,
      createdAt: DateTime(2026, 9, 25),
      paymentRequired: false,
      isSubmitted: true,
    );

Future<Widget> _host({
  required Widget child,
  required Brightness brightness,
  required double textScale,
  required List<KycRequest> requests,
}) async {
  final kyc = FakeKycService(requests: requests);
  final auth = AuthController(FakeAuthService());
  await auth.initialize();

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthController>.value(value: auth),
      ChangeNotifierProvider<KycController>.value(value: KycController(kyc)),
      ChangeNotifierProvider<NotificationsController>.value(
          value: NotificationsController(kyc)),
      ChangeNotifierProvider<MvolaController>.value(
          value: MvolaController(FakeMvolaService())),
      ChangeNotifierProvider<AdminController>.value(
          value: AdminController(FakeAdminService())),
      ChangeNotifierProvider<AdminMvolaController>.value(
          value: AdminMvolaController(FakeAdminMvolaService())),
      ChangeNotifierProvider<SettingsController>(
          create: (_) => SettingsController(const FlutterSecureStorage())),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      // copyWith, never a fresh MediaQueryData: a bare MediaQueryData() carries
      // size == Size.zero and would leave the whole tree unlaid-out.
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child,
        ),
      ),
    ),
  );
}

/// The smallest side of a widget's on-screen box, in logical pixels.
double _minSide(WidgetTester tester, Finder finder) {
  final size = tester.getSize(finder);
  return size.width < size.height ? size.width : size.height;
}

/// Scrolls the whole page to the end, asserting after every step that nothing
/// overflowed. A [ListView] only builds what is visible, so a single check at
/// the top would never see a lower section laid out at a large text size.
Future<void> _walkToEnd(WidgetTester tester, String where) async {
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 14; i++) {
    await tester.drag(list, const Offset(0, -180));
    await tester.pump();
    expect(
      tester.takeException(),
      isNull,
      reason: 'overflow while scrolling $where (step $i)',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  for (final brightness in [Brightness.dark, Brightness.light]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    group('$mode Home text scaling', () {
      for (final size in _sizes.entries) {
        for (final scaler in _scalers.entries) {
          testWidgets('${size.key} @ ${scaler.key}x active', (tester) async {
            tester.view.physicalSize = size.value * 3;
            tester.view.devicePixelRatio = 3.0;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(await _host(
              child: const HomeScreen(),
              brightness: brightness,
              textScale: scaler.value,
              requests: [_activeTicket()],
            ));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));

            // 1. Nothing overflows or throws at this text size.
            expect(
              tester.takeException(),
              isNull,
              reason: 'Home active threw at ${size.key} @${scaler.key}x $mode',
            );

            // 2. The header avatar stays reachable, and its label is exposed.
            //    Checked before scrolling: it sits at the very top of the list.
            final avatar = find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label == 'Ouvrir le profil',
            );
            expect(avatar, findsOneWidget);
            expect(
              _minSide(tester, avatar),
              greaterThanOrEqualTo(48),
              reason: 'avatar target below 48dp at ${size.key} '
                  '@${scaler.key}x $mode',
            );

            // 3. The primary action keeps a real touch target. At a large text
            //    size it can sit below the fold, so it is brought into view
            //    first (the list only builds what is visible).
            final cta = find.byType(PrimaryActionCard);
            await tester.scrollUntilVisible(
              cta,
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pump();
            expect(cta, findsOneWidget);
            expect(
              tester.getSize(cta).height,
              greaterThanOrEqualTo(48),
              reason: 'primary card too small to tap at ${size.key} '
                  '@${scaler.key}x $mode',
            );

            // 4. Every section below the fold also lays out cleanly.
            await _walkToEnd(tester, 'active ${size.key} @${scaler.key}x $mode');
          });

          testWidgets('${size.key} @ ${scaler.key}x empty', (tester) async {
            tester.view.physicalSize = size.value * 3;
            tester.view.devicePixelRatio = 3.0;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(await _host(
              child: const HomeScreen(),
              brightness: brightness,
              textScale: scaler.value,
              requests: const [],
            ));
            await tester.pump();
            // The Home shows a skeleton while `load()` is in flight; the empty
            // state only exists once that settles.
            await tester.pumpAndSettle();

            expect(
              tester.takeException(),
              isNull,
              reason: 'Home empty threw at ${size.key} @${scaler.key}x $mode',
            );

            // The empty state still offers the primary action, tappable. It may
            // sit below the fold at a large text size.
            final empty = find.byType(NoActiveRequestCard);
            await tester.scrollUntilVisible(
              empty,
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pump();
            expect(empty, findsOneWidget);
            final action = find.descendant(
              of: empty,
              matching: find.byType(TextButton),
            );
            expect(action, findsOneWidget);
            expect(
              tester.getSize(action).height,
              greaterThanOrEqualTo(48),
              reason: 'empty-state action below 48dp at ${size.key} '
                  '@${scaler.key}x $mode',
            );

            await _walkToEnd(tester, 'empty ${size.key} @${scaler.key}x $mode');
          });
        }
      }

      // The shell owns the app bar, so its bell is validated at the largest
      // scaler only, where a cramped bar would first break.
      testWidgets('shell app bar stays usable at 2.0x on the smallest screen',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568) * 3;
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(await _host(
          child: const AppShell(),
          brightness: brightness,
          textScale: 2.0,
          requests: [_activeTicket()],
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.takeException(), isNull,
            reason: 'AppShell threw at 320x568 @2.0x $mode');

        final bell = find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.notifications_none_rounded),
        );
        expect(bell, findsOneWidget);

        // Measure the button, not the 24dp glyph inside it: the touch target is
        // the IconButton's own box.
        final bellButton = find.ancestor(
          of: bell,
          matching: find.byType(IconButton),
        );
        expect(bellButton, findsOneWidget);
        expect(
          _minSide(tester, bellButton),
          greaterThanOrEqualTo(48),
          reason: 'bell target below 48dp at 2.0x $mode',
        );
      });
    });
  }
}
