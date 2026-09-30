/// Persisted user preferences.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsController extends ChangeNotifier {
  SettingsController(this._storage);

  final FlutterSecureStorage _storage;

  static const _themeKey = 'settings.theme_mode';
  static const _onboardingKey = 'settings.onboarding_done';

  /// Records that the notification-permission prompt was answered, so it is
  /// never shown twice. The stored value is the outcome (`authorized` or
  /// `dismissed`), written by [markNotificationPromptAnswered].
  static const _notifPromptKey = 'settings.notification_prompt_answered';

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  /// Whether the first-run onboarding has been completed or skipped.
  bool _onboardingDone = false;
  bool get onboardingDone => _onboardingDone;

  /// Whether the in-app notification-permission prompt was already shown and
  /// answered (either way).
  bool _notificationPromptAnswered = false;
  bool get notificationPromptAnswered => _notificationPromptAnswered;

  Future<void> load() async {
    final stored = await _storage.read(key: _themeKey);
    _themeMode = switch (stored) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    _onboardingDone = await _storage.read(key: _onboardingKey) == 'true';
    _notificationPromptAnswered =
        await _storage.read(key: _notifPromptKey) != null;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _storage.write(
      key: _themeKey,
      value: switch (mode) {
        ThemeMode.dark => 'dark',
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
      },
    );
  }

  /// Records that onboarding has been seen, so it is not shown again.
  Future<void> completeOnboarding() async {
    _onboardingDone = true;
    notifyListeners();
    await _storage.write(key: _onboardingKey, value: 'true');
  }

  /// Records that the notification-permission prompt was answered, whatever the
  /// user chose. This is what stops the prompt from nagging on every launch.
  Future<void> markNotificationPromptAnswered() async {
    _notificationPromptAnswered = true;
    notifyListeners();
    await _storage.write(key: _notifPromptKey, value: 'answered');
  }
}
