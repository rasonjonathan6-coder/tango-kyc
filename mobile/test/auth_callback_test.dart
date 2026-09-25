// Tests for deep-link routing.
//
// A password-recovery link is consumed under the PKCE flow, where the callback
// URL is a bare `?code=...` carrying no `type=recovery` parameter. Routing must
// therefore be driven by the redirect type the auth library recovers from the
// stored code verifier, not by inspecting the URL.
import 'package:flutter_test/flutter_test.dart';

import 'package:tango_kyc_verification/config/app_config.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';

import 'fakes.dart';

void main() {
  group('oauthRedirectUrl', () {
    test('is parseable by Dart URI handling', () {
      // app_links converts incoming links with Uri.tryParse and silently drops
      // anything it cannot parse, so the configured scheme must be valid DNS
      // syntax (notably: no underscore).
      expect(Uri.tryParse(AppConfig.oauthRedirectUrl), isNotNull);
    });

    test('carries the scheme and host the Android manifest registers', () {
      final uri = Uri.parse(AppConfig.oauthRedirectUrl);
      expect(uri.scheme, 'com.tango.kyc.verification');
      expect(uri.host, 'login-callback');
    });
  });

  group('outcomeForRedirectType', () {
    test('routes an explicit recovery redirect to the reset screen', () {
      expect(
        outcomeForRedirectType('passwordRecovery'),
        AuthCallbackOutcome.passwordRecovery,
      );
    });

    test('treats a PKCE sign-in as an ordinary sign-in', () {
      // Under PKCE an OAuth callback yields no redirect type at all.
      expect(outcomeForRedirectType(null), AuthCallbackOutcome.signedIn);
    });

    test('does not mistake other redirect types for recovery', () {
      for (final type in ['signedIn', 'initialSession', 'magiclink']) {
        expect(outcomeForRedirectType(type), AuthCallbackOutcome.signedIn);
      }
    });
  });

  group('FakeAuthService', () {
    test('surfaces the configured outcome so routing can be exercised', () async {
      final fake = FakeAuthService(
        callbackOutcome: AuthCallbackOutcome.passwordRecovery,
      );
      final outcome = await fake.handleAuthCallback(
        Uri.parse('com.tango.kyc.verification://login-callback?code=abc'),
      );
      expect(outcome, AuthCallbackOutcome.passwordRecovery);
    });
  });
}
