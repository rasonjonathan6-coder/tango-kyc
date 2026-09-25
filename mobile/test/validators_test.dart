// Tests for client-side validation and user-facing error messages.
//
// These mirror the rules enforced in Postgres: the client validates for fast
// feedback, the server remains the authority.
import 'package:flutter_test/flutter_test.dart';
import 'package:tango_kyc_verification/core/validators.dart';
import 'package:tango_kyc_verification/models/models.dart';

void main() {
  group('profile link validation', () {
    test('rejects empty input', () {
      expect(Validators.validateProfileLink(''), isNotNull);
      expect(Validators.validateProfileLink('   '), isNotNull);
      expect(Validators.validateProfileLink(null), isNotNull);
    });

    test('rejects values that are not URLs', () {
      expect(Validators.validateProfileLink('not-a-url'), isNotNull);
      expect(Validators.validateProfileLink('tango.me/profile'), isNotNull);
      expect(Validators.validateProfileLink('javascript:alert(1)'), isNotNull);
    });

    test('accepts http and https URLs', () {
      expect(Validators.validateProfileLink('https://tango.me/user/42'), isNull);
      expect(Validators.validateProfileLink('http://example.com/43'), isNull);
      expect(Validators.validateProfileLink('  https://tango.me/user/44  '), isNull);
    });

    test('rejects an over-long link', () {
      expect(Validators.validateProfileLink('https://tango.me/${'a' * 3000}'), isNotNull);
    });
  });

  group('register value validation', () {
    test('rejects empty input', () {
      expect(Validators.validateRegisterValue(''), isNotNull);
      expect(Validators.validateRegisterValue(null), isNotNull);
    });

    test('detects an email address', () {
      expect(Validators.looksLikeEmail('user@example.com'), isTrue);
      expect(Validators.looksLikeEmail('+261341234567'), isFalse);
    });

    test('accepts a well formed email', () {
      expect(Validators.validateRegisterValue('user@example.com'), isNull);
      expect(Validators.validateRegisterValue('  User@Example.COM  '), isNull);
    });

    test('rejects a malformed email', () {
      expect(Validators.validateRegisterValue('user@'), isNotNull);
      expect(Validators.validateRegisterValue('user@example'), isNotNull);
      expect(Validators.validateRegisterValue('@example.com'), isNotNull);
    });

    test('accepts phone numbers in several notations', () {
      expect(Validators.validateRegisterValue('+261341234567'), isNull);
      expect(Validators.validateRegisterValue('+261 34 12 345 67'), isNull);
      expect(Validators.validateRegisterValue('0341234567'), isNull);
      expect(Validators.validateRegisterValue('(034) 123-4567'), isNull);
    });

    test('rejects a phone number that is too short', () {
      expect(Validators.validateRegisterValue('12345'), isNotNull);
    });
  });

  group('combined form validation', () {
    test('reports both field errors at once', () {
      final result = Validators.validateRequestForm(profileLink: '', registerValue: '');
      expect(result.isValid, isFalse);
      expect(result.profileLinkError, isNotNull);
      expect(result.registerError, isNotNull);
    });

    test('passes when both fields are valid', () {
      final result = Validators.validateRequestForm(
        profileLink: 'https://tango.me/user/1',
        registerValue: '+261341234567',
      );
      expect(result.isValid, isTrue);
    });
  });

  group('email and password validation', () {
    test('email', () {
      expect(Validators.validateEmail(''), isNotNull);
      expect(Validators.validateEmail('nope'), isNotNull);
      expect(Validators.validateEmail('ok@example.com'), isNull);
    });

    test('password length', () {
      expect(Validators.validatePassword(''), isNotNull);
      expect(Validators.validatePassword('short'), isNotNull);
      expect(Validators.validatePassword('longenough1'), isNull);
    });

    test('password confirmation', () {
      expect(Validators.validatePasswordConfirmation('aaaa1111', 'aaaa1111'), isNull);
      expect(Validators.validatePasswordConfirmation('aaaa1111', 'bbbb2222'), isNotNull);
    });
  });

  group('normalisation matches the backend', () {
    test('trims and collapses whitespace', () {
      expect(Validators.normalize('  https://a.b/c   d  '), 'https://a.b/c d');
    });
  });

  group('error messages', () {
    test('maps every documented server error code to friendly copy', () {
      expect(ErrorMessages.from('PROFILE_LINK_INVALID'), contains('https://'));
      expect(ErrorMessages.from('RATE_LIMITED'), contains('wait'));
      expect(ErrorMessages.from('RATE_LIMITED_DAILY'), contains('maximum'));
      expect(ErrorMessages.from('FORBIDDEN'), contains('not allowed'));
      expect(ErrorMessages.from('AUTH_REQUIRED'), contains('sign in'));
    });

    test('maps Supabase auth messages to the required wording', () {
      expect(ErrorMessages.from('User already registered'), 'Email already registered.');
      expect(
        ErrorMessages.from('AuthApiException: Invalid login credentials'),
        'Incorrect password.',
      );
      expect(ErrorMessages.from('Unable to validate email address: invalid format'), 'Invalid email.');
      expect(
        ErrorMessages.from('Password should be at least 6 characters'),
        'Password is too short.',
      );
    });

    test('never leaks internal details', () {
      final message = ErrorMessages.from(
        'PostgrestException(code: 42501, message: FORBIDDEN, details: internal)',
      );
      expect(message, 'You are not allowed to do that.');
      expect(message.toLowerCase(), isNot(contains('postgrest')));
      expect(message, isNot(contains('42501')));
    });

    test('falls back to a generic message for unknown failures', () {
      expect(
        ErrorMessages.from('SomeUnmappedException: stack trace here'),
        'Something went wrong. Please try again.',
      );
    });
  });

  group('model parsing', () {
    test('register type and status parse from wire values', () {
      expect(RegisterType.parse('email'), RegisterType.email);
      expect(RegisterType.parse('phone'), RegisterType.phone);
      expect(RegisterType.parse('nonsense'), isNull);

      expect(KycStatus.parse('pending'), KycStatus.pending);
      expect(KycStatus.parse('in_review'), KycStatus.inReview);
      expect(KycStatus.parse('replied'), KycStatus.replied);
      expect(KycStatus.parse('closed'), KycStatus.closed);
      // An unknown status must never be presented as something it is not.
      expect(KycStatus.parse('bogus'), KycStatus.pending);
    });

    test('status labels match the requested wording', () {
      expect(KycStatus.pending.label, 'Pending');
      expect(KycStatus.replied.label, 'Reply received');
    });

    test('register type labels pick the right field name', () {
      expect(RegisterType.email.label, 'Register email');
      expect(RegisterType.phone.label, 'Register number');
    });

    test('sender type labels are human readable', () {
      expect(SenderType.parse('admin').label, 'Support');
      expect(SenderType.parse('user').label, 'You');
    });

    test('KycRequest parses a full row', () {
      final request = KycRequest.fromMap({
        'id': '11111111-1111-1111-1111-111111111111',
        'ticket_code': 'TNG-KYC-8F42A91C',
        'tango_profile_link': 'https://tango.me/user/7',
        'register_type': 'phone',
        'register_value': '+261341234567',
        'status': 'replied',
        'created_at': '2026-09-25T10:00:00.000Z',
        'updated_at': '2026-09-25T11:00:00.000Z',
        'last_reply_at': '2026-09-25T11:00:00.000Z',
      });

      expect(request.ticketCode, 'TNG-KYC-8F42A91C');
      expect(request.registerType, RegisterType.phone);
      expect(request.status, KycStatus.replied);
      expect(request.lastReplyAt, isNotNull);
    });

    test('Profile greeting uses the first name', () {
      expect(
        const Profile(id: 'x', displayName: 'Jonathan Raso', role: 'user').greetingName,
        'Jonathan',
      );
      expect(
        const Profile(id: 'x', email: 'jonathan@example.com', role: 'user').greetingName,
        'jonathan',
      );
    });

    test('Profile reports admin role from the server value only', () {
      expect(const Profile(id: 'x', role: 'admin').isAdmin, isTrue);
      expect(const Profile(id: 'x', role: 'user').isAdmin, isFalse);
      expect(const Profile(id: 'x', role: 'somethingelse').isAdmin, isFalse);
    });

    test('AdminStats parses the RPC payload', () {
      final stats = AdminStats.fromMap({
        'total': 12,
        'pending': 3,
        'in_review': 2,
        'replied': 5,
        'closed': 2,
        'unmatched': 1,
      });
      expect(stats.total, 12);
      expect(stats.replied, 5);
      expect(stats.unmatched, 1);
    });
  });
}
