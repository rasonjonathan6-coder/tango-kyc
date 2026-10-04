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

    test('accepts ten-digit numbers with every allowed prefix', () {
      for (final prefix in ['032', '033', '034', '037', '038']) {
        expect(Validators.validateRegisterValue('${prefix}1234567'), isNull,
            reason: '$prefix must be accepted');
      }
    });

    test('accepts the number even when formatted with spaces or dashes', () {
      expect(Validators.validateRegisterValue('034 67 54 333'), isNull);
      expect(Validators.validateRegisterValue('034-675-4333'), isNull);
      expect(Validators.validateRegisterValue('(034) 675-4333'), isNull);
    });

    test('rejects a number that is not ten digits', () {
      expect(Validators.validateRegisterValue('034675433'), isNotNull); // nine
      expect(Validators.validateRegisterValue('03467543330'), isNotNull); // eleven
      expect(Validators.validateRegisterValue('12345'), isNotNull);
    });

    test('rejects a number with a disallowed prefix', () {
      expect(Validators.validateRegisterValue('0311234567'), isNotNull);
      expect(Validators.validateRegisterValue('0351234567'), isNotNull);
      expect(Validators.validateRegisterValue('0361234567'), isNotNull);
      expect(Validators.validateRegisterValue('0391234567'), isNotNull);
    });

    test('shows the "veuillez vérifier votre numéro" message', () {
      expect(Validators.validateRegisterValue('0311234567'),
          'Veuillez vérifier votre numéro.');
      expect(Validators.validateRegisterValue('12345'),
          'Veuillez vérifier votre numéro.');
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
        registerValue: '0341234567',
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
      expect(ErrorMessages.from('RATE_LIMITED'), contains('Patientez'));
      expect(ErrorMessages.from('RATE_LIMITED_DAILY'), contains('maximum'));
      expect(ErrorMessages.from('FORBIDDEN'), contains('autorisé'));
      expect(ErrorMessages.from('AUTH_REQUIRED'), contains('Connectez-vous'));
    });

    test('maps Supabase auth messages to the required wording', () {
      expect(ErrorMessages.from('User already registered'), 'Email déjà enregistré.');
      expect(
        ErrorMessages.from('AuthApiException: Invalid login credentials'),
        'Mot de passe incorrect.',
      );
      expect(
        ErrorMessages.from('Unable to validate email address: invalid format'),
        'Email invalide.',
      );
      expect(
        ErrorMessages.from('Password should be at least 6 characters'),
        'Mot de passe trop court.',
      );
    });

    test('never leaks internal details', () {
      final message = ErrorMessages.from(
        'PostgrestException(code: 42501, message: FORBIDDEN, details: internal)',
      );
      expect(message, 'Vous n’êtes pas autorisé à effectuer cette action.');
      expect(message.toLowerCase(), isNot(contains('postgrest')));
      expect(message, isNot(contains('42501')));
    });

    test('falls back to a generic message for unknown failures', () {
      expect(
        ErrorMessages.from('SomeUnmappedException: stack trace here'),
        'Une erreur est survenue. Réessayez.',
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
      expect(KycStatus.pending.label, 'En attente');
      expect(KycStatus.inReview.label, 'En cours');
      expect(KycStatus.replied.label, 'Répondu');
      expect(KycStatus.closed.label, 'Fermé');
    });

    test('register type labels pick the right field name', () {
      expect(RegisterType.email.label, 'Email enregistré');
      expect(RegisterType.phone.label, 'Numéro enregistré');
    });

    test('sender type labels are human readable', () {
      expect(SenderType.parse('admin').label, 'Support');
      expect(SenderType.parse('user').label, 'Vous');
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

    test('KycRequest derives the submission state from the create response', () {
      final pending = KycRequest.fromMap({
        'id': '1',
        'ticket_code': 'TNG-1',
        'tango_profile_link': 'https://tango.me/u/1',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
        'payment_required': true,
        'payment_status': 'awaiting_submission',
        'is_submitted': false,
      });
      expect(pending.paymentRequired, isTrue);
      expect(pending.isSubmitted, isFalse);
      expect(pending.paymentStatus, 'awaiting_submission');

      final approved = KycRequest.fromMap({
        'id': '2',
        'ticket_code': 'TNG-2',
        'tango_profile_link': 'https://tango.me/u/2',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
        'payment_required': true,
        'payment_status': 'approved',
        'is_submitted': true,
      });
      expect(approved.paymentRequired, isTrue);
      expect(approved.isSubmitted, isTrue);
      expect(approved.paymentStatus, 'approved');
    });

    test('KycRequest derives the submission state from embedded payment rows', () {
      Map<String, dynamic> row(List<Map<String, dynamic>> payments) => {
        'id': '1',
        'ticket_code': 'TNG-1',
        'tango_profile_link': 'https://tango.me/u/1',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
        'payment_required': true,
        'mvola_payments': payments,
      };

      final noPayment = KycRequest.fromMap(row(const []));
      expect(noPayment.isSubmitted, isFalse);
      expect(noPayment.paymentStatus, 'awaiting_submission');

      final pendingPayment = KycRequest.fromMap(
        row([
          {'status': 'pending'},
        ]),
      );
      expect(pendingPayment.isSubmitted, isFalse);
      expect(pendingPayment.paymentStatus, 'pending');

      final approvedPayment = KycRequest.fromMap(
        row([
          {'status': 'rejected'},
          {'status': 'approved'},
        ]),
      );
      expect(approvedPayment.isSubmitted, isTrue);
      expect(approvedPayment.paymentStatus, 'approved');
    });

    test('KycRequest trusts the server state over an absent payment embed', () {
      // Regression: a payment approved server side must show as submitted even
      // when the read path returns no (or a stale) `mvola_payments` embed. The
      // embed used to override the server-derived `is_submitted`, which hid the
      // reply composer for a request the server would in fact accept.
      final approved = KycRequest.fromMap({
        'id': '1',
        'ticket_code': 'TNG-1',
        'tango_profile_link': 'https://tango.me/u/1',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
        'payment_required': true,
        'payment_status': 'approved',
        'is_submitted': true,
      });
      expect(approved.paymentRequired, isTrue);
      expect(approved.isSubmitted, isTrue);
      expect(approved.paymentStatus, 'approved');

      // A stale embed still cannot un-submit a request the server reports as
      // submitted.
      final staleEmbed = KycRequest.fromMap({
        'id': '1',
        'ticket_code': 'TNG-1',
        'tango_profile_link': 'https://tango.me/u/1',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
        'payment_required': true,
        'payment_status': 'approved',
        'is_submitted': true,
        'mvola_payments': const [],
      });
      expect(staleEmbed.isSubmitted, isTrue);
      expect(staleEmbed.paymentStatus, 'approved');

      // The inverse is preserved: a not-yet-approved payment stays unsubmitted.
      final pending = KycRequest.fromMap({
        'id': '2',
        'ticket_code': 'TNG-2',
        'tango_profile_link': 'https://tango.me/u/2',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
        'payment_required': true,
        'payment_status': 'awaiting_submission',
        'is_submitted': false,
        'mvola_payments': const [],
      });
      expect(pending.isSubmitted, isFalse);
      expect(pending.paymentStatus, 'awaiting_submission');
    });

    test('KycRequest defaults to submitted when the server sends no state', () {
      final request = KycRequest.fromMap({
        'id': '1',
        'ticket_code': 'TNG-1',
        'tango_profile_link': 'https://tango.me/u/1',
        'register_type': 'email',
        'register_value': 'a@b.com',
        'status': 'pending',
        'created_at': '2026-09-25T10:00:00.000Z',
      });
      expect(request.isSubmitted, isTrue);
      expect(request.paymentRequired, isFalse);
    });

    test('Profile greeting uses the first name', () {
      expect(
        const Profile(id: 'x', displayName: 'Jonathan Raso', role: 'user').greetingName,
        'Jonathan',
      );
      expect(
        const Profile(id: 'x', email: 'amina@example.com', role: 'user').greetingName,
        'amina',
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
