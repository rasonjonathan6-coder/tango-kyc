/// Web stub for the temporary DNS diagnostic.
///
/// The diagnostic binds to `dart:io` sockets and an Android `MethodChannel`, so
/// it is a no-op wherever `dart:io` is unavailable (the web build). See
/// `dns_test_io.dart` for the real implementation.
library;

/// No-op on platforms without `dart:io`.
Future<void> runDnsDiagnostic() async {}
