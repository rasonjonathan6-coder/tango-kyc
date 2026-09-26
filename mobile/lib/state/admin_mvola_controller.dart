/// State for the admin MVola queue.
///
/// Every call goes through `admin-actions`, which verifies the admin role both
/// in the function and again inside the SQL functions it invokes. The controller
/// only presents what the server returns.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/kyc_service.dart';
import '../services/mvola_service.dart';

class AdminMvolaController extends ChangeNotifier {
  AdminMvolaController(this._service);

  final AdminMvolaService _service;

  List<MvolaPayment> _payments = const [];
  bool _loading = false;
  String? _error;
  String? lastErrorCode;

  List<MvolaPayment> get payments => _payments;
  bool get loading => _loading;
  String? get error => _error;

  /// Payments the user has confirmed and that still await a decision.
  List<MvolaPayment> get awaitingReview =>
      _payments.where((p) => p.isAwaitingReview).toList();

  int get awaitingCount => awaitingReview.length;

  Future<void> load() async {
    _loading = true;
    _error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      _payments = await _service.list();
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

  /// Approves or refuses a payment. Returns true on success.
  Future<bool> decide({
    required String paymentId,
    required MvolaStatus decision,
    String? reason,
  }) async {
    lastErrorCode = null;
    try {
      await _service.decide(paymentId: paymentId, decision: decision, reason: reason);
      await load();
      return true;
    } on KycServiceException catch (error) {
      lastErrorCode = error.code;
      _error = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      lastErrorCode = 'INTERNAL';
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }
}
