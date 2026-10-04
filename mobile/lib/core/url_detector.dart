/// Detects http(s) URLs inside free-form text so they can be rendered as real,
/// tappable links.
///
/// The detection is deliberately conservative and dependency-free:
///
///   * a match must start with `http://`, `https://` or `www.`;
///   * it runs to the next whitespace or an obvious delimiter (`<`, `>`, `"`,
///     `'`);
///   * trailing sentence punctuation (`.,;:!?`) and closing quotes are trimmed,
///     so `https://tango.me/x).` keeps the link and loses the `).` — a `)`/`]`/`}`
///     is only trimmed when it is unbalanced, so a bracket that belongs to the
///     URL is preserved;
///   * query strings, fragments, `%`-encoding and multiple links in one text are
///     all supported.
///
/// Nothing here interprets markup: the input is plain text, exactly as the
/// backend stores it.
library;

/// One detected link: the exact [text] span inside the source and the [url] to
/// open (with the redundant `https://` added for a `www.` match).
class DetectedUrl {
  const DetectedUrl({
    required this.start,
    required this.end,
    required this.text,
    required this.url,
  });

  /// Offset of the first character of the link in the source string.
  final int start;

  /// Offset just past the last character of the link.
  final int end;

  /// The link exactly as it appears in the source.
  final String text;

  /// The absolute URL to hand to the launcher.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is DetectedUrl && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

class UrlDetector {
  const UrlDetector._();

  /// A URL body may not contain whitespace or the delimiters that never appear
  /// inside a link in prose.
  static final RegExp _pattern = RegExp(
    r'''(?:https?://|www\.)[^\s<>"']+''',
    caseSensitive: false,
  );

  static const _trailing = '.,;:!?';
  static const _openers = '([{';
  static const _closers = ')]}';
  static const _quotes = '"\'»«';

  /// Every URL found in [text], in order.
  static List<DetectedUrl> detect(String text) {
    if (text.isEmpty) return const [];
    final result = <DetectedUrl>[];
    for (final match in _pattern.allMatches(text)) {
      var end = match.end;
      // Trim trailing punctuation that clearly belongs to the sentence.
      while (end > match.start) {
        final ch = text[end - 1];
        if (_trailing.contains(ch) || _quotes.contains(ch)) {
          end--;
          continue;
        }
        // A closing bracket only belongs to the sentence when there is no
        // matching opener inside the candidate link.
        if (_closers.contains(ch)) {
          final body = text.substring(match.start, end);
          final open = _openers[_closers.indexOf(ch)];
          if (_count(body, ch) > _count(body, open)) {
            end--;
            continue;
          }
        }
        break;
      }
      if (end <= match.start) continue;
      final linkText = text.substring(match.start, end);
      result.add(DetectedUrl(
        start: match.start,
        end: end,
        text: linkText,
        url: _absolute(linkText),
      ));
    }
    return result;
  }

  /// True when [text] contains at least one URL.
  static bool containsUrl(String text) => _pattern.hasMatch(text);

  /// Adds the missing scheme for a `www.` match; everything else is already
  /// absolute.
  static String _absolute(String link) {
    final lower = link.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return link;
    return 'https://$link';
  }
}

/// How many times the single-character [needle] appears in [haystack].
int _count(String haystack, String needle) {
  var count = 0;
  for (var i = 0; i < haystack.length; i++) {
    if (haystack[i] == needle) count++;
  }
  return count;
}
