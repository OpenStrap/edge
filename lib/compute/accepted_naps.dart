import 'nap_edits.dart';

/// One composition rule for normal derivation and a review after raw expiry.
/// Updates only nap-owned fields; measured night and daytime metrics survive.
void composeAcceptedNaps(Map<String, dynamic> bundle, List<NapEdit> edits) {
  final old = bundle['naps'] as Map?;
  if (old == null && edits.isEmpty) return;
  final accepted = applyNapEdits(const [], edits);
  final assessed = old?['value'] != null || accepted.isNotEmpty;
  final minutes = assessed && accepted.every((n) => n['duration_min'] is num)
      ? napMinutes(accepted)
      : null;
  bundle['naps'] = <String, dynamic>{
    ...?old?.cast<String, dynamic>(),
    'value': assessed ? accepted : null,
    'count': assessed ? accepted.length : null,
    'note': assessed ? 'Confirmed and logged naps only' : old?['note'],
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
