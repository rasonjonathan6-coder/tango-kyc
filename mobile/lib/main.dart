/// Tango KYC Verification.
///
/// Flutter client for the manual KYC review workflow. All privileged behaviour
/// (ticket creation, reply ingestion, admin operations) happens in Supabase Edge
/// Functions; this app only holds the public anon key, and Row Level Security
/// constrains every read to the signed-in user's own rows.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'services/auth_service.dart';
import 'services/kyc_service.dart';
import 'services/mvola_service.dart';
import 'services/notification_service.dart';
import 'services/realtime_service.dart';
import 'state/admin_controller.dart';
import 'state/admin_mvola_controller.dart';
import 'state/auth_controller.dart';
import 'state/kyc_controller.dart';
import 'state/mvola_controller.dart';
import 'state/notifications_controller.dart';
import 'state/settings_controller.dart';
import 'ui/app_shell.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/request_details_screen.dart';
import 'ui/screens/reset_password_screen.dart';
import 'ui/screens/splash_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/aurora.dart';

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

class TangoKycApp extends StatefulWidget {
  const TangoKycApp({super.key, this.push});

  /// Push transport. Production leaves this null and uses FCM; tests inject a
  /// fake so no Firebase plugin is touched.
  final PushService? push;

  @override
  State<TangoKycApp> createState() => _TangoKycAppState();
}

class _TangoKycAppState extends State<TangoKycApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  late final PushService _push;

  @override
  void initState() {
    super.initState();
    final client = Supabase.instance.client;
    _push = widget.push ?? FirebasePushService(SupabaseKycService(client));
    // Best effort: without a google-services.json this resolves false and the
    // app runs normally, just without push.
    unawaited(_push.initialize());
  }

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    final authService = SupabaseAuthService(client);

    return MultiProvider(
      providers: [
        Provider<SupabaseClient>.value(value: client),
        Provider<PushService>.value(value: _push),
        Provider<AuthService>.value(value: authService),
        Provider<KycService>.value(value: SupabaseKycService(client)),
        Provider<AdminService>.value(value: SupabaseAdminService(client)),
        Provider<MvolaService>.value(value: SupabaseMvolaService(client)),
        Provider<AdminMvolaService>.value(value: SupabaseAdminMvolaService(client)),
        ChangeNotifierProvider(create: (_) => AuthController(authService)..initialize()),
        ChangeNotifierProvider(create: (_) => KycController(SupabaseKycService(client))),
        ChangeNotifierProvider(create: (_) => AdminController(SupabaseAdminService(client))),
        ChangeNotifierProvider(create: (_) => MvolaController(SupabaseMvolaService(client))),
        ChangeNotifierProvider(
            create: (_) => AdminMvolaController(SupabaseAdminMvolaService(client))),
        ChangeNotifierProvider(create: (_) => SettingsController(_storage)..load()),
        ChangeNotifierProvider(
            create: (_) => NotificationsController(SupabaseKycService(client))),
      ],
      child: Consumer<SettingsController>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Tango KYC Verification',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themeMode,
          // One aurora backdrop for the whole app, behind every route. Screens
          // keep a transparent Scaffold so the auras show through; a nested
          // AuroraBackground is a no-op (see the widget).
          builder: (context, child) => AuroraBackground(
            animate: !kIsWeb,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const RootGate(),
        ),
      ),
    );
  }
}

/// Chooses between the splash, the sign-in screen and the signed-in shell, and
/// routes OAuth / password-recovery / email-confirmation deep links.
class RootGate extends StatefulWidget {
  const RootGate({super.key, this.linkStream, this.initialLink, this.recovering, this.realtime});

  /// Deep-link sources. Production leaves these null and uses [AppLinks]; tests
  /// supply their own so no platform channel is involved.
  final Stream<Uri>? linkStream;
  final Uri? initialLink;

  /// Live change feed. Production leaves this null and uses Supabase Realtime;
  /// tests inject a fake so no socket is opened.
  final RealtimeService? realtime;

  /// Seed for the password-recovery state so a test can exercise the reset
  /// screen without a live deep link.
  final bool? recovering;

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  StreamSubscription<Uri>? _linkSubscription;
  StreamSubscription<PushEvent>? _pushSubscription;
  RealtimeService? _realtime;
  RealtimeSubscription? _realtimeSubscription;
  bool _recovering = false;

  @override
  void initState() {
    super.initState();
    _recovering = widget.recovering ?? false;
    // Null-aware short-circuit: AppLinks is only touched when no test stream is
    // supplied, so widget tests never hit the platform channel.
    _linkSubscription = (widget.linkStream ?? AppLinks().uriLinkStream).listen(
      _handleLink,
      onError: (_) {
        // A malformed link is not actionable; ignore it rather than crash.
      },
    );
    _handleInitialLink();
    final push = _maybePush();
    _pushSubscription = push?.onTicketOpen.listen(_openTicket);
    // Initial reconciliation: load the feed for an already-restored session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onAuthChanged(force: true);
    });
  }

  /// The push transport, or null when none was provided. Kept optional so the
  /// gate can be embedded without Firebase (tests, deep-link-only harnesses);
  /// the app always provides one.
  PushService? _maybePush() {
    try {
      return Provider.of<PushService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Opens the exact ticket a notification refers to. Called for both a live tap
  /// (foreground/background) and a cold-start launch from a terminated app.
  ///
  /// A tap that arrives before the app has restored its session is simply
  /// dropped: there is no ticket to show to a signed-out user, and the event
  /// carries nothing sensitive beyond an opaque ticket id.
  void _openTicket(PushEvent event) {
    final ticketId = event.ticketId;
    if (!mounted || ticketId == null) return;
    final auth = context.read<AuthController>();
    if (!auth.isSignedIn) return;
    final navigator = Navigator.of(context);
    if (_recovering) return;
    navigator.push(
      MaterialPageRoute(builder: (_) => RequestDetailsScreen(ticketId: ticketId)),
    );
  }

  /// Reloads the notification feed whenever the signed-in identity changes, so
  /// one account never sees another's rows and a fresh session is up to date.
  /// [force] is used for the very first reconciliation after startup.
  String? _lastNotifUserId;
  void _onAuthChanged({bool force = false}) {
    final auth = context.read<AuthController>();
    final notifications = context.read<NotificationsController>();
    final userId = auth.isSignedIn ? auth.session?.user.id : null;
    if (!force && userId == _lastNotifUserId) return;
    _lastNotifUserId = userId;
    if (userId != null) {
      notifications.load();
      _startRealtime();
      // Register this device once the identity is known, so a push can reach it.
      _maybePush()?.registerCurrentToken();
    } else {
      _stopRealtime();
      _maybePush()?.unregisterCurrentToken();
      notifications.clear();
    }
  }

  /// Subscribes to the owner's own row changes so a reply that arrives while the
  /// app is open refreshes the list and the badge without a manual pull.
  void _startRealtime() {
    if (_realtimeSubscription != null) return;
    final service = widget.realtime ?? _defaultRealtime();
    if (service == null) return;
    _realtime = service;
    _realtimeSubscription = service.watch((changed) {
      if (!mounted) return;
      if (changed.contains(RealtimeTopic.requests)) {
        context.read<KycController>().load();
      }
      if (changed.contains(RealtimeTopic.notifications)) {
        context.read<NotificationsController>().load();
      }
    });
  }

  /// The app's default realtime feed. Null when no [SupabaseClient] is in scope
  /// (a deep-link-only harness without a backend), in which case the screen
  /// simply never receives a live event and still works on pull-to-refresh.
  SupabaseRealtimeService? _defaultRealtime() {
    try {
      return SupabaseRealtimeService(context.read<SupabaseClient>());
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _stopRealtime() {
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    _realtime?.dispose();
    _realtime = null;
  }

  @override
  void dispose() {
    _stopRealtime();
    _pushSubscription?.cancel();
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleInitialLink() async {
    // Only the platform fetch is guarded here; [_handleLink] reports its own
    // failures (an expired code must never be swallowed).
    Uri? uri = widget.initialLink;
    if (uri == null) {
      try {
        uri = await AppLinks().getInitialLink();
      } catch (_) {
        return; // No initial link, or the platform could not supply one.
      }
    }
    if (uri != null) await _handleLink(uri);
  }

  /// Completes an OAuth or recovery/confirmation link. A recovery link lands the
  /// user on the reset-password screen; an ordinary link (Google OAuth or an
  /// email-confirmation `?code=`) simply establishes the session, which the root
  /// gate then reacts to.
  ///
  /// The token exchange goes through [AuthController.handleCallback], which
  /// serialises it so a duplicated delivery cannot race the single-use PKCE
  /// verifier.
  Future<void> _handleLink(Uri uri) async {
    if (!mounted) return;
    final auth = context.read<AuthController>();
    try {
      final outcome = await auth.handleCallback(uri);
      if (!mounted || outcome == AuthCallbackOutcome.notAuthenticated) return;

      if (outcome == AuthCallbackOutcome.passwordRecovery) {
        setState(() => _recovering = true);
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
        );
        if (mounted) setState(() => _recovering = false);
      }
    } catch (_) {
      // An expired, already-consumed or incompatible code. Report it plainly
      // instead of hiding it, and never retry automatically.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ce lien de confirmation n\'est plus valide. '
            'Demandez un nouvel email de confirmation.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on any auth change, and reconcile the notification feed for the
    // new identity after the frame (never during build).
    return Consumer<AuthController>(
      builder: (context, auth, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onAuthChanged();
        });

        if (!auth.initialized || _recovering) {
          return const SplashScreen();
        }
        if (auth.isSignedIn) return const AppShell();

        // First run shows onboarding once; afterwards users go straight to sign-in.
        final settings = context.watch<SettingsController>();
        if (!settings.onboardingDone) {
          return OnboardingScreen(onFinished: settings.completeOnboarding);
        }
        return const LoginScreen();
      },
    );
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
