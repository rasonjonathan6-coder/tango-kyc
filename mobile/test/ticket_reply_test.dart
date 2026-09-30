/// In-app replies on a ticket, exercised without a backend:
///
///   * an open ticket shows an active composer and posting adds the message;
///   * a closed ticket is read-only — no composer, and the reason is shown;
///   * a request still owing a payment is blocked — no composer, and the rule
///     is explained with the payment action offered;
///   * a server `TICKET_CLOSED` answer flips the screen to read-only;
///   * a server `PAYMENT_NOT_CONFIRMED` answer flips it to payment-blocked;
///   * an empty reply is never sent.
///
/// The real write path (`reply-to-ticket` -> `user_post_message`) and its
/// database guard are covered by the fake here and asserted directly in the
/// SQL; a widget test cannot observe a real Supabase call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/ui/screens/request_details_screen.dart';

import 'fakes.dart';

KycRequest _request(
  String id, {
  KycStatus status = KycStatus.pending,
  bool paymentRequired = false,
  bool isSubmitted = true,
}) =>
    KycRequest(
      id: id,
      ticketCode: 'TNG-KYC-$id',
      status: status,
      tangoProfileLink: 'https://tango.me/x',
      registerType: RegisterType.email,
      registerValue: 'a@example.com',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      paymentRequired: paymentRequired,
      isSubmitted: isSubmitted,
    );

Widget _host(FakeKycService kyc, String ticketId) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<KycController>.value(value: KycController(kyc)),
      ChangeNotifierProvider<NotificationsController>.value(
          value: NotificationsController(kyc)),
    ],
    child: MaterialApp(home: RequestDetailsScreen(ticketId: ticketId)),
  );
}

void main() {
  testWidgets('an open ticket shows a composer and posts the reply',
      (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Écrire un message…'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Bonjour, une précision.');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(kyc.replies, hasLength(1));
    expect(kyc.replies.single.ticketId, 't1');
    expect(kyc.replies.single.body, 'Bonjour, une précision.');
    // The sent message is appended to the conversation.
    expect(find.text('Bonjour, une précision.'), findsOneWidget);
  });

  testWidgets('a closed ticket is read-only and explains why', (tester) async {
    final kyc = FakeKycService(
      requests: [_request('t1', status: KycStatus.closed)],
    );
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    // The closed notice is pinned in the footer, so it is always on screen.
    expect(find.textContaining('Cette demande est fermée'), findsOneWidget);
  });

  testWidgets('a TICKET_CLOSED answer flips the screen to read-only',
      (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);

    // The ticket is closed between load and send: the server refuses, and the
    // screen reloads so the composer disappears.
    kyc.failReplyWithCode = 'TICKET_CLOSED';
    kyc.requests.clear();
    kyc.requests.add(_request('t1', status: KycStatus.closed));

    await tester.enterText(find.byType(TextField), 'Trop tard ?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(kyc.replies, isEmpty);
    expect(find.byType(TextField), findsNothing);
    // The notice is pinned in the footer; the transient SnackBar repeats the
    // same reason, so allow more than one match.
    expect(find.textContaining('Cette demande est fermée'), findsWidgets);
  });

  testWidgets('an empty reply is never sent', (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(kyc.replies, isEmpty);
  });

  testWidgets('an unpaid request blocks the reply and explains why',
      (tester) async {
    final kyc = FakeKycService(
      requests: [_request('t1', paymentRequired: true, isSubmitted: false)],
    );
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    // No composer, and the reason is stated with the payment action offered.
    expect(find.byType(TextField), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Réponse bloquée'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Réponse bloquée'), findsOneWidget);
    expect(
      find.textContaining('doit être confirmé avant de pouvoir répondre'),
      findsOneWidget,
    );
    expect(find.text('Payer avec MVola'), findsWidgets);
  });

  testWidgets('a PAYMENT_NOT_CONFIRMED answer flips the screen to blocked',
      (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);

    // The payment gate appears between load and send: the server refuses, and
    // the screen reloads so the composer is replaced by the blocked notice.
    kyc.failReplyWithCode = 'PAYMENT_NOT_CONFIRMED';
    kyc.requests.clear();
    kyc.requests.add(_request('t1', paymentRequired: true, isSubmitted: false));

    await tester.enterText(find.byType(TextField), 'Je peux répondre ?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(kyc.replies, isEmpty);
    expect(find.byType(TextField), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Réponse bloquée'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Réponse bloquée'), findsOneWidget);
  });
}
