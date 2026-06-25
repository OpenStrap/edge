// Pure unit test for the cross-day analytics rollup (crossday_pipeline.dart).
//
// buildCrossDayBundle is a pure, isolate-safe function: given a time-ordered
// (oldest-first) list of per-day records + a profile, it runs every cross-day
// analytics family ONCE and returns a JSON-safe map. We feed it ~30 synthetic
// days and assert structure, the load metric, the illness/anomaly seams, that an
// injected RHR spike trips the illness flag, and that absent inputs degrade to
// honest absent envelopes (never a thrown exception, never a fabricated number).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';

/// Build a synthetic oldest-first day series anchored on a fixed calendar date
/// so the free/work weekday split is deterministic.
List<Map<String, dynamic>> _synthDays(
  int n, {
  bool rhrSpikeLast = false,
  bool withTrimp = true,
  bool withSleep = true,
}) {
  final days = <Map<String, dynamic>>[];
  // 2024-01-01 was a Monday — gives a clean run of weekdays + weekends.
  var dt = DateTime(2024, 1, 1);
  for (var i = 0; i < n; i++) {
    final date =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    // Gentle deterministic variation (no Random — keeps the test reproducible).
    final wobble = (i % 5) - 2; // -2..2
    var rhr = 55.0 + wobble; // bpm
    final rmssd = 45.0 + wobble * 1.5; // ms
    final readiness = 70.0 + wobble * 2.0; // 0..100
    final resp = 14.0 + wobble * 0.3; // br/min
    final temp = wobble * 0.4; // relative z
    final trimp = 80.0 + (i % 7) * 10.0; // load

    // Inject a sustained RHR spike on the final few days.
    if (rhrSpikeLast && i >= n - 4) rhr = 75.0 + wobble;

    // Sleep ~23:00 -> 07:00 (onset 23h, wake 31h next day in seconds-of-day axis).
    final onsetSec = 23 * 3600; // 82800
    final wakeSec = 31 * 3600; // 111600 (07:00 next day)
    final tstMin = 8 * 60 - 30; // ~7.5 h asleep

    days.add({
      'date': date,
      'rhr': rhr,
      'rmssd': rmssd,
      'readiness': readiness,
      'resp_rate': resp,
      'skin_temp_z': temp,
      if (withTrimp) 'trimp': trimp,
      if (withSleep) 'onset_sec': onsetSec,
      if (withSleep) 'wake_sec': wakeSec,
      if (withSleep) 'tst_min': tstMin,
      if (withSleep)
        'hypnogram': [
          // start/end are epoch SECONDS; map mod-day to clock minutes.
          {'start': onsetSec, 'end': wakeSec, 'stage': 'nrem'},
        ],
    });
    dt = dt.add(const Duration(days: 1));
  }
  return days;
}

void main() {
  group('buildCrossDayBundle', () {
    test('returns a well-formed map with all family keys', () {
      final days = _synthDays(30);
      final out = buildCrossDayBundle(days, const {});

      expect(out, isA<Map<String, dynamic>>());
      expect(out['computed_at_marker'], true);
      expect(out['n_days'], 30);

      // Every family seam is present (value-or-null / envelope), no exceptions.
      for (final k in [
        'illness',
        'anomaly',
        'temp_illness',
        'load',
        'regularity',
        'social_jetlag',
        'chronotype',
        'sleep_debt',
        'readiness_glassbox',
        'brv',
        'percentiles',
        'recent',
      ]) {
        expect(out.containsKey(k), isTrue, reason: 'missing key $k');
      }

      // recent is one flag-row per input day.
      final recent = out['recent'] as List;
      expect(recent.length, 30);
      expect((recent.first as Map).containsKey('illness'), isTrue);
    });

    test('load metric present with numeric ctl/atl/tsb when TRIMP present', () {
      final out = buildCrossDayBundle(_synthDays(30), const {});
      final load = out['load'] as Map;
      // Metric envelope: value is the LoadState toJson map (not "—").
      final value = load['value'];
      expect(value, isA<Map>());
      final v = (value as Map).cast<String, dynamic>();
      expect(v['ctl'], isA<num>());
      expect(v['atl'], isA<num>());
      expect(v['tsb'], isA<num>());
    });

    test('illness/anomaly keys exist (envelopes, not thrown)', () {
      final out = buildCrossDayBundle(_synthDays(30), const {});
      // With a calm series these may be null/green — the point is no throw and
      // the keys are addressable.
      expect(out.containsKey('illness'), isTrue);
      expect(out.containsKey('anomaly'), isTrue);
    });

    test('a sustained RHR spike on recent days trips the illness flag', () {
      final out = buildCrossDayBundle(
        _synthDays(40, rhrSpikeLast: true),
        const {},
      );
      // The latest IllnessDay should be elevated (yellow/red) given a sustained
      // multi-night RHR jump well above the 28-day robust baseline.
      final illness = out['illness'] as Map?;
      expect(illness, isNotNull);
      expect(illness!['state'], anyOf('yellow', 'red'));

      // And at least one recent day flag should read illness=true (red state).
      final recent = (out['recent'] as List).cast<Map>();
      final anyRed = recent.any((r) => r['illness'] == true);
      expect(anyRed, isTrue);
    });

    test('absent inputs degrade to honest absent envelopes, no throw', () {
      // All-null physiological fields, no trimp, no sleep — every family should
      // return its absent envelope (value "—") or null, never a fabrication.
      final blank = <Map<String, dynamic>>[
        for (var i = 0; i < 5; i++)
          {
            'date': '2024-02-0${i + 1}',
            'rhr': null,
            'rmssd': null,
            'readiness': null,
            'resp_rate': null,
            'skin_temp_z': null,
          }
      ];
      final out = buildCrossDayBundle(blank, const {});

      expect(out['n_days'], 5);
      // load: no daily TRIMP -> absent envelope (value "—", confidence 0).
      final load = (out['load'] as Map).cast<String, dynamic>();
      expect(load['value'], '—');
      expect(load['confidence'], 0);
      // brv: no resp series -> absent envelope.
      final brv = (out['brv'] as Map).cast<String, dynamic>();
      expect(brv['value'], '—');
      // regularity (SRI): no hypnogram coverage -> absent envelope.
      final reg = (out['regularity'] as Map).cast<String, dynamic>();
      expect(reg['value'], '—');
      // percentile-of-you: no history -> absent envelope per metric.
      final pct = (out['percentiles'] as Map).cast<String, dynamic>();
      expect((pct['rmssd'] as Map)['value'], '—');
      // illness/anomaly latest entries still serialize without throwing.
      expect(out.containsKey('illness'), isTrue);
    });

    test('survives a short series with partial sleep coverage', () {
      // 3 days, no sleep fields at all — chronotype/jetlag/SRI absent, no throw.
      final out = buildCrossDayBundle(
        _synthDays(3, withSleep: false),
        const {},
      );
      expect(out['n_days'], 3);
      expect((out['regularity'] as Map)['value'], '—');
      expect((out['social_jetlag'] as Map)['value'], '—');
    });
  });
}
