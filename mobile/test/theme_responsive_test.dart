// Automated Dark/Light + responsive audit for every real screen.
//
// This is a validation harness, not a feature. For each screen it renders the
// production widget under both [AppTheme.dark] and [AppTheme.light], at the five
// reference Android sizes, and asserts:
//   * no layout overflow / render exception at any size,
//   * text actually carries contrast against what sits behind it (no white text
//     left on the light canvas, no near-black text left on the dark canvas).
//
// The contrast check walks the live render tree: it reads each [Text]'s resolved
// colour and compares it with the canvas behind it. The canvas colours are the
// single source of truth in [AppColors], so this stays honest if the theme moves.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';
import 'package:tango_kyc_verification/state/admin_controller.dart';
import 'package:tango_kyc_verification/state/admin_mvola_controller.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/mvola_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/theme/app_theme.dart';
import 'package:tango_kyc_verification/ui/screens/about_screen.dart';
import 'package:tango_kyc_verification/ui/screens/account_info_screen.dart';
import 'package:tango_kyc_verification/ui/screens/forgot_password_screen.dart';
import 'package:tango_kyc_verification/ui/screens/help_support_screen.dart';
import 'package:tango_kyc_verification/ui/screens/home_screen.dart';
import 'package:tango_kyc_verification/ui/screens/language_screen.dart';
import 'package:tango_kyc_verification/ui/screens/login_screen.dart';
import 'package:tango_kyc_verification/ui/screens/my_requests_screen.dart';
import 'package:tango_kyc_verification/ui/screens/new_request_screen.dart';
import 'package:tango_kyc_verification/ui/screens/notifications_screen.dart';
import 'package:tango_kyc_verification/ui/screens/otp_screen.dart';
import 'package:tango_kyc_verification/ui/screens/profile_screen.dart';
import 'package:tango_kyc_verification/ui/screens/register_screen.dart';
import 'package:tango_kyc_verification/ui/screens/request_details_screen.dart';
import 'package:tango_kyc_verification/ui/screens/security_screen.dart';
import 'package:tango_kyc_verification/ui/screens/settings_screen.dart';
import 'package:tango_kyc_verification/ui/screens/support_chat_screen.dart';

import 'fakes.dart';

const _sizes = <String, Size>{
  '320x568': Size(320, 568),
  '360x640': Size(360, 640),
  '375x812': Size(375, 812),
  '412x915': Size(412, 915),
  '432x932': Size(432, 932),
};

/// Every screen reachable in the app, paired with the widget under test.
Map<String, Widget Function()> _screens() {
  return {
    'Login': () => const LoginScreen(),
    'Register': () => const RegisterScreen(),
    'ForgotPassword': () => const ForgotPasswordScreen(),
    'Otp': () => const OtpScreen(
          email: 'user@example.com',
          purpose: EmailOtpPurpose.signup,
          resendCooldown: Duration.zero,
        ),
    'Home': () => const HomeScreen(),
    'MyRequests': () => const MyRequestsScreen(),
    'NewRequest': () => const NewRequestScreen(),
    'RequestDetails': () => const RequestDetailsScreen(ticketId: 't1'),
    'Notifications': () => const NotificationsScreen(),
    'Profile': () => const ProfileScreen(),
    'Settings': () => const SettingsScreen(),
    'Security': () => const SecurityScreen(),
    'HelpSupport': () => const HelpSupportScreen(),
    'SupportChat': () => const SupportChatScreen(),
    'Language': () => const LanguageScreen(),
    'About': () => const AboutScreen(),
    'AccountInfo': () => const AccountInfoScreen(),
  };
}

Future<Widget> _host(Widget child, Brightness brightness) async {
  final kyc = FakeKycService(
    requests: [
      KycRequest(
        id: 't1',
        ticketCode: 'TNG-1',
        tangoProfileLink: 'https://tango.me/u/1',
        registerType: RegisterType.email,
        registerValue: 'a@b.com',
        status: KycStatus.pending,
        createdAt: DateTime(2026, 9, 25),
        paymentRequired: false,
        isSubmitted: true,
      ),
    ],
  );
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
      home: child,
    ),
  );
}

/// Resolved colour + owning element of every visible [Text] in the tree.
List<(Element, String, Color?)> _texts(WidgetTester tester) {
  final out = <(Element, String, Color?)>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final DefaultTextStyle fallback = DefaultTextStyle.of(element);
    final style = widget.style ?? fallback.style;
    final data = widget.data ?? widget.textSpan?.toPlainText() ?? '';
    if (data.trim().isEmpty) continue;
    out.add((element, data, style.color));
  }
  return out;
}

/// The effective opaque fill sitting behind [text], or `null` when that fill is
/// a gradient (an unknown colour, so the text is exempt from the canvas check).
Color? _fillBehind(Element text, Color canvas) {
  Color? fill;
  var gradient = false;
  text.visitAncestorElements((el) {
    final w = el.widget;
    if (w is ShaderMask) {
      // The fill is a shader (the brand gradient), not a solid colour.
      gradient = true;
      return false;
    }
    if (w is ChoiceChip) {
      final c = w.selected ? w.selectedColor : w.backgroundColor;
      if (c != null && c.a > 0.5) {
        fill = c;
        return false;
      }
    }
    if (w is DecoratedBox) {
      final d = w.decoration;
      if (d is BoxDecoration) {
        if (d.gradient != null) {
          gradient = true;
          return false;
        }
        final c = d.color;
        if (c != null && c.a > 0.5) {
          fill = c;
          return false;
        }
      }
    } else if (w is ColoredBox) {
      if (w.color.a > 0.5) {
        fill = w.color;
        return false;
      }
    } else if (w is Material) {
      final c = w.color;
      if (c != null && c.a > 0.5) {
        fill = c;
        return false;
      }
    } else if (w is Card) {
      final c = Theme.of(el).cardTheme.color;
      if (c != null && c.a > 0.5) {
        fill = c;
        return false;
      }
    }
    return true;
  });
  if (gradient) return null;
  return fill ?? canvas;
}

/// Contrast ratio between two opaque colours, WCAG style.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The three auth screens paint the dark login artwork in BOTH brightnesses
/// (see `AuthBackground`), so in light mode they are NOT judged against
/// [AppColors.canvasLight]. This is the artwork behind the copy expressed as one
/// worst-case surface: its content region (left 60%, the part the scrim holds)
/// after the scrim, at its measured p99 luminance (~0.03). The magenta links sit
/// right at the 3:1 line against it, which is the design's honest limit.
const Color _authArtworkCanvas = Color(0xFF353535);

bool _isAuth(String screen) =>
    screen == 'Login' || screen == 'Register' || screen == 'ForgotPassword';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  for (final brightness in [Brightness.dark, Brightness.light]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    group('$mode / $mode', () {
      for (final screen in _screens().entries) {
        for (final size in _sizes.entries) {
          testWidgets('${screen.key} ${size.key}', (tester) async {
            tester.view.physicalSize = size.value * 3;
            tester.view.devicePixelRatio = 3.0;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(await _host(screen.value(), brightness));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));

            // 1. No overflow / layout exception anywhere.
            expect(tester.takeException(), isNull,
                reason: '${screen.key} threw at ${size.key} in $mode');

            // 2. Text stays legible against whatever actually sits behind it.
            // Text drawn on a brand-gradient fill is exempt (unknown colour).
            final behindCanvas =
                (!_isAuth(screen.key) && brightness == Brightness.light)
                    ? AppColors.canvasLight
                    : (brightness == Brightness.light
                        ? _authArtworkCanvas
                        : AppColors.canvasDark);
            for (final (element, data, colour) in _texts(tester)) {
              if (colour == null) continue;
              if (colour.a < 0.85) continue; // translucent overlays skip
              final behind = _fillBehind(element, behindCanvas);
              if (behind == null) continue;
              final ratio = _contrast(colour, behind);
              expect(ratio, greaterThan(3.0),
                  reason: 'low contrast "${data.trim()}" '
                      '($colour) on $behind in $mode ${screen.key} ${size.key}');
            }
          });
        }
      }
    });
  }
}
