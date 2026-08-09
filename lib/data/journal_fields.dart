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

import 'package:flutter/foundation.dart';

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
];

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
