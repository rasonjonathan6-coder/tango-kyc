/// Conversation state for the Tango KYC assistant.
///
/// Holds the transcript, sends it to the [AssistantService], and exposes a
/// sending flag and the last error. The conversation is in-memory only: the
/// assistant is a help tool, not a record of the user's dossier, so nothing is
/// persisted and closing the screen starts fresh.
library;

import 'package:flutter/foundation.dart';

import '../core/net_log.dart';
import '../services/assistant_service.dart';
import '../services/kyc_service.dart';

class AssistantController extends ChangeNotifier {
  AssistantController(this._service);

  final AssistantService _service;

  final List<AssistantMessage> _messages = [];
  bool _sending = false;
  String? _error;
  bool _configured = true;

  List<AssistantMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;
  String? get error => _error;

  /// False once the server has told us no provider key is configured, so the
  /// screen can show the honest "not available" notice and hide the composer.
  bool get configured => _configured;

  bool get isEmpty => _messages.isEmpty;

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;

    _messages.add(AssistantMessage(fromUser: true, text: trimmed));
    _sending = true;
    _error = null;
    notifyListeners();

    try {
      netStart('edge:chat-assistant');
      final reply = await _service.send(List.unmodifiable(_messages));
      netEnd('edge:chat-assistant');
      _configured = reply.configured;
      _messages.add(AssistantMessage(fromUser: false, text: reply.text));
    } catch (error) {
      netError('edge:chat-assistant', error);
      _error = error is KycServiceException ? error.code : error.toString();
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  /// Clears the transcript (the "Nouvelle conversation" action).
  void reset() {
    _messages.clear();
    _error = null;
    notifyListeners();
  }
}
