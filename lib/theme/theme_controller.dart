// Theme controller — owns the user's appearance choice (System / Light / Dark),
// tracks the OS brightness, and resolves the two into the *effective* mode that
// MaterialApp paints. Screens read their palette from the theme through
// `P.of(context)` (lib/ui2/theme.dart), so there is no global colour state to
// keep in step; this drives the system bars and the iOS widget's mode.
//
// First launch follows the OS: if the phone is in dark mode, Locus opens in
// Char (Volt's dark) from the first screen onward. The choice is persisted and
// editable later from Profile; UI updates live on change.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui2/theme.dart' show P;
import '../widget/widget_service.dart';

/// What the user picked. `system` defers to the OS brightness.
enum AppThemeChoice { system, light, dark }

extension AppThemeChoiceLabel on AppThemeChoice {
  String get label => switch (this) {
        AppThemeChoice.system => 'System',
        AppThemeChoice.light => 'Light',
        AppThemeChoice.dark => 'Dark',
      };
}

class ThemeController extends ChangeNotifier {
  static const String _kChoice = 'theme_choice'; // 'system' | 'light' | 'dark'

  AppThemeChoice _choice;
  Brightness _platform;

  ThemeController._(this._choice, this._platform) {
    _applyActive();
  }

  /// Build synchronously from already-loaded inputs (used by [bootstrap]).
  factory ThemeController.seed(AppThemeChoice choice, Brightness platform) =>
      ThemeController._(choice, platform);

  /// Load the persisted choice + current OS brightness BEFORE the first frame.
  /// Call from main() before runApp so the first screen already renders in
  /// the right mode.
  static Future<ThemeController> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final choice = _parse(prefs.getString(_kChoice));
    final platform =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final c = ThemeController._(choice, platform);
    c._applySystemChrome();
    return c;
  }

  static AppThemeChoice _parse(String? s) => switch (s) {
        'light' => AppThemeChoice.light,
        'dark' => AppThemeChoice.dark,
        _ => AppThemeChoice.system,
      };

  AppThemeChoice get choice => _choice;

  /// The brightness actually being rendered.
  Brightness get effective => switch (_choice) {
        AppThemeChoice.light => Brightness.light,
        AppThemeChoice.dark => Brightness.dark,
        AppThemeChoice.system => _platform,
      };

  bool get isDark => effective == Brightness.dark;

  /// We resolve `system` ourselves and hand MaterialApp an explicit mode, so the
  /// rendered brightness can never drift from [effective].
  ThemeMode get materialThemeMode =>
      isDark ? ThemeMode.dark : ThemeMode.light;


  /// User picked a mode (onboarding / profile). Updates live + persists.
  Future<void> setChoice(AppThemeChoice choice) async {
    if (_choice == choice) return;
    _choice = choice;
    _applyActive();
    _applySystemChrome();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kChoice, choice.name);
  }

  /// Called when the OS brightness changes (only matters under `system`).
  void updatePlatformBrightness(Brightness b) {
    if (_platform == b) return;
    _platform = b;
    if (_choice == AppThemeChoice.system) {
      _applyActive();
      _applySystemChrome();
      notifyListeners();
    }
  }

  void _applyActive() {
    // Keep the iOS widget + Live Activity in the same mode (best-effort).
    WidgetService.setThemeDark(isDark);
  }

  void _applySystemChrome() {
    // Status-bar (and Android nav-bar) icon brightness must oppose the surface.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      // The page colour, so the Android nav bar is one surface with the app.
      // It was the legacy Ember `bg`, which matched nothing on screen.
      systemNavigationBarColor: P(isDark).bg,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ));
  }
}
