/// Tests for the in-app notification layer and the KYC journey helper.
///
/// The notification layer is server-backed: rows come from the caller's own
/// `notifications` feed (RLS-scoped), and read state is persisted server side.
/// These tests drive the real controller against an offline fake service, so
/// no network and no mocks of the HTTP layer are involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tango_kyc_verification/core/kyc_journey.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';

import 'fakes.dart';

NotificationItem _item({
  required String id,
  String type = 'status_changed',
  String? ticketId,
  DateTime? readAt,
  DateTime? createdAt,
}) =>
    NotificationItem(
      id: id,
      type: type,
      title: 'Titre',
      body: 'Contenu',
      createdAt: createdAt ?? DateTime(2026, 9, 25),
      ticketId: ticketId,
      readAt: readAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('journey helper', () {
    test('pending stays at the submission step until the payment is validated', () {
      // Created, payment owed, not yet validated: the request is not submitted.
      expect(
        currentStep(KycStatus.pending, paymentRequired: true),
        KycStep.submitted,
      );
      expect(currentStep(KycStatus.pending, paymentRequired: true).position, 1);
      // Payment validated: it has been officially submitted and is in review.
      expect(
        currentStep(KycStatus.pending, paymentRequired: true, isSubmitted: true),
        KycStep.review,
      );
      expect(currentStep(KycStatus.pending, paymentRequired: true, isSubmitted: true).position, 3);
      // A pending ticket that owes nothing has already been submitted.
      expect(currentStep(KycStatus.pending), KycStep.submitted);
      expect(currentStep(KycStatus.pending).position, 1);
    });

    test('each later status advances the step', () {
      expect(currentStep(KycStatus.inReview), KycStep.review);
      expect(currentStep(KycStatus.replied), KycStep.answer);
      expect(currentStep(KycStatus.closed), KycStep.answer);
    });

    test('steps up to the current one are done', () {
      expect(isStepDone(KycStatus.pending, KycStep.submitted, paymentRequired: true), isTrue);
      // Unpaid: the payment step is not done and review has not started.
      expect(isStepDone(KycStatus.pending, KycStep.payment, paymentRequired: true), isFalse);
      expect(isStepDone(KycStatus.pending, KycStep.review, paymentRequired: true), isFalse);
      expect(isStepDone(KycStatus.pending, KycStep.payment), isFalse);
      // Paid and validated: every step up to review is done.
      expect(
        isStepDone(KycStatus.pending, KycStep.payment, paymentRequired: true, isSubmitted: true),
        isTrue,
      );
      expect(
        isStepDone(KycStatus.pending, KycStep.review, paymentRequired: true, isSubmitted: true),
        isTrue,
      );
      expect(
        isStepDone(KycStatus.pending, KycStep.answer, paymentRequired: true, isSubmitted: true),
        isFalse,
      );
    });

    test('journeyFor returns every step in order', () {
      final journey = journeyFor(KycStatus.replied);
      expect(journey.length, KycStep.total);
      expect(journey.every((step) => step.done), isTrue);
    });

    test('next action hint is status specific and never empty', () {
      for (final status in KycStatus.values) {
        expect(nextActionHint(status), isNotEmpty);
      }
      expect(nextActionHint(KycStatus.pending, paymentRequired: true), contains('MVola'));
      // Once the payment is validated the request is submitted; stop asking.
      expect(
        nextActionHint(KycStatus.pending, paymentRequired: true, isSubmitted: true),
        isNot(contains('MVola')),
      );
      // Without a payment request the hint must not mention paying.
      expect(nextActionHint(KycStatus.pending), isNot(contains('MVola')));
    });
  });

  group('notifications', () {
    test('load pulls the server feed and counts unread rows', () async {
      final service = FakeKycService(
        notificationItems: [
          _item(id: 'a', ticketId: 't1'),
          _item(id: 'b', readAt: DateTime(2026, 9, 25, 10)),
        ],
      );
      final controller = NotificationsController(service);

      await controller.load();

      expect(service.notificationsCalls, 1);
      expect(controller.items, hasLength(2));
      expect(controller.unreadCount, 1);
      expect(controller.hasUnread, isTrue);
      expect(controller.error, isNull);
    });

    test('an empty feed is not an error', () async {
      final controller = NotificationsController(FakeKycService());
      await controller.load();
      expect(controller.items, isEmpty);
      expect(controller.unreadCount, 0);
      expect(controller.hasUnread, isFalse);
    });

    test('a load failure surfaces an error without wiping state', () async {
      final controller = NotificationsController(
        FakeKycService(failNotificationsWithCode: 'INTERNAL'),
      );
      await controller.load();
      expect(controller.error, isNotNull);
      expect(controller.items, isEmpty);
    });

    test('marking read updates locally and persists server side', () async {
      final service = FakeKycService(notificationItems: [_item(id: 'a')]);
      final controller = NotificationsController(service);
      await controller.load();

      await controller.markRead('a');

      expect(controller.unreadCount, 0);
      expect(controller.items.first.unread, isFalse);
      expect(service.markReadCalls, 1);
      expect(service.lastMarkedReadId, 'a');
    });

    test('marking an already-read row is a no-op', () async {
      final service = FakeKycService(
        notificationItems: [_item(id: 'a', readAt: DateTime(2026, 9, 25, 10))],
      );
      final controller = NotificationsController(service);
      await controller.load();

      await controller.markRead('a');
      expect(service.markReadCalls, 0);
    });

    test('markAllRead clears every badge and calls the service once', () async {
      final service = FakeKycService(
        notificationItems: [_item(id: 'a'), _item(id: 'b')],
      );
      final controller = NotificationsController(service);
      await controller.load();
      expect(controller.unreadCount, 2);

      await controller.markAllRead();

      expect(controller.unreadCount, 0);
      expect(service.markAllReadCalls, 1);
    });

    test('markAllRead on an all-read feed does not call the service', () async {
      final service = FakeKycService(
        notificationItems: [_item(id: 'a', readAt: DateTime(2026, 9, 25, 10))],
      );
      final controller = NotificationsController(service);
      await controller.load();

      await controller.markAllRead();
      expect(service.markAllReadCalls, 0);
    });

    test('clear drops the feed (used on sign-out)', () async {
      final controller = NotificationsController(
        FakeKycService(notificationItems: [_item(id: 'a')]),
      );
      await controller.load();
      expect(controller.items, isNotEmpty);

      controller.clear();
      expect(controller.items, isEmpty);
      expect(controller.unreadCount, 0);
    });
  });
}
