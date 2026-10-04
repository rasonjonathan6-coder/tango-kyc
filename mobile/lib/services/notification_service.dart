/// Real Android notifications for KYC replies, delivered by Firebase Cloud
/// Messaging.
///
/// Three delivery states are handled explicitly:
///
///   * foreground  - FCM does not draw a notification while the app is on
///                   screen, so the payload is shown through
///                   `flutter_local_notifications`, on the same channel and with
///                   the same importance as the background case;
///   * background  - the OS draws the `notification` payload itself;
///   * terminated  - the OS draws it and, on tap, the launch intent carries the
///                   data payload, read back via `getInitialMessage`.
///
/// Tapping any of them yields the `ticket_id` carried in the data payload, which
/// the app uses to open the exact ticket.
///
/// Security: the token is the device's address, nothing more. The recipient of
/// every push is chosen server side from the ticket owner; the client never says
/// who a notification is for. No Firebase service-account credential is present
/// in this app - only the public client configuration from `google-services.json`.
///
/// If Firebase is not configured (no `google-services.json`), [initialize]
/// catches the failure and returns false: the app keeps working, it simply
/// receives no push. Nothing pretends to be functional.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'kyc_service.dart';

/// The Android notification channel used for every KYC reply notification. A
/// single stable id means the user's per-channel settings (sound, vibration,
/// importance, lock-screen visibility) are set once and respected thereafter.
const String kycReplyChannelId = 'kyc_replies';

/// Title/body shown by the app itself when the app is in the foreground. The
/// server sends the same wording in the `notification` payload for the
/// background/terminated cases, so the user sees one message, not two variants.
const String kycReplyTitle = 'Nouvelle réponse à votre demande';
const String kycReplyBody =
    'Vous avez reçu une nouvelle réponse concernant votre demande KYC.';

/// The monochrome status-bar glyph, shared by the OS path (set in the manifest
/// as `default_notification_icon`) and the foreground path below, so a
/// notification looks identical whether it arrived with the app open or not.
const String kycReplyIcon = 'ic_stat_tango';

/// Pulls the ticket id out of an FCM data payload. Pure, so it is unit-tested
/// without any device or network.
String? ticketIdFromData(Map<String, dynamic> data) {
  final value = data['ticket_id'];
  final id = value?.toString().trim();
  return (id == null || id.isEmpty) ? null : id;
}

/// A safe, non-replayable label for a token in a debug log: its length and a
/// short prefix, never the token itself. An FCM token is the device's push
/// address, so it must not appear whole in any log line.
String maskTokenForLog(String token) {
  final prefix = token.length <= 6 ? token : token.substring(0, 6);
  return 'length=${token.length} prefix=$prefix';
}

/// The device's notification-permission state, as far as the app can tell.
///
/// [unavailable] means the question cannot be answered — Firebase is not
/// configured, or the platform has no such permission — in which case the app
/// must not prompt at all.
enum NotificationPermission { granted, denied, unavailable }

/// A new push to react to: the ticket to open, if any.
class PushEvent {
  const PushEvent({this.ticketId});

  final String? ticketId;
}

/// Seam over push so the app can be driven without a device.
abstract class PushService {
  /// Returns true when Firebase was available and the service is live.
  Future<bool> initialize();

  /// Registers the signed-in user's device with the server.
  Future<void> registerCurrentToken();

  /// Removes the device's token server-side on sign-out.
  Future<void> unregisterCurrentToken();

  /// Reads the current permission state. Must never prompt: this exists so a
  /// screen can decide whether prompting is even necessary.
  Future<NotificationPermission> notificationPermission();

  /// Prompts once for the notification permission and reports the outcome.
  /// Callers are responsible for not asking again after a refusal.
  Future<NotificationPermission> requestNotificationPermission();

  /// Ticket-opening events from notification taps.
  Stream<PushEvent> get onTicketOpen;
}

/// Used when Firebase is not configured: an inert but honest no-op.
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  Future<bool> initialize() async => false;

  @override
  Future<void> registerCurrentToken() async {}

  @override
  Future<void> unregisterCurrentToken() async {}

  @override
  Future<NotificationPermission> notificationPermission() async =>
      NotificationPermission.unavailable;

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      NotificationPermission.unavailable;

  @override
  Stream<PushEvent> get onTicketOpen => const Stream<PushEvent>.empty();
}

/// Top-level background handler. FCM requires it to be a top-level function.
///
/// A `notification` payload is drawn by the OS without running this code, so
/// there is nothing to do here but acknowledge; the data payload is preserved by
/// the OS and read on tap. Kept intentionally tiny so a background isolate can
/// never fail startup.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

class FirebasePushService implements PushService {
  FirebasePushService(
    this._service, {
    Future<bool> Function()? initialize,
    Future<AuthorizationStatus> Function()? requestPermission,
    Future<String?> Function()? getToken,
  })  : _initializeOverride = initialize,
        _requestPermission = requestPermission ?? _defaultRequestPermission,
        _getToken = getToken ?? _defaultGetToken;

  final KycService _service;

  /// Seams over the Firebase plugin calls. Production passes none of them, so the
  /// real `FirebaseMessaging` calls are used; they exist only so the registration
  /// decision can be exercised on a host where no plugin is available.
  final Future<bool> Function()? _initializeOverride;
  final Future<AuthorizationStatus> Function() _requestPermission;
  final Future<String?> Function() _getToken;

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  final StreamController<PushEvent> _open = StreamController<PushEvent>.broadcast();

  /// The single shared initialisation. [initialize] and an early
  /// [registerCurrentToken] both await this same future, so concurrent calls
  /// collapse into one `Firebase.initializeApp()` and an early caller waits for
  /// it instead of giving up on `if (!_initialized) return;`.
  Future<bool>? _initFuture;
  bool _initialized = false;

  /// Number of real initialisation attempts. Always 0 or 1 in production; a test
  /// uses it to prove concurrent calls share a single attempt.
  @visibleForTesting
  int debugInitAttempts = 0;

  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _onMessage;
  StreamSubscription<RemoteMessage>? _onOpened;
  String? _token;

  static Future<AuthorizationStatus> _defaultRequestPermission() async =>
      (await FirebaseMessaging.instance.requestPermission()).authorizationStatus;

  static Future<String?> _defaultGetToken() => FirebaseMessaging.instance.getToken();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    kycReplyChannelId,
    'Réponses KYC',
    description: 'Vous informe quand une réponse arrive sur votre demande KYC.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    showBadge: true,
  );

  @override
  Stream<PushEvent> get onTicketOpen => _open.stream;

  @override
  Future<bool> initialize() {
    // One shared future: a second call (or an early `registerCurrentToken`)
    // awaits the in-flight initialisation instead of starting another one.
    return _initFuture ??= _initialize();
  }

  Future<bool> _initialize() async {
    debugPrint('[fcm] initialize: start');
    final override = _initializeOverride;
    try {
      final ok = override != null ? await override() : await _initFirebase();
      if (!ok) {
        debugPrint('[fcm] initialize: Firebase unavailable');
        return false;
      }
      _initialized = true;
      debugPrint('[fcm] initialize: done');
      return true;
    } catch (error) {
      // Most often: no google-services.json, or Firebase not initialised on this
      // platform (the test host). Stay inert rather than crash.
      debugPrint('[fcm] initialize: failed: $error');
      return false;
    }
  }

  /// The real plugin setup. Returns false when Firebase cannot be initialised,
  /// which the caller turns into an inert service rather than a crash.
  Future<bool> _initFirebase() async {
    debugInitAttempts += 1;
    await Firebase.initializeApp();
    debugPrint('[fcm] initializeApp: ok');
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings(kycReplyIcon),
      ),
      onDidReceiveNotificationResponse: (response) {
        // The foreground-path tap carries the payload in `payload`.
        final raw = response.payload;
        if (raw != null && raw.isNotEmpty) {
          _open.add(PushEvent(ticketId: raw));
        }
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    _onMessage = FirebaseMessaging.onMessage.listen(_showForeground);
    _onOpened = FirebaseMessaging.onMessageOpenedApp.listen(_fromMessage);

    // Cold start from a notification tap.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _fromMessage(initial);

    _tokenRefresh = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      debugPrint('[fcm] onTokenRefresh: ${maskTokenForLog(token)}');
      _token = token;
      unawaited(_register(token));
    });

    return true;
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final title = message.notification?.title ?? kycReplyTitle;
    final body = message.notification?.body ?? kycReplyBody;
    await _local.show(
      message.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          kycReplyChannelId,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          showWhen: true,
          // Drives the launcher badge on launchers that support it.
          number: 1,
          icon: kycReplyIcon,
        ),
      ),
      payload: ticketIdFromData(message.data),
    );
  }

  void _fromMessage(RemoteMessage message) {
    _open.add(PushEvent(ticketId: ticketIdFromData(message.data)));
  }

  Future<void> _register(String token) async {
    try {
      await _service.registerDeviceToken(token: token, platform: 'android');
      debugPrint('[fcm] token registered: ${maskTokenForLog(token)}');
    } catch (error) {
      // Registration retries on the next sign-in or token refresh.
      debugPrint('[fcm] token registration failed: $error');
    }
  }

  @override
  Future<void> registerCurrentToken() async {
    // Wait for the shared initialisation instead of bailing out when an early
    // caller (a restored session) reaches here before `initialize()` finished.
    final ready = await initialize();
    if (!ready) {
      debugPrint('[fcm] register skipped: Firebase not initialized');
      return;
    }
    try {
      // Android 13+ requires a runtime permission before any notification shows.
      final status = await _requestPermission();
      debugPrint('[fcm] permission: ${status.name}');
      if (status == AuthorizationStatus.denied) {
        // The user refused: do not register a token we could never use for a
        // visible notification, but never block the app either.
        return;
      }
      final token = _token ?? await _getToken();
      if (token == null || token.isEmpty) {
        debugPrint('[fcm] getToken: none');
        return;
      }
      _token = token;
      debugPrint('[fcm] getToken: ${maskTokenForLog(token)}');
      await _register(token);
    } catch (error) {
      // Best effort; a later sign-in retries.
      debugPrint('[fcm] registerCurrentToken failed: $error');
    }
  }

  /// Reads the permission state without prompting.
  ///
  /// `getNotificationSettings` is a read; only `requestPermission` prompts. On
  /// Android < 13 the platform reports `authorized` because posting is allowed
  /// by default, which is exactly the answer the UI needs.
  @override
  Future<NotificationPermission> notificationPermission() async {
    if (!_initialized) return NotificationPermission.unavailable;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional =>
          NotificationPermission.granted,
        AuthorizationStatus.denied => NotificationPermission.denied,
        AuthorizationStatus.notDetermined => NotificationPermission.denied,
      };
    } catch (_) {
      return NotificationPermission.unavailable;
    }
  }

  /// Prompts for the permission exactly once, returning the user's answer.
  @override
  Future<NotificationPermission> requestNotificationPermission() async {
    if (!_initialized) return NotificationPermission.unavailable;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional =>
          NotificationPermission.granted,
        AuthorizationStatus.denied ||
        AuthorizationStatus.notDetermined =>
          NotificationPermission.denied,
      };
    } catch (_) {
      return NotificationPermission.unavailable;
    }
  }

  @override
  Future<void> unregisterCurrentToken() async {
    final token = _token;
    if (token == null) return;
    try {
      await _service.unregisterDeviceToken(token: token);
    } catch (_) {
      // Best effort.
    }
  }

  @visibleForTesting
  void disposeForTest() {
    _tokenRefresh?.cancel();
    _onMessage?.cancel();
    _onOpened?.cancel();
    _open.close();
  }
}
