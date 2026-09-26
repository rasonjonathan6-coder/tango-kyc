/// Client-side input validation and user-facing error messages.
///
/// These checks exist to give fast, friendly feedback. The same rules are
/// enforced again in Postgres (`create_kyc_request`), which is the only
/// authority: the client is never trusted.
library;

class ValidationResult {
  const ValidationResult({this.profileLinkError, this.registerError});

  final String? profileLinkError;
  final String? registerError;

  bool get isValid => profileLinkError == null && registerError == null;
}

class Validators {
  const Validators._();

  static final RegExp _urlPattern = RegExp(r'^https?://[^\s/]+\.[^\s/]+', caseSensitive: false);
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$');
  static final RegExp _phonePattern = RegExp(r'^\+?[0-9]{7,15}$');

  /// Collapses whitespace the way the backend does before storing a value.
  static String normalize(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Detects whether the value looks like an email or a phone number.
  /// Returns null when neither is recognisable.
  static bool looksLikeEmail(String value) => value.trim().contains('@');

  static String? validateProfileLink(String? value) {
    final link = normalize(value ?? '');
    if (link.isEmpty) return 'Tango Profile Link is required.';
    if (link.length > 2048) return 'This profile link is too long.';
    if (!_urlPattern.hasMatch(link)) {
      return 'Please enter a valid link starting with https://';
    }
    return null;
  }

  static String? validateRegisterValue(String? value) {
    final input = normalize(value ?? '');
    if (input.isEmpty) return 'Please enter your register email or phone number.';

    if (looksLikeEmail(input)) {
      return _emailPattern.hasMatch(input) ? null : 'Please enter a valid email address.';
    }

    // Strip formatting characters the way the backend does.
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 'Please enter a valid email address or phone number.';
    if (!_phonePattern.hasMatch(input.replaceAll(RegExp(r'[^0-9+]'), ''))) {
      return 'Please enter a valid phone number (7 to 15 digits).';
    }
    return null;
  }

  static ValidationResult validateRequestForm({
    required String profileLink,
    required String registerValue,
  }) =>
      ValidationResult(
        profileLinkError: validateProfileLink(profileLink),
        registerError: validateRegisterValue(registerValue),
      );

  static String? validateEmail(String? value) {
    final email = normalize(value ?? '');
    if (email.isEmpty) return 'Please enter your email address.';
    if (!_emailPattern.hasMatch(email)) return 'Please enter a valid email address.';
    return null;
  }

  static String? validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Please enter a password.';
    if (password.length < 8) return 'Password is too short (at least 8 characters).';
    return null;
  }

  static String? validatePasswordConfirmation(String? password, String? confirmation) {
    if ((password ?? '') != (confirmation ?? '')) return 'Passwords do not match.';
    return null;
  }

  /// MVola transaction reference. Mirrors `mvola_submit_payment`: 3-64
  /// characters, no markup and no control characters. The backend re-checks it.
  static String? validateMvolaReference(String? value) {
    final reference = normalize(value ?? '');
    if (reference.isEmpty) return 'Please enter your MVola transaction reference.';
    if (reference.length < 3) return 'This transaction reference is too short.';
    if (reference.length > 64) return 'This transaction reference is too long.';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._/-]*$').hasMatch(reference)) {
      return 'Use letters, digits, spaces and . _ / - only.';
    }
    return null;
  }

  /// The number the transfer was sent from. Optional, but validated when given.
  static String? validateMvolaPayerNumber(String? value) {
    final input = normalize(value ?? '');
    if (input.isEmpty) return null;
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7 || digits.length > 15) {
      return 'Please enter a valid phone number (7 to 15 digits).';
    }
    return null;
  }
}

/// Maps technical failures to clear, non-technical messages.
class ErrorMessages {
  const ErrorMessages._();

  /// Translates an exception or a server error code into user-facing copy.
  /// Internal details are never surfaced.
  static String from(Object error) {
    final raw = error.toString();

    // Server error codes returned by the Edge Functions.
    const codes = <String, String>{
      'PROFILE_LINK_REQUIRED': 'Tango Profile Link is required.',
      'PROFILE_LINK_INVALID': 'Please enter a valid link starting with https://',
      'PROFILE_LINK_TOO_LONG': 'This profile link is too long.',
      'REGISTER_REQUIRED': 'Please enter your register email or phone number.',
      'REGISTER_EMAIL_INVALID': 'Please enter a valid email address.',
      'REGISTER_PHONE_INVALID': 'Please enter a valid phone number.',
      'RATE_LIMITED': 'You already sent a request recently. Please wait a few minutes.',
      'RATE_LIMITED_DAILY': 'You have reached the maximum number of requests for today.',
      'FORBIDDEN': 'You are not allowed to do that.',
      'TICKET_NOT_FOUND': 'Request not found.',
      'AUTH_REQUIRED': 'Please sign in and try again.',
      'INVALID_TOKEN': 'Your session has expired. Please sign in again.',
      'MESSAGE_REQUIRED': 'Please write a message.',
      'EMAIL_DELIVERY_FAILED':
          'Your request was saved, but the confirmation email could not be sent. Support has been notified.',
      'SERVICE_NOT_CONFIGURED': 'This service is temporarily unavailable. Please try again later.',
      // MVola
      'PAYMENT_NOT_FOUND': 'Payment not found.',
      'PAYMENT_ALREADY_REVIEWED': 'This payment has already been reviewed.',
      'MVOLA_NOT_CONFIGURED': 'Mobile Money payment is not available right now.',
      'MVOLA_DISABLED': 'Mobile Money payment is not available right now.',
      'MVOLA_UNAVAILABLE': 'Mobile Money payment is not available right now.',
      'MVOLA_REFERENCE_REQUIRED': 'Please enter your MVola transaction reference.',
      'MVOLA_REFERENCE_INVALID': 'This transaction reference is not valid.',
      'MVOLA_PAYER_INVALID': 'Please enter a valid phone number.',
      'MVOLA_DECISION_INVALID': 'Invalid decision.',
      'MVOLA_REASON_REQUIRED': 'Please explain why the payment is refused.',
      'MVOLA_REASON_INVALID': 'This explanation is too long.',
      'INTERNAL': 'Something went wrong. Please try again.',
    };

    // Longest code first: `RATE_LIMITED_DAILY` must not be shadowed by its
    // `RATE_LIMITED` prefix.
    final ordered = codes.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in ordered) {
      if (raw.contains(entry.key)) return entry.value;
    }

    // Supabase Auth messages, mapped to the wording the brief requires.
    final lower = raw.toLowerCase();
    if (lower.contains('already registered') || lower.contains('already been registered')) {
      return 'Email already registered.';
    }
    if (lower.contains('user already exists')) return 'Email already registered.';
    if (lower.contains('invalid login credentials') || lower.contains('incorrect password')) {
      return 'Incorrect password.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Please confirm your email address before signing in.';
    }
    if (lower.contains('invalid email') || lower.contains('unable to validate email')) {
      return 'Invalid email.';
    }
    if (lower.contains('password should be at least')) return 'Password is too short.';
    if (lower.contains('rate limit') || lower.contains('too many requests')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (lower.contains('network') || lower.contains('socket') || lower.contains('connection')) {
      return 'No internet connection. Please check your network and try again.';
    }
    if (lower.contains('timeout')) return 'The request took too long. Please try again.';

    return 'Something went wrong. Please try again.';
  }
}
