// The numeric half of a journal entry — the vocabulary, not the storage.
//
// `journal` holds a tag set and a note, which can only ever answer "did this
// happen today". These fields carry a NUMBER, and the number is usually the
// question: one coffee and five coffees are not the same day, and a tag cannot
// tell them apart.
//
// Built-in fields live in [kJournalFields] as a plain constant table, the same
// shape as the workout-type table — extend it HERE, never with a local map in
// a screen. User-invented fields carry their own [JournalFieldSpec] loaded
// from the database, so a custom field behaves exactly like a built-in one
// everywhere downstream.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'day_label.dart';

/// What a field measures, which decides how it is entered and read back.
enum JournalFieldKind {
  /// A subjective 1–5 self-report (mood, sleep quality). Ordinal: the gap
  /// between 3 and 4 is not claimed to equal the gap between 4 and 5, which is
  /// exactly why the correlation over these is rank-based.
  rating,

  /// A physical quantity with a unit (ml, mg, units).
  dose,

  /// Minutes.
  duration,
}

/// One day's value for one field.
@immutable
class JournalMetricValue {
  const JournalMetricValue(this.value, {this.atMinuteOfDay});

  /// The day's total for a dose, or the day's single reading for a rating.
  final double value;

  /// Local minutes past midnight for the LATEST occurrence, or null when the
  /// field has no meaningful time. Held because when a dose landed often
  /// matters more than how big it was — the sleep-relevant fact about caffeine
  /// is the last cup, not the total.
  final int? atMinuteOfDay;

  @override
  bool operator ==(Object other) =>
      other is JournalMetricValue &&
      other.value == value &&
      other.atMinuteOfDay == atMinuteOfDay;

  @override
  int get hashCode => Object.hash(value, atMinuteOfDay);

  @override
  String toString() => 'JournalMetricValue($value, at: $atMinuteOfDay)';
}

@immutable
class JournalFieldSpec {
  const JournalFieldSpec({
    required this.key,
    required this.label,
    required this.kind,
    required this.unit,
    required this.max,
    required this.step,
    this.hasTime = false,
    this.custom = false,
  });

  /// Stored `field` value. Lowercase and stable — renaming one orphans its
  /// history, so labels change freely and keys never do.
  final String key;
  final String label;
  final JournalFieldKind kind;

  /// Shown after the number; empty for ratings.
  final String unit;

  /// Entry ceiling. Not a physiological claim — it exists so a slip on a
  /// stepper cannot enter 40 coffees and quietly dominate every correlation
  /// that field appears in.
  final double max;

  /// Increment for one tap of the stepper.
  final double step;

  /// Whether the field offers a "last one at" time.
  final bool hasTime;

  /// User-invented rather than built in.
  final bool custom;

  bool get isRating => kind == JournalFieldKind.rating;

  /// Human-readable value, without the unit.
  String format(double v) {
    if (isRating) return v.round().toString();
    // Doses are entered on whole steps, so a trailing .0 is noise.
    return v == v.roundToDouble()
        ? v.round().toString()
        : v.toStringAsFixed(1);
  }

  String formatWithUnit(double v) =>
      unit.isEmpty ? format(v) : '${format(v)} $unit';
}

/// The built-in fields, in the order the editor shows them.
///
/// Ratings run 1–5 rather than 1–10: a ten-point self-report is not ten
/// distinguishable states, and the extra resolution is noise that a rank
/// correlation then has to see through.
const kJournalFields = <JournalFieldSpec>[
  JournalFieldSpec(
    key: 'mood',
    label: 'Mood',
    kind: JournalFieldKind.rating,
    unit: '',
    max: 5,
    step: 1,
  ),
  JournalFieldSpec(
    key: 'sleep_quality',
    label: 'Sleep quality',
    kind: JournalFieldKind.rating,
    unit: '',
    max: 5,
    step: 1,
  ),
  JournalFieldSpec(
    key: 'energy',
    label: 'Energy',
    kind: JournalFieldKind.rating,
    unit: '',
    max: 5,
    step: 1,
  ),
  JournalFieldSpec(
    key: 'stress',
    label: 'Stress',
    kind: JournalFieldKind.rating,
    unit: '',
    max: 5,
    step: 1,
  ),
  JournalFieldSpec(
    key: 'soreness',
    label: 'Soreness',
    kind: JournalFieldKind.rating,
    unit: '',
    max: 5,
    step: 1,
  ),
  JournalFieldSpec(
    key: 'water_ml',
    label: 'Water',
    kind: JournalFieldKind.dose,
    unit: 'ml',
    max: 6000,
    step: 250,
  ),
  // Caffeine is the field the timing support exists for. A 200 mg morning
  // coffee and a 200 mg evening one are the same dose and a completely
  // different night, and collapsing them loses the only part that predicts
  // anything.
  JournalFieldSpec(
    key: 'caffeine_mg',
    label: 'Caffeine',
    kind: JournalFieldKind.dose,
    unit: 'mg',
    max: 1000,
    step: 25,
    hasTime: true,
  ),
  JournalFieldSpec(
    key: 'alcohol_units',
    label: 'Alcohol',
    kind: JournalFieldKind.dose,
    unit: 'units',
    max: 20,
    step: 1,
    hasTime: true,
  ),
  JournalFieldSpec(
    key: 'screens_min',
    label: 'Screens before bed',
    kind: JournalFieldKind.duration,
    unit: 'min',
    max: 480,
    step: 15,
  ),
  // MT-03 — WEIGHT AS A SERIES, not a profile field.
  //
  // HealthKit/Health Connect WEIGHT is read once at profile import and
  // collapsed to a single scalar, so Mifflin BMR is pinned to whatever you
  // weighed on install day forever. `journal_metric` is already (date, field,
  // value) with a field-first index and CSV export, so this one row gets
  // storage, editor, chart and correlation without a table.
  //
  // ENTERED, NEVER MEASURED, and labelled that way wherever it appears. Read
  // the ceiling before building anything on it: this is the most
  // eating-disorder-adjacent surface in the app and it must never EMIT.
  //   * Render [weightTrendEwma], NOT the raw readings — day-to-day scale
  //     noise is water and glycogen at ±1-2 kg and a raw line makes that read
  //     as change.
  //   * Show gaps. Never interpolate one.
  //   * No goal weight, no daily prompt, no red/green, no "you gained"
  //     notification, no body fat, no lean mass, no metabolic age.
  //   * BMR keeps reading the onboarding scalar for now — see the note on
  //     [weightTrendEwma].
  JournalFieldSpec(
    key: 'weight_kg',
    label: 'Weight',
    kind: JournalFieldKind.dose,
    unit: 'kg',
    max: 400,
    step: 0.1,
  ),
];

/// Half-life of the weight trend, in days.
///
/// A week is long enough that a salty dinner does not move the line and short
/// enough that a real four-week change is visible by the end of it.
const double kWeightTrendHalfLifeDays = 7;

/// The EWMA trend through a set of dated weight readings — THE thing to draw.
///
/// [byDay] is keyed by 'YYYY-MM-DD'. The output has one entry per day that
/// actually had a reading, in date order: gaps stay gaps, because a smoothed
/// line drawn across a fortnight nobody weighed is a fortnight of invented
/// data. The decay is by ELAPSED DAYS, not by position in the list, so two
/// readings a month apart do not smooth into each other the way two
/// consecutive ones do.
///
/// NOT WIRED TO BMR, deliberately. Changing the BMR input recomputes every
/// historical calorie number in the app, so that lands on its own commit where
/// a regression is attributable. And the calorie-model calibration from a
/// weight-drift residual is DROPPED, not deferred: the noise band on a weekly
/// delta (~±1 kg) is several times the signal a 2 400 kcal weekly imbalance
/// produces (~0.3 kg), so "your balance says −2 400 and you didn't move, so
/// the model is off for you" would be false more often than true.
Map<String, double> weightTrendEwma(
  Map<String, double> byDay, {
  double halfLifeDays = kWeightTrendHalfLifeDays,
}) {
  final days = byDay.keys.toList()..sort();
  final out = <String, double>{};
  double? ewma;
  DateTime? prev;
  for (final day in days) {
    final d = DateTime.tryParse(day);
    final v = byDay[day];
    if (d == null || v == null || !v.isFinite) continue;
    if (ewma == null || prev == null) {
      ewma = v;
    } else {
      // Calendar days: a spring-forward day is 23 h, which inDays floors to 0
      // and gives the new reading no weight at all.
      final gap =
          calendarDaysBetween(prev, d).abs().clamp(0, 3650).toDouble();
      // Weight of the new reading after `gap` days of decay. One day at a
      // 7-day half-life is ~0.094; a month is ~0.95, i.e. after a long gap the
      // trend restarts from the reading rather than dragging the old one in.
      final w = 1 - math.pow(0.5, gap / halfLifeDays).toDouble();
      ewma = ewma + w * (v - ewma);
    }
    prev = d;
    out[day] = ewma;
  }
  return out;
}

/// Built-ins by key, for a lookup that does not walk the list.
final Map<String, JournalFieldSpec> kJournalFieldsByKey = {
  for (final f in kJournalFields) f.key: f,
};

/// Resolve a stored field key to its spec, preferring built-ins.
///
/// Returns null for a key with no definition at all — a field whose custom
/// definition was deleted while its history remained. Callers must render
/// those as raw values rather than inventing a unit for them.
JournalFieldSpec? journalFieldSpec(
  String key, {
  List<JournalFieldSpec> custom = const [],
}) {
  final builtIn = kJournalFieldsByKey[key];
  if (builtIn != null) return builtIn;
  for (final c in custom) {
    if (c.key == key) return c;
  }
  return null;
}

/// A stable storage key for a user-invented field name.
///
/// Prefixed so a custom field can never collide with a built-in one, present
/// or future: adding `magnesium` to [kJournalFields] later must not silently
/// adopt somebody's existing custom column and reinterpret its units.
String customJournalFieldKey(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return 'custom_$slug';
}

/// Local minutes past midnight → "7:05 AM".
String formatMinuteOfDay(int minuteOfDay) {
  final m = minuteOfDay % (24 * 60);
  final h24 = m ~/ 60;
  final mm = (m % 60).toString().padLeft(2, '0');
  final h = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h:$mm ${h24 < 12 ? 'AM' : 'PM'}';
}
