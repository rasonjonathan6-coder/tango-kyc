/// Push notification behaviour that can be asserted without a device:
///
///   * the payload parser that decides which ticket a tap opens (G);
///   * that a tap opens the right ticket (G);
///   * that a tap is dropped for a signed-out user, so a notification can never
///     reveal a ticket to the wrong account;
///   * that a signed-in session registers the device token.
///
/// The OS-level delivery paths (background, terminated, lock screen) are the
/// platform's responsibility and are reported as PARTIAL/NOT TESTED in the
/// accompanying report; a widget test cannot observe a real Android tray.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:tango_kyc_verification/main.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/kyc_service.dart';
import 'package:tango_kyc_verification/services/notification_service.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';
import 'package:tango_kyc_verification/ui/screens/request_details_screen.dart';

import 'fakes.dart';
import 'realtime_test.dart' show FakeRealtimeService;

class FakePushService implements PushService {
  final _controller = StreamController<PushEvent>.broadcast();
  int registerCalls = 0;
  int unregisterCalls = 0;
  bool initialized = false;

  @override
  Future<bool> initialize() async {
    initialized = true;
    return true;
  }

  @override
  Future<void> registerCurrentToken() async => registerCalls += 1;

  @override
  Future<void> unregisterCurrentToken() async => unregisterCalls += 1;

  @override
  Stream<PushEvent> get onTicketOpen => _controller.stream;

  void tap(String? ticketId) => _controller.add(PushEvent(ticketId: ticketId));

  void close() => _controller.close();
}

Session _session(String id) => Session(
      accessToken: 'a',
      tokenType: 'bearer',
      refreshToken: 'r',
      expiresIn: 3600,
      user: User(
        id: id,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        email: '$id@example.com',
        createdAt: '2026-09-27T00:00:00Z',
      ),
    );

KycRequest _request(String id) => KycRequest(
      id: id,
      ticketCode: 'TNG-KYC-$id',
      status: KycStatus.replied,
      tangoProfileLink: 'https://tango.me/x',
      registerType: RegisterType.email,
      registerValue: 'a@example.com',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

Future<SettingsController> _readySettings() async {
  FlutterSecureStorage.setMockInitialValues({});
  final settings = SettingsController(const FlutterSecureStorage());
  await settings.load();
  await settings.completeOnboarding();
  return settings;
}

Widget _host({
  required FakePushService push,
  required FakeKycService kyc,
  required AuthController auth,
  required SettingsController settings,
}) {
  return MultiProvider(
    providers: [
      Provider<KycService>.value(value: kyc),
      Provider<PushService>.value(value: push),
      ChangeNotifierProvider<AuthController>.value(value: auth),
      ChangeNotifierProvider<SettingsController>.value(value: settings),
      ChangeNotifierProvider<KycController>(create: (_) => KycController(kyc)),
      ChangeNotifierProvider<NotificationsController>(
          create: (_) => NotificationsController(kyc)),
    ],
    child: MaterialApp(
      home: RootGate(realtime: FakeRealtimeService(), linkStream: const Stream.empty()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ticketIdFromData', () {
    test('G: extracts the ticket id from the data payload', () {
      expect(ticketIdFromData({'ticket_id': 'abc-123'}), 'abc-123');
    });

    test('G: returns null when there is no usable ticket id', () {
      expect(ticketIdFromData(const {}), isNull);
      expect(ticketIdFromData({'ticket_id': ''}), isNull);
      expect(ticketIdFromData({'ticket_id': '   '}), isNull);
    });
  });

  testWidgets('G: a tap opens the exact ticket carried by the notification',
      (tester) async {
    final push = FakePushService();
    final kyc = FakeKycService(requests: [_request('ticket-42')]);
    final settings = await _readySettings();
    final auth = AuthController(FakeAuthService(callbackSession: _session('user-a')));
    await auth.initialize();
    await auth.handleCallback(
      Uri.parse('com.tango.kyc.verification://login-callback?code=valid-code'),
    );

    await tester.pumpWidget(_host(push: push, kyc: kyc, auth: auth, settings: settings));
    await tester.pumpAndSettle();

    push.tap('ticket-42');
    await tester.pumpAndSettle();

    expect(find.byType(RequestDetailsScreen), findsOneWidget);
    final screen = tester.widget<RequestDetailsScreen>(find.byType(RequestDetailsScreen));
    expect(screen.ticketId, 'ticket-42');
    push.close();
  });

  testWidgets('B/D: a tap marks the ticket read and drops the badge',
      (tester) async {
    final push = FakePushService();
    final kyc = FakeKycService(
      requests: [_request('ticket-42')],
      notificationItems: [
        NotificationItem(
          id: 'n1',
          type: 'admin_message',
          title: 'Nouveau message',
          body: 'body',
          createdAt: DateTime(2026, 1, 1),
          ticketId: 'ticket-42',
        ),
      ],
    );
    final settings = await _readySettings();
    final auth = AuthController(FakeAuthService(callbackSession: _session('user-a')));
    await auth.initialize();
    await auth.handleCallback(
      Uri.parse('com.tango.kyc.verification://login-callback?code=valid-code'),
    );

    await tester.pumpWidget(_host(push: push, kyc: kyc, auth: auth, settings: settings));
    await tester.pumpAndSettle();
    expect(kyc.notificationsCalls, greaterThanOrEqualTo(1));

    push.tap('ticket-42');
    await tester.pumpAndSettle();

    // The tap opened the ticket and marked its notifications read...
    expect(find.byType(RequestDetailsScreen), findsOneWidget);
    expect(kyc.markTicketReadCalls, 1);
    expect(kyc.lastMarkedTicketId, 'ticket-42');
    // ...and the controller's badge fell without a manual refresh.
    final notifications = tester
        .element(find.byType(RequestDetailsScreen))
        .read<NotificationsController>();
    expect(notifications.unreadCount, 0);
    push.close();
  });

  testWidgets('O: a tap is dropped for a signed-out user', (tester) async {
    final push = FakePushService();
    final kyc = FakeKycService();
    final settings = await _readySettings();
    final auth = AuthController(FakeAuthService());
    await auth.initialize();

    await tester.pumpWidget(_host(push: push, kyc: kyc, auth: auth, settings: settings));
    await tester.pumpAndSettle();

    expect(find.byType(RequestDetailsScreen), findsNothing);
    push.tap('ticket-42');
    await tester.pumpAndSettle();

    expect(find.byType(RequestDetailsScreen), findsNothing,
        reason: 'a signed-out user must never be shown a ticket from a push');
    push.close();
  });

  testWidgets('a signed-in session registers the device token', (tester) async {
    final push = FakePushService();
    final kyc = FakeKycService(requests: [_request('1')]);
    final settings = await _readySettings();
    final auth = AuthController(FakeAuthService(callbackSession: _session('user-a')));
    await auth.initialize();
    await auth.handleCallback(
      Uri.parse('com.tango.kyc.verification://login-callback?code=valid-code'),
    );

    await tester.pumpWidget(_host(push: push, kyc: kyc, auth: auth, settings: settings));
    await tester.pumpAndSettle();

    expect(push.registerCalls, greaterThanOrEqualTo(1),
        reason: 'the device is registered once the identity is known');
    push.close();
  });
}
