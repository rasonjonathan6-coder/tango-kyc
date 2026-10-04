/// Temporary diagnostics for the email one-time-code flow.
///
/// The flow can fail at two distinct points — the request to send the code and
/// the verification of the code — and the user-facing copy deliberately hides
/// which. These helpers record the type and, for an API rejection, the HTTP
/// status and server error code, so a device report can be tied to the request
/// that actually failed. Nothing else is emitted: never the address, the code,
/// the session, or any key. Debug-only, so a release build stays silent.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void otpStartSend() => _log('[otp] START send');

void otpSendSucceeded() => _log('[otp] send_result=success');

void otpSendFailed(Object error) => _logApi('[otp] send_result=error', error);

/// A verification attempt that the server rejected. A wrong and an expired code
/// are reported identically, so only the failure shape is logged, never a guess
/// at which it was.
void otpVerifyRejected(Object error) => _logApi('[otp] verify_result=error', error);

void _log(String message) {
  if (!kDebugMode) return;
  debugPrint(message);
}

void _logApi(String prefix, Object error) {
  if (!kDebugMode) return;
  debugPrint('$prefix error_type=${error.runtimeType}');
  if (error is AuthApiException) {
    debugPrint('$prefix error_status=${error.statusCode} error_code=${error.code}');
  } else if (error is AuthException) {
    debugPrint('$prefix error_status=${error.statusCode} error_code=${error.code}');
  } else {
    debugPrint('$prefix error_message=${error.toString()}');
  }
}
