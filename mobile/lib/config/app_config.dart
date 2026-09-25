/// Build-time configuration.
///
/// Values are read from `--dart-define` first, then from the bundled `assets/env`
/// file. Only non-secret values may appear here: the Supabase anon key is a
/// public client key protected by Row Level Security. The service-role key, the
/// email provider API key and the webhook signing secret live exclusively as
/// Edge Function secrets and must never be present in this application.
library;

import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  const AppConfig._();

  static const String _defineSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _defineSupabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Must match the redirect URL registered in Supabase Auth and Google Cloud.
  ///
  /// The scheme deliberately contains no underscore: Dart's `Uri` parser
  /// rejects underscore characters in a scheme, and `app_links` converts the
  /// incoming link with `Uri.tryParse`, so an underscore here would make every
  /// callback silently fail to arrive.
  static const String oauthRedirectUrl = 'com.tango.kyc.verification://login-callback';

  static String get supabaseUrl {
    final value = _defineSupabaseUrl.isNotEmpty
        ? _defineSupabaseUrl
        : (dotenv.isInitialized ? dotenv.env['SUPABASE_URL'] ?? '' : '');
    if (value.isEmpty) {
      throw StateError(
        'SUPABASE_URL is not configured. Pass --dart-define=SUPABASE_URL=... '
        'or add SUPABASE_URL to mobile/assets/env.',
      );
    }
    return value;
  }

  static String get supabaseAnonKey {
    final value = _defineSupabaseAnonKey.isNotEmpty
        ? _defineSupabaseAnonKey
        : (dotenv.isInitialized ? dotenv.env['SUPABASE_ANON_KEY'] ?? '' : '');
    if (value.isEmpty) {
      throw StateError(
        'SUPABASE_ANON_KEY is not configured. Pass --dart-define=SUPABASE_ANON_KEY=... '
        'or add SUPABASE_ANON_KEY to mobile/assets/env.',
      );
    }
    return value;
  }

  /// Loads the bundled env file when present. A missing file is not fatal
  /// because `--dart-define` values may have been supplied instead.
  static Future<void> load() async {
    try {
      await dotenv.load(fileName: 'assets/env');
    } on FileSystemException {
      // No bundled env file: rely on --dart-define.
    } catch (_) {
      // Malformed file: surface at first use rather than crashing at startup.
    }
  }

  static bool get isConfigured {
    final url = _defineSupabaseUrl.isNotEmpty
        ? _defineSupabaseUrl
        : (dotenv.isInitialized ? dotenv.env['SUPABASE_URL'] ?? '' : '');
    final key = _defineSupabaseAnonKey.isNotEmpty
        ? _defineSupabaseAnonKey
        : (dotenv.isInitialized ? dotenv.env['SUPABASE_ANON_KEY'] ?? '' : '');
    return url.isNotEmpty && key.isNotEmpty;
  }
}
