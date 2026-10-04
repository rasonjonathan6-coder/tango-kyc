/// State for the user's own KYC requests.
library;

import 'package:flutter/foundation.dart';

import '../core/net_log.dart';
import '../models/models.dart';
import '../services/kyc_service.dart';

class KycController extends ChangeNotifier {
  KycController(this._service);

  final KycService _service;

  List<KycRequest> _requests = const [];
  bool _loading = false;
  bool _submitting = false;
  String? _error;
  KycRequest? _lastCreated;

  List<KycRequest> get requests => _requests;
  bool get loading => _loading;
  bool get submitting => _submitting;
  String? get error => _error;

  /// The ticket created by the most recent successful submission, used to show
  /// the confirmation with its ticket id and initial status.
  KycRequest? get lastCreated => _lastCreated;

  void clearLastCreated() {
    _lastCreated = null;
    notifyListeners();
  }

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      netStart('myRequests');
      _requests = await _service.myRequests();
      netEnd('myRequests');
    } catch (error) {
      netError('myRequests', error);
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Submits a request. Returns the created ticket, or null on failure with
  /// [lastErrorCode] set for the UI to translate.
  String? lastErrorCode;

  Future<KycRequest?> submit({
    required String tangoProfileLink,
    required String registerValue,
  }) async {
    _submitting = true;
    _error = null;
    lastErrorCode = null;
    notifyListeners();

    try {
      final ticket = await _service.createRequest(
        tangoProfileLink: tangoProfileLink,
        registerValue: registerValue,
      );
      _lastCreated = ticket;
      // Refresh the list so the new ticket appears immediately.
      _requests = await _service.myRequests();
      return ticket;
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
      return null;
    } catch (error) {
      lastErrorCode = 'INTERNAL';
      _error = error.toString();
      return null;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  Future<KycRequest> requestById(String id) => _service.requestById(id);

  Future<List<TicketMessage>> messages(String ticketId) => _service.messages(ticketId);

  Future<List<StatusHistoryEntry>> statusHistory(String ticketId) =>
      _service.statusHistory(ticketId);

  /// Posts the caller's own reply on a ticket.
  ///
  /// Returns the created message, or null on failure with [lastErrorCode] set so
  /// the screen can translate it — including `TICKET_CLOSED`, which the server
  /// returns when the ticket was closed in the meantime.
  String? replyErrorCode;

  Future<TicketMessage?> reply({required String ticketId, required String body}) async {
    replyErrorCode = null;
    try {
      return await _service.replyToTicket(ticketId: ticketId, body: body);
    } on KycServiceException catch (error) {
      replyErrorCode = error.code;
      return null;
    } catch (_) {
      replyErrorCode = 'INTERNAL';
      return null;
    }
  }
}
