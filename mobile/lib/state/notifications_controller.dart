/// In-app notifications, backed by the server-side `notifications` table.
///
/// Every row belongs to exactly one user and is scoped by RLS, so the client
/// can only ever read its own feed. Read state is persisted server side
/// (`read_at`), which is what makes the badge survive a reinstall or a second
/// device: there is no local-only "seen" cache.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/kyc_service.dart';

class NotificationsController extends ChangeNotifier {
  NotificationsController(this._service);

  final KycService _service;

  List<NotificationItem> _items = const [];
  bool _loading = false;
  String? _error;

  List<NotificationItem> get items => _items;
  bool get loading => _loading;
  String? get error => _error;

  int get unreadCount => _items.where((n) => n.unread).length;
  bool get hasUnread => unreadCount > 0;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _items = await _service.notifications();
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Marks one notification read, then reflects it locally without a refetch.
  Future<void> markRead(String id) async {
    final index = _items.indexWhere((n) => n.id == id);
    if (index == -1 || _items[index].readAt != null) return;
    _items = [
      for (final n in _items)
        if (n.id == id)
          NotificationItem(
            id: n.id,
            type: n.type,
            title: n.title,
            body: n.body,
            createdAt: n.createdAt,
            ticketId: n.ticketId,
            readAt: DateTime.now(),
          )
        else
          n,
    ];
    notifyListeners();
    try {
      await _service.markNotificationRead(id);
    } catch (_) {
      // The optimistic update stands; a later refresh reconciles.
    }
  }

  /// Marks every unread notification tied to one ticket read, then reflects it
  /// locally without a refetch, so the badge drops as soon as the ticket opens
  /// from a push. Returns nothing on failure: the optimistic update stands and a
  /// later refresh reconciles.
  Future<void> markTicketRead(String ticketId) async {
    final hadUnread =
        _items.any((n) => n.ticketId == ticketId && n.readAt == null);
    if (!hadUnread) return;
    final now = DateTime.now();
    _items = [
      for (final n in _items)
        if (n.ticketId == ticketId && n.readAt == null)
          NotificationItem(
            id: n.id,
            type: n.type,
            title: n.title,
            body: n.body,
            createdAt: n.createdAt,
            ticketId: n.ticketId,
            readAt: now,
          )
        else
          n,
    ];
    notifyListeners();
    try {
      await _service.markTicketNotificationsRead(ticketId);
    } catch (_) {
      // Best effort; the next load reconciles with the server.
    }
  }

  Future<void> markAllRead() async {
    if (!hasUnread) return;
    _items = [
      for (final n in _items)
        n.readAt != null
            ? n
            : NotificationItem(
                id: n.id,
                type: n.type,
                title: n.title,
                body: n.body,
                createdAt: n.createdAt,
                ticketId: n.ticketId,
                readAt: DateTime.now(),
              ),
    ];
    notifyListeners();
    try {
      await _service.markAllNotificationsRead();
    } catch (_) {
      // Best effort, reconciled on the next load.
    }
  }

  /// Called on sign-out so a previous user's feed never lingers.
  void clear() {
    _items = const [];
    notifyListeners();
  }
}
