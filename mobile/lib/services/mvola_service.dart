/// MVola payment data access.
///
/// Reads go through PostgREST constrained by Row Level Security, so a user only
/// ever receives their own payments. Every write goes through the
/// `mvola-payments` Edge Function, which derives the actor from the access token
/// and delegates to SQL functions that decide ownership, amount and status
/// server side.
///
/// The client never sends a price or a status: `amount`, `recipient_number` and
/// `ussd_code` are produced by the backend from its own configuration.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'kyc_service.dart';

abstract class MvolaService {
  /// Payment instructions, read from server configuration.
  Future<MvolaConfig> config();

  /// Opens, or returns, the active payment for one of the caller's tickets.
  Future<MvolaPayment> start(String ticketId);

  /// Confirms payment and supplies the transaction reference.
  Future<MvolaPayment> submit({
    required String paymentId,
    required String transactionReference,
    String? payerNumber,
  });

  Future<List<MvolaPayment>> mine();
}

abstract class AdminMvolaService {
  Future<List<MvolaPayment>> list();

  Future<MvolaPayment> decide({
    required String paymentId,
    required MvolaStatus decision,
    String? reason,
  });
}

class SupabaseMvolaService implements MvolaService {
  SupabaseMvolaService(this._client);

  final SupabaseClient _client;

  @override
  Future<MvolaConfig> config() => _invoke(
        'config',
        const {},
        (payload) {
          final raw = payload['config'];
          if (raw is! Map<String, dynamic>) {
            throw const KycServiceException('MVOLA_NOT_CONFIGURED', 'Payment is not available.');
          }
          return MvolaConfig.fromMap(raw);
        },
      );

  @override
  Future<MvolaPayment> start(String ticketId) => _invoke(
        'start',
        {'ticket_id': ticketId},
        _parsePayment,
      );

  @override
  Future<MvolaPayment> submit({
    required String paymentId,
    required String transactionReference,
    String? payerNumber,
  }) =>
      _invoke(
        'submit',
        {
          'payment_id': paymentId,
          'transaction_reference': transactionReference,
          if (payerNumber != null && payerNumber.isNotEmpty) 'payer_number': payerNumber,
        },
        _parsePayment,
      );

  @override
  Future<List<MvolaPayment>> mine() => _invoke(
        'mine',
        const {},
        (payload) => (payload['payments'] as List? ?? const [])
            .map((row) => MvolaPayment.fromMap(row as Map<String, dynamic>))
            .toList(),
      );

  Future<T> _invoke<T>(
    String action,
    Map<String, dynamic> extra,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final payload = await invokeFunction(_client, 'mvola-payments', {
      'action': action,
      ...extra,
    });
    return parse(payload);
  }
}

class SupabaseAdminMvolaService implements AdminMvolaService {
  SupabaseAdminMvolaService(this._client);

  final SupabaseClient _client;

  @override
  Future<List<MvolaPayment>> list() => _invoke(
        'mvola_list',
        const {},
        (payload) => (payload['payments'] as List? ?? const [])
            .map((row) => MvolaPayment.fromMap(row as Map<String, dynamic>))
            .toList(),
      );

  @override
  Future<MvolaPayment> decide({
    required String paymentId,
    required MvolaStatus decision,
    String? reason,
  }) =>
      _invoke(
        'mvola_decision',
        {
          'payment_id': paymentId,
          'decision': decision == MvolaStatus.approved ? 'approved' : 'rejected',
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        },
        _parsePayment,
      );

  Future<T> _invoke<T>(
    String action,
    Map<String, dynamic> extra,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final payload = await invokeFunction(_client, 'admin-actions', {
      'action': action,
      ...extra,
    });
    return parse(payload);
  }
}

MvolaPayment _parsePayment(Map<String, dynamic> payload) {
  final raw = payload['payment'];
  if (raw is! Map<String, dynamic>) {
    throw const KycServiceException('INTERNAL', 'Something went wrong. Please try again.');
  }
  return MvolaPayment.fromMap(raw);
}
