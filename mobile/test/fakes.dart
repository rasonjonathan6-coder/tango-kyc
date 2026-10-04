// Offline test doubles for the service interfaces.
//
// These exist only so widget and controller tests can run without a network.
// Production code always uses the Supabase implementations.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/assistant_service.dart';
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
    this.callbackError,
    this.callbackDelay = Duration.zero,
    this.callbackSession,
    this.resendError,
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

  /// When set, [handleAuthCallback] throws it: an expired, already-consumed or
  /// incompatible PKCE code.
  final Object? callbackError;

  /// Holds [handleAuthCallback] open so a duplicate delivery can overlap it and
  /// prove the exchange is serialised.
  final Duration callbackDelay;

  /// The session a successful callback would establish. Mirrors the library,
  /// where exchanging the code signs the user in before returning.
  final Session? callbackSession;

  /// When set, [resendEmailOtp] throws it (for example the per-hour limit).
  final Object? resendError;

  int signInCalls = 0;
  int signUpCalls = 0;
  int resetCalls = 0;
  int googleCalls = 0;
  int otpSendCalls = 0;
  int otpResendCalls = 0;
  int otpVerifyCalls = 0;
  int callbackCalls = 0;
  Session? _session;
  String? lastEmail;
  String? lastOtpToken;
  EmailOtpPurpose? lastOtpPurpose;
  Uri? lastCallbackUri;

  @override
  Session? get session => _session;

  @override
  User? get currentUser => _session?.user;

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
    if (resendError != null) {
      throw resendError!;
    }
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
  Future<AuthCallbackOutcome> handleAuthCallback(Uri uri) async {
    callbackCalls += 1;
    lastCallbackUri = uri;
    if (callbackDelay > Duration.zero) {
      await Future<void>.delayed(callbackDelay);
    }
    if (callbackError != null) {
      throw callbackError!;
    }
    // A real exchange stores the session before returning.
    _session = callbackSession;
    return callbackOutcome;
  }

  @override
  Future<Profile> loadProfile() async => profile;
}

class FakeKycService implements KycService {
  FakeKycService({
    this.createdTicket,
    this.failWithCode,
    this.requests = const [],
    this.statusHistoryEntries = const [],
    this.notificationItems = const [],
    this.messageItems = const [],
    this.failNotificationsWithCode,
  });

  final KycRequest? createdTicket;
  final String? failWithCode;
  final List<KycRequest> requests;
  final List<StatusHistoryEntry> statusHistoryEntries;
  final List<NotificationItem> notificationItems;

  /// Messages returned by [messages], so a ticket's conversation can be rendered
  /// without a backend.
  final List<TicketMessage> messageItems;

  /// When set, the notification reads fail with this code, so error handling
  /// can be exercised without a network.
  final String? failNotificationsWithCode;

  int createCalls = 0;
  int statusHistoryCalls = 0;
  int notificationsCalls = 0;
  int markReadCalls = 0;
  int markAllReadCalls = 0;
  int markTicketReadCalls = 0;
  String? lastMarkedReadId;
  String? lastMarkedTicketId;

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
  Future<List<TicketMessage>> messages(String ticketId) async =>
      messageItems.where((m) => m.ticketId == ticketId).toList();

  final List<({String ticketId, String body})> replies = [];

  /// When set, a reply fails with this code, so the closed-ticket and network
  /// error paths can be exercised without a backend.
  String? failReplyWithCode;

  @override
  Future<TicketMessage> replyToTicket({
    required String ticketId,
    required String body,
  }) async {
    if (failReplyWithCode != null) {
      throw KycServiceException(failReplyWithCode!, 'boom');
    }
    replies.add((ticketId: ticketId, body: body));
    return TicketMessage(
      id: 'reply-${replies.length}',
      ticketId: ticketId,
      senderType: SenderType.user,
      body: body,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<List<StatusHistoryEntry>> statusHistory(String ticketId) async {
    statusHistoryCalls += 1;
    return statusHistoryEntries;
  }

  @override
  Future<List<NotificationItem>> notifications() async {
    notificationsCalls += 1;
    if (failNotificationsWithCode != null) {
      throw KycServiceException(failNotificationsWithCode!, 'boom');
    }
    return notificationItems;
  }

  @override
  Future<void> markNotificationRead(String notificationId) async {
    markReadCalls += 1;
    lastMarkedReadId = notificationId;
  }

  @override
  Future<void> markAllNotificationsRead() async {
    markAllReadCalls += 1;
  }

  @override
  Future<void> markTicketNotificationsRead(String ticketId) async {
    markTicketReadCalls += 1;
    lastMarkedTicketId = ticketId;
  }

  final List<({String token, String platform})> registeredTokens = [];
  final List<String> unregisteredTokens = [];

  @override
  Future<void> registerDeviceToken({required String token, String platform = 'android'}) async {
    registeredTokens.add((token: token, platform: platform));
  }

  @override
  Future<void> unregisterDeviceToken({required String token}) async {
    unregisteredTokens.add(token);
  }
}

/// In-memory assistant service. Records the conversation it was sent and returns
/// a canned reply, so the chatbot screen and controller can be tested without a
/// network or a real LLM provider.
class FakeAssistantService implements AssistantService {
  FakeAssistantService({this.reply = 'Réponse de test.', this.configured = true, this.failWithCode});

  /// The text the assistant answers with.
  String reply;

  /// Whether the server reports a provider is configured.
  bool configured;

  /// When set, [send] throws with this code, to exercise the error path.
  String? failWithCode;

  int sendCalls = 0;
  List<AssistantMessage> lastConversation = const [];

  @override
  Future<AssistantReply> send(List<AssistantMessage> conversation) async {
    sendCalls += 1;
    lastConversation = List.of(conversation);
    if (failWithCode != null) {
      throw KycServiceException(failWithCode!, 'boom');
    }
    return AssistantReply(text: reply, configured: configured);
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

/// In-memory admin service, mirroring the read/act split of the real one.
class FakeAdminService implements AdminService {
  FakeAdminService({this.requests = const [], this.unmatched = const []});

  final List<KycRequest> requests;
  final List<UnmatchedReply> unmatched;

  int statusCalls = 0;
  int postCalls = 0;
  int paymentCalls = 0;

  @override
  Future<AdminStats> stats() async => AdminStats(
        total: requests.length,
        pending: requests.where((r) => r.status == KycStatus.pending).length,
        inReview: requests.where((r) => r.status == KycStatus.inReview).length,
        replied: requests.where((r) => r.status == KycStatus.replied).length,
        closed: requests.where((r) => r.status == KycStatus.closed).length,
        unmatched: unmatched.length,
      );

  @override
  Future<({List<KycRequest> tickets, List<UnmatchedReply> unmatched})> list() async =>
      (tickets: requests, unmatched: unmatched);

  @override
  Future<List<TicketMessage>> messages(String ticketId) async => const [];

  @override
  Future<void> setStatus(String ticketId, KycStatus status) async => statusCalls += 1;

  @override
  Future<void> postMessage(String ticketId, String body) async => postCalls += 1;

  @override
  Future<void> resolveUnmatched(String unmatchedId, String ticketId) async {}

  @override
  Future<void> requestPayment(String ticketId) async => paymentCalls += 1;
}
