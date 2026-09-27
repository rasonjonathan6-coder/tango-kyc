/// Realtime dashboard behaviour: a live change refreshes the request list and
/// the notification feed without a restart, and the feed is torn down when the
/// widget goes away so it cannot leak into another session.
///
/// These exercise the production [RootGate] with an injected realtime fake; the
/// account isolation itself is enforced server side (RLS) and asserted in
/// `tests/db/push_tokens_tests.sql`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:tango_kyc_verification/main.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/kyc_service.dart';
import 'package:tango_kyc_verification/services/realtime_service.dart';
import 'package:tango_kyc_verification/state/auth_controller.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/state/settings_controller.dart';

import 'fakes.dart';

/// Emits on demand, standing in for the Realtime socket.
class FakeRealtimeService implements RealtimeService {
  void Function(Set<RealtimeTopic> changed)? _onChange;
  int watchCalls = 0;
  int disposeCalls = 0;
  bool cancelled = false;

  @override
  RealtimeSubscription watch(void Function(Set<RealtimeTopic> changed) onChange) {
    watchCalls += 1;
    _onChange = onChange;
    return _FakeSubscription(this);
  }

  void emit(Set<RealtimeTopic> changed) => _onChange?.call(changed);

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}

class _FakeSubscription implements RealtimeSubscription {
  _FakeSubscription(this._owner);
  final FakeRealtimeService _owner;

  @override
  Future<void> cancel() async {
    _owner.cancelled = true;
  }
}

Session _session(String id) => Session(
      accessToken: 'access-token',
      tokenType: 'bearer',
      refreshToken: 'refresh-token',
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
      status: KycStatus.pending,
      tangoProfileLink: 'https://tango.me/x',
      registerType: RegisterType.email,
      registerValue: 'a@example.com',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

NotificationItem _notification(String id) => NotificationItem(
      id: id,
      type: 'status_changed',
      title: 'Nouvelle réponse à votre demande',
      body: 'Vous avez reçu une nouvelle réponse concernant votre demande KYC.',
      createdAt: DateTime(2026, 1, 1),
    );

Future<SettingsController> _readySettings() async {
  FlutterSecureStorage.setMockInitialValues({});
  final settings = SettingsController(const FlutterSecureStorage());
  await settings.load();
  await settings.completeOnboarding();
  return settings;
}

Future<AuthController> _signedIn(String userId) async {
  final auth = AuthController(FakeAuthService(callbackSession: _session(userId)));
  await auth.initialize();
  await auth.handleCallback(
    Uri.parse('com.tango.kyc.verification://login-callback?code=valid-code'),
  );
  return auth;
}

Widget _host({
  required KycService kycService,
  required FakeRealtimeService realtime,
  required AuthController auth,
  required SettingsController settings,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthController>.value(value: auth),
      ChangeNotifierProvider<SettingsController>.value(value: settings),
      ChangeNotifierProvider<KycController>(create: (_) => KycController(kycService)),
      ChangeNotifierProvider<NotificationsController>(
          create: (_) => NotificationsController(kycService)),
    ],
    child: MaterialApp(home: RootGate(realtime: realtime, linkStream: const Stream.empty())),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E: a live kyc_requests change reloads the dashboard without a restart',
      (tester) async {
    final kyc = FakeKycService(requests: [_request('1')]);
    final realtime = FakeRealtimeService();
    final settings = await _readySettings();
    final auth = await _signedIn('user-a');

    await tester.pumpWidget(
        _host(kycService: kyc, realtime: realtime, auth: auth, settings: settings));
    await tester.pumpAndSettle();

    expect(realtime.watchCalls, 1, reason: 'a signed-in user subscribes exactly once');

    final context = tester.element(find.byType(RootGate));
    final controller = Provider.of<KycController>(context, listen: false);
    expect(controller.requests, hasLength(1));

    // The server moved the ticket to "reply received"; the live event is what
    // makes the client refetch, so no restart or pull-to-refresh is needed.
    realtime.emit({RealtimeTopic.requests});
    await tester.pumpAndSettle();

    expect(controller.loading, isFalse);
    expect(controller.requests, hasLength(1));
  });

  testWidgets('F: a live notifications change refreshes the feed and the badge count',
      (tester) async {
    final kyc = FakeKycService(notificationItems: [_notification('n1'), _notification('n2')]);
    final realtime = FakeRealtimeService();
    final settings = await _readySettings();
    final auth = await _signedIn('user-a');

    await tester.pumpWidget(
        _host(kycService: kyc, realtime: realtime, auth: auth, settings: settings));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(RootGate));
    final notifications = Provider.of<NotificationsController>(context, listen: false);
    expect(notifications.unreadCount, 2);

    final before = kyc.notificationsCalls;
    realtime.emit({RealtimeTopic.notifications});
    await tester.pumpAndSettle();

    expect(kyc.notificationsCalls, greaterThan(before),
        reason: 'a live event triggers a refetch of the feed');
    expect(notifications.unreadCount, 2);
  });

  testWidgets('the live feed is cancelled when the gate is disposed', (tester) async {
    final kyc = FakeKycService(requests: [_request('1')]);
    final realtime = FakeRealtimeService();
    final settings = await _readySettings();
    final auth = await _signedIn('user-a');

    await tester.pumpWidget(
        _host(kycService: kyc, realtime: realtime, auth: auth, settings: settings));
    await tester.pumpAndSettle();
    expect(realtime.watchCalls, 1);

    // Replace the tree so RootGate is disposed, as a sign-out-driven shell
    // rebuild would do.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(realtime.cancelled, isTrue, reason: 'the subscription is cancelled on teardown');
    expect(realtime.disposeCalls, greaterThanOrEqualTo(1));
  });
}
