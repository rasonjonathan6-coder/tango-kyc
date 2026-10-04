// Transport-level tests for the email one-time-code flow.
//
// The other OTP tests assert `AuthController` and `OtpScreen` against
// `FakeAuthService`. These assert the *real* `SupabaseAuthService` against a
// local `MockClient`, so the exact HTTP request is pinned — which endpoint is
// called, and what it carries — without touching the network. That is the layer
// where the device bug lived: the request was never made, and the resend used an
// endpoint that had no token to re-send.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:tango_kyc_verification/services/auth_service.dart';

/// In-memory `GotrueAsyncStorage` so the client needs no platform plugins.
class _MemoryStorage extends GotrueAsyncStorage {
  const _MemoryStorage();

  @override
  Future<String?> getItem({required String key}) async => null;

  @override
  Future<void> setItem({required String key, required String value}) async {}

  @override
  Future<void> removeItem({required String key}) async {}
}

void main() {
  late List<http.Request> requests;
  late Map<String, http.Response> responses;

  SupabaseAuthService build() {
    final client = MockClient((request) async {
      requests.add(request);
      for (final entry in responses.entries) {
        if (request.url.path.endsWith(entry.key)) return entry.value;
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });
    // PKCE is a client-side flow: it would store a code verifier before the
    // request. `implicit` keeps the requests pure, so what is asserted below is
    // only the request the server sees.
    final supabase = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: client,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
        pkceAsyncStorage: _MemoryStorage(),
      ),
    );
    return SupabaseAuthService(supabase);
  }

  setUp(() {
    requests = [];
    responses = {
      '/otp': http.Response('{}', 200, headers: {'content-type': 'application/json'}),
      '/resend': http.Response('{}', 200, headers: {'content-type': 'application/json'}),
    };
  });

  group('sendEmailOtp', () {
    test('posts the address to the code endpoint and never asks for a link',
        () async {
      final service = build();

      await service.sendEmailOtp('user@example.com', EmailOtpPurpose.signup);

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/auth/v1/otp'));
      // A `redirect_to` is what turns this into a magic-link request, and the
      // magic-link email carries a link rather than the code the screen needs.
      expect(request.url.queryParameters.containsKey('redirect_to'), isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['email'], 'user@example.com');
      // Registration already created the account; a code request must not mint
      // a second one.
      expect(body['create_user'], isFalse);
    });

    test('a rate-limited request surfaces the server error', () async {
      responses['/otp'] = http.Response(
        '{"code":429,"error_code":"over_email_send_rate_limit",'
        '"msg":"Email rate limit exceeded"}',
        429,
        headers: {'content-type': 'application/json'},
      );
      final service = build();

      await expectLater(
        service.sendEmailOtp('user@example.com', EmailOtpPurpose.signup),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('resendEmailOtp', () {
    test('a sign-in code is re-requested, not re-sent as a signup token',
        () async {
      final service = build();

      await service.resendEmailOtp('user@example.com', EmailOtpPurpose.signup);

      // The regression: `resend(type: signup)` has no pending signup token for a
      // confirmed account, so it answers 200 while mailing nothing.
      expect(requests, hasLength(1));
      expect(requests.single.url.path, endsWith('/auth/v1/otp'));
      expect(requests.any((r) => r.url.path.endsWith('/auth/v1/resend')), isFalse);
    });

    test('a recovery resend stays on the resend endpoint, never a code request',
        () async {
      // The recovery path is out of scope for this fix and is only pinned here so
      // the sign-in change cannot leak into it: a `signInWithOtp` call would
      // overwrite the PKCE verifier a pending recovery link depends on.
      responses['/resend'] = http.Response(
        '{"code":401,"error_code":"validation_failed","msg":"invalid email"}',
        401,
        headers: {'content-type': 'application/json'},
      );
      final service = build();

      // The SDK rejects `resend(type: recovery)` for email before it reaches the
      // network, so no request is expected; what matters is that the code
      // endpoint is not called.
      await expectLater(
        service.resendEmailOtp('user@example.com', EmailOtpPurpose.recovery),
        throwsA(anything),
      );
      expect(requests.any((r) => r.url.path.endsWith('/auth/v1/otp')), isFalse);
    });
  });

  group('verifyEmailOtp', () {
    test('posts the code with the signup type', () async {
      responses['/verify'] = http.Response(
        '{"access_token":"access","token_type":"bearer","expires_in":3600,'
        '"expires_at":4102444800,"refresh_token":"refresh",'
        '"user":{"id":"11111111-1111-1111-1111-111111111111",'
        '"aud":"authenticated","role":"authenticated",'
        '"email":"user@example.com","created_at":"2024-01-01T00:00:00Z",'
        '"app_metadata":{},"user_metadata":{}}}',
        200,
        headers: {'content-type': 'application/json'},
      );
      final service = build();

      await service.verifyEmailOtp(
        email: 'user@example.com',
        token: '12345678',
        purpose: EmailOtpPurpose.signup,
      );

      expect(requests, hasLength(1));
      expect(requests.single.url.path, endsWith('/auth/v1/verify'));
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['email'], 'user@example.com');
      expect(body['token'], '12345678');
      // The code endpoint mints an `email` type token, so that is what the code
      // has to be verified as — `signup` would be rejected.
      expect(body['type'], 'email');
    });
  });
}
