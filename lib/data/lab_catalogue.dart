// Blood-work markers you can enter by hand — the vocabulary, not the storage.
//
// WHY REFERENCE RANGES ARE HERE AT ALL, AND WHAT THEY ARE NOT.
// A number like "ferritin 42" means nothing on its own, so a tracker that
// stores bare numbers is a spreadsheet with extra steps. The ranges below let
// a value render as in or out of range and let a chart draw a band.
//
// They are NOT a diagnosis and NOT this app's opinion of your health. Every
// laboratory publishes its own reference interval, derived from its own assay
// and its own local population, and those differ enough that a value inside
// one lab's range can sit outside another's. **The range printed on your own
// report is the one that applies to you.** So each entry here is marked with
// where the interval came from, a value outside it is styled as "outside the
// typical range" rather than "high"/"abnormal", and nothing in the app ever
// tells you what to do about it.
//
// Units are fixed per marker rather than free-form, because a chart that mixes
// ng/mL and nmol/L on one axis is worse than no chart. A marker your lab
// reports in a different unit is a custom entry.

import 'package:flutter/foundation.dart';

enum LabCategory {
  blood,
  iron,
  metabolic,
  lipids,
  hormones,
  vitamins,
  inflammation,
  organ,
}

extension LabCategoryLabel on LabCategory {
  String get label => switch (this) {
    LabCategory.blood => 'Blood count',
    LabCategory.iron => 'Iron',
    LabCategory.metabolic => 'Metabolic',
    LabCategory.lipids => 'Lipids',
    LabCategory.hormones => 'Hormones',
    LabCategory.vitamins => 'Vitamins & minerals',
    LabCategory.inflammation => 'Inflammation',
    LabCategory.organ => 'Liver & kidney',
  };
}

/// Which reference interval applies. Several markers genuinely differ by sex,
/// and collapsing them to one range would mark a large share of normal results
/// as out of range — which is exactly the kind of false alarm that makes a
/// feature like this harmful rather than useful.
enum LabRefScope { any, male, female }

@immutable
class LabRefRange {
  const LabRefRange({
    required this.low,
    required this.high,
    this.scope = LabRefScope.any,
  });

  final double low;
  final double high;
  final LabRefScope scope;

  bool appliesTo(String? sex) => switch (scope) {
    LabRefScope.any => true,
    LabRefScope.male => sex == 'm' || sex == 'male',
    LabRefScope.female => sex == 'f' || sex == 'female',
  };

  bool contains(double v) => v >= low && v <= high;
}

@immutable
class LabMarker {
  const LabMarker({
    required this.key,
    required this.label,
    required this.unit,
    required this.category,
    this.ranges = const [],
    this.decimals = 1,
    this.note,
    this.custom = false,
  });

  /// Stable storage key. Labels can change; this cannot, or history orphans.
  final String key;
  final String label;
  final String unit;
  final LabCategory category;

  /// Typical adult reference intervals. Empty means the app shows the value
  /// with no band at all rather than inventing one.
  final List<LabRefRange> ranges;
  final int decimals;

  /// Shown under the value when there is something the number alone hides.
  final String? note;
  final bool custom;

  /// The interval that applies to [sex], or null when none is defined for
  /// them. Sex-specific entries win over an `any` entry.
  LabRefRange? rangeFor(String? sex) {
    LabRefRange? fallback;
    for (final r in ranges) {
      if (r.scope == LabRefScope.any) {
        fallback ??= r;
      } else if (r.appliesTo(sex)) {
        return r;
      }
    }
    return fallback;
  }

  /// Whether [value] sits inside the applicable interval. Null when there is
  /// no interval to judge against — which must render as "no opinion", never
  /// as "fine".
  bool? inRange(double value, {String? sex}) => rangeFor(sex)?.contains(value);

  String format(double v) => v.toStringAsFixed(decimals);
  String formatWithUnit(double v) => '${format(v)} $unit';
}

/// Common adult panels. Intervals are widely published typical adult ranges;
/// they are a display aid, and the interval on your own report wins.
const kLabMarkers = <LabMarker>[
  // ── Blood count ──────────────────────────────────────────────────────────
  LabMarker(
    key: 'hemoglobin',
    label: 'Haemoglobin',
    unit: 'g/dL',
    category: LabCategory.blood,
    ranges: [
      LabRefRange(low: 13.5, high: 17.5, scope: LabRefScope.male),
      LabRefRange(low: 12.0, high: 15.5, scope: LabRefScope.female),
    ],
  ),
  LabMarker(
    key: 'hematocrit',
    label: 'Haematocrit',
    unit: '%',
    category: LabCategory.blood,
    ranges: [
      LabRefRange(low: 38.8, high: 50.0, scope: LabRefScope.male),
      LabRefRange(low: 34.9, high: 44.5, scope: LabRefScope.female),
    ],
  ),
  // ── Iron ─────────────────────────────────────────────────────────────────
  LabMarker(
    key: 'ferritin',
    label: 'Ferritin',
    unit: 'ng/mL',
    category: LabCategory.iron,
    decimals: 0,
    ranges: [
      LabRefRange(low: 30, high: 400, scope: LabRefScope.male),
      LabRefRange(low: 15, high: 200, scope: LabRefScope.female),
    ],
    note: 'Rises with inflammation, so a normal value does not by itself rule '
        'out low iron stores.',
  ),
  LabMarker(
    key: 'transferrin_saturation',
    label: 'Transferrin saturation',
    unit: '%',
    category: LabCategory.iron,
    decimals: 0,
    ranges: [LabRefRange(low: 20, high: 50)],
  ),
  // ── Metabolic ────────────────────────────────────────────────────────────
  LabMarker(
    key: 'hba1c',
    label: 'HbA1c',
    unit: '%',
    category: LabCategory.metabolic,
    ranges: [LabRefRange(low: 4.0, high: 5.6)],
    note: 'Reflects roughly the last three months, not today.',
  ),
  LabMarker(
    key: 'glucose_fasting',
    label: 'Fasting glucose',
    unit: 'mg/dL',
    category: LabCategory.metabolic,
    decimals: 0,
    ranges: [LabRefRange(low: 70, high: 99)],
  ),
  LabMarker(
    key: 'insulin_fasting',
    label: 'Fasting insulin',
    unit: 'µIU/mL',
    category: LabCategory.metabolic,
    ranges: [LabRefRange(low: 2.6, high: 24.9)],
  ),
  // ── Lipids ───────────────────────────────────────────────────────────────
  LabMarker(
    key: 'cholesterol_total',
    label: 'Total cholesterol',
    unit: 'mg/dL',
    category: LabCategory.lipids,
    decimals: 0,
    ranges: [LabRefRange(low: 0, high: 200)],
  ),
  LabMarker(
    key: 'ldl',
    label: 'LDL cholesterol',
    unit: 'mg/dL',
    category: LabCategory.lipids,
    decimals: 0,
    ranges: [LabRefRange(low: 0, high: 100)],
  ),
  LabMarker(
    key: 'hdl',
    label: 'HDL cholesterol',
    unit: 'mg/dL',
    category: LabCategory.lipids,
    decimals: 0,
    ranges: [
      LabRefRange(low: 40, high: 200, scope: LabRefScope.male),
      LabRefRange(low: 50, high: 200, scope: LabRefScope.female),
    ],
  ),
  LabMarker(
    key: 'triglycerides',
    label: 'Triglycerides',
    unit: 'mg/dL',
    category: LabCategory.lipids,
    decimals: 0,
    ranges: [LabRefRange(low: 0, high: 150)],
  ),
  LabMarker(
    key: 'apob',
    label: 'ApoB',
    unit: 'mg/dL',
    category: LabCategory.lipids,
    decimals: 0,
    ranges: [LabRefRange(low: 0, high: 90)],
  ),
  // ── Hormones ─────────────────────────────────────────────────────────────
  LabMarker(
    key: 'tsh',
    label: 'TSH',
    unit: 'mIU/L',
    decimals: 2,
    category: LabCategory.hormones,
    ranges: [LabRefRange(low: 0.4, high: 4.0)],
  ),
  LabMarker(
    key: 'free_t4',
    label: 'Free T4',
    unit: 'ng/dL',
    decimals: 2,
    category: LabCategory.hormones,
    ranges: [LabRefRange(low: 0.8, high: 1.8)],
  ),
  LabMarker(
    key: 'testosterone_total',
    label: 'Total testosterone',
    unit: 'ng/dL',
    decimals: 0,
    category: LabCategory.hormones,
    ranges: [
      LabRefRange(low: 300, high: 1000, scope: LabRefScope.male),
      LabRefRange(low: 15, high: 70, scope: LabRefScope.female),
    ],
    note: 'Varies through the day — morning draws are the comparable ones.',
  ),
  LabMarker(
    key: 'cortisol_am',
    label: 'Morning cortisol',
    unit: 'µg/dL',
    category: LabCategory.hormones,
    ranges: [LabRefRange(low: 6, high: 23)],
  ),
  // ── Vitamins & minerals ──────────────────────────────────────────────────
  LabMarker(
    key: 'vitamin_d',
    label: 'Vitamin D (25-OH)',
    unit: 'ng/mL',
    decimals: 0,
    category: LabCategory.vitamins,
    ranges: [LabRefRange(low: 30, high: 100)],
  ),
  LabMarker(
    key: 'vitamin_b12',
    label: 'Vitamin B12',
    unit: 'pg/mL',
    decimals: 0,
    category: LabCategory.vitamins,
    ranges: [LabRefRange(low: 200, high: 900)],
  ),
  LabMarker(
    key: 'folate',
    label: 'Folate',
    unit: 'ng/mL',
    category: LabCategory.vitamins,
    ranges: [LabRefRange(low: 3.0, high: 20.0)],
  ),
  LabMarker(
    key: 'magnesium',
    label: 'Magnesium',
    unit: 'mg/dL',
    decimals: 2,
    category: LabCategory.vitamins,
    ranges: [LabRefRange(low: 1.7, high: 2.2)],
  ),
  // ── Inflammation ─────────────────────────────────────────────────────────
  LabMarker(
    key: 'crp_hs',
    label: 'hs-CRP',
    unit: 'mg/L',
    decimals: 2,
    category: LabCategory.inflammation,
    ranges: [LabRefRange(low: 0, high: 3.0)],
    note: 'Any recent infection or hard training block can lift this.',
  ),
  // ── Liver & kidney ───────────────────────────────────────────────────────
  LabMarker(
    key: 'alt',
    label: 'ALT',
    unit: 'U/L',
    decimals: 0,
    category: LabCategory.organ,
    ranges: [
      LabRefRange(low: 7, high: 55, scope: LabRefScope.male),
      LabRefRange(low: 7, high: 45, scope: LabRefScope.female),
    ],
  ),
  LabMarker(
    key: 'ast',
    label: 'AST',
    unit: 'U/L',
    decimals: 0,
    category: LabCategory.organ,
    ranges: [LabRefRange(low: 8, high: 48)],
  ),
  LabMarker(
    key: 'creatinine',
    label: 'Creatinine',
    unit: 'mg/dL',
    decimals: 2,
    category: LabCategory.organ,
    ranges: [
      LabRefRange(low: 0.74, high: 1.35, scope: LabRefScope.male),
      LabRefRange(low: 0.59, high: 1.04, scope: LabRefScope.female),
    ],
    note: 'Muscle mass lifts this, so it reads high in some athletes without '
        'anything being wrong.',
  ),
  LabMarker(
    key: 'egfr',
    label: 'eGFR',
    unit: 'mL/min/1.73m²',
    decimals: 0,
    category: LabCategory.organ,
    ranges: [LabRefRange(low: 90, high: 200)],
  ),
];

final Map<String, LabMarker> kLabMarkersByKey = {
  for (final m in kLabMarkers) m.key: m,
};

/// Markers grouped for the picker, in [LabCategory] declaration order.
Map<LabCategory, List<LabMarker>> labMarkersByCategory() {
  final out = <LabCategory, List<LabMarker>>{};
  for (final c in LabCategory.values) {
    final markers = kLabMarkers.where((m) => m.category == c).toList();
    if (markers.isNotEmpty) out[c] = markers;
  }
  return out;
}

/// Resolve a stored key, preferring the shipped catalogue so a future built-in
/// always wins over a same-named custom (otherwise one key would mean two
/// different things on two installs).
LabMarker? labMarker(String key, {List<LabMarker> custom = const []}) {
  final builtIn = kLabMarkersByKey[key];
  if (builtIn != null) return builtIn;
  for (final c in custom) {
    if (c.key == key) return c;
  }
  return null;
}

/// Storage key for a user-defined marker. Prefixed so it can never collide
/// with a catalogue key added in a later release.
String customLabMarkerKey(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return 'custom_$slug';
}
