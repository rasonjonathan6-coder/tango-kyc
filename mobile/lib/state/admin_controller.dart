/// State for the admin dashboard. All data is fetched server side behind a
/// role check; this controller only presents it.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/kyc_service.dart';

class AdminController extends ChangeNotifier {
  AdminController(this._service);

  final AdminService _service;

  AdminStats _stats = AdminStats.empty;
  List<KycRequest> _tickets = const [];
  List<UnmatchedReply> _unmatched = const [];
  bool _loading = false;
  String? _error;
  String? lastErrorCode;

  AdminStats get stats => _stats;
  List<KycRequest> get tickets => _tickets;
  List<UnmatchedReply> get unmatched => _unmatched;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> load() async {
    _loading = true;
    _error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      final stats = await _service.stats();
      final result = await _service.list();
      _stats = stats;
      _tickets = result.tickets;
      _unmatched = result.unmatched;
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<List<TicketMessage>> messages(String ticketId) => _service.messages(ticketId);

  Future<bool> setStatus(String ticketId, KycStatus status) =>
      _run(() => _service.setStatus(ticketId, status));

  Future<bool> postMessage(String ticketId, String body) =>
      _run(() => _service.postMessage(ticketId, body));

  Future<bool> resolveUnmatched(String unmatchedId, String ticketId) =>
      _run(() => _service.resolveUnmatched(unmatchedId, ticketId));

  Future<bool> requestPayment(String ticketId) =>
      _run(() => _service.requestPayment(ticketId));

  Future<bool> _run(Future<void> Function() action) async {
    lastErrorCode = null;
    try {
      await action();
      await load();
      return true;
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }
}
