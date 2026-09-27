// Offline test doubles for the service interfaces.
//
// These exist only so widget and controller tests can run without a network.
// Production code always uses the Supabase implementations.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';
import 'package:tango_kyc_verification/services/kyc_service.dart';
import 'package:tango_kyc_verification/services/mvola_service.dart';

class FakeAuthService implements AuthService {
  FakeAuthService({
    this.failWith,
    this.profile = const Profile(id: 'fake-user', email: 'user@example.com', role: 'user'),
    this.callbackOutcome = AuthCallbackOutcome.signedIn,
    this.acceptedOtp = '12345678',
    this.otpSendFails = false,
  });

  /// When set, every action throws [AuthException] carrying this message.
  final String? failWith;
  final Profile profile;

  /// Returned by [handleAuthCallback]; lets tests exercise recovery routing.
  final AuthCallbackOutcome callbackOutcome;

  /// The only code [verifyEmailOtp] accepts. Any other value throws, mirroring
  /// Supabase's rejection of an invalid or expired token.
  final String acceptedOtp;

  /// Fails only the OTP send, so a test can reach the entry screen with a code
  /// request that the server refused.
  final bool otpSendFails;

  int signInCalls = 0;
  int signUpCalls = 0;
  int resetCalls = 0;
  int googleCalls = 0;
  int otpSendCalls = 0;
  int otpResendCalls = 0;
  int otpVerifyCalls = 0;
  String? lastEmail;
  String? lastOtpToken;
  EmailOtpPurpose? lastOtpPurpose;

  @override
  Session? get session => null;

  @override
  User? get currentUser => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream<AuthState>.empty();

  void _maybeFail() {
    if (failWith != null) {
      throw AuthException(failWith!);
    }
  }

  @override
  Future<void> signInWithPassword({required String email, required String password}) async {
    signInCalls += 1;
    lastEmail = email;
    _maybeFail();
  }

  @override
  Future<void> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    signUpCalls += 1;
    lastEmail = email;
    _maybeFail();
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    resetCalls += 1;
    lastEmail = email;
    _maybeFail();
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    _maybeFail();
  }

  @override
  Future<void> resendConfirmation(String email) async {
    _maybeFail();
  }

  @override
  Future<void> sendEmailOtp(String email, EmailOtpPurpose purpose) async {
    otpSendCalls += 1;
    lastEmail = email;
    lastOtpPurpose = purpose;
    _maybeFail();
    if (otpSendFails) {
      throw const AuthException('over_email_send_rate_limit');
    }
  }

  @override
  Future<void> resendEmailOtp(String email, EmailOtpPurpose purpose) async {
    otpResendCalls += 1;
    lastEmail = email;
    lastOtpPurpose = purpose;
    _maybeFail();
  }

  @override
  Future<void> verifyEmailOtp({
    required String email,
    required String token,
    required EmailOtpPurpose purpose,
  }) async {
    otpVerifyCalls += 1;
    lastEmail = email;
    lastOtpToken = token;
    lastOtpPurpose = purpose;
    _maybeFail();
    // Supabase reports a wrong code and an expired code identically.
    if (token != acceptedOtp) {
      throw const AuthException('Token has expired or is invalid');
    }
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> signInWithGoogle() async {
    googleCalls += 1;
    _maybeFail();
    return true;
  }

  @override
  Future<AuthCallbackOutcome> handleAuthCallback(Uri uri) async =>
      callbackOutcome;

  @override
  Future<Profile> loadProfile() async => profile;
}

class FakeKycService implements KycService {
  FakeKycService({this.createdTicket, this.failWithCode, this.requests = const []});

  final KycRequest? createdTicket;
  final String? failWithCode;
  final List<KycRequest> requests;

  int createCalls = 0;
  int replyCalls = 0;

  @override
  Future<KycRequest> createRequest({
    required String tangoProfileLink,
    required String registerValue,
  }) async {
    createCalls += 1;
    if (failWithCode != null) {
      throw KycServiceException(failWithCode!, 'boom');
    }
    final ticket = createdTicket;
    if (ticket == null) {
      throw const KycServiceException('INTERNAL', 'no ticket configured');
    }
    return ticket;
  }

  @override
  Future<List<KycRequest>> myRequests() async => requests;

  @override
  Future<KycRequest> requestById(String id) async {
    return requests.firstWhere(
      (r) => r.id == id,
      orElse: () => throw const KycServiceException('TICKET_NOT_FOUND', 'not found'),
    );
  }

  @override
  Future<List<TicketMessage>> messages(String ticketId) async => const [];

  @override
  Future<void> reply(String ticketId, String body) async {
    replyCalls += 1;
  }
}

/// In-memory MVola service. Mirrors the real backend rules that matter to the
/// controller: one active payment per ticket, an approved payment is final, and
/// a rejected payment lets the user start again.
class FakeMvolaService implements MvolaService {
  FakeMvolaService({
    this.failWithCode,
    this.failSubmitWithCode,
    MvolaConfig? config,
    List<MvolaPayment>? payments,
  })  : configValue = config ?? _defaultConfig,
        _payments = List<MvolaPayment>.from(payments ?? const []);

  static const _defaultConfig = MvolaConfig(
    recipientNumber: '0346715622',
    amount: 20000,
    currency: 'MGA',
    ussdCode: '#111*1*0346715622*20000*2#',
    instructions: 'Open your MVola app and confirm the transfer.',
  );

  final String? failWithCode;

  /// Fails only the submit call, so a test can reach `submit` with a real
  /// payment already created.
  final String? failSubmitWithCode;
  final MvolaConfig configValue;
  final List<MvolaPayment> _payments;

  int configCalls = 0;
  int startCalls = 0;
  int submitCalls = 0;

  void _maybeFail() {
    if (failWithCode != null) {
      throw KycServiceException(failWithCode!, 'boom');
    }
  }

  @override
  Future<MvolaConfig> config() async {
    configCalls += 1;
    _maybeFail();
    return configValue;
  }

  @override
  Future<MvolaPayment> start(String ticketId) async {
    startCalls += 1;
    _maybeFail();
    for (final payment in _payments) {
      if (payment.ticketId == ticketId && payment.status != MvolaStatus.rejected) {
        return payment;
      }
    }
    final created = MvolaPayment(
      id: 'pay-${_payments.length + 1}',
      ticketId: ticketId,
      amount: configValue.amount,
      currency: configValue.currency,
      recipientNumber: configValue.recipientNumber,
      ussdCode: configValue.ussdCode,
      status: MvolaStatus.pending,
      createdAt: DateTime(2026, 9, 25, 10),
    );
    _payments.insert(0, created);
    return created;
  }

  @override
  Future<MvolaPayment> submit({
    required String paymentId,
    required String transactionReference,
    String? payerNumber,
  }) async {
    submitCalls += 1;
    if (failSubmitWithCode != null) {
      throw KycServiceException(failSubmitWithCode!, 'boom');
    }
    _maybeFail();
    // Mirror `mvola_submit_payment`: an empty reference never reaches the DB.
    if (transactionReference.trim().isEmpty) {
      throw const KycServiceException('MVOLA_REFERENCE_REQUIRED', 'reference required');
    }
    final index = _payments.indexWhere((p) => p.id == paymentId);
    if (index < 0) throw const KycServiceException('PAYMENT_NOT_FOUND', 'not found');
    final current = _payments[index];
    final updated = MvolaPayment(
      id: current.id,
      ticketId: current.ticketId,
      amount: current.amount,
      currency: current.currency,
      recipientNumber: current.recipientNumber,
      ussdCode: current.ussdCode,
      status: current.status,
      createdAt: current.createdAt,
      transactionReference: transactionReference,
      payerNumber: payerNumber,
      submittedAt: DateTime(2026, 9, 25, 11),
    );
    _payments[index] = updated;
    return updated;
  }

  @override
  Future<List<MvolaPayment>> mine() async {
    _maybeFail();
    return List.unmodifiable(_payments);
  }
}

/// In-memory admin MVola service.
class FakeAdminMvolaService implements AdminMvolaService {
  FakeAdminMvolaService({this.failWithCode, List<MvolaPayment>? payments})
      : _payments = List<MvolaPayment>.from(payments ?? const []);

  final String? failWithCode;
  final List<MvolaPayment> _payments;

  int listCalls = 0;
  int decideCalls = 0;
  String? lastReason;

  @override
  Future<List<MvolaPayment>> list() async {
    listCalls += 1;
    if (failWithCode != null) throw KycServiceException(failWithCode!, 'boom');
    return List.unmodifiable(_payments);
  }

  @override
  Future<MvolaPayment> decide({
    required String paymentId,
    required MvolaStatus decision,
    String? reason,
  }) async {
    decideCalls += 1;
    lastReason = reason;
    if (failWithCode != null) throw KycServiceException(failWithCode!, 'boom');
    final index = _payments.indexWhere((p) => p.id == paymentId);
    if (index < 0) throw const KycServiceException('PAYMENT_NOT_FOUND', 'not found');
    final current = _payments[index];
    final updated = MvolaPayment(
      id: current.id,
      ticketId: current.ticketId,
      amount: current.amount,
      currency: current.currency,
      recipientNumber: current.recipientNumber,
      ussdCode: current.ussdCode,
      status: decision,
      createdAt: current.createdAt,
      transactionReference: current.transactionReference,
      payerNumber: current.payerNumber,
      rejectionReason: reason,
      submittedAt: current.submittedAt,
      reviewedAt: DateTime(2026, 9, 25, 12),
    );
    _payments[index] = updated;
    return updated;
  }
}
