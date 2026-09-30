// Flow tests for the opening screen.
//
// These drive the production `RootGate` (not the splash widget in isolation) so
// they prove what the user actually sees first at launch: the splash, held for
// the minimum opening time, and never skipped straight to Login.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/main.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/onboarding_screen.dart';
import 'package:tango_kyc_verification/ui/screens/splash_screen.dart';

import 'fakes.dart';

Future<SettingsController> _settings({required bool onboardingDone}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final settings = SettingsController(const FlutterSecureStorage());
  await settings.load();
  if (onboardingDone) await settings.completeOnboarding();
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the splash is the first screen while the session is restoring',
      (tester) async {
    // Nothing has been restored yet: the very first frame must be the splash.
    final auth = AuthController(FakeAuthService());
    final settings = await _settings(onboardingDone: true);

    await tester.pumpWidget(_host(auth, settings));
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget,
        reason: 'the app must open on the splash, not on Login');
    expect(find.byType(LoginScreen), findsNothing);

    // Still restoring, halfway through the floor: the splash stays.
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byType(SplashScreen), findsOneWidget);

    // The restore completes, but the minimum opening time has not elapsed yet,
    // so the splash is not cut short.
    await auth.initialize();
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);

    // Only once the floor has passed does the gate move on.
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.byType(SplashScreen), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('an instant restore is still held for the minimum duration',
      (tester) async {
    // A local, already-restored session resolves before the first frame; the
    // floor is what keeps the splash visible in that common case.
    final auth = AuthController(FakeAuthService());
    await auth.initialize();
    final settings = await _settings(onboardingDone: true);

    await tester.pumpWidget(_host(auth, settings));
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byType(SplashScreen), findsOneWidget,
        reason: 'the splash must not disappear before the floor');

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('after the splash a first-run user lands on the welcome screen',
      (tester) async {
    final auth = AuthController(FakeAuthService());
    await auth.initialize();
    final settings = await _settings(onboardingDone: false);

    await tester.pumpWidget(_host(auth, settings));
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 7200));
    expect(find.byType(OnboardingScreen), findsOneWidget);
  });

  testWidgets('production floor is seven seconds', (tester) async {
    expect(kSplashMinimumDuration, const Duration(seconds: 7));
  });

  testWidgets(
      'syncing to the production floor: Welcome and Login stay away until 7s',
      (tester) async {
    // The same gate the app builds, but at the real production floor instead of
    // the test override, so the shipped duration is exercised end to end.
    Future<void> pumpWith(SettingsController settings, String tag) async {
      final auth = AuthController(FakeAuthService());
      await auth.initialize(); // instant restore: the floor is the only hold
      final kyc = FakeKycService();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthController>.value(value: auth),
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<NotificationsController>(
              create: (_) => NotificationsController(kyc)),
        ],
        // A distinct key forces a fresh State each run: otherwise the first
        // run's elapsed timer is reused and the second would skip the floor.
        child: MaterialApp(
          home: RootGate(
            key: ValueKey(tag),
            linkStream: Stream.empty(),
          ),
        ),
      ));
      await tester.pump();
    }

    // First-run: the welcome screen must not appear before the floor.
    final firstRun = await _settings(onboardingDone: false);
    await pumpWith(firstRun, 'first-run');
    expect(find.byType(SplashScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(OnboardingScreen), findsNothing,
        reason: 'Welcome must be impossible before 7 seconds');
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    expect(find.byType(OnboardingScreen), findsOneWidget);

    // Returning user: Login likewise waits the full floor.
    final returning = await _settings(onboardingDone: true);
    await pumpWith(returning, 'returning');
    expect(find.byType(SplashScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(LoginScreen), findsNothing,
        reason: 'Login must be impossible before 7 seconds');
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('a slow auth restore is waited on, never cut short',
      (tester) async {
    // Auth still uninitialized after the 7s floor: the splash must remain,
    // proving the floor is a minimum and not a hard cutoff.
    final auth = AuthController(FakeAuthService());
    final settings = await _settings(onboardingDone: true);
    await tester.pumpWidget(_host(auth, settings));
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    expect(find.byType(SplashScreen), findsOneWidget,
        reason: 'the gate must still wait for auth.initialized');

    await auth.initialize();
    await tester.pump();
    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
