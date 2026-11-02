import 'nap_edits.dart';

/// One composition rule for normal derivation and a review after raw expiry.
/// Updates only nap-owned fields; measured night and daytime metrics survive.
void composeAcceptedNaps(Map<String, dynamic> bundle, List<NapEdit> edits) {
  final old = bundle['naps'] as Map?;
  if (old == null && edits.isEmpty) return;
  final sleep = bundle['sleep'];
  final metric = sleep is Map ? sleep['window'] : null;
  final window = metric is Map ? metric['value'] : null;
  final onset = window is Map ? window['onset_ms'] : null;
  final offset = window is Map ? window['offset_ms'] : null;
  final hasMainWindow =
      onset is num &&
      offset is num &&
      onset.isFinite &&
      offset.isFinite &&
      offset > onset;
  // A corrected main window can absorb an older detector's nap snapshot.
  // Suppress only fully contained snapshots, retaining the stored entry for
  // a later correction. Partial overlaps keep their recorded duration: the
  // snapshot has no stages to apportion sleep inside/outside the main window.
  // Manual/confirmed decisions still win.
  final accepted = applyNapEdits(const [], edits)
      .where(
        (nap) =>
            nap['source'] != 'legacy' ||
            !hasMainWindow ||
            (nap['start'] as num) * 1000 < onset ||
            (nap['end'] as num) * 1000 > offset,
      )
      .toList();
  // Whether the detector judged the day, persisted so a later compose cannot
  // turn an unjudged day into a measured zero once its logged naps are gone.
  // Rows from before the flag: an unjudged day only carried a value when the
  // user had logged one, stamped inputs_used [user].
  final inputs = old?['inputs_used'];
  final judged = (old?['assessment_complete'] as bool?) ??
      (old?['value'] != null &&
          !(inputs is List && inputs.length == 1 && inputs.first == 'user'));
  final assessed = judged || accepted.isNotEmpty;
  final minutes = assessed && accepted.every((n) => n['duration_min'] is num)
      ? napMinutes(accepted)
      : null;
  bundle['naps'] = <String, dynamic>{
    ...?old?.cast<String, dynamic>(),
    'value': assessed ? accepted : null,
    'count': assessed ? accepted.length : null,
    'note': judged ? 'Confirmed and logged naps only' : old?['note'],
    'assessment_complete': judged,
  };
  final scalars = Map<String, dynamic>.from((bundle['scalars'] as Map?) ?? {});
  scalars['nap_min'] = minutes?.toDouble();
  bundle['scalars'] = scalars;
  final previousSleep = bundle['sleep_periods'] as Map?;
  final previousPeriods = previousSleep?['periods'];
  // A list created from accepted snapshots is not evidence that the whole
  // day was assessed. Persist that distinction through retries and restarts.
  // A fresh derivation supplies its measured total and replaces this state.
  final assessmentComplete =
      (previousSleep?['assessment_complete'] as bool?) ??
      (previousSleep?['total_asleep_min'] is num);
  final periods = <Map<String, dynamic>>[
    if (previousPeriods is List)
      for (final p in previousPeriods.whereType<Map>())
        if (p['is_main'] == true) Map<String, dynamic>.from(p),
    for (final n in accepted)
      {
        'is_main': false,
        'onset_ts': n['start'],
        'wake_ts': n['end'],
        'duration_min': n['duration_min'],
        'in_bed_min': n['in_bed_min'],
        'efficiency': n['efficiency'],
        'confidence': n['confidence'],
        'source': n['source'],
      },
  ];
  final known =
      assessed &&
      assessmentComplete &&
      periods.every((p) => p['duration_min'] is num);
  bundle['sleep_periods'] = {
    'assessment_complete': assessmentComplete,
    'periods': periods,
    'total_asleep_min': known
        ? periods.fold<num>(0, (a, p) => a + (p['duration_min'] as num))
        : null,
  };
}
