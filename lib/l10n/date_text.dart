import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app_localizations.dart';

bool _dateDataLoaded = false;

/// Also works in standalone share cards without the app's localization loader.
String localizedDate(
  DateTime date,
  String code, {
  bool weekday = false,
  String? pattern,
}) {
  if (!_dateDataLoaded) {
    // The bundled local initializer installs symbols and patterns synchronously,
    // then returns an already-completed Future; it performs no I/O.
    unawaited(initializeDateFormatting());
    _dateDataLoaded = true;
  }
  final locale = DateFormat.localeExists(code) ? code : 'en';
  if (pattern != null) return DateFormat(pattern, locale).format(date);
  if (weekday) {
    final result = DateFormat('EEEE, d MMMM', locale).format(date);
    return '${result[0].toUpperCase()}${result.substring(1)}';
  }
  return DateFormat.yMMMd(locale).format(date);
}

String displayDate(BuildContext context, DateTime date) => localizedDate(
  date,
  AppLocalizations.of(context)?.localeName ??
      Localizations.localeOf(context).languageCode,
);

String displayDay(String? day, AppLocalizations? l, {bool weekday = false}) {
  final date = day == null ? null : DateTime.tryParse(day);
  return date == null
      ? day ?? ''
      : localizedDate(date, l?.localeName ?? 'en', weekday: weekday);
}
