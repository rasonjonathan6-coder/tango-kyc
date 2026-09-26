/// State for the manual MVola payment flow.
///
/// The controller holds no business rule: amount, recipient and USSD come from
/// the server, and whether a payment may be opened or submitted is decided by
/// the backend. Its job is to expose loading, error and success states to the UI
/// without leaking internal error text.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/kyc_service.dart';
import '../services/mvola_service.dart';

class MvolaController extends ChangeNotifier {
  MvolaController(this._service);

  final MvolaService _service;

  MvolaConfig? _config;
  MvolaPayment? _payment;
  List<MvolaPayment> _payments = const [];
  bool _loading = false;
  bool _starting = false;
  bool _submitting = false;
  String? _error;

  /// Stable error code from the backend, so the UI can translate it instead of
  /// rendering a server string.
  String? lastErrorCode;

  MvolaConfig? get config => _config;
  MvolaPayment? get payment => _payment;
  List<MvolaPayment> get payments => _payments;
  bool get loading => _loading;
  bool get starting => _starting;
  bool get submitting => _submitting;
  String? get error => _error;

  /// True while any write is in flight, so a button can be disabled against
  /// double taps.
  bool get busy => _starting || _submitting;

  /// Loads the configuration and the active payment for a ticket.
  Future<void> load(String ticketId) async {
    _loading = true;
    _error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      _config = await _service.config();
      final existing = await _service.mine();
      _payments = existing;
      // `mine()` is ordered newest first, so the first match is the active one.
      _payment = null;
      for (final candidate in existing) {
        if (candidate.ticketId == ticketId) {
          _payment = candidate;
          break;
        }
      }
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
    } catch (error) {
      lastErrorCode = 'INTERNAL';
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Opens, or returns, the payment for a ticket. Returns null on failure with
  /// [lastErrorCode] set.
  Future<MvolaPayment?> start(String ticketId) async {
    _starting = true;
    _error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      _payment = await _service.start(ticketId);
      return _payment;
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
      return null;
    } catch (error) {
      lastErrorCode = 'INTERNAL';
      _error = error.toString();
      return null;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  /// Confirms payment. Returns true on success.
  Future<bool> submit({
    required String paymentId,
    required String transactionReference,
    String? payerNumber,
  }) async {
    _submitting = true;
    _error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      _payment = await _service.submit(
        paymentId: paymentId,
        transactionReference: transactionReference,
        payerNumber: payerNumber,
      );
      return true;
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
      return false;
    } catch (error) {
      lastErrorCode = 'INTERNAL';
      _error = error.toString();
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Clears the in-memory payment so a new ticket's screen starts clean.
  void reset() {
    _payment = null;
    _error = null;
    lastErrorCode = null;
    notifyListeners();
  }
}
