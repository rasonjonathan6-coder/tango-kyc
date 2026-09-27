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
  FirebasePushService(this._service);

  final KycService _service;

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  final StreamController<PushEvent> _open = StreamController<PushEvent>.broadcast();

  bool _initialized = false;
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _onMessage;
  StreamSubscription<RemoteMessage>? _onOpened;
  String? _token;

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
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      await Firebase.initializeApp();
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
        _token = token;
        unawaited(_register(token));
      });

      _initialized = true;
      return true;
    } catch (_) {
      // Most often: no google-services.json, or Firebase not initialised on this
      // platform (the test host). Stay inert rather than crash.
      return false;
    }
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
    } catch (_) {
      // Registration retries on the next sign-in or token refresh.
    }
  }

  @override
  Future<void> registerCurrentToken() async {
    if (!_initialized) return;
    try {
      // Android 13+ requires a runtime permission before any notification shows.
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        // The user refused: do not register a token we could never use for a
        // visible notification, but never block the app either.
        return;
      }
      final token = _token ?? await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      _token = token;
      await _register(token);
    } catch (_) {
      // Best effort; a later sign-in retries.
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
