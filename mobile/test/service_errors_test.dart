// Tests for the mapping from a failed Edge Function call to a typed exception.
//
// This is the join between the backend's stable error codes and the UI's copy,
// so it is tested directly with the real FunctionException type rather than a
// stub.
import 'package:flutter_test/flutter_test.dart';
import 'package:functions_client/functions_client.dart';
import 'package:tango_kyc_verification/services/kyc_service.dart';

void main() {
  group('HTTP error responses', () {
    test('reads the stable code and message from a JSON body', () {
      final exception = kycExceptionFor(
        FunctionsHttpException(
          status: 429,
          reasonPhrase: 'Too Many Requests',
          details: {'error': 'RATE_LIMITED', 'message': 'You already sent a request.'},
        ),
      );

      expect(exception.code, 'RATE_LIMITED');
      expect(exception.message, 'You already sent a request.');
    });

    test('parses a JSON body delivered as a raw string', () {
      final exception = kycExceptionFor(
        FunctionsHttpException(
          status: 403,
          reasonPhrase: 'Forbidden',
          details: '{"error":"FORBIDDEN","message":"You are not allowed to do that."}',
        ),
      );

      expect(exception.code, 'FORBIDDEN');
    });

    test('keeps the code when the message is missing', () {
      final exception = kycExceptionFor(
        FunctionsHttpException(
          status: 422,
          reasonPhrase: 'Unprocessable',
          details: {'error': 'PROFILE_LINK_INVALID'},
        ),
      );

      expect(exception.code, 'PROFILE_LINK_INVALID');
      expect(exception.message, 'Something went wrong. Please try again.');
    });
  });

  group('unexpected failures', () {
    test('a non-JSON body degrades to a generic code', () {
      final exception = kycExceptionFor(
        FunctionsHttpException(
          status: 500,
          reasonPhrase: 'Internal Server Error',
          details: '<html>502 Bad Gateway</html>',
        ),
      );

      expect(exception.code, 'INTERNAL');
      expect(exception.message, 'Something went wrong. Please try again.');
    });

    test('an empty body degrades to a generic code', () {
      final exception = kycExceptionFor(
        FunctionsHttpException(status: 500, reasonPhrase: 'Error', details: ''),
      );
      expect(exception.code, 'INTERNAL');
    });

    test('a transport failure degrades to a generic code', () {
      final exception = kycExceptionFor(
        FunctionsFetchException(details: Exception('SocketException: connection refused')),
      );
      expect(exception.code, 'INTERNAL');
      expect(exception.message, 'Something went wrong. Please try again.');
    });

    test('an unrelated error object degrades to a generic code', () {
      expect(kycExceptionFor(Exception('boom')).code, 'INTERNAL');
      expect(kycExceptionFor('plain string').code, 'INTERNAL');
    });
  });

  group('payload normalisation', () {
    test('passes through a decoded map', () {
      expect(asJsonMap({'a': 1}), {'a': 1});
    });

    test('decodes a JSON string', () {
      expect(asJsonMap('{"a":1}'), {'a': 1});
    });

    test('returns an empty map for junk', () {
      expect(asJsonMap('not json'), isEmpty);
      expect(asJsonMap(null), isEmpty);
      expect(asJsonMap(42), isEmpty);
      expect(asJsonMap('[1,2,3]'), isEmpty);
    });
  });

  group('server submission state merge', () {
    test('folds a well-formed state into the row', () {
      final merged = mergeSubmissionState(
        {'id': 't1', 'payment_required': true},
        {'payment_status': 'approved', 'is_submitted': true},
      );
      expect(merged['payment_status'], 'approved');
      expect(merged['is_submitted'], true);
      expect(merged['id'], 't1');
      expect(merged['payment_required'], true);
    });

    test('overrides a stale embedded fallback', () {
      // The row already carries an embedded fallback; the server state wins.
      final merged = mergeSubmissionState(
        {'payment_required': true, 'is_submitted': false, 'payment_status': 'awaiting_submission'},
        {'payment_status': 'approved', 'is_submitted': true},
      );
      expect(merged['is_submitted'], true);
      expect(merged['payment_status'], 'approved');
    });

    test('leaves the row untouched when the state is missing or malformed', () {
      final row = {'is_submitted': false, 'payment_status': 'awaiting_submission'};
      expect(mergeSubmissionState(row, null), same(row));
      expect(mergeSubmissionState(row, 'nope'), same(row));
      expect(mergeSubmissionState(row, <String, dynamic>{}), same(row));
      expect(mergeSubmissionState(row, {'is_submitted': 'yes'}), same(row));
    });

    test('accepts a partial state without inventing the missing field', () {
      final merged = mergeSubmissionState(
        {'is_submitted': false},
        {'payment_status': 'approved'},
      );
      expect(merged['payment_status'], 'approved');
      expect(merged['is_submitted'], false);
    });
  });

  group('exception surface', () {
    test('toString exposes the code for logging', () {
      const exception = KycServiceException('RATE_LIMITED', 'Slow down.');
      expect(exception.toString(), 'RATE_LIMITED: Slow down.');
    });
  });
}
