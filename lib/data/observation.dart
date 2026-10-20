// observation.dart — the type for a number Locus did not compute.
//
// Deliberately NOT `Metric`. `Metric` carries `tier`, `confidence` and
// `inputs_used`, and every one of those is a statement about OUR method: which
// published algorithm ran, over which inputs, with how much of the window
// present. A vendor's Body Battery has no method we can describe, a typed-in
// mood has none at all, and an Apple Health step count has someone else's.
// Giving any of them a tier would be inventing a provenance claim.
//
// Lives in `edge/` on purpose. `analytics/` never sees this type — it stays
// device-blind and computes only from raw signal (OBSERVATION_SPEC §4).
//
// NAME COLLISION, on purpose and worth knowing about: `ui2/grammar.dart` also
// declares an `Observation` — the clinician-worthy-pattern CARD. No file
// imports both today. A file that ever needs both must prefix one import;
// renaming either would be worse, because both names are the right word for
// what they are.

import 'day_label.dart' show dayLabelOf;

/// Where an observation came from — the `observation.source_kind` column.
///
/// An enum rather than a bare string because this value is part of the row's
/// identity (it is in the unique index), so a typo does not fail, it forks the
/// row into a second one that never collides with the first.
///
/// NOT derivable from the other fields, which is why it is carried explicitly:
/// an imported Apple Health step count and a typed-in mood both fill [key] and
/// leave [vendorKey] null, and they are not the same kind of thing.
enum ObservationSource {
  /// The band computed it on-device and shipped the conclusion.
  vendor,

  /// The user typed it in — food, a workout, mood, water.
  entered,

  /// Another app's history, adopted wholesale (Apple Health, a Takeout).
  imported,
}

/// One scalar Locus stores but did not derive.
///
/// Exactly one of [key] and [vendorKey] identifies the row, and at least one
/// MUST be set — the storage layer's unique index is built on
/// `COALESCE(vendor_key, key)` and a row with neither has no identity at all.
///
/// The split is the whole point, and it is the rule that stops `readiness`
/// meaning three different algorithms depending on which band was worn:
///
///  * [key] — OUR vocabulary, and ONLY for a **comparable quantity**: the same
///    physical thing measured a different way (steps, sleep duration, resting
///    HR).
///  * [vendorKey] — THEIR name, verbatim, forever, for a **proprietary
///    composite** (Body Battery, PAI, Recovery %, a sleep score). Mapping one
///    of those onto one of our keys is the worst available mistake here.
class Observation {
  const Observation({
    required this.sourceKind,
    required this.value,
    required this.attribution,
    required this.at,
    this.key,
    this.vendorKey,
    this.unit,
  }) : assert(
         key != null || vendorKey != null,
         'an observation with neither key nor vendorKey has no identity',
       );

  /// Our vocabulary — comparable quantities only. Null for a composite.
  final String? key;

  /// Their name, verbatim. Null for anything that is not a vendor's own.
  final String? vendorKey;

  final num value;

  /// Free text, as the vendor states it ('%', 'steps', 'bpm'). Null when the
  /// number is unitless — a sleep score out of 100 is not a measurement of
  /// anything and inventing a unit for it would imply it was.
  final String? unit;

  /// What the user sees next to the number: 'Amazfit', 'you', 'Apple Health'.
  /// A value without this is not renderable — the whole product posture for a
  /// `reports` device is that their number is shown as theirs.
  final String attribution;

  final DateTime at;

  /// The LOCAL calendar day this observation belongs to — the same day model
  /// every other table is keyed by, via the one helper that gets DST right.
  String get date => dayLabelOf(at);

  final ObservationSource sourceKind;
}
