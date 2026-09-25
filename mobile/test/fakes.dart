// Offline test doubles for the service interfaces.
//
// These exist only so widget and controller tests can run without a network.
// Production code always uses the Supabase implementations.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/services/auth_service.dart';
import 'package:tango_kyc_verification/services/kyc_service.dart';

class FakeAuthService implements AuthService {
  FakeAuthService({
    this.failWith,
    this.profile = const Profile(id: 'fake-user', email: 'user@example.com', role: 'user'),
  });

  /// When set, every action throws [AuthException] carrying this message.
  final String? failWith;
  final Profile profile;

  int signInCalls = 0;
  int signUpCalls = 0;
  int resetCalls = 0;
  int googleCalls = 0;
  String? lastEmail;

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
  Future<void> signOut() async {}

  @override
  Future<bool> signInWithGoogle() async {
    googleCalls += 1;
    _maybeFail();
    return true;
  }

  @override
  Future<bool> handleAuthCallback(Uri uri) async => true;

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
