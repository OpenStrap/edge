// Theme controller — owns the user's appearance choice (System / Light / Dark),
// tracks the OS brightness, and resolves the two into the *effective* mode that
// MaterialApp paints. It keeps [AppColors.active] in lockstep (set synchronously
// before notifying) so the 546 `AppColors.x` call sites always resolve to the
// mode being rendered, and it drives the system status-bar icon brightness.
//
// First launch follows the OS: if the phone is in dark mode, OpenStrap opens in
// "Ember on Char" from the login/signup screen onward. The choice is persisted
// and editable later from onboarding and Profile; UI updates live on change.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widget/widget_service.dart';
import 'tokens.dart';
import 'theme.dart';

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
    _applyActive(); // make AppColors.active correct immediately
  }

  /// Build synchronously from already-loaded inputs (used by [bootstrap]).
  factory ThemeController.seed(AppThemeChoice choice, Brightness platform) =>
      ThemeController._(choice, platform);

  /// Load the persisted choice + current OS brightness and set [AppColors.active]
  /// BEFORE the first frame. Call from main() before runApp so login/signup
  /// already render in the right mode.
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
  /// rendered brightness can never drift from [AppColors.active].
  ThemeMode get materialThemeMode =>
      isDark ? ThemeMode.dark : ThemeMode.light;

  ThemeData get lightTheme => buildOpenStrapTheme(kLightPalette);
  ThemeData get darkTheme => buildOpenStrapTheme(kDarkPalette);

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
    AppColors.active = isDark ? kDarkPalette : kLightPalette;
    // Keep the iOS widget + Live Activity in the same mode (best-effort).
    WidgetService.setThemeDark(isDark);
  }

  void _applySystemChrome() {
    // Status-bar (and Android nav-bar) icon brightness must oppose the surface.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ));
  }
}
