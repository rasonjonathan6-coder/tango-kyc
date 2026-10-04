// Tests for the Tango KYC assistant controller and screen.
//
// The controller is exercised against a fake service (no network, no provider),
// and the screen is pumped to assert the two things that matter for safety and
// honesty: a signed-in user can send a turn and see the reply, and when the
// server reports no provider is configured the composer is replaced by an
// honest notice plus the link into the real support channel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/state/assistant_controller.dart';
import 'package:tango_kyc_verification/ui/screens/assistant_screen.dart';

import 'fakes.dart';

Widget _host(AssistantController controller) {
  return ChangeNotifierProvider<AssistantController>.value(
    value: controller,
    child: const MaterialApp(home: AssistantScreen()),
  );
}

void main() {
  group('AssistantController', () {
    test('a blank message is ignored', () async {
      final service = FakeAssistantService();
      final controller = AssistantController(service);

      await controller.send('   ');

      expect(service.sendCalls, 0);
      expect(controller.messages, isEmpty);
    });

    test('a message is sent and the reply appended', () async {
      final service = FakeAssistantService(reply: 'Sous 24 heures ouvrées.');
      final controller = AssistantController(service);

      await controller.send('Quel est le délai ?');

      expect(service.sendCalls, 1);
      expect(controller.messages.length, 2);
      expect(controller.messages[0].fromUser, isTrue);
      expect(controller.messages[0].text, 'Quel est le délai ?');
      expect(controller.messages[1].fromUser, isFalse);
      expect(controller.messages[1].text, 'Sous 24 heures ouvrées.');
      expect(controller.error, isNull);
    });

    test('the whole conversation is sent on each turn', () async {
      final service = FakeAssistantService();
      final controller = AssistantController(service);

      await controller.send('Première');
      await controller.send('Deuxième');

      expect(service.lastConversation.length, 3);
      expect(service.lastConversation.first.text, 'Première');
      expect(service.lastConversation.last.text, 'Deuxième');
    });

    test('a server error surfaces a code and adds no reply', () async {
      final service = FakeAssistantService(failWithCode: 'INTERNAL');
      final controller = AssistantController(service);

      await controller.send('Bonjour');

      expect(controller.error, 'INTERNAL');
      // Only the user's own turn is present; no assistant turn was appended.
      expect(controller.messages.length, 1);
      expect(controller.messages.single.fromUser, isTrue);
    });

    test('a server that reports no provider flips configured false', () async {
      final service = FakeAssistantService(configured: false, reply: 'Indisponible.');
      final controller = AssistantController(service);

      await controller.send('Bonjour');

      expect(controller.configured, isFalse);
    });

    test('reset clears the transcript', () async {
      final controller = AssistantController(FakeAssistantService());
      await controller.send('Bonjour');
      expect(controller.messages, isNotEmpty);

      controller.reset();

      expect(controller.messages, isEmpty);
      expect(controller.error, isNull);
    });
  });

  group('AssistantScreen', () {
    testWidgets('composer is present when the assistant is configured', (tester) async {
      final controller = AssistantController(FakeAssistantService());
      await tester.pumpWidget(_host(controller));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Ouvrir une demande'), findsNothing);
    });

    testWidgets('a sent question and its reply are both shown', (tester) async {
      final controller = AssistantController(
        FakeAssistantService(reply: 'Le support répond sous 24h ouvrées.'),
      );
      await tester.pumpWidget(_host(controller));

      await tester.enterText(find.byType(TextField), 'Quel délai ?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.text('Quel délai ?'), findsOneWidget);
      expect(find.text('Le support répond sous 24h ouvrées.'), findsOneWidget);
    });

    testWidgets('an unconfigured server hides the composer and offers a demande',
        (tester) async {
      final service = FakeAssistantService(configured: false, reply: 'Indisponible.');
      final controller = AssistantController(service);
      await controller.send('Bonjour');
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('Ouvrir une demande'), findsOneWidget);
    });
  });
}
