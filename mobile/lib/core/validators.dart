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
    if (link.isEmpty) return 'Le lien du profil Tango est obligatoire.';
    if (link.length > 2048) return 'Ce lien de profil est trop long.';
    if (!_urlPattern.hasMatch(link)) {
      return 'Saisissez un lien valide commençant par https://';
    }
    return null;
  }

  static String? validateRegisterValue(String? value) {
    final input = normalize(value ?? '');
    if (input.isEmpty) return 'Saisissez l’adresse email ou le numéro enregistré.';

    if (looksLikeEmail(input)) {
      return _emailPattern.hasMatch(input) ? null : 'Saisissez une adresse email valide.';
    }

    // Strip formatting characters the way the backend does.
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 'Saisissez une adresse email ou un numéro valide.';
    if (!_phonePattern.hasMatch(input.replaceAll(RegExp(r'[^0-9+]'), ''))) {
      return 'Saisissez un numéro de téléphone valide (7 à 15 chiffres).';
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
    if (email.isEmpty) return 'Saisissez votre adresse email.';
    if (!_emailPattern.hasMatch(email)) return 'Saisissez une adresse email valide.';
    return null;
  }

  static String? validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Saisissez un mot de passe.';
    if (password.length < 8) return 'Mot de passe trop court (8 caractères minimum).';
    return null;
  }

  static String? validatePasswordConfirmation(String? password, String? confirmation) {
    if ((password ?? '') != (confirmation ?? '')) return 'Les mots de passe ne correspondent pas.';
    return null;
  }

  /// MVola transaction reference. Mirrors `mvola_submit_payment`: 3-64
  /// characters, no markup and no control characters. The backend re-checks it.
  static String? validateMvolaReference(String? value) {
    final reference = normalize(value ?? '');
    if (reference.isEmpty) return 'Saisissez la référence de la transaction MVola.';
    if (reference.length < 3) return 'Cette référence de transaction est trop courte.';
    if (reference.length > 64) return 'Cette référence de transaction est trop longue.';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._/-]*$').hasMatch(reference)) {
      return 'Utilisez uniquement des lettres, des chiffres et les espaces . _ / -';
    }
    return null;
  }

  /// The number the transfer was sent from. Optional, but validated when given.
  static String? validateMvolaPayerNumber(String? value) {
    final input = normalize(value ?? '');
    if (input.isEmpty) return null;
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7 || digits.length > 15) {
      return 'Saisissez un numéro de téléphone valide (7 à 15 chiffres).';
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
      'PROFILE_LINK_REQUIRED': 'Le lien du profil Tango est obligatoire.',
      'PROFILE_LINK_INVALID': 'Saisissez un lien valide commençant par https://',
      'PROFILE_LINK_TOO_LONG': 'Ce lien de profil est trop long.',
      'REGISTER_REQUIRED': 'Saisissez l’adresse email ou le numéro enregistré.',
      'REGISTER_EMAIL_INVALID': 'Saisissez une adresse email valide.',
      'REGISTER_PHONE_INVALID': 'Saisissez un numéro de téléphone valide.',
      'RATE_LIMITED': 'Vous avez déjà envoyé une demande récemment. Patientez quelques minutes.',
      'RATE_LIMITED_DAILY': 'Vous avez atteint le nombre maximum de demandes pour aujourd’hui.',
      'FORBIDDEN': 'Vous n’êtes pas autorisé à effectuer cette action.',
      'TICKET_NOT_FOUND': 'Demande introuvable.',
      'TICKET_CLOSED': 'Cette demande est fermée : vous ne pouvez plus y répondre.',
      'PAYMENT_NOT_CONFIRMED':
          'Votre paiement MVola doit être confirmé avant de pouvoir répondre à cette demande.',
      'AUTH_REQUIRED': 'Connectez-vous puis réessayez.',
      'INVALID_TOKEN': 'Votre session a expiré. Reconnectez-vous.',
      'MESSAGE_REQUIRED': 'Écrivez un message.',
      'EMAIL_DELIVERY_FAILED':
          'Votre demande a été enregistrée, mais l’email de confirmation n’a pas pu être envoyé. Le support a été prévenu.',
      'SERVICE_NOT_CONFIGURED': 'Ce service est momentanément indisponible. Réessayez plus tard.',
      // MVola
      'PAYMENT_NOT_FOUND': 'Paiement introuvable.',
      'PAYMENT_ALREADY_REVIEWED': 'Ce paiement a déjà été examiné.',
      'MVOLA_NOT_CONFIGURED': 'Le paiement Mobile Money n’est pas disponible pour le moment.',
      'MVOLA_DISABLED': 'Le paiement Mobile Money n’est pas disponible pour le moment.',
      'MVOLA_UNAVAILABLE': 'Le paiement Mobile Money n’est pas disponible pour le moment.',
      'MVOLA_REFERENCE_REQUIRED': 'Saisissez la référence de la transaction MVola.',
      'MVOLA_REFERENCE_INVALID': 'Cette référence de transaction n’est pas valide.',
      'MVOLA_PAYER_INVALID': 'Saisissez un numéro de téléphone valide.',
      'MVOLA_DECISION_INVALID': 'Décision invalide.',
      'MVOLA_REASON_REQUIRED': 'Expliquez pourquoi le paiement est refusé.',
      'MVOLA_REASON_INVALID': 'Cette explication est trop longue.',
      'INTERNAL': 'Une erreur est survenue. Réessayez.',
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
      return 'Email déjà enregistré.';
    }
    if (lower.contains('user already exists')) return 'Email déjà enregistré.';
    if (lower.contains('invalid login credentials') || lower.contains('incorrect password')) {
      return 'Mot de passe incorrect.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Confirmez votre adresse email avant de vous connecter.';
    }
      // OTP verification failures. Supabase reports both an expired code and a
      // wrong code as "token has expired or is invalid", and it must not disclose
      // which, so the copy stays deliberately ambiguous.
      if (lower.contains('token has expired') ||
          lower.contains('otp_expired') ||
          lower.contains('invalid token') ||
          lower.contains('token is invalid')) {
        return 'Ce code est incorrect ou a expiré. Demandez-en un nouveau.';
      }
    if (lower.contains('invalid email') || lower.contains('unable to validate email')) {
      return 'Email invalide.';
    }
    if (lower.contains('password should be at least')) return 'Mot de passe trop court.';
    if (lower.contains('rate limit') || lower.contains('too many requests')) {
      return 'Trop de tentatives. Patientez un instant puis réessayez.';
    }
    if (lower.contains('network') || lower.contains('socket') || lower.contains('connection')) {
      return 'Pas de connexion internet. Vérifiez votre réseau puis réessayez.';
    }
    if (lower.contains('timeout')) return 'La requête a pris trop de temps. Réessayez.';

    return 'Une erreur est survenue. Réessayez.';
  }
}
