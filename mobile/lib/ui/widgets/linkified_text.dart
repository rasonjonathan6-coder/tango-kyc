/// Renders plain text, turning any detected URL into a real, tappable link.
///
/// Used wherever user- or admin-authored text is shown: conversation messages,
/// notification bodies and the FAQ. The text itself is never reinterpreted as
/// markup — only the spans [UrlDetector] identified become links.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/url_detector.dart';

/// Opens [url] in the most appropriate Android app: a matching native app when
/// the platform offers one (external handler), otherwise the browser.
///
/// Returns quietly when nothing can handle the URL rather than throwing into the
/// widget tree. Handlers are stored on the enclosing `LinkifiedText` so a test
/// can observe the launch without touching a platform channel.
typedef UrlLauncher = Future<bool> Function(Uri uri);

/// The production launcher: `LaunchMode.platformDefault` lets Android dispatch
/// to the app registered for the scheme/host (e.g. the Tango app for a
/// `tango.me` link), falling back to the browser.
Future<bool> launchExternalUrl(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.platformDefault);
  } catch (_) {
    // No handler, or the platform refused: report it to the caller's onError
    // instead of crashing the frame.
    return false;
  }
}

class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.launcher,
    this.onError,
  });

  final String text;
  final TextStyle? style;

  /// Style applied to the link spans only. Defaults to the base style tinted
  /// with the theme primary colour and underlined.
  final TextStyle? linkStyle;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// Seam over the real launcher, for tests.
  final UrlLauncher? launcher;

  /// Called when a launch fails, so the caller can show a message.
  final void Function(Uri uri)? onError;

  @override
  State<LinkifiedText> createState() => LinkifiedTextState();
}

/// Public state so a test can read the taps it recorded.
class LinkifiedTextState extends State<LinkifiedText> {
  /// Every URL this instance attempted to open, in order. Exposed for tests.
  final List<Uri> launched = [];

  Future<void> _open(Uri uri) async {
    final launcher = widget.launcher ?? launchExternalUrl;
    final ok = await launcher(uri);
    if (!ok) {
      launched.add(uri);
      widget.onError?.call(uri);
      return;
    }
    launched.add(uri);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = widget.style ?? theme.textTheme.bodyMedium;
    final linkStyle = widget.linkStyle ??
        baseStyle?.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary.withValues(alpha: 0.6),
          fontWeight: FontWeight.w600,
        );

    final text = widget.text;
    final links = UrlDetector.detect(text);
    if (links.isEmpty) {
      return Text(
        text,
        style: baseStyle,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        textAlign: widget.textAlign,
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final link in links) {
      if (link.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, link.start)));
      }
      final uri = Uri.tryParse(link.url);
      spans.add(TextSpan(
        text: link.text,
        style: linkStyle,
        recognizer: uri == null
            ? null
            : (TapGestureRecognizer()..onTap = () => _open(uri)),
        // Semantic label so screen readers announce the link as actionable.
        semanticsLabel: 'Lien : ${link.url}',
      ));
      cursor = link.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
  }
}
