/// URL detection inside free-form text, and its rendering as tappable links.
///
/// Covers the cases the product asked for explicitly: several URLs in one text,
/// URLs with query parameters, long URLs, `www.` links and trailing sentence
/// punctuation that must not be swallowed into the link.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tango_kyc_verification/core/url_detector.dart';
import 'package:tango_kyc_verification/ui/widgets/linkified_text.dart';

void main() {
  group('UrlDetector.detect', () {
    test('finds a single https link', () {
      final links = UrlDetector.detect('Voir https://tango.me/profile/123 merci');
      expect(links, hasLength(1));
      expect(links.single.text, 'https://tango.me/profile/123');
      expect(links.single.url, 'https://tango.me/profile/123');
    });

    test('finds several URLs in one message', () {
      final links = UrlDetector.detect(
        'Premier https://tango.me/a puis http://example.com/b et www.tango.me/c',
      );
      expect(links.map((l) => l.text), [
        'https://tango.me/a',
        'http://example.com/b',
        'www.tango.me/c',
      ]);
      // A bare www. link is opened over https.
      expect(links.last.url, 'https://www.tango.me/c');
    });

    test('keeps query parameters and fragments intact', () {
      const raw = 'https://tango.me/user?id=42&ref=kyc#section';
      final links = UrlDetector.detect('Lien: $raw');
      expect(links, hasLength(1));
      expect(links.single.text, raw);
      expect(links.single.url, raw);
    });

    test('keeps a long URL whole', () {
      final long = 'https://tango.me/${'a' * 300}?x=1';
      final links = UrlDetector.detect(long);
      expect(links, hasLength(1));
      expect(links.single.text, long);
    });

    test('drops trailing sentence punctuation', () {
      expect(
        UrlDetector.detect('Allez sur https://tango.me/x.').single.text,
        'https://tango.me/x',
      );
      expect(
        UrlDetector.detect('Vraiment ? https://tango.me/x!').single.text,
        'https://tango.me/x',
      );
    });

    test('keeps a balanced bracket inside the URL but trims an unbalanced one', () {
      expect(
        UrlDetector.detect('(https://tango.me/wiki/Foo_(bar))').single.text,
        'https://tango.me/wiki/Foo_(bar)',
      );
      expect(
        UrlDetector.detect('(voir https://tango.me/x)').single.text,
        'https://tango.me/x',
      );
    });

    test('ignores text without a URL', () {
      expect(UrlDetector.detect('Aucun lien ici.'), isEmpty);
      expect(UrlDetector.containsUrl('Aucun lien ici.'), isFalse);
    });

    test('records the exact span offsets', () {
      const raw = 'avant https://tango.me/x après';
      final link = UrlDetector.detect(raw).single;
      expect(raw.substring(link.start, link.end), 'https://tango.me/x');
    });
  });

  group('LinkifiedText', () {
    testWidgets('renders links as tappable spans and opens them', (tester) async {
      final launched = <Uri>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LinkifiedText(
            'Contactez https://tango.me/support svp',
            launcher: (uri) async {
              launched.add(uri);
              return true;
            },
          ),
        ),
      ));

      await tester.pumpAndSettle();
      // Tap on the rendered link text.
      await tester.tap(find.textContaining('https://tango.me/support'));
      await tester.pumpAndSettle();

      expect(launched, [Uri.parse('https://tango.me/support')]);
    });

    testWidgets('plain text without links is a single Text', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: LinkifiedText('Rien à ouvrir')),
      ));
      expect(find.text('Rien à ouvrir'), findsOneWidget);
    });
  });
}
