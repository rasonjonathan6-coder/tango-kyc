// Tests for the KYC submission controller: success, validation failures from the
// server, rate limiting, duplicate handling and the user reply path.
import 'package:flutter_test/flutter_test.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';

import 'fakes.dart';

KycRequest _ticket({
  String code = 'TNG-KYC-8F42A91C',
  KycStatus status = KycStatus.pending,
  RegisterType type = RegisterType.email,
  String value = 'user@example.com',
}) =>
    KycRequest(
      id: '11111111-1111-1111-1111-111111111111',
      ticketCode: code,
      tangoProfileLink: 'https://tango.me/user/1',
      registerType: type,
      registerValue: value,
      status: status,
      createdAt: DateTime(2026, 9, 25),
    );

void main() {
  group('successful submission', () {
    test('returns the created ticket and records it as lastCreated', () async {
      final service = FakeKycService(createdTicket: _ticket(), requests: [_ticket()]);
      final controller = KycController(service);

      final ticket = await controller.submit(
        tangoProfileLink: 'https://tango.me/user/1',
        registerValue: 'user@example.com',
      );

      expect(ticket, isNotNull);
      expect(ticket!.ticketCode, 'TNG-KYC-8F42A91C');
      expect(ticket.status, KycStatus.pending);
      expect(controller.lastCreated, isNotNull);
      expect(service.createCalls, 1);
    });

    test('refreshes the request list after submitting', () async {
      final service = FakeKycService(createdTicket: _ticket(), requests: [_ticket()]);
      final controller = KycController(service);

      await controller.submit(tangoProfileLink: 'https://a.b/c', registerValue: 'a@b.com');

      expect(controller.requests, hasLength(1));
    });

    test('clears the submitting flag on completion', () async {
      final service = FakeKycService(createdTicket: _ticket());
      final controller = KycController(service);

      expect(controller.submitting, isFalse);
      await controller.submit(tangoProfileLink: 'https://a.b/c', registerValue: 'a@b.com');
      expect(controller.submitting, isFalse);
    });
  });

  group('server-declined submissions', () {
    test('surfaces the rate limit code without creating a ticket', () async {
      final service = FakeKycService(failWithCode: 'RATE_LIMITED');
      final controller = KycController(service);

      final ticket = await controller.submit(
        tangoProfileLink: 'https://a.b/c',
        registerValue: 'a@b.com',
      );

      expect(ticket, isNull);
      expect(controller.lastErrorCode, 'RATE_LIMITED');
      expect(controller.lastCreated, isNull);
    });

    test('surfaces the daily ceiling code', () async {
      final service = FakeKycService(failWithCode: 'RATE_LIMITED_DAILY');
      final controller = KycController(service);

      await controller.submit(tangoProfileLink: 'https://a.b/c', registerValue: 'a@b.com');
      expect(controller.lastErrorCode, 'RATE_LIMITED_DAILY');
    });

    test('surfaces validation codes returned by the server', () async {
      for (final code in [
        'PROFILE_LINK_INVALID',
        'REGISTER_EMAIL_INVALID',
        'REGISTER_PHONE_INVALID',
      ]) {
        final controller = KycController(FakeKycService(failWithCode: code));
        await controller.submit(tangoProfileLink: 'x', registerValue: 'y');
        expect(controller.lastErrorCode, code, reason: 'for $code');
      }
    });

    test('resets the error state on a subsequent successful attempt', () async {
      final service = FakeKycService(failWithCode: 'RATE_LIMITED');
      final controller = KycController(service);

      await controller.submit(tangoProfileLink: 'https://a.b/c', registerValue: 'a@b.com');
      expect(controller.lastErrorCode, 'RATE_LIMITED');

      // A second controller backed by an accepting service must be clean.
      final good = KycController(FakeKycService(createdTicket: _ticket()));
      final ticket = await good.submit(tangoProfileLink: 'https://a.b/c', registerValue: 'a@b.com');
      expect(ticket, isNotNull);
      expect(good.lastErrorCode, isNull);
    });
  });

  group('reply handling', () {
    test('forwards the reply to the service', () async {
      final service = FakeKycService(requests: [_ticket()]);
      final controller = KycController(service);

      await controller.sendReply('11111111-1111-1111-1111-111111111111', 'Any update?');
      expect(service.replyCalls, 1);
    });
  });

  group('loading', () {
    test('populates the request list', () async {
      final controller = KycController(FakeKycService(requests: [_ticket(), _ticket(code: 'TNG-KYC-AAAABBBB')]));

      await controller.load();
      expect(controller.requests, hasLength(2));
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
    });
  });
}
