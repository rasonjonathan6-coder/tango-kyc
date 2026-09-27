/// In-app notifications.
///
/// Derived entirely from ticket data the backend already produced and RLS already
/// scoped to the caller: a notification exists when a request carries an admin
/// reply (`replied` / `lastReplyAt`). No new endpoint, table or query is
/// introduced, so the validated backend contract is untouched.
///
/// The only local state is which reply the user has already looked at, persisted
/// in secure storage so the "new reply" badge survives a restart.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// A reply worth surfacing to the user.
class AppNotification {
  const AppNotification({
    required this.ticketId,
    required this.ticketCode,
    required this.title,
    required this.preview,
    required this.receivedAt,
    required this.unread,
  });

  final String ticketId;
  final String ticketCode;
  final String title;
  final String preview;
  final DateTime receivedAt;
  final bool unread;
}

class NotificationsController extends ChangeNotifier {
  NotificationsController(this._storage);

  final FlutterSecureStorage _storage;

  static const _seenKey = 'notifications.seen_replies';

  /// ticketId -> timestamp of the reply the user has already opened.
  Map<String, DateTime> _seen = {};
  List<AppNotification> _items = const [];
  bool _loaded = false;

  List<AppNotification> get items => _items;

  /// Number of replies the user has not opened yet.
  int get unreadCount => _items.where((n) => n.unread).length;

  bool get hasUnread => unreadCount > 0;

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _seenKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _seen = {
            for (final entry in decoded.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: DateTime.tryParse(entry.value as String) ??
                    DateTime.fromMillisecondsSinceEpoch(0),
          };
        }
      }
    } catch (_) {
      // A corrupt or unreadable store must never block the app; start fresh.
      _seen = {};
    }
    _loaded = true;
    notifyListeners();
  }

  /// Recomputes notifications from the caller's own requests.
  ///
  /// Called after the ticket list refreshes, so the badge always reflects what
  /// the server just returned.
  void sync(List<KycRequest> requests) {
    if (!_loaded) return;

    final replied = requests
        .where((r) => r.lastReplyAt != null)
        .toList()
      ..sort((a, b) => b.lastReplyAt!.compareTo(a.lastReplyAt!));

    _items = [
      for (final request in replied)
        AppNotification(
          ticketId: request.id,
          ticketCode: request.ticketCode,
          title: 'New reply from support',
          preview: _previewFor(request),
          receivedAt: request.lastReplyAt!,
          unread: _isUnread(request),
        ),
    ];
    notifyListeners();
  }

  String _previewFor(KycRequest request) {
    final status = request.status;
    return status == KycStatus.replied
        ? 'Your verification request has received a response. Tap to read it.'
        : 'Update on your verification request.';
  }

  bool _isUnread(KycRequest request) {
    final seen = _seen[request.id];
    if (seen == null) return true;
    return request.lastReplyAt!.isAfter(seen);
  }

  /// Marks a ticket's current reply as read and persists that choice.
  Future<void> markRead(String ticketId) async {
    final index = _items.indexWhere((n) => n.ticketId == ticketId);
    if (index == -1) return;
    final receivedAt = _items[index].receivedAt;

    final existing = _seen[ticketId];
    if (existing != null && !receivedAt.isAfter(existing)) return;

    _seen[ticketId] = receivedAt;
    _items = [
      for (final n in _items)
        if (n.ticketId == ticketId)
          AppNotification(
            ticketId: n.ticketId,
            ticketCode: n.ticketCode,
            title: n.title,
            preview: n.preview,
            receivedAt: n.receivedAt,
            unread: false,
          )
        else
          n,
    ];
    notifyListeners();

    try {
      await _storage.write(
        key: _seenKey,
        value: jsonEncode({for (final e in _seen.entries) e.key: e.value.toIso8601String()}),
      );
    } catch (_) {
      // Persistence is best-effort; the in-memory state is already correct.
    }
  }

  Future<void> markAllRead() async {
    for (final n in _items) {
      _seen[n.ticketId] = n.receivedAt;
    }
    _items = [
      for (final n in _items)
        AppNotification(
          ticketId: n.ticketId,
          ticketCode: n.ticketCode,
          title: n.title,
          preview: n.preview,
          receivedAt: n.receivedAt,
          unread: false,
        ),
    ];
    notifyListeners();
    try {
      await _storage.write(
        key: _seenKey,
        value: jsonEncode({for (final e in _seen.entries) e.key: e.value.toIso8601String()}),
      );
    } catch (_) {
      // Best-effort, as above.
    }
  }
}
