/// Temporary network diagnostics.
///
/// Records the exact type, HTTP status and raw text of an exception before it is
/// flattened into a user-facing string, so a "no connection" report can be tied
/// to the request that actually failed. Debug-only: nothing is emitted in a
/// release build.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Marks the start of a network call. [label] identifies the request.
void netStart(String label) {
  if (!kDebugMode) return;
  debugPrint('[net] START $label');
}

/// Marks the successful end of a network call.
void netEnd(String label) {
  if (!kDebugMode) return;
  debugPrint('[net] END $label');
}

/// Records a failure with the detail the UI layer discards.
void netError(String label, Object error) {
  if (!kDebugMode) return;
  debugPrint('[net] ERROR $label runtimeType=${error.runtimeType}');
  debugPrint('[net] ERROR $label raw=$error');
  if (error is PostgrestException) {
    debugPrint(
      '[net] ERROR $label http=${error.code} '
      'details=${error.details} hint=${error.hint}',
    );
  } else if (error is AuthException) {
    debugPrint('[net] ERROR $label http=${error.statusCode} code=${error.code}');
  } else if (error is FunctionException) {
    debugPrint('[net] ERROR $label http=${error.status} details=${error.details}');
  }
}
