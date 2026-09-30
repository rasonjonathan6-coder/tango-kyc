/// Realtime change feed for the signed-in user's own rows.
///
/// The dashboard must refresh itself when a reply lands, without polling and
/// without a restart. Supabase Realtime is the mechanism already available to
/// the project, so it is used here: a single channel subscribes to the two
/// tables the dashboard reacts to —
///
///   * `notifications` -> the bell badge and the notifications list;
///   * `kyc_requests`  -> the request list and its status pill.
///
/// Realtime delivers rows through the same Row Level Security that guards
/// PostgREST, so a subscriber only ever receives its own rows. Nothing here
/// decides what a user may see; it only reacts to what the server already
/// allowed.
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// The tables the dashboard listens to.
enum RealtimeTopic { notifications, requests }

/// Minimal seam over Realtime so the controller can be tested without a socket.
abstract class RealtimeService {
  /// Calls [onChange] whenever one of the watched tables changes. Returns a
  /// disposable subscription.
  RealtimeSubscription watch(void Function(Set<RealtimeTopic> changed) onChange);

  /// Tears everything down on sign-out.
  Future<void> dispose();
}

/// A cancellable handle, mirroring the shape of the Supabase channel.
abstract class RealtimeSubscription {
  Future<void> cancel();
}

/// No-op implementation for tests and for the unconfigured case: it never calls
/// back, so the controller simply never receives a live event.
class NoopRealtimeService implements RealtimeService {
  const NoopRealtimeService();

  @override
  RealtimeSubscription watch(void Function(Set<RealtimeTopic> changed) onChange) =>
      const _NoopSubscription();

  @override
  Future<void> dispose() async {}
}

class _NoopSubscription implements RealtimeSubscription {
  const _NoopSubscription();

  @override
  Future<void> cancel() async {}
}

/// Supabase-backed implementation.
///
/// A burst of rows (a webhook stores a message *and* flips the status *and*
/// inserts a notification) arrives as several events; they are coalesced into a
/// single callback within [coalesce] so the UI refetches once per burst rather
/// than three times. The refetch is the same RLS-scoped query the screen already
/// uses, so no new data path is introduced.
class SupabaseRealtimeService implements RealtimeService {
  SupabaseRealtimeService(this._client, {this.coalesce = const Duration(milliseconds: 250)});

  final SupabaseClient _client;
  final Duration coalesce;

  RealtimeChannel? _channel;
  final Set<RealtimeTopic> _pending = {};
  Timer? _timer;

  void _flush(void Function(Set<RealtimeTopic> changed) onChange) {
    _timer?.cancel();
    _timer = Timer(coalesce, () {
      final changed = Set<RealtimeTopic>.from(_pending);
      _pending.clear();
      if (changed.isNotEmpty) onChange(changed);
    });
  }

  void _mark(RealtimeTopic topic, void Function(Set<RealtimeTopic>) onChange) {
    _pending.add(topic);
    _flush(onChange);
  }

  @override
  RealtimeSubscription watch(void Function(Set<RealtimeTopic> changed) onChange) {
    // One channel for both tables keeps the socket count low and makes
    // teardown a single operation.
    final channel = _client.channel('user-dashboard');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          callback: (_) => _mark(RealtimeTopic.notifications, onChange),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'kyc_requests',
          callback: (_) => _mark(RealtimeTopic.requests, onChange),
        )
        .subscribe();
    _channel = channel;
    return _ChannelSubscription(this, channel);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await _client.removeChannel(channel);
    }
  }
}

class _ChannelSubscription implements RealtimeSubscription {
  _ChannelSubscription(this._owner, this._channel);

  final SupabaseRealtimeService _owner;
  final RealtimeChannel _channel;

  @override
  Future<void> cancel() async {
    if (identical(_owner._channel, _channel)) {
      _owner._channel = null;
    }
    _owner._timer?.cancel();
    await _owner._client.removeChannel(_channel);
  }
}
