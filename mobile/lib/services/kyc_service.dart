/// Data access contracts and their Supabase implementations.
///
/// Reads go through PostgREST constrained by Row Level Security, so a user only
/// ever receives their own rows. Every write goes through an Edge Function which
/// re-validates input and decides ownership, status and role server side.
library;

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';

/// Raised when the backend declines a request, carrying the stable error code.
class KycServiceException implements Exception {
  const KycServiceException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

abstract class KycService {
  Future<KycRequest> createRequest({
    required String tangoProfileLink,
    required String registerValue,
  });

  Future<List<KycRequest>> myRequests();
  Future<KycRequest> requestById(String id);
  Future<List<TicketMessage>> messages(String ticketId);
  Future<void> reply(String ticketId, String body);
}

abstract class AdminService {
  Future<AdminStats> stats();
  Future<({List<KycRequest> tickets, List<UnmatchedReply> unmatched})> list();
  Future<List<TicketMessage>> messages(String ticketId);
  Future<void> setStatus(String ticketId, KycStatus status);
  Future<void> postMessage(String ticketId, String body);
  Future<void> resolveUnmatched(String unmatchedId, String ticketId);
}

class SupabaseKycService implements KycService {
  SupabaseKycService(this._client);

  final SupabaseClient _client;

  @override
  Future<KycRequest> createRequest({
    required String tangoProfileLink,
    required String registerValue,
  }) async {
    final payload = await invokeFunction(
      _client,
      'create-kyc-request',
      {
        'tango_profile_link': tangoProfileLink,
        'register_value': registerValue,
      },
    );

    final ticket = payload['ticket'] as Map<String, dynamic>?;
    if (ticket == null) {
      throw const KycServiceException('INTERNAL', 'Something went wrong. Please try again.');
    }
    return KycRequest.fromMap(ticket);
  }

  @override
  Future<List<KycRequest>> myRequests() async {
    final rows = await _client
        .from('kyc_requests')
        .select(
          'id, ticket_code, tango_profile_link, register_type, register_value, '
          'status, created_at, updated_at, last_reply_at',
        )
        .order('created_at', ascending: false);
    return rows.map((row) => KycRequest.fromMap(row)).toList();
  }

  @override
  Future<KycRequest> requestById(String id) async {
    final row = await _client
        .from('kyc_requests')
        .select(
          'id, ticket_code, tango_profile_link, register_type, register_value, '
          'status, created_at, updated_at, last_reply_at',
        )
        .eq('id', id)
        .maybeSingle();

    // A row belonging to another user is invisible under RLS, so a null result
    // means either it does not exist or it is not ours.
    if (row == null) {
      throw const KycServiceException('TICKET_NOT_FOUND', 'Request not found.');
    }
    return KycRequest.fromMap(row);
  }

  @override
  Future<List<TicketMessage>> messages(String ticketId) async {
    final rows = await _client
        .from('messages')
        .select('id, ticket_id, sender_type, body, created_at')
        .eq('ticket_id', ticketId)
        .order('created_at', ascending: true);
    return rows.map((row) => TicketMessage.fromMap(row)).toList();
  }

  @override
  Future<void> reply(String ticketId, String body) async {
    await _client.rpc('user_post_message', params: {
      'p_ticket_id': ticketId,
      'p_body': body,
    });
  }
}

class SupabaseAdminService implements AdminService {
  SupabaseAdminService(this._client);

  final SupabaseClient _client;

  @override
  Future<AdminStats> stats() => _invoke(
        'stats',
        const {},
        (payload) => AdminStats.fromMap(payload['stats'] as Map<String, dynamic>? ?? const {}),
      );

  @override
  Future<({List<KycRequest> tickets, List<UnmatchedReply> unmatched})> list() => _invoke(
        'list',
        const {},
        (payload) => (
          tickets: (payload['tickets'] as List? ?? const [])
              .map((row) => KycRequest.fromMap(row as Map<String, dynamic>))
              .toList(),
          unmatched: (payload['unmatched'] as List? ?? const [])
              .map((row) => UnmatchedReply.fromMap(row as Map<String, dynamic>))
              .toList(),
        ),
      );

  @override
  Future<List<TicketMessage>> messages(String ticketId) => _invoke(
        'messages',
        {'ticket_id': ticketId},
        (payload) => (payload['messages'] as List? ?? const [])
            .map((row) => TicketMessage.fromMap(row as Map<String, dynamic>))
            .toList(),
      );

  @override
  Future<void> setStatus(String ticketId, KycStatus status) => _invoke<void>(
        'set_status',
        {'ticket_id': ticketId, 'status': status.wireValue},
        (_) {},
      );

  @override
  Future<void> postMessage(String ticketId, String body) => _invoke<void>(
        'post_message',
        {'ticket_id': ticketId, 'body': body},
        (_) {},
      );

  @override
  Future<void> resolveUnmatched(String unmatchedId, String ticketId) => _invoke<void>(
        'resolve_unmatched',
        {'unmatched_id': unmatchedId, 'ticket_id': ticketId},
        (_) {},
      );

  Future<T> _invoke<T>(
    String action,
    Map<String, dynamic> extra,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final payload = await invokeFunction(_client, 'admin-actions', {'action': action, ...extra});
    return parse(payload);
  }
}

/// Invokes an Edge Function and unwraps its JSON body.
///
/// Shared by the KYC and MVola services so the error mapping stays in one place.
/// The Supabase client throws [FunctionException] on a non-2xx response before
/// the caller ever sees the body, so the status and payload have to be read off
/// the exception. See [kycExceptionFor] for the mapping.
Future<Map<String, dynamic>> invokeFunction(
  SupabaseClient client,
  String name,
  Map<String, dynamic> body,
) async {
  try {
    final response = await client.functions.invoke(name, body: body);
    return asJsonMap(response.data);
  } on FunctionException catch (error) {
    throw kycExceptionFor(error);
  }
}

/// Maps a failed Edge Function call to a [KycServiceException].
///
/// The functions answer with `{ error, message }` where `error` is a stable code
/// from `_shared/http.ts`. Anything unexpected degrades to a generic code so the
/// UI never renders an unmapped server string.
KycServiceException kycExceptionFor(Object error) {
  if (error is FunctionException) {
    final payload = asJsonMap(error.details);
    final code = payload['error'];
    if (code is String && code.isNotEmpty) {
      final message = payload['message'];
      return KycServiceException(
        code,
        message is String && message.isNotEmpty
            ? message
            : 'Something went wrong. Please try again.',
      );
    }
  }
  return const KycServiceException('INTERNAL', 'Something went wrong. Please try again.');
}

/// Normalises an Edge Function payload to a map, whether it arrived decoded or
/// as a JSON string.
Map<String, dynamic> asJsonMap(dynamic data) {
  if (data is Map<String, dynamic>) return data;
  if (data is String && data.isNotEmpty) {
    try {
      final parsed = jsonDecode(data);
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {
      // Fall through to the empty map; the caller raises a generic error.
    }
  }
  return const {};
}
