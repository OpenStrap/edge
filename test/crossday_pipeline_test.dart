// Pure unit test for the cross-day analytics rollup (crossday_pipeline.dart).
//
// buildCrossDayBundle is a pure, isolate-safe function: given a time-ordered
// (oldest-first) list of per-day records + a profile, it runs every cross-day
// analytics family ONCE and returns a JSON-safe map. We feed it ~30 synthetic
// days and assert structure, the load metric, the illness/anomaly seams, that an
// injected RHR spike trips the illness flag, and that absent inputs degrade to
// honest absent envelopes (never a thrown exception, never a fabricated number).

import 'dart:math' as math;

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
      'skin_temp_adc': 3000.0 + wobble * 8.0,
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

    // ── the SRI grid must WRAP around midnight, not drop the segment ─────────
    //
    // Segment bounds are mapped to clock-minute-of-day in [0,1440). A segment
    // crossing local midnight therefore reads start > end (e.g. 1430 → 20), and
    // the old `for (m = startMin; m < endMin; m++)` never executed — silently
    // dropping it, despite a comment claiming it "clamps into grid". EVERY
    // night has exactly one such segment, so sleep-regularity was always
    // computed with a hole right at the boundary.
    test('a hypnogram segment crossing local midnight is not dropped from the '
        'SRI grid', () {
      // Local 23:30 → 00:30 the next day, expressed as epoch seconds.
      final onset = DateTime(2024, 3, 4, 23, 30).millisecondsSinceEpoch ~/ 1000;
      final wake = DateTime(2024, 3, 5, 0, 30).millisecondsSinceEpoch ~/ 1000;

      List<Map<String, dynamic>> nights({required bool crossMidnight}) => [
            for (var i = 0; i < 14; i++)
              {
                'date': '2024-03-${(4 + i).toString().padLeft(2, '0')}',
                'onset_sec': onset + i * 86400,
                'wake_sec': wake + i * 86400,
                'tst_min': 60,
                'hypnogram': [
                  {
                    'start': onset + i * 86400,
                    'end': (crossMidnight ? wake : onset + 1800) + i * 86400,
                    'stage': 'nrem',
                  },
                ],
              },
          ];

      // A midnight-crossing segment must produce REAL coverage — under the old
      // clamp the grid stayed entirely uncovered and SRI came back absent.
      final crossing = buildCrossDayBundle(
        nights(crossMidnight: true),
        const {},
      );
      final reg = (crossing['regularity'] as Map).cast<String, dynamic>();
      expect(reg['value'], isNot('—'),
          reason: 'the only segment of each night crosses midnight; dropping '
              'it leaves the SRI with zero valid epochs');

      // Sanity: a same-day segment (no wrap) was always handled, and still is.
      final sameDay = buildCrossDayBundle(
        nights(crossMidnight: false),
        const {},
      );
      expect((sameDay['regularity'] as Map)['value'], isNot('—'));
    });

    // ── the resting-HR CUSUM notification's input must actually be emitted ───
    test('recent rows carry rhr so the resting-HR trend notification can fire',
        () {
      final out = buildCrossDayBundle(_synthDays(30), const {});
      final recent = (out['recent'] as List).cast<Map>();
      // DerivationEngine._runNotifications collects `r['rhr'] is num` off these
      // rows and needs >= 10 of them; the builder never emitted the field, so
      // the series was always empty and the branch was dead code.
      final rhrSeries = [
        for (final r in recent)
          if (r['rhr'] is num) (r['rhr'] as num).toDouble(),
      ];
      expect(rhrSeries.length, 30);
      expect(rhrSeries.length, greaterThanOrEqualTo(10));
    });

    test('every row carries its date, so the CUSUM can align index → day', () {
      // `DerivationEngine._runNotifications` compacts the null-rhr days out of
      // this feed and used to fire when the detected change sat at the LAST
      // INDEX of the compacted series — which is "the most recent day that
      // happened to have an rhr", not today. It now reads the date at that
      // index and requires it to equal the day the notification is stamped
      // with; that is only possible because every row here carries `date`.
      final days = _synthDays(30);
      for (var i = 25; i < 30; i++) {
        days[i]['rhr'] = null; // five days with no nocturnal RHR
      }
      final recent = (buildCrossDayBundle(days, const {})['recent'] as List)
          .cast<Map>();
      final compactedDates = <String>[
        for (final r in recent)
          if (r['rhr'] is num) r['date'] as String,
      ];
      expect(compactedDates, isNotEmpty);
      expect(compactedDates.last, isNot(recent.last['date']),
          reason: 'the hazard: the last compacted index is five days stale');
    });

    test('a day with no rhr keeps a null rhr (never a fabricated number)', () {
      final days = _synthDays(3);
      days[1]['rhr'] = null;
      final recent = (buildCrossDayBundle(days, const {})['recent'] as List)
          .cast<Map>();
      expect(recent[1]['rhr'], isNull);
      expect(recent[0]['rhr'], isA<num>());
    });

    // ── CTL/ATL/TSB needs a DENSE per-day series ─────────────────────────────
    //
    // ctlAtlTsb is an EWMA over ONE SAMPLE PER DAY. Filtering to only the days
    // that carry a TRIMP handed it a compressed calendar, so load never decayed
    // across rest gaps and TSB was systematically wrong for anyone who trains
    // sporadically.
    test('rest days are 0-load impulses, not omitted from the load EWMA', () {
      // 90 days, but only every 9th day carries a TRIMP (10 loaded days).
      final days = <Map<String, dynamic>>[];
      var dt = DateTime(2024, 1, 1);
      for (var i = 0; i < 90; i++) {
        days.add({
          'date': '${dt.year}-${dt.month.toString().padLeft(2, '0')}'
              '-${dt.day.toString().padLeft(2, '0')}',
          'rhr': 55.0,
          'rmssd': 45.0,
          if (i % 9 == 0) 'trimp': 150.0,
        });
        dt = DateTime(dt.year, dt.month, dt.day + 1);
      }
      final load = ((buildCrossDayBundle(days, const {})['load'] as Map)['value']
              as Map)
          .cast<String, dynamic>();
      final ctl = (load['ctl'] as num).toDouble();
      final atl = (load['atl'] as num).toDouble();

      // Sparse (old) behaviour handed ctlAtlTsb ten CONSECUTIVE 150s, which
      // converges both EWMAs to 150 with no decay between them. Dense (fixed)
      // behaviour decays across the 8 rest days after each session, so the
      // 7-day ATL in particular must sit far below the session load.
      expect(atl, lessThan(100.0),
          reason: 'fatigue must decay across 8 consecutive rest days');
      expect(ctl, lessThan(150.0));
      // TSB = ctl - atl must be a real (non-degenerate) form number. The
      // tolerance is deliberately looser than 1e-6: ctl/atl/tsb round-trip
      // through JSON independently, so the reconstructed difference can differ
      // from the stored tsb by a ULP, and which way it lands is
      // platform-dependent (this passed on arm64 macOS and failed on x64 Linux
      // CI by exactly 1e-6). 1e-4 still pins the relationship without
      // asserting bit-level float reproducibility across architectures.
      expect((load['tsb'] as num).toDouble(), closeTo(ctl - atl, 1e-4));
    });

    test('an every-day-trained series is unchanged by densification', () {
      // No calendar gaps and a TRIMP on every day → the dense series IS the
      // per-row series, so this pins that the fix is a no-op for that case.
      final out = buildCrossDayBundle(_synthDays(30), const {});
      final load = ((out['load'] as Map)['value'] as Map).cast<String, dynamic>();
      expect(load['ctl'], isA<num>());
      expect((load['atl'] as num).toDouble(), greaterThan(50.0));
    });
  });
  group('unsettled (today, not finalized) day scoping', () {
    // Regression: today's unfinalized row used to be DROPPED from the input
    // list entirely to keep it out of the illness CUSUM. That also removed it
    // from readiness/glass-box, the resting-HR trend-shift CUSUM feed, load,
    // sleep debt and `recent` — whose last row dates every notification. It
    // must now stay in the series and only be nulled out of the alert inputs.
    test('stays in `recent` (so notifications date to today)', () {
      final days = _synthDays(30);
      final lastDate = days.last['date'] as String;
      days.last['unsettled'] = true;

      final bundle = buildCrossDayBundle(days, const {});
      final recent = bundle['recent'] as List;

      expect(recent.length, days.length);
      expect((recent.last as Map)['date'], lastDate);
      // The resting-HR trend-shift CUSUM reads `rhr` back off these rows.
      expect((recent.last as Map)['rhr'], isNotNull);
      // ...and the flag rides along with it, so that ALERT consumer can stand
      // down on a half-drained night while the trend keeps the raw value.
      expect((recent.last as Map)['unsettled'], isTrue);
      expect((recent.first as Map)['unsettled'], isFalse);
    });

    test('does not drive the illness/anomaly alert', () {
      // A sustained spike on the final days trips the flag when settled...
      final settled = _synthDays(30, rhrSpikeLast: true);
      final settledBundle = buildCrossDayBundle(settled, const {});
      expect(settledBundle['illness'], isNotNull);
      expect((settledBundle['illness'] as Map)['state'], 'red');

      // ...and the SAME spike on a still-syncing today must not, because its
      // inputs are withheld from the CUSUMs.
      final unsettled = _synthDays(30, rhrSpikeLast: true);
      unsettled.last['unsettled'] = true;
      final bundle = buildCrossDayBundle(unsettled, const {});

      final last = (bundle['recent'] as List).last as Map;
      expect(last['illness'], isFalse);
      expect(last['anomaly'], isFalse);
    });

    test('the published alert entry is the newest SETTLED night, with its own date',
        () {
      final days = _synthDays(30, rhrSpikeLast: true); // 2024-01-01 .. 2024-01-30
      days.last['unsettled'] = true; // today still settling
      final b = buildCrossDayBundle(days, const {});
      final illness = b['illness'] as Map;
      expect(illness['date'], '2024-01-29');
      expect(illness['state'], 'red');
      expect((b['anomaly'] as Map)['date'], '2024-01-29');
      expect((b['temp_illness'] as Map)['date'], '2024-01-29');
    });

    // A settled day with no overnight inputs (a day worn only in daytime) is
    // a night the detectors could not score: they hold it green by
    // construction. Publishing it would hide a red run that is still open.
    test('a settled night with no overnight inputs does not hide the newest '
        'scored one', () {
      final days = _synthDays(30, rhrSpikeLast: true); // .. 2024-01-30, red
      days.add({
        'date': '2024-01-31',
        'rhr': null,
        'rmssd': null,
        'readiness': null,
        'resp_rate': null,
        'skin_temp_z': null,
      });
      final b = buildCrossDayBundle(days, const {});
      final illness = b['illness'] as Map;
      expect(illness['date'], '2024-01-30');
      expect(illness['state'], 'red');
      expect((b['anomaly'] as Map)['date'], '2024-01-30');
      expect((b['temp_illness'] as Map)['date'], '2024-01-30');
    });

    test('an all-unsettled series publishes no alert entry, not a green one',
        () {
      final days = _synthDays(3);
      for (final d in days) {
        d['unsettled'] = true;
      }
      final b = buildCrossDayBundle(days, const {});
      expect(b['illness'], isNull);
      expect(b['anomaly'], isNull);
      expect(b['temp_illness'], isNull);
    });

    test('an all-settled series is unaffected by the flag plumbing', () {
      final bundle = buildCrossDayBundle(_synthDays(30), const {});
      expect((bundle['recent'] as List).length, 30);
      expect(bundle['n_days'], 30);
    });
  });

  group("today's readiness is read from the stamp, not the last row", () {
    // `days` only contains rows that EXIST. On a day whose derive has not run
    // yet the most recent row is yesterday, so a positional `readyList.last`
    // built today's strain target out of yesterday's recovery — the exact
    // imputation `_todayNum`'s doc describes and the comment above the line
    // already promised not to make.
    test('no is_today stamp → the strain target is absent', () {
      final bundle = buildCrossDayBundle(_synthDays(30), const {});
      expect((bundle['strain_coach'] as Map)['value'], '—');
    });

    test('with the stamp → the target is built from TODAY', () {
      final days = _synthDays(30);
      days.last['is_today'] = true;
      final bundle = buildCrossDayBundle(days, const {});
      expect((bundle['strain_coach'] as Map)['value'], isA<Map>());
    });
  });

  group('percentile-of-you is oriented', () {
    test('a low resting HR reads as good, not as "among your worst"', () {
      // rhr is LOWER-is-better. Unoriented, the user's lowest resting HR in a
      // month came back labelled by its raw rank — the wrong end of the scale.
      final days = _synthDays(30);
      days.last['rhr'] = 40.0; // well below every other day in the series
      final pct = ((buildCrossDayBundle(days, const {})['percentiles'] as Map)
          ['rhr'] as Map)['value'] as Map;
      expect(pct['label'], anyOf('among your best', 'better than usual'));
    });

    test('a high RMSSD still reads as good (higher-is-better is unchanged)', () {
      final days = _synthDays(30);
      days.last['rmssd'] = 120.0;
      final pct = ((buildCrossDayBundle(days, const {})['percentiles'] as Map)
          ['rmssd'] as Map)['value'] as Map;
      expect(pct['label'], anyOf('among your best', 'better than usual'));
    });
  });

  group('bedtime needs a measured efficiency', () {
    test('no efficiency history → bedtime and wake are absent, not 88 %', () {
      // The old `_median(effs) ?? 88.0` was an invented baseline: bedtime is
      // "wake − need ÷ efficiency", so the substitution moved the recommended
      // bedtime by real minutes for a user who had never had one measured.
      final days = _synthDays(30);
      final coach =
          (buildCrossDayBundle(days, const {})['sleep_coach'] as Map);
      expect((coach['bedtime'] as Map)['value'], '—');
      expect((coach['wake'] as Map)['value'], '—');

      // …and the SAME series with a measured efficiency does produce one, so
      // the assertion above is about the efficiency and not about `need`.
      final withEff = _synthDays(30);
      for (final d in withEff) {
        d['efficiency'] = 92.0;
      }
      final coach2 =
          (buildCrossDayBundle(withEff, const {})['sleep_coach'] as Map);
      expect((coach2['bedtime'] as Map)['value'], isA<Map>());
      expect((coach2['wake'] as Map)['value'], isA<Map>());
    });
  });

  // CV-02. VO2max was exactly k/RHR — the resting-HR chart with the wrong
  // unit on the axis — and fitness age counted the same variable twice, in
  // the same direction. Both are deleted, not hidden.
  test('publishes no VO2max and no fitness age', () {
    final out = buildCrossDayBundle(_synthDays(30), const {
      'age': 34,
      'sex': 'm',
    });
    expect(out.containsKey('vo2max'), isFalse);
    expect(out.containsKey('fitness_age'), isFalse);
  });

  // WH-01. The `luteal` argument was written, typed and never passed, so the
  // confound branch had never once executed and the flag cried wolf for two
  // weeks a month.
  group('the luteal argument reaches the temperature flag', () {
    // The published row is the LATEST day, which for _synthDays(30) anchored
    // on 2024-01-01 is 2024-01-30.
    bool lutealOn(List<String> starts) {
      final out = buildCrossDayBundle(
        _synthDays(30),
        const {},
        cycleStartDates: starts,
      );
      return ((out['temp_illness'] as Map)['luteal'] as bool?) ?? false;
    }

    test('a day in the second half of its own cycle is marked', () {
      // Two starts 28 days apart, so the open cycle inherits her median
      // length; 2024-01-30 is day 30 of a 28-day cycle.
      expect(lutealOn(const ['2023-12-04', '2024-01-01']), isTrue);
    });

    test('a day just after a start is not', () {
      expect(lutealOn(const ['2024-01-01', '2024-01-29']), isFalse);
    });

    test('with no cycle log nothing is marked — we do not guess', () {
      expect(lutealOn(const []), isFalse);
      // One start alone gives no measured length either.
      expect(lutealOn(const ['2024-01-01']), isFalse);
    });
  });

  _wiredFamilies();
}

// ── the three cross-day families wired in this pass ──────────────────────────

void _wiredFamilies() {
  group('SLP-08 — the SRI pairs name their two nights', () {
    test('every emitted pair resolves to the day before and the day itself',
        () {
      final days = _synthDays(30);
      final reg = (buildCrossDayBundle(days, const {})['regularity'] as Map)
          .cast<String, dynamic>();
      final pairs = (reg['value'] as Map)['pairs'] as List;
      expect(pairs, isNotEmpty);
      for (final p in pairs.cast<Map>()) {
        final i = p['day_index'] as int;
        // `day_index` indexes the day list and nothing else — the whole reason
        // it has to be resolved here rather than in the analytics.
        expect(p['date'], days[i]['date']);
        expect(p['prev_date'], days[i - 1]['date']);
      }
      // A pair's SRI is on the same 200p−100 scale as the headline.
      expect((pairs.first as Map)['sri'], isA<num>());
    });

    test('a missing calendar day is a gap, not an adjacent night', () {
      // Drop every third day, so some neighbouring rows are two days apart.
      final all = _synthDays(30);
      final days = [
        for (var i = 0; i < all.length; i++)
          if (i % 3 != 1) all[i],
      ];
      final reg = (buildCrossDayBundle(days, const {})['regularity'] as Map)
          .cast<String, dynamic>();
      final pairs = (reg['value'] as Map)['pairs'] as List;
      expect(pairs, isNotEmpty);
      for (final p in pairs.cast<Map>()) {
        final prev = DateTime.parse('${p['prev_date']}T00:00:00Z');
        final date = DateTime.parse('${p['date']}T00:00:00Z');
        expect(date.difference(prev).inDays, 1,
            reason: '${p['prev_date']} → ${p['date']} is not a 24 h pair');
      }
    });

    test('padded gap days do not count toward days or confidence', () {
      // Rows on day 1, 2 and 10: a 10-day grid with one observed pair.
      final all = _synthDays(10);
      final reg = (buildCrossDayBundle([all[0], all[1], all[9]], const {})[
              'regularity'] as Map)
          .cast<String, dynamic>();
      expect((reg['value'] as Map)['days'], 2);
      expect(reg['confidence'] as num, lessThanOrEqualTo(0.3));
    });

    test('a gap past the densify bound still breaks the pair', () {
      // Two runs of nights 500 days apart. No pair may span the break.
      final days = _synthDays(10);
      for (var i = 5; i < 10; i++) {
        days[i]['date'] = DateTime.utc(2025, 5, 15 + i)
            .toIso8601String()
            .substring(0, 10);
      }
      final reg = (buildCrossDayBundle(days, const {})['regularity'] as Map)
          .cast<String, dynamic>();
      for (final p in ((reg['value'] as Map)['pairs'] as List).cast<Map>()) {
        final prev = DateTime.parse('${p['prev_date']}T00:00:00Z');
        final cur = DateTime.parse('${p['date']}T00:00:00Z');
        expect(cur.difference(prev).inDays, 1);
      }
      expect((reg['value'] as Map)['days'], 9);
    });

    test('unobserved minutes are not scored as sleep', () {
      // Every night is light 23:00-03:00. After 03:00, half the nights are
      // awake and the other half the band saw nothing. Only 23:00-03:00 is
      // observed on both sides of any pair, and it agrees perfectly.
      int at(int day, int h) =>
          DateTime(2024, 3, 4 + day, h).millisecondsSinceEpoch ~/ 1000;
      final days = [
        for (var i = 0; i < 14; i++)
          {
            'date': '2024-03-${(5 + i).toString().padLeft(2, '0')}',
            'hypnogram': [
              {'start': at(i, 23), 'end': at(i + 1, 3), 'stage': 'light'},
              {
                'start': at(i + 1, 3),
                'end': at(i + 1, 7),
                'stage': i.isEven ? 'wake' : 'unobserved',
              },
            ],
          },
      ];
      final reg = (buildCrossDayBundle(days, const {})['regularity'] as Map)
          .cast<String, dynamic>();
      expect((reg['value'] as Map)['sri'], closeTo(100, 1e-9));
    });
  });

  group('sleep performance is last night only', () {
    test('no TST last night → absent, not an older night\'s TST', () {
      final days = _synthDays(30);
      days.last['is_today'] = true;
      days.last.remove('tst_min');
      final coach = (buildCrossDayBundle(days, const {})['sleep_coach'] as Map);
      expect((coach['performance'] as Map)['value'], '—');
    });

    test('TST last night → scored', () {
      final days = _synthDays(30);
      days.last['is_today'] = true;
      final coach = (buildCrossDayBundle(days, const {})['sleep_coach'] as Map);
      expect((coach['performance'] as Map)['value'], isA<Map>());
    });
  });

  group('TS-12 — overreaching as two facts', () {
    test('the two facts coincide only when BOTH hold', () {
      // Baseline RHR ~55 for 40 days, then five nights well above it, and a
      // final week of load far above the 42-day chronic.
      final days = _synthDays(45);
      for (var i = 40; i < 45; i++) {
        days[i]['rhr'] = 70.0;
        days[i]['trimp'] = 600.0;
      }
      final v = ((buildCrossDayBundle(days, const {})['overreaching'] as Map)
          ['value'] as Map);
      expect(v['nights_elevated'], 5);
      expect(v['load_ratio'], greaterThan(1.5));
      expect(v['both_point_same_way'], isTrue);

      // Same load, ordinary nights: silence, which is the normal state.
      final quiet = _synthDays(45);
      for (var i = 40; i < 45; i++) {
        quiet[i]['trimp'] = 600.0;
      }
      final qv = ((buildCrossDayBundle(quiet, const {})['overreaching'] as Map)
          ['value'] as Map);
      expect(qv['both_point_same_way'], isFalse);
    });

    test('it is not a notification: no alert family reads it', () {
      // _runNotifications collects illness/anomaly/temp_illness only. This is
      // the structural half of the "no new notification class" rule.
      final out = buildCrossDayBundle(_synthDays(30), const {});
      expect(out.containsKey('overreaching'), isTrue);
      expect((out['illness'] as Map?)?.containsKey('overreaching') ?? false,
          isFalse);
    });
  });

  group('TS-11 — what each session type cost the next morning', () {
    List<Map<String, dynamic>> covered(int n) {
      final days = _synthDays(n);
      for (final d in days) {
        d['sleep_coverage'] = 0.95;
      }
      return days;
    }

    test('no sessions logged → absent, never an empty-but-confident table', () {
      final sc = (buildCrossDayBundle(covered(45), const {})['session_cost']
          as Map)['rhr'] as Map;
      expect(sc['value'], '—');
      expect(sc['confidence'], 0);
    });

    test('a type with ten clean mornings reports a signed median and its n',
        () {
      final days = covered(60);
      final types = <String, List<String>>{};
      // Twelve football days, each followed by a morning 6 bpm above baseline.
      for (var i = 30; i < 54; i += 2) {
        types[days[i]['date'] as String] = ['football'];
        days[i + 1]['rhr'] = (days[i + 1]['rhr'] as double) + 6.0;
      }
      final sc = (buildCrossDayBundle(days, const {},
          sessionTypesByDate: types)['session_cost'] as Map)['rhr'] as Map;
      final rows = sc['value'] as List;
      expect(rows.length, 1);
      final row = rows.first as Map;
      expect(row['session_type'], 'football');
      expect(row['n'], greaterThanOrEqualTo(10));
      expect(row['median_delta'], greaterThan(4.0));
    });

    test('a night we barely watched is dropped, not averaged in', () {
      final days = covered(60);
      final types = <String, List<String>>{};
      for (var i = 30; i < 54; i += 2) {
        types[days[i]['date'] as String] = ['football'];
        days[i + 1]['sleep_coverage'] = 0.1;
      }
      final sc = (buildCrossDayBundle(days, const {},
          sessionTypesByDate: types)['session_cost'] as Map)['rhr'] as Map;
      expect(sc['value'], '—');
    });

    test('a day with two sessions belongs to neither type', () {
      final days = covered(60);
      final types = <String, List<String>>{};
      for (var i = 30; i < 54; i += 2) {
        types[days[i]['date'] as String] = ['football', 'run'];
      }
      final sc = (buildCrossDayBundle(days, const {},
          sessionTypesByDate: types)['session_cost'] as Map)['rhr'] as Map;
      expect(sc['value'], '—');
    });
  });

  // The temperature flag standardises its own input. It was handed
  // `skin_temp_z`, which is already scored against a baseline that holds the
  // earlier fever nights, so the z it saw decayed night over night and a real
  // multi-night rise never stayed above threshold for two nights.
  group('the temperature flag reads the raw nightly mean', () {
    // Deterministic noise around 3000 ADC, SD ~8.
    const noise = [-9.0, 4.0, 11.0, -3.0, -12.0, 7.0, 1.0, -6.0, 13.0, -5.0,
      2.0, -10.0, 8.0, -1.0, 5.0, -7.0, 10.0, -4.0, 0.0, 6.0];

    // The edge z exactly as the per-day pipeline computes it: trailing 28 raw
    // nightly means strictly before the night, sample SD, gated at SD >= 1.
    double? edgeZ(List<double> raw, int i) {
      final hist = raw.sublist(i - 28 < 0 ? 0 : i - 28, i);
      if (hist.length < 3) return null;
      final mean = hist.reduce((a, b) => a + b) / hist.length;
      var ss = 0.0;
      for (final v in hist) {
        ss += (v - mean) * (v - mean);
      }
      final sd = ss == 0 ? 0.0 : math.sqrt(ss / (hist.length - 1));
      return sd >= 1 ? (raw[i] - mean) / sd : null;
    }

    List<Map<String, dynamic>> feverDays({
      required double feverSd,
      String? Function(int i)? family,
      double Function(int i, double v)? shift,
    }) {
      const baseline = 40;
      final raw = <double>[
        for (var i = 0; i < baseline; i++) 3000 + noise[i % noise.length],
        for (var i = 0; i < 3; i++) 3000 + feverSd * 8,
      ];
      var dt = DateTime(2024, 1, 1);
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i < raw.length; i++) {
        final v = shift == null ? raw[i] : shift(i, raw[i]);
        out.add({
          'date': '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
              '${dt.day.toString().padLeft(2, '0')}',
          'skin_temp_z': edgeZ(raw, i),
          'skin_temp_adc': v,
          if (family != null) 'skin_temp_family': family(i),
        });
        dt = dt.add(const Duration(days: 1));
      }
      return out;
    }

    List<bool> flags(List<Map<String, dynamic>> days) => [
          for (final r in buildCrossDayBundle(days, const {})['recent'] as List)
            (r as Map)['temp'] as bool,
        ];

    test('a three-night rise is flagged on its second and third nights', () {
      final f = flags(feverDays(feverSd: 3));
      expect(f.sublist(f.length - 3), [false, true, true]);
    });

    // A warm, ambient-correlated night is left out of the flag's input but
    // still carries its raw value. Publishing its held-normal entry hid the
    // open run from every alert surface.
    test('an ambient-excluded last night does not hide an elevated run', () {
      final days = feverDays(feverSd: 3);
      days.last['skin_temp_illness_ok'] = false;
      final b = buildCrossDayBundle(days, const {});
      final tmp = b['temp_illness'] as Map;
      expect(tmp['date'], days[days.length - 2]['date']);
      expect(tmp['flag'], 'elevated');
    });

    test('nights in another family\'s unit are not mixed into the baseline',
        () {
      // A gen4 history in ADC counts, then a swap to gen5 reading centi-°C
      // around 3400 for the last five nights. No fever anywhere: mixed into
      // one series the swap itself reads as a sustained rise.
      final days = feverDays(
        feverSd: 0,
        family: (i) => i < 38 ? 'gen4' : 'gen5',
        shift: (i, v) => i < 38 ? v : 3400 + noise[i % noise.length] / 4,
      );
      final f = flags(days);
      expect(f.contains(true), isFalse);
      final b = buildCrossDayBundle(days, const {});
      expect((b['temp_illness'] as Map)['date'], days.last['date']);
    });

    test('an unstamped history stays in the baseline once nights are stamped',
        () {
      // Rows from before the family stamp existed, then five stamped nights
      // that include the rise. Too few stamped nights to baseline on their own.
      final f = flags(feverDays(
        feverSd: 3,
        family: (i) => i < 38 ? null : 'gen4',
      ));
      expect(f.sublist(f.length - 3), [false, true, true]);
    });

    test('an unstamped newest night keeps the stamped history', () {
      // A strap-swap day carries no single family; it is still a band night.
      final f = flags(feverDays(
        feverSd: 3,
        family: (i) => i == 42 ? null : 'gen4',
      ));
      expect(f.sublist(f.length - 3), [false, true, true]);
    });
  });

  // The multivariate anomaly standardises every column itself, so its temp
  // feature is the raw nightly mean. It was handed `skin_temp_z`, which is
  // scored against a baseline that already holds the earlier fever nights, and
  // it skipped the ambient exclusion the temperature flag applies.
  group('the anomaly reads the raw, ambient-gated nightly temp', () {
    const noise = [-9.0, 4.0, 11.0, -3.0, -12.0, 7.0, 1.0, -6.0, 13.0, -5.0,
      2.0, -10.0, 8.0, -1.0, 5.0, -7.0, 10.0, -4.0, 0.0, 6.0];

    // 40 ordinary nights, then [tail] nights whose raw temp is [tailTemp].
    // `skin_temp_z` is whatever [z] returns, so a test can make it disagree
    // with the raw mean.
    List<Map<String, dynamic>> nights({
      int tail = 3,
      double tailTemp = 3040,
      double? Function(int i)? z,
      bool Function(int i)? ambient,
    }) {
      var dt = DateTime(2024, 1, 1);
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i < 40 + tail; i++) {
        final w = noise[i % noise.length];
        out.add({
          'date': '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
              '${dt.day.toString().padLeft(2, '0')}',
          'rhr': 55.0 + w / 4,
          'rmssd': 45.0 + w / 2,
          'resp_rate': 14.0 + w / 20,
          'skin_temp_z': z == null ? null : z(i),
          'skin_temp_adc': i < 40 ? 3000 + w : tailTemp,
          'skin_temp_family': 'gen4',
          if (ambient != null && ambient(i)) 'skin_temp_illness_ok': false,
        });
        dt = dt.add(const Duration(days: 1));
      }
      return out;
    }

    double? tempDriver(List<Map<String, dynamic>> days) {
      final a = buildCrossDayBundle(days, const {})['anomaly'] as Map?;
      if (a == null) return null;
      for (final d in a['drivers'] as List) {
        if ((d as Map)['label'] == 'temp') {
          return (d['contribution'] as num).toDouble();
        }
      }
      return null;
    }

    test('a raw rise reaches the anomaly even when no z was stored', () {
      final days = nights();
      expect((buildCrossDayBundle(days, const {})['anomaly'] as Map)['date'],
          days.last['date']);
      final t = tempDriver(days);
      expect(t, isNotNull);
      expect(t!, greaterThan(2));
    });

    test('the temp term follows the raw rise, not a z that disagrees', () {
      // A z claiming every night is ordinary while the raw mean has risen.
      final days = nights(z: (i) => 0.0);
      expect(tempDriver(days)!, greaterThan(2));
    });

    test('a night that tracked the ambient channel carries no temp term', () {
      final days = nights(
        tail: 1,
        z: (i) => i < 40 ? noise[i % noise.length] / 8 : 4.0,
        ambient: (i) => i == 40,
      );
      final a = buildCrossDayBundle(days, const {})['anomaly'] as Map;
      expect(a['date'], days.last['date']);
      expect(tempDriver(days), isNull);
    });
  });

  group('the breakdown ranks tonight against its own method family', () {
    const methods = {'gen4': 'hr_1hz', 'gen5': 'hr_1hz', 'oura': 'hr_5min'};

    // 30 band nights, then 20 ring nights whose vendor HRV runs ~20 ms lower
    // and whose resting HR runs ~8 bpm higher. Both series are steady within
    // their own device; only the switch is a step.
    List<Map<String, dynamic>> switched(String later) {
      final days = _synthDays(50);
      for (var i = 0; i < days.length; i++) {
        final wobble = (i % 5) - 2;
        final ring = i >= 30;
        days[i]['skin_temp_family'] = ring ? later : 'gen4';
        if (ring && later == 'oura') {
          days[i]['rmssd'] = 25.0 + wobble * 1.5;
          days[i]['rhr'] = 63.0 + wobble;
        }
      }
      // Tonight is the ring's median night, not its worst.
      days.last['rmssd'] = 25.0;
      days.last['rhr'] = 63.0;
      return days;
    }

    Map<String, dynamic> pct(Map<String, dynamic> b, String k) =>
        ((b['percentiles'] as Map)[k] as Map)['value'] as Map<String, dynamic>;

    test('a new ring is not ranked against the band it replaced', () {
      final b = buildCrossDayBundle(switched('oura'), const {},
          methodFamilies: methods);
      // Only the 19 prior ring nights are history.
      expect(pct(b, 'rmssd')['n'], 19);
      expect(pct(b, 'rhr')['n'], 19);
      // Tonight is the ring's median, so it ranks mid-history. Mixed with the
      // 30 band nights it ranked near the bottom (~20th percentile for HRV,
      // ~80th for resting HR).
      expect(pct(b, 'rmssd')['percentile_of_you'], greaterThan(40));
      expect(pct(b, 'rhr')['percentile_of_you'], lessThan(60));
      final items = (((b['readiness_glassbox'] as Map)['value']
              as Map)['breakdown'] as List)
          .cast<Map>();
      final hrv = items.firstWhere((m) => m['label'] == 'hrv');
      expect(hrv['percentile_of_you'], greaterThan(40));
    });

    test('WHOOP 4 to WHOOP 5 keeps one history (same method family)', () {
      final b = buildCrossDayBundle(switched('gen5'), const {},
          methodFamilies: methods);
      expect(pct(b, 'rmssd')['n'], 49);
      expect(pct(b, 'rhr')['n'], 49);
    });

    test('an unstamped night counts as a band night', () {
      final days = switched('gen5');
      for (var i = 0; i < 20; i++) {
        days[i].remove('skin_temp_family');
      }
      final b =
          buildCrossDayBundle(days, const {}, methodFamilies: methods);
      expect(pct(b, 'rmssd')['n'], 49);
    });
  });
}
