// Tests for the manual MVola payment feature.
//
// The controllers are driven through the real interfaces with offline service
// doubles. The server-side rules (ownership, one payment per ticket, idempotent
// decisions, RLS) are asserted against the live backend in
// tests/scripts/mvola_e2e.py and tests/db/run_tests.sql; these tests cover the
// Flutter-facing behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:tango_kyc_verification/core/validators.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/admin_mvola_controller.dart';
import 'package:tango_kyc_verification/state/mvola_controller.dart';

import 'fakes.dart';

MvolaPayment _payment({
  String id = 'pay-1',
  String ticketId = 'ticket-1',
  MvolaStatus status = MvolaStatus.pending,
  String? reference,
  String? payer,
  DateTime? submittedAt,
  String? rejectionReason,
}) =>
    MvolaPayment(
      id: id,
      ticketId: ticketId,
      amount: 20000,
      currency: 'MGA',
      recipientNumber: '0346715622',
      ussdCode: '#111*1*0346715622*20000*2#',
      status: status,
      createdAt: DateTime(2026, 9, 25, 10),
      transactionReference: reference,
      payerNumber: payer,
      submittedAt: submittedAt,
      rejectionReason: rejectionReason,
    );

void main() {
  group('MvolaStatus', () {
    test('parses the server values', () {
      expect(MvolaStatus.parse('pending'), MvolaStatus.pending);
      expect(MvolaStatus.parse('approved'), MvolaStatus.approved);
      expect(MvolaStatus.parse('rejected'), MvolaStatus.rejected);
      expect(MvolaStatus.parse('cancelled'), MvolaStatus.cancelled);
    });

    test('falls back to pending for an unknown value', () {
      expect(MvolaStatus.parse('made_up'), MvolaStatus.pending);
      expect(MvolaStatus.parse(null), MvolaStatus.pending);
    });
  });

  group('MvolaPayment', () {
    test('shows whole amounts without a decimal part', () {
      expect(_payment().amountLabel, '20000 MGA');
    });

    test('is awaiting review only once submitted and still pending', () {
      expect(_payment().isAwaitingReview, isFalse);
      expect(_payment(submittedAt: DateTime(2026, 9, 25, 11)).isAwaitingReview, isTrue);
      expect(
        _payment(status: MvolaStatus.approved, submittedAt: DateTime(2026, 9, 25, 11))
            .isAwaitingReview,
        isFalse,
      );
    });

    test('parses the admin listing fields', () {
      final payment = MvolaPayment.fromMap({
        'id': 'p1',
        'ticket_id': 't1',
        'amount': 20000,
        'currency': 'MGA',
        'recipient_number': '0346715622',
        'ussd_code': '#111*1*2*0346715622*20000*2#',
        'status': 'approved',
        'created_at': '2026-09-25T10:00:00Z',
        'ticket_code': 'TNG-KYC-8F42A91C',
        'user_email': 'user@example.com',
      });
      expect(payment.status, MvolaStatus.approved);
      expect(payment.ticketCode, 'TNG-KYC-8F42A91C');
      expect(payment.userEmail, 'user@example.com');
    });
  });

  group('MvolaController.load', () {
    test('loads the config and matches the payment to the ticket', () async {
      final service = FakeMvolaService(payments: [_payment(ticketId: 'ticket-1')]);
      final controller = MvolaController(service);

      await controller.load('ticket-1');

      expect(controller.config, isNotNull);
      expect(controller.config!.recipientNumber, '0346715622');
      expect(controller.payment, isNotNull);
      expect(controller.payment!.ticketId, 'ticket-1');
      expect(controller.error, isNull);
      expect(controller.loading, isFalse);
    });

    test('leaves payment null when the ticket has no payment yet', () async {
      final service = FakeMvolaService(payments: [_payment(ticketId: 'other')]);
      final controller = MvolaController(service);

      await controller.load('ticket-1');

      expect(controller.payment, isNull);
      expect(controller.config, isNotNull);
    });

    test('surfaces a stable error code', () async {
      final service = FakeMvolaService(failWithCode: 'MVOLA_NOT_CONFIGURED');
      final controller = MvolaController(service);

      await controller.load('ticket-1');

      expect(controller.lastErrorCode, 'MVOLA_NOT_CONFIGURED');
      expect(controller.error, isNotNull);
      expect(controller.loading, isFalse);
    });
  });

  group('MvolaController.start', () {
    test('creates a payment from the server config', () async {
      final controller = MvolaController(FakeMvolaService());

      final payment = await controller.start('ticket-1');

      expect(payment, isNotNull);
      expect(payment!.status, MvolaStatus.pending);
      expect(payment.amount, 20000);
      expect(payment.recipientNumber, '0346715622');
      expect(controller.payment, isNotNull);
    });

    test('returns the same payment on a second start', () async {
      final controller = MvolaController(FakeMvolaService());

      final first = await controller.start('ticket-1');
      final second = await controller.start('ticket-1');

      expect(second!.id, first!.id);
    });

    test('reports a failure without creating a payment', () async {
      final controller = MvolaController(FakeMvolaService(failWithCode: 'FORBIDDEN'));

      final payment = await controller.start('ticket-1');

      expect(payment, isNull);
      expect(controller.lastErrorCode, 'FORBIDDEN');
    });

    test('sets and clears the starting flag', () async {
      final controller = MvolaController(FakeMvolaService());
      final states = <bool>[];
      controller.addListener(() => states.add(controller.starting));

      await controller.start('ticket-1');

      expect(states.first, isTrue);
      expect(controller.starting, isFalse);
    });
  });

  group('MvolaController.submit', () {
    test('records the reference and marks the payment submitted', () async {
      final controller = MvolaController(FakeMvolaService());
      final payment = await controller.start('ticket-1');

      final ok = await controller.submit(
        paymentId: payment!.id,
        transactionReference: 'MV-123456789',
        payerNumber: '+261341234567',
      );

      expect(ok, isTrue);
      expect(controller.payment!.transactionReference, 'MV-123456789');
      expect(controller.payment!.submittedAt, isNotNull);
      expect(controller.payment!.isAwaitingReview, isTrue);
    });

    test('rejects an empty reference', () async {
      final controller = MvolaController(FakeMvolaService());
      final payment = await controller.start('ticket-1');

      final ok = await controller.submit(paymentId: payment!.id, transactionReference: '');

      expect(ok, isFalse);
      expect(controller.lastErrorCode, 'MVOLA_REFERENCE_REQUIRED');
    });

    test('does not mark the payment submitted when the server refuses', () async {
      final service = FakeMvolaService(failSubmitWithCode: 'MVOLA_REFERENCE_INVALID');
      final controller = MvolaController(service);
      final payment = await controller.start('ticket-1');

      final ok = await controller.submit(paymentId: payment!.id, transactionReference: 'x');

      expect(ok, isFalse);
      expect(controller.lastErrorCode, 'MVOLA_REFERENCE_INVALID');
    });
  });

  group('MvolaController.reset', () {
    test('clears the payment so another ticket starts clean', () async {
      final controller = MvolaController(FakeMvolaService());
      await controller.start('ticket-1');

      controller.reset();

      expect(controller.payment, isNull);
      expect(controller.error, isNull);
      expect(controller.lastErrorCode, isNull);
    });
  });

  group('AdminMvolaController', () {
    test('lists payments and flags the ones awaiting review', () async {
      final service = FakeAdminMvolaService(payments: [
        _payment(id: 'p1', submittedAt: DateTime(2026, 9, 25, 11)),
        _payment(id: 'p2', status: MvolaStatus.approved),
        _payment(id: 'p3'),
      ]);
      final controller = AdminMvolaController(service);

      await controller.load();

      expect(controller.payments, hasLength(3));
      expect(controller.awaitingReview, hasLength(1));
      expect(controller.awaitingReview.single.id, 'p1');
      expect(controller.awaitingCount, 1);
    });

    test('approves a payment', () async {
      final service = FakeAdminMvolaService(payments: [
        _payment(submittedAt: DateTime(2026, 9, 25, 11)),
      ]);
      final controller = AdminMvolaController(service);
      await controller.load();

      final ok = await controller.decide(
        paymentId: 'pay-1',
        decision: MvolaStatus.approved,
      );

      expect(ok, isTrue);
      expect(controller.payments.single.status, MvolaStatus.approved);
      expect(controller.awaitingReview, isEmpty);
    });

    test('refuses a payment and keeps the reason', () async {
      final service = FakeAdminMvolaService(payments: [_payment()]);
      final controller = AdminMvolaController(service);
      await controller.load();

      final ok = await controller.decide(
        paymentId: 'pay-1',
        decision: MvolaStatus.rejected,
        reason: 'Reference MVola introuvable.',
      );

      expect(ok, isTrue);
      expect(service.lastReason, 'Reference MVola introuvable.');
      expect(controller.payments.single.status, MvolaStatus.rejected);
      expect(controller.payments.single.rejectionReason, 'Reference MVola introuvable.');
    });

    test('reports a failure when the server refuses the decision', () async {
      final service = FakeAdminMvolaService(
        failWithCode: 'PAYMENT_ALREADY_REVIEWED',
        payments: [_payment()],
      );
      final controller = AdminMvolaController(service);
      await controller.load();

      final ok = await controller.decide(paymentId: 'pay-1', decision: MvolaStatus.approved);

      expect(ok, isFalse);
      expect(controller.lastErrorCode, 'PAYMENT_ALREADY_REVIEWED');
    });
  });

  group('MVola validation', () {
    test('accepts a plausible transaction reference', () {
      expect(Validators.validateMvolaReference('MV-123456789'), isNull);
      expect(Validators.validateMvolaReference('  MV 987 654  '), isNull);
      expect(Validators.validateMvolaReference('123456789'), isNull);
    });

    test('rejects an empty or too short reference', () {
      expect(Validators.validateMvolaReference(''), isNotNull);
      expect(Validators.validateMvolaReference('  '), isNotNull);
      expect(Validators.validateMvolaReference('ab'), isNotNull);
    });

    test('rejects markup and unsupported characters', () {
      expect(Validators.validateMvolaReference('<script>alert(1)</script>'), isNotNull);
      expect(Validators.validateMvolaReference('ref;drop table'), isNotNull);
      expect(Validators.validateMvolaReference('a' * 65), isNotNull);
    });

    test('treats the payer number as optional', () {
      expect(Validators.validateMvolaPayerNumber(''), isNull);
      expect(Validators.validateMvolaPayerNumber('+261 34 12 345 67'), isNull);
      expect(Validators.validateMvolaPayerNumber('0346715622'), isNull);
      expect(Validators.validateMvolaPayerNumber('123'), isNotNull);
    });
  });

  group('MVola error messages', () {
    test('never exposes the raw server text', () {
      final message = ErrorMessages.from('MVOLA_REFERENCE_REQUIRED');
      expect(message, 'Saisissez la référence de la transaction MVola.');
      expect(message.contains('MVOLA_'), isFalse);
    });

    test('maps the remaining MVola codes', () {
      expect(ErrorMessages.from('MVOLA_NOT_CONFIGURED'),
          'Le paiement Mobile Money n’est pas disponible pour le moment.');
      expect(ErrorMessages.from('MVOLA_REASON_REQUIRED'),
          'Expliquez pourquoi le paiement est refusé.');
      expect(ErrorMessages.from('PAYMENT_ALREADY_REVIEWED'),
          'Ce paiement a déjà été examiné.');
      expect(ErrorMessages.from('PAYMENT_NOT_FOUND'), 'Paiement introuvable.');
      expect(ErrorMessages.from('MVOLA_PAYER_INVALID'),
          'Saisissez un numéro de téléphone valide.');
    });
  });
}
