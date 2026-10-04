/// Data access contracts and their Supabase implementations.
///
/// Reads go through PostgREST constrained by Row Level Security, so a user only
/// ever receives their own rows. Every write goes through an Edge Function which
/// re-validates input and decides ownership, status and role server side.
library;

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/net_log.dart';
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
  Future<List<StatusHistoryEntry>> statusHistory(String ticketId);

  /// Posts the caller's own reply on one of their tickets.
  ///
  /// Goes through the `reply-to-ticket` Edge Function, which re-checks ownership
  /// and refuses a closed ticket server side. A closed ticket therefore stays
  /// read-only even if the UI is bypassed.
  Future<TicketMessage> replyToTicket({required String ticketId, required String body});

  /// The caller's own persisted notifications, newest first.
  Future<List<NotificationItem>> notifications();

  /// Marks one of the caller's own notifications as read.
  Future<void> markNotificationRead(String notificationId);
  Future<void> markAllNotificationsRead();

  /// Marks every unread notification about one ticket read, so opening a ticket
  /// from a push clears its badge. RLS makes this a no-op for a ticket the
  /// caller does not own.
  Future<void> markTicketNotificationsRead(String ticketId);

  /// Registers this device's FCM token for the signed-in user. The row's
  /// `user_id` is the caller's own; RLS rejects any other value, and the server
  /// decides the recipient of a push from the ticket owner, never from here.
  Future<void> registerDeviceToken({required String token, String platform = 'android'});

  /// Removes this device's token, so a signed-out device stops receiving pushes.
  Future<void> unregisterDeviceToken({required String token});
}

abstract class AdminService {
  Future<AdminStats> stats();
  Future<({List<KycRequest> tickets, List<UnmatchedReply> unmatched})> list();
  Future<List<TicketMessage>> messages(String ticketId);
  Future<void> setStatus(String ticketId, KycStatus status);
  Future<void> postMessage(String ticketId, String body);
  Future<void> resolveUnmatched(String unmatchedId, String ticketId);

  /// Flags the ticket as requiring a payment (the explicit, secure signal).
  Future<void> requestPayment(String ticketId);
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
          'status, created_at, updated_at, last_reply_at, payment_required, payment_requested_at, '
          'mvola_payments(status)',
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
          'status, created_at, updated_at, last_reply_at, payment_required, payment_requested_at, '
          'mvola_payments(status)',
        )
        .eq('id', id)
        .maybeSingle();

    // A row belonging to another user is invisible under RLS, so a null result
    // means either it does not exist or it is not ours.
    if (row == null) {
      throw const KycServiceException('TICKET_NOT_FOUND', 'Request not found.');
    }

    // `is_submitted` / `payment_status` are derived server side by
    // `kyc_submission_state`, which the client cannot call directly. They are
    // fetched through the `mvola-payments` Edge Function (which proves ownership
    // before deriving the state) and merged in, so the screen never infers the
    // submission state from the embedded payment rows. A failure here degrades
    // to the embedded fallback instead of failing the whole screen; the reply
    // guard is still enforced server side by `user_post_message`.
    var map = Map<String, dynamic>.from(row);
    try {
      final payload = await invokeFunction(_client, 'mvola-payments', {
        'action': 'state',
        'ticket_id': id,
      });
      map = mergeSubmissionState(map, payload['state']);
    } catch (_) {
      // Keep the embedded fallback.
    }
    return KycRequest.fromMap(map);
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
  Future<List<StatusHistoryEntry>> statusHistory(String ticketId) async {
    final rows = await _client
        .from('kyc_status_history')
        .select('id, from_status, to_status, actor_role, created_at')
        .eq('ticket_id', ticketId)
        .order('created_at', ascending: true);
    return rows.map((row) => StatusHistoryEntry.fromMap(row)).toList();
  }

  @override
  Future<TicketMessage> replyToTicket({
    required String ticketId,
    required String body,
  }) async {
    final payload = await invokeFunction(
      _client,
      'reply-to-ticket',
      {'ticket_id': ticketId, 'body': body},
    );
    final message = payload['message'] as Map<String, dynamic>?;
    if (message == null) {
      throw const KycServiceException('INTERNAL', 'Something went wrong. Please try again.');
    }
    return TicketMessage.fromMap(message);
  }

  @override
  Future<List<NotificationItem>> notifications() async {
    final rows = await _client
        .from('notifications')
        .select('id, type, title, body, ticket_id, read_at, created_at')
        .order('created_at', ascending: false)
        .limit(100);
    return rows.map((row) => NotificationItem.fromMap(row)).toList();
  }

  @override
  Future<void> markNotificationRead(String notificationId) async {
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', notificationId);
  }

  @override
  Future<void> markAllNotificationsRead() async {
    // RLS scopes the update to the caller's own rows, so no user filter is
    // needed (and none would be trusted). Only still-unread rows are touched.
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .isFilter('read_at', null);
  }

  @override
  Future<void> markTicketNotificationsRead(String ticketId) async {
    // Same RLS-scoped update as markAllNotificationsRead, narrowed to one
    // ticket. A ticket that is not the caller's has no visible notifications,
    // so the update simply matches nothing - there is no server-side path to
    // touch another user's rows.
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('ticket_id', ticketId)
        .isFilter('read_at', null);
  }

  @override
  Future<void> registerDeviceToken({
    required String token,
    String platform = 'android',
  }) async {
    if (_client.auth.currentUser == null) return;
    // Goes through a SECURITY DEFINER function so a shared device can move its
    // token to the account that just signed in; the identity is taken from the
    // session server side. See the push_tokens migration.
    await _client.rpc('register_device_token', params: {
      'p_token': token,
      'p_platform': platform,
    });
  }

  @override
  Future<void> unregisterDeviceToken({required String token}) async {
    // RLS confines the delete to the caller's own row.
    await _client.from('device_tokens').delete().eq('token', token);
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

  @override
  Future<void> requestPayment(String ticketId) => _invoke<void>(
        'request_payment',
        {'ticket_id': ticketId},
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

/// Folds the server-derived submission state into a `kyc_requests` row map.
///
/// The state comes from `kyc_submission_state` (via the `mvola-payments` Edge
/// Function) as `{ payment_status, is_submitted }`. Only well-formed values are
/// written; anything else is ignored so the caller keeps its embedded fallback.
/// Returns a new map, leaving the input untouched.
Map<String, dynamic> mergeSubmissionState(Map<String, dynamic> row, Object? state) {
  if (state is! Map) return row;
  final status = state['payment_status'];
  final submitted = state['is_submitted'];
  if (status is! String && submitted is! bool) return row;
  return {
    ...row,
    if (status is String) 'payment_status': status,
    if (submitted is bool) 'is_submitted': submitted,
  };
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
    netStart('edge:$name');
    final response = await client.functions.invoke(name, body: body);
    netEnd('edge:$name');
    return asJsonMap(response.data);
  } on FunctionException catch (error) {
    netError('edge:$name', error);
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
