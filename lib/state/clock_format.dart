// Clock format: a local display preference (system / 24-hour / 12-hour),
// persisted like UnitsController. Display only; stored, exported and coach
// values stay `HH:mm`. The formatters are context-free and read the last
// controller built, falling back to the OS setting when there is none.

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;
import 'package:shared_preferences/shared_preferences.dart';

enum ClockFormat { system, h24, h12 }

extension ClockFormatLabel on ClockFormat {
  String get label => switch (this) {
        ClockFormat.system => 'System',
        ClockFormat.h24 => '24-hour',
        ClockFormat.h12 => '12-hour',
      };
}

class ClockFormatController extends ChangeNotifier {
  static const String _kClockFormat = 'clock_format'; // 'system'|'h24'|'h12'

  static ClockFormatController? _active;

  ClockFormat _format;
  ClockFormatController._(this._format) {
    _active = this;
  }

  factory ClockFormatController.seed(ClockFormat f) =>
      ClockFormatController._(f);

  static Future<ClockFormatController> bootstrap({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final prefs = await SharedPreferences.getInstance().timeout(timeout);
    return ClockFormatController._(_parse(prefs.getString(_kClockFormat)));
  }

  /// An unknown stored value (an older build, a hand-edited pref) is "system".
  static ClockFormat _parse(String? s) => ClockFormat.values
      .firstWhere((f) => f.name == s, orElse: () => ClockFormat.system);

  ClockFormat get format => _format;

  /// Whether [format] resolves to 24-hour, given the OS's own answer.
  bool resolve24h(bool systemUse24h) => switch (_format) {
        ClockFormat.system => systemUse24h,
        ClockFormat.h24 => true,
        ClockFormat.h12 => false,
      };

  Future<void> setFormat(ClockFormat f) async {
    if (_format == f) return;
    _format = f;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kClockFormat, f.name);
  }

  /// Tapped through in place, like Units and Appearance.
  Future<void> cycle() => setFormat(
      ClockFormat.values[(_format.index + 1) % ClockFormat.values.length]);

  /// Tests only: forget the active controller so the next test starts from
  /// the OS setting again.
  @visibleForTesting
  static void debugReset() {
    _active = null;
    _localizations = null;
  }
}

/// The app locale's AM/PM text and 12-hour order, bound by the app's clock
/// scope. Null (no app yet, a background isolate) falls back to English.
MaterialLocalizations? _localizations;

void bindClockLocalizations(MaterialLocalizations? l) => _localizations = l;

/// Whether clock times render 24-hour right now: the user's choice, or the
/// OS's "use 24-hour format" when the choice is "system" (or no controller
/// exists in this isolate).
bool get use24HourClock {
  final system = _systemUse24h();
  return ClockFormatController._active?.resolve24h(system) ?? system;
}

/// The OS setting, via the binding's dispatcher when there is one (the one
/// MediaQuery reads).
bool _systemUse24h() {
  try {
    return WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat;
  } catch (_) {
    return PlatformDispatcher.instance.alwaysUse24HourFormat;
  }
}

/// Hour + minute → "07:05" or "7:05 AM" (the locale's AM/PM), per
/// [use24HourClock].
String formatClock(int hour, int minute) {
  final mm = minute.toString().padLeft(2, '0');
  if (use24HourClock) return '${hour.toString().padLeft(2, '0')}:$mm';
  final h = hour % 12 == 0 ? 12 : hour % 12;
  final l = _localizations;
  final period = hour < 12
      ? (l?.anteMeridiemAbbreviation ?? 'AM')
      : (l?.postMeridiemAbbreviation ?? 'PM');
  // A 24-hour-native locale (de, fr, es) has no 12-hour order of its own, so
  // the period goes after, as in English.
  return l?.timeOfDayFormat() == TimeOfDayFormat.a_space_h_colon_mm
      ? '$period $h:$mm'
      : '$h:$mm $period';
}

/// The time of day of [d], as [formatClock].
String formatClockOf(DateTime d) => formatClock(d.hour, d.minute);

/// Local minutes past midnight, as [formatClock]. Wraps past 24 h.
String formatClockMinute(int minuteOfDay) {
  final m = minuteOfDay % 1440; // Dart's % is never negative here
  return formatClock(m ~/ 60, m % 60);
}

/// The time picker only takes `alwaysUse24HourFormat` as a way to force
/// 24-hour; `false` leaves a 24-hour-native locale (de, es, fr) on its 24-hour
/// dial. When the clock resolves to 12-hour this hands those locales the same
/// translations with a 12-hour order, so pickers match [formatClock].
class ClockMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const ClockMaterialLocalizationsDelegate({required this.twelveHour});
  final bool twelveHour;

  // ponytail: only the 24-hour-native languages the app ships; a new one
  // falls through to the stock delegate (24-hour dial) until listed here.
  static const _langs = {'de', 'es', 'fr'};

  @override
  bool isSupported(Locale locale) =>
      twelveHour && _langs.contains(locale.languageCode);

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    // Loads intl's date symbols (cached), which the formats below need.
    GlobalMaterialLocalizations.delegate.load(locale);
    final n = locale.languageCode;
    final make = switch (n) {
      'de' => _De12.new,
      'es' => _Es12.new,
      _ => _Fr12.new,
    };
    return SynchronousFuture(make(
      fullYearFormat: intl.DateFormat.y(n),
      compactDateFormat: intl.DateFormat.yMd(n),
      shortDateFormat: intl.DateFormat.yMMMd(n),
      mediumDateFormat: intl.DateFormat.MMMEd(n),
      longDateFormat: intl.DateFormat.yMMMMEEEEd(n),
      yearMonthFormat: intl.DateFormat.yMMMM(n),
      shortMonthDayFormat: intl.DateFormat.MMMd(n),
      decimalFormat: intl.NumberFormat.decimalPattern(n),
      twoDigitZeroPaddedFormat: intl.NumberFormat('00', n),
    ));
  }

  @override
  bool shouldReload(ClockMaterialLocalizationsDelegate old) =>
      old.twelveHour != twelveHour;
}

mixin _TwelveHour on GlobalMaterialLocalizations {
  @override
  TimeOfDayFormat get timeOfDayFormatRaw => TimeOfDayFormat.h_colon_mm_space_a;
}

class _De12 = MaterialLocalizationDe with _TwelveHour;
class _Es12 = MaterialLocalizationEs with _TwelveHour;
class _Fr12 = MaterialLocalizationFr with _TwelveHour;
