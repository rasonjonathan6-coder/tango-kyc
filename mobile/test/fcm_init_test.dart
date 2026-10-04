/// The FCM registration handshake, exercised without a device or the Firebase
/// plugin.
///
/// These tests drive [FirebasePushService] through its injected seams
/// (`initialize`, `requestPermission`, `getToken`) so the *decision* logic is
/// real code under test: whether an early caller waits, whether a failure is
/// swallowed, whether a refusal skips registration. They do not claim to run
/// Firebase itself — that is the platform's job and is NOT TESTED here.
library;

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tango_kyc_verification/services/kyc_service.dart';
import 'package:tango_kyc_verification/services/notification_service.dart';

import 'fakes.dart';

/// A [KycService] whose token registration can be made to fail, so the
/// "registration error must not crash" path is real code rather than a mock.
class _FailingRegisterKycService extends FakeKycService {
  _FailingRegisterKycService();

  @override
  Future<void> registerDeviceToken({
    required String token,
    String platform = 'android',
  }) async {
    throw StateError('register_device_token failed');
  }
}

FirebasePushService _service(
  KycService kyc, {
  required Future<bool> Function() initialize,
  Future<AuthorizationStatus> Function()? requestPermission,
  Future<String?> Function()? getToken,
}) {
  return FirebasePushService(
    kyc,
    initialize: initialize,
    requestPermission: requestPermission ?? () async => AuthorizationStatus.authorized,
    getToken: getToken ?? () async => 'fcm-token-0123456789',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registerCurrentToken waits for an in-flight initialize', () async {
    final kyc = FakeKycService();
    final gate = Completer<bool>();
    final push = _service(kyc, initialize: () => gate.future);

    final started = push.initialize(); // in flight, not finished
    final registering = push.registerCurrentToken(); // must await it

    await Future<void>.delayed(Duration.zero);
    expect(kyc.registeredTokens, isEmpty,
        reason: 'nothing may be registered before Firebase is ready');

    gate.complete(true);
    expect(await started, isTrue);
    await registering;

    expect(kyc.registeredTokens.single.token, 'fcm-token-0123456789',
        reason: 'the early caller registers once init resolves');
  });

  test('concurrent initialize and register share a single initialization', () async {
    final kyc = FakeKycService();
    final gate = Completer<bool>();
    var initCalls = 0;
    final push = _service(kyc, initialize: () {
      initCalls += 1;
      return gate.future;
    });

    final a = push.initialize();
    final b = push.initialize();
    final c = push.registerCurrentToken();

    await Future<void>.delayed(Duration.zero);
    expect(initCalls, 1, reason: 'the three calls collapse into one attempt');

    gate.complete(true);
    await Future.wait([a, b, c]);
    expect(initCalls, 1, reason: 'no further attempt after the shared future resolves');
  });

  test('a failed initialization is swallowed and registration is skipped', () async {
    final kyc = FakeKycService();
    final push = _service(kyc, initialize: () async => false);

    expect(await push.initialize(), isFalse);
    await push.registerCurrentToken(); // must not throw

    expect(kyc.registeredTokens, isEmpty);
  });

  test('a throwing initialization is caught and never escapes', () async {
    final kyc = FakeKycService();
    final push = _service(kyc, initialize: () async => throw StateError('no firebase'));

    expect(await push.initialize(), isFalse);
    await push.registerCurrentToken();

    expect(kyc.registeredTokens, isEmpty);
  });

  test('a denied permission skips token retrieval and registration', () async {
    final kyc = FakeKycService();
    var getTokenCalls = 0;
    final push = _service(
      kyc,
      initialize: () async => true,
      requestPermission: () async => AuthorizationStatus.denied,
      getToken: () async {
        getTokenCalls += 1;
        return 'fcm-token-0123456789';
      },
    );

    await push.registerCurrentToken();

    expect(getTokenCalls, 0, reason: 'a refused user must not have a token fetched');
    expect(kyc.registeredTokens, isEmpty);
  });

  test('an obtained token is registered for the signed-in user', () async {
    final kyc = FakeKycService();
    final push = _service(
      kyc,
      initialize: () async => true,
      getToken: () async => 'fcm-token-0123456789',
    );

    await push.registerCurrentToken();

    expect(kyc.registeredTokens.single.token, 'fcm-token-0123456789');
    expect(kyc.registeredTokens.single.platform, 'android');
  });

  test('a null token is a no-op, not a crash', () async {
    final kyc = FakeKycService();
    final push = _service(
      kyc,
      initialize: () async => true,
      getToken: () async => null,
    );

    await push.registerCurrentToken();

    expect(kyc.registeredTokens, isEmpty);
  });

  test('a registration failure is caught and never crashes', () async {
    final kyc = _FailingRegisterKycService();
    final push = _service(kyc, initialize: () async => true);

    await push.registerCurrentToken(); // must not throw
  });

  group('maskTokenForLog', () {
    test('never returns the whole token', () {
      const token = 'fcm-token-0123456789abcdef';
      final masked = maskTokenForLog(token);

      expect(masked, contains('length=${token.length}'));
      expect(masked, contains('prefix=fcm-to'));
      expect(masked.contains(token), isFalse,
          reason: 'the full FCM token must never be logged');
    });

    test('handles a short token without throwing', () {
      expect(maskTokenForLog('abc'), contains('length=3'));
    });
  });
}
