// Locale controller — the user's language override (or "System default").
// Persisted on-device via SharedPreferences, mirroring ThemeController /
// UnitsController. Null means follow the OS locale.

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

class LocaleController extends ChangeNotifier {
  static const String _kLocale = 'locale_override'; // language code, e.g. 'es'

  String? _code;
  static LocaleController? _active;
  LocaleController._(this._code);

  /// Bind the controller actually provided to the app, not a bootstrap probe.
  void useForPresentation() {
    _active = this;
  }

  /// The app root binds its controller once per UI isolate. Creating another
  /// controller (including a late bootstrap) does not change this override.
  /// This affects presentation only; storage and calculation units stay invariant.
  static String get displayLanguageCode {
    final supported = AppLocalizations.supportedLocales
        .map((l) => l.languageCode).toSet();
    final override = _active?._code;
    if (override != null) return supported.contains(override) ? override : 'en';
    for (final locale in WidgetsBinding.instance.platformDispatcher.locales) {
      if (supported.contains(locale.languageCode)) return locale.languageCode;
    }
    return 'en';
  }

  /// The language for text rendered outside the widget tree (OS
  /// notifications). A headless entry (background sync, BGTask, the Android
  /// service engine) never builds the app root, so nothing is bound and
  /// [displayLanguageCode] would fall through to the phone's language — wrong
  /// for anyone who picked a different language in the app. Read the saved
  /// override instead, with the same validation as [bootstrap]. Never throws.
  static Future<String> presentationLanguageCode() async {
    if (_active != null) return displayLanguageCode;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Another isolate (the UI) may have changed the setting since this
      // isolate first cached the store.
      await prefs.reload();
      final code = _validCode(prefs.getString(_kLocale));
      if (code != null) return code;
    } catch (_) {}
    return displayLanguageCode;
  }

  static String? _validCode(String? stored) =>
      AppLocalizations.supportedLocales.any((l) => l.languageCode == stored)
      ? stored
      : null;

  factory LocaleController.seed(String? code) => LocaleController._(code);

  static Future<LocaleController> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kLocale);
    // A locale dropped from AppLocalizations.supportedLocales (or from a
    // stale build) has no row in the picker — fall back to system default
    // rather than showing a selection nothing matches.
    return LocaleController._(_validCode(stored));
  }

  @override
  void dispose() {
    // An older test/app instance must not clear a newer controller's override.
    if (identical(_active, this)) _active = null;
    super.dispose();
  }

  /// null = system default.
  String? get code => _code;
  Locale? get locale => _code == null ? null : Locale(_code!);

  Future<void> setCode(String? code) async {
    if (_code == code) return;
    _code = code;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (code == null) {
      await prefs.remove(_kLocale);
    } else {
      await prefs.setString(_kLocale, code);
    }
  }
}
