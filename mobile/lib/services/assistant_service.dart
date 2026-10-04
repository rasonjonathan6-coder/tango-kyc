/// Data access for the Tango KYC assistant (the in-app chatbot).
///
/// The assistant is an Edge Function: the provider API key, the system prompt
/// and the knowledge base all live server side. This client only sends the
/// conversation turns and receives a reply, so no provider credential is ever
/// present in the app.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'kyc_service.dart';

/// One turn in the assistant conversation.
class AssistantMessage {
  const AssistantMessage({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;

  Map<String, dynamic> toJson() => {
        'role': fromUser ? 'user' : 'assistant',
        'content': text,
      };
}

/// The assistant's answer plus whether a provider is configured server side.
class AssistantReply {
  const AssistantReply({required this.text, required this.configured});

  final String text;
  final bool configured;
}

abstract class AssistantService {
  /// Sends the conversation and returns the assistant's next reply.
  Future<AssistantReply> send(List<AssistantMessage> conversation);
}

class SupabaseAssistantService implements AssistantService {
  SupabaseAssistantService(this._client);

  final SupabaseClient _client;

  @override
  Future<AssistantReply> send(List<AssistantMessage> conversation) async {
    final payload = await invokeFunction(_client, 'chat-assistant', {
      'messages': [for (final m in conversation) m.toJson()],
    });

    final reply = payload['reply'];
    final configured = payload['configured'];
    return AssistantReply(
      text: reply is String && reply.isNotEmpty
          ? reply
          : 'L’assistant n’a pas pu répondre. Réessayez ou ouvrez une demande.',
      configured: configured is bool ? configured : true,
    );
  }
}
