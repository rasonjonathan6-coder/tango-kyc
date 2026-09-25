/// Tango KYC Verification.
///
/// Flutter client for the manual KYC review workflow. All privileged behaviour
/// (ticket creation, reply ingestion, admin operations) happens in Supabase Edge
/// Functions; this app only holds the public anon key, and Row Level Security
/// constrains every read to the signed-in user's own rows.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'services/auth_service.dart';
import 'services/kyc_service.dart';
import 'state/admin_controller.dart';
import 'state/auth_controller.dart';
import 'state/kyc_controller.dart';
import 'state/settings_controller.dart';
import 'ui/app_shell.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/reset_password_screen.dart';
import 'ui/screens/splash_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppConfig.load();

  if (!AppConfig.isConfigured) {
    runApp(const _ConfigurationMissingApp());
    return;
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );


  runApp(const TangoKycApp());
}

class TangoKycApp extends StatelessWidget {
  const TangoKycApp({super.key});

  @override
  Widget build(BuildContext context) {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final client = Supabase.instance.client;
    final authService = SupabaseAuthService(client);

    return MultiProvider(
      providers: [
        Provider<AuthService>.value(value: authService),
        Provider<KycService>.value(value: SupabaseKycService(client)),
        Provider<AdminService>.value(value: SupabaseAdminService(client)),
        ChangeNotifierProvider(create: (_) => AuthController(authService)..initialize()),
        ChangeNotifierProvider(create: (_) => KycController(SupabaseKycService(client))),
        ChangeNotifierProvider(create: (_) => AdminController(SupabaseAdminService(client))),
        ChangeNotifierProvider(create: (_) => SettingsController(storage)..load()),
      ],
      child: Consumer<SettingsController>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Tango KYC Verification',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themeMode,
          home: const _RootGate(),
        ),
      ),
    );
  }
}

/// Chooses between the splash, the sign-in screen and the signed-in shell, and
/// routes OAuth / password-recovery deep links.
class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  bool _recovering = false;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleLink,
      onError: (_) {
        // A malformed link is not actionable; ignore it rather than crash.
      },
    );
    _handleInitialLink();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) await _handleLink(uri);
    } catch (_) {
      // No initial link, or the platform could not supply one.
    }
  }

  /// Completes an OAuth or recovery link. A recovery link lands the user on the
  /// reset-password screen; an OAuth link simply establishes the session.
  Future<void> _handleLink(Uri uri) async {
    if (!mounted) return;
    final auth = context.read<AuthService>();
    try {
      final isRecovery = uri.toString().contains('type=recovery');
      final established = await auth.handleAuthCallback(uri);
      if (!established || !mounted) return;

      if (isRecovery) {
        setState(() => _recovering = true);
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
        );
        if (mounted) setState(() => _recovering = false);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This link is no longer valid. Please request a new one.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    if (!auth.initialized || _recovering) {
      return const SplashScreen();
    }
    return auth.isSignedIn ? const AppShell() : const LoginScreen();
  }
}

/// Shown when the build has no Supabase configuration. It states the problem
/// plainly instead of failing silently or pretending to work.
class _ConfigurationMissingApp extends StatelessWidget {
  const _ConfigurationMissingApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.settings_suggest_rounded, size: 56),
                const SizedBox(height: 20),
                Text(
                  'Configuration required',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text(
                  'SUPABASE_URL and SUPABASE_ANON_KEY are not set.\n\n'
                  'Build with:\n'
                  'flutter run --dart-define=SUPABASE_URL=... '
                  '--dart-define=SUPABASE_ANON_KEY=...\n\n'
                  'or copy mobile/assets/env.example to mobile/assets/env '
                  'and fill in the values. See docs/SUPABASE_SETUP.md.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
