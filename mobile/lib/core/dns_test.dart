/// Temporary DNS diagnostic entry point.
///
/// Selects the real `dart:io`/Android implementation on native builds and a
/// no-op on the web, so the app compiles for the browser without changing the
/// Android diagnostic. Debug-only: nothing is emitted in a release build.
library;

export 'dns_test_stub.dart' if (dart.library.io) 'dns_test_io.dart';
