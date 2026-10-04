/// The request detail screen offers a reply composer only when the server would
/// accept a reply.
///
/// The rule mirrors `user_post_message`:
///   * an open ticket that owes no payment, or whose payment has been approved,
///     shows the composer and can send a reply;
///   * a request that owes an unconfirmed payment stays read-only and explains
///     that the reply will be available after confirmation;
///   * a closed ticket stays read-only and explains it is closed;
///   * the synthetic welcome ticket never shows a composer.
///
/// The server remains authoritative: a refusal (for example a payment gate that
/// is still shut, or a ticket closed in the meantime) is surfaced to the user
/// and stores nothing. The administration's own write path (`AdminTicketScreen`)
/// and the `reply-to-ticket` / `user_post_message` functions are untouched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tango_kyc_verification/models/models.dart';
import 'package:tango_kyc_verification/state/kyc_controller.dart';
import 'package:tango_kyc_verification/state/notifications_controller.dart';
import 'package:tango_kyc_verification/ui/screens/request_details_screen.dart';
import 'package:tango_kyc_verification/ui/widgets/aurora.dart';

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

/// Lets a pending SnackBar timer fire so the test can end cleanly.
Future<void> _dismissSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// The conversation lives in a lazily-built list, so a message below the fold
/// must be scrolled into view before it is attached to the tree.
Future<void> _revealMessage(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.textContaining(text),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an open ticket that owes no payment shows the composer',
      (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await _revealComposer(tester);
    expect(find.text('Votre réponse'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Écrire une réponse...'), findsOneWidget);
    expect(find.text('Envoyer'), findsOneWidget);
  });

  testWidgets('a real request explains the support turnaround', (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await _revealMessage(tester, 'Délai de réponse du support');
    expect(find.text('Délai de réponse du support'), findsOneWidget);
    expect(find.textContaining('jusqu’à 24 h ouvrées'), findsOneWidget);
    expect(
      find.textContaining('peuvent varier selon le volume de demandes'),
      findsOneWidget,
    );
  });

  testWidgets('an approved payment unlocks the composer', (tester) async {
    final kyc = FakeKycService(
      requests: [_request('t1', paymentRequired: true, isSubmitted: true)],
    );
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    // The payment action is no longer offered once the payment is approved.
    expect(find.text('Payer avec MVola'), findsNothing);
    await _revealComposer(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Envoyer'), findsOneWidget);
  });

  testWidgets('a reply is sent and kept in the conversation', (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await _revealComposer(tester);
    await tester.enterText(find.byType(TextField), 'Voici mon document.');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(GradientButton));
    await tester.pumpAndSettle();

    expect(kyc.replies, hasLength(1));
    expect(kyc.replies.single.ticketId, 't1');
    expect(kyc.replies.single.body, 'Voici mon document.');
    // The reply is appended to the conversation shown on the ticket.
    await _revealMessage(tester, 'Voici mon document.');
    expect(find.textContaining('Voici mon document.'), findsWidgets);
    await _dismissSnackBar(tester);
  });

  testWidgets('an empty reply is not sent', (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')]);
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await _revealComposer(tester);
    await tester.tap(find.byType(GradientButton));
    await tester.pumpAndSettle();

    expect(kyc.replies, isEmpty);
  });

  testWidgets('a request owing an unconfirmed payment stays read-only',
      (tester) async {
    final kyc = FakeKycService(
      requests: [_request('t1', paymentRequired: true, isSubmitted: false)],
    );
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Écrire une réponse...'), findsNothing);
    expect(find.text('Envoyer'), findsNothing);
    // The payment action is still offered, but never a reply box.
    expect(find.text('Payer avec MVola'), findsWidgets);
    expect(
      find.textContaining('après confirmation de votre paiement'),
      findsOneWidget,
    );
  });

  testWidgets('a closed ticket shows no composer and explains it is closed',
      (tester) async {
    final kyc = FakeKycService(
      requests: [_request('t1', status: KycStatus.closed)],
    );
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('fermée'), findsOneWidget);
  });

  testWidgets('a server refusal is surfaced and stores nothing', (tester) async {
    final kyc = FakeKycService(requests: [_request('t1')])
      ..failReplyWithCode = 'PAYMENT_NOT_CONFIRMED';
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await _revealComposer(tester);
    await tester.enterText(find.byType(TextField), 'Bonjour');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(GradientButton));
    await tester.pumpAndSettle();

    expect(kyc.replies, isEmpty);
    expect(find.textContaining('confirmé'), findsWidgets);
    await _dismissSnackBar(tester);
  });

  testWidgets('the administration messages are shown, with links clickable',
      (tester) async {
    final kyc = FakeKycService(
      requests: [_request('t1')],
      messageItems: [
        TicketMessage(
          id: 'm1',
          ticketId: 't1',
          senderType: SenderType.admin,
          body: 'Votre profil est validé. Détails : https://tango.me/profil/42',
          createdAt: DateTime(2026, 1, 2),
        ),
      ],
    );
    await tester.pumpWidget(_host(kyc, 't1'));
    await tester.pumpAndSettle();

    await _revealMessage(tester, 'Votre profil est validé');
    expect(find.textContaining('Votre profil est validé'), findsOneWidget);
    // The URL inside the admin message is rendered as a link span.
    expect(find.textContaining('https://tango.me/profil/42'), findsWidgets);
  });

  testWidgets('the welcome ticket stays read-only', (tester) async {
    final welcome = KycRequest(
      id: 'w1',
      ticketCode: 'TNG-KYC-w1',
      status: KycStatus.pending,
      tangoProfileLink: 'https://tango.me/x',
      registerType: RegisterType.phone,
      registerValue: 'WELCOME',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final kyc = FakeKycService(requests: [welcome]);
    await tester.pumpWidget(_host(kyc, 'w1'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Envoyer'), findsNothing);
  });
}
