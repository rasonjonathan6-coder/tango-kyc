/// Tests for the in-app notification layer and the KYC journey helper.
///
/// These cover the presentation logic added for the dashboard: unread counting,
/// read persistence, and the step mapping. The notification layer derives from
/// already-validated ticket data, so the tests exercise real code paths rather
/// than mocks of a network call.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tango_kyc_verification/core/kyc_journey.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';

KycRequest _request({
  required String id,
  required String code,
  required KycStatus status,
  DateTime? lastReplyAt,
}) =>
    KycRequest(
      id: id,
      ticketCode: code,
      tangoProfileLink: 'https://tango.me/$id',
      registerType: RegisterType.email,
      registerValue: 'user@example.com',
      status: status,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 2),
      lastReplyAt: lastReplyAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('journey helper', () {
    test('pending maps to the payment step', () {
      expect(currentStep(KycStatus.pending), KycStep.payment);
      expect(currentStep(KycStatus.pending).position, 2);
    });

    test('each later status advances the step', () {
      expect(currentStep(KycStatus.inReview), KycStep.review);
      expect(currentStep(KycStatus.replied), KycStep.answer);
      expect(currentStep(KycStatus.closed), KycStep.answer);
    });

    test('steps up to the current one are done', () {
      expect(isStepDone(KycStatus.pending, KycStep.submitted), isTrue);
      expect(isStepDone(KycStatus.pending, KycStep.payment), isTrue);
      expect(isStepDone(KycStatus.pending, KycStep.review), isFalse);
    });

    test('journeyFor returns every step in order', () {
      final journey = journeyFor(KycStatus.replied);
      expect(journey.length, KycStep.total);
      expect(journey.first.label, 'Request submitted');
      expect(journey.every((step) => step.done), isTrue);
    });

    test('next action hint is status specific and never empty', () {
      for (final status in KycStatus.values) {
        expect(nextActionHint(status), isNotEmpty);
      }
      expect(nextActionHint(KycStatus.pending), contains('MVola'));
      expect(nextActionHint(KycStatus.replied).toLowerCase(), contains('replied'));
    });
  });

  group('notifications', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('a request without a reply produces no notification', () async {
      final controller = NotificationsController(const FlutterSecureStorage());
      await controller.load();
      controller.sync([_request(id: 'a', code: 'TNG-1', status: KycStatus.pending)]);
      expect(controller.items, isEmpty);
      expect(controller.unreadCount, 0);
    });

    test('a replied request produces one unread notification', () async {
      final controller = NotificationsController(const FlutterSecureStorage());
      await controller.load();
      controller.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 25),
        ),
      ]);
      expect(controller.items.length, 1);
      expect(controller.unreadCount, 1);
      expect(controller.hasUnread, isTrue);
      expect(controller.items.first.ticketCode, 'TNG-1');
    });

    test('marking read clears the badge and persists the choice', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final controller = NotificationsController(const FlutterSecureStorage());
      await controller.load();
      controller.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 25),
        ),
      ]);
      await controller.markRead('a');
      expect(controller.unreadCount, 0);
      expect(controller.items.first.unread, isFalse);

      // A fresh controller reading the same storage must still consider it read.
      final reopened = NotificationsController(const FlutterSecureStorage());
      await reopened.load();
      reopened.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 25),
        ),
      ]);
      expect(reopened.unreadCount, 0);
    });

    test('a newer reply reopens the notification', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final controller = NotificationsController(const FlutterSecureStorage());
      await controller.load();
      controller.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 25),
        ),
      ]);
      await controller.markRead('a');
      expect(controller.unreadCount, 0);

      controller.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 26),
        ),
      ]);
      expect(controller.unreadCount, 1);
    });

    test('notifications are ordered most recent first', () async {
      final controller = NotificationsController(const FlutterSecureStorage());
      await controller.load();
      controller.sync([
        _request(
          id: 'old',
          code: 'TNG-OLD',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 10),
        ),
        _request(
          id: 'new',
          code: 'TNG-NEW',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 24),
        ),
      ]);
      expect(controller.items.first.ticketCode, 'TNG-NEW');
    });

    test('markAllRead clears every badge', () async {
      final controller = NotificationsController(const FlutterSecureStorage());
      await controller.load();
      controller.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 25),
        ),
        _request(
          id: 'b',
          code: 'TNG-2',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 24),
        ),
      ]);
      expect(controller.unreadCount, 2);
      await controller.markAllRead();
      expect(controller.unreadCount, 0);
    });

    test('sync before load is ignored rather than wiping state', () async {
      final controller = NotificationsController(const FlutterSecureStorage());
      controller.sync([
        _request(
          id: 'a',
          code: 'TNG-1',
          status: KycStatus.replied,
          lastReplyAt: DateTime(2026, 9, 25),
        ),
      ]);
      expect(controller.items, isEmpty);
    });
  });
}
