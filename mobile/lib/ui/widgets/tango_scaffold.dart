/// The single scaffold every screen in the app is built on.
///
/// It exists to guarantee one thing: the master backdrop is painted once, at the
/// root, and every page simply shows through it. No screen defines its own
/// background, so the 18 screens cannot drift apart visually, and navigating
/// between them can never flash a different canvas.
///
/// The widget itself is deliberately thin — a transparent [Scaffold] wrapping
/// [AuroraBackground], which is a no-op when the root instance is already in
/// scope. Screens that already sat on an [AuroraBackground] keep behaving the
/// same; they just go through the shared component instead of rolling their own
/// `Scaffold` + backdrop pair.
library;

import 'package:flutter/material.dart';

import 'aurora.dart';

/// A page scaffold that inherits the app's master backdrop.
///
/// Use this instead of a bare [Scaffold] so the canvas is owned in one place.
class TangoKycScaffold extends StatelessWidget {
  const TangoKycScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
    this.safeArea = true,
    this.padding,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;

  /// Whether to wrap [body] in a [SafeArea]. Off for bodies that manage their
  /// own insets (for example a full-bleed image or a custom scroll view).
  final bool safeArea;

  /// Optional padding applied inside the [SafeArea].
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    Widget content = body;
    if (padding != null) content = Padding(padding: padding!, child: content);
    if (safeArea) content = SafeArea(child: content);

    return Scaffold(
      // Transparent everywhere so the one root backdrop shows through.
      backgroundColor: Colors.transparent,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      body: AuroraBackground(child: content),
    );
  }
}
