// Manual / retimed workout logging — the pure policy layer.
//
// Context: the auto-detector reports the HARD-EFFORT CORE (>=0.45*HRR held
// >=12 min, dips >90 s break the span), so an hour of mixed-intensity training
// commonly lands as ~25 detected minutes. `manual_session.dart` is what lets
// the athlete state the real window; these tests pin the parts that decide
// what gets written, without a DB or a clock in the way.
//
// The load-bearing guarantee is the honesty contract: a window with no 1 Hz HR
// behind it (pruned past the `rawRetentionDays` `decoded_onehz` retention, or
// band off) must produce NULL strain/calories — never a figure inferred from
// duration.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/profile.dart';

/// The ONE ceiling for [_profile] since TS-03a: estimatedMaxHr(30, 'gen4'|'gen5')
/// = Tanaka 208 - 0.7*30 = 187. It bands the zones AND anchors TRIMP/Keytel;
/// the tests used to pass 190 for zones and let the scorer derive 187 for the
/// anchors, which is exactly the split TS-03a removed.
const _hrMax = 187.0;

/// A full profile — every anchor the scored metrics need.
const _profile = Profile(
  ageYears: 30,
  weightKg: 75,
  heightCm: 180,
  sex: 'm',
  restingHrManual: 55,
);

/// 1 Hz samples at a flat [bpm] for [minutes], starting at [start].
({List<int> ts, List<int> bpm}) _flat(int start, int minutes, int bpm) {
  final ts = <int>[];
  final hr = <int>[];
  for (var i = 0; i < minutes * 60; i++) {
    ts.add(start + i);
    hr.add(bpm);
  }
  return (ts: ts, bpm: hr);
}

void main() {
  group('validateManualWindow', () {
    const now = 1_700_000_000;

    test('accepts an ordinary past window', () {
      expect(
        validateManualWindow(
          startSec: now - 3600,
          endSec: now - 1800,
          nowSec: now,
        ),
        isNull,
      );
    });

    test('rejects end <= start', () {
      expect(
        validateManualWindow(startSec: now - 60, endSec: now - 60, nowSec: now),
        ManualWindowError.endNotAfterStart,
      );
      expect(
        validateManualWindow(startSec: now - 60, endSec: now - 120, nowSec: now),
        ManualWindowError.endNotAfterStart,
      );
    });

    test('rejects a sub-minute window but accepts exactly a minute', () {
      expect(
        validateManualWindow(startSec: now - 59, endSec: now, nowSec: now),
        ManualWindowError.tooShort,
      );
      expect(
        validateManualWindow(startSec: now - 60, endSec: now, nowSec: now),
        isNull,
      );
    });

    test('rejects beyond the 24 h typo guard, accepts exactly 24 h', () {
      expect(
        validateManualWindow(
          startSec: now - kMaxManualWorkoutSec - 1,
          endSec: now,
          nowSec: now,
        ),
        ManualWindowError.tooLong,
      );
      expect(
        validateManualWindow(
          startSec: now - kMaxManualWorkoutSec,
          endSec: now,
          nowSec: now,
        ),
        isNull,
      );
    });

    test('rejects a window ending in the future', () {
      expect(
        validateManualWindow(
          startSec: now - 1800,
          endSec: now + 1,
          nowSec: now,
        ),
        ManualWindowError.inFuture,
      );
    });

    test('rejects overlap but allows back-to-back sessions', () {
      final existing = [SessionSpan('a', now - 7200, now - 3600)];
      // Overlapping by a single second.
      expect(
        validateManualWindow(
          startSec: now - 3601,
          endSec: now - 1800,
          nowSec: now,
          existing: existing,
        ),
        ManualWindowError.overlapsExisting,
      );
      // Touching end-to-start is legitimate (a brick session, back-to-back).
      expect(
        validateManualWindow(
          startSec: now - 3600,
          endSec: now - 1800,
          nowSec: now,
          existing: existing,
        ),
        isNull,
      );
    });

    test('fully-contained and fully-containing windows both count as overlap', () {
      final existing = [SessionSpan('a', now - 7200, now - 3600)];
      // New window swallows the existing one — the widen-a-fragment case, which
      // must be an EDIT, not a second row.
      expect(
        validateManualWindow(
          startSec: now - 7800,
          endSec: now - 3000,
          nowSec: now,
          existing: existing,
        ),
        ManualWindowError.overlapsExisting,
      );
      // New window sits inside the existing one.
      expect(
        validateManualWindow(
          startSec: now - 6000,
          endSec: now - 5000,
          nowSec: now,
          existing: existing,
        ),
        ManualWindowError.overlapsExisting,
      );
    });

    test('editingId excludes the row being retimed from its own overlap check', () {
      final existing = [SessionSpan('a', now - 7200, now - 3600)];
      // Widening 'a' overlaps 'a' — without the exclusion this is unfixable.
      expect(
        validateManualWindow(
          startSec: now - 7800,
          endSec: now - 3000,
          nowSec: now,
          existing: existing,
          editingId: 'a',
        ),
        isNull,
      );
    });

    test('a stranded live row (no usable end) is skipped, not guessed at', () {
      final existing = [SessionSpan('live', now - 3600, 0)];
      expect(
        validateManualWindow(
          startSec: now - 3600,
          endSec: now - 1800,
          nowSec: now,
          existing: existing,
        ),
        isNull,
      );
    });

    test('every error carries user-facing copy', () {
      for (final e in ManualWindowError.values) {
        expect(e.message, isNotEmpty);
      }
    });
  });

  group('hrPerMinute', () {
    test('collapses 1 Hz samples to one entry per minute', () {
      final s = _flat(0, 10, 140);
      final perMin = hrPerMinute(s.ts, s.bpm);
      expect(perMin.length, 10);
      expect(perMin.every((v) => v == 140.0), isTrue);
    });

    test('averages within a minute', () {
      // 30 s at 100, 30 s at 200 inside one minute bucket.
      final ts = [for (var i = 0; i < 60; i++) i];
      final bpm = [for (var i = 0; i < 60; i++) i < 30 ? 100 : 200];
      expect(hrPerMinute(ts, bpm), [150.0]);
    });

    test('a gap produces no entry rather than a zero minute', () {
      // Minute 0 present, minute 1 absent, minute 2 present.
      final ts = <int>[0, 1, 2, 120, 121, 122];
      final bpm = <int>[120, 120, 120, 130, 130, 130];
      expect(hrPerMinute(ts, bpm), [120.0, 130.0]);
    });

    test('empty and mismatched inputs yield nothing', () {
      expect(hrPerMinute(const [], const []), isEmpty);
      expect(hrPerMinute(const [1, 2], const [100]), isEmpty);
    });
  });

  group('zoneMinutesFor', () {
    test('bands on the supplied display HRmax', () {
      // maxHr 190 → Z3 is 70–80% = 133–152 bpm. 120 s at 140 bpm = 2.0 min Z3.
      final z = zoneMinutesFor(List<int>.filled(120, 140), 190);
      expect(z.length, 5);
      expect(z[2], 2.0);
      expect(z[0], 0.0);
      expect(z[4], 0.0);
    });

    test('below Z1 counts nowhere', () {
      // 50 bpm at maxHr 190 is under the 50% floor.
      expect(zoneMinutesFor(List<int>.filled(60, 50), 190).every((v) => v == 0),
          isTrue);
    });

    test('empty HR or a degenerate HRmax yields no bands', () {
      expect(zoneMinutesFor(const [], 190), isEmpty);
      expect(zoneMinutesFor(const [140], 0), isEmpty);
    });
  });

  group('computeManualSessionStats — honesty contract', () {
    test('no HR in the window → every scored field is null', () {
      final s = computeManualSessionStats(
        hrTs: const [],
        hrBpm: const [],
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(s.isUnscored, isTrue);
      expect(s.hrSampleCount, 0);
      expect(s.strain, isNull);
      expect(s.calories, isNull);
      expect(s.avgHr, isNull);
      expect(s.maxHr, isNull);
      expect(s.zoneMinutes, isEmpty);
    });

    test('no resting HR → neither strain nor calories', () {
      final w = _flat(0, 30, 150);
      final s = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: null,
        quietHrr: 0.20,
      );
      // Banister carries RHR as a term in the formula — absent it, abstain.
      expect(s.strain, isNull);
      // Keytel's own kJ/min formula takes no RHR, so it is tempting to score
      // calories anyway. But `estimateBoutCalories` uses RHR to place the
      // active/resting threshold that decides which seconds burn at the active
      // rate, and reports `usedDefaultAnchors` when it had to invent one. We
      // honour that flag rather than banking a figure built on a 60 bpm guess.
      expect(s.calories, isNull);
      // Raw HR observations are real regardless, and still reported.
      expect(s.avgHr, 150);
      expect(s.hrSampleCount, 30 * 60);
    });

    test('no ceiling → no HRmax anchor → neither strain nor calories', () {
      // No age OR an uncalibrated/unstamped strap: both make `estimatedMaxHr`
      // null, and the caller passes that null straight through (TS-03a).
      final w = _flat(0, 30, 150);
      final s = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: const Profile(weightKg: 75, heightCm: 180, sex: 'm'),
        hrMax: null,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(s.strain, isNull);
      expect(s.calories, isNull);
      // Raw HR observations are still real and still reported.
      expect(s.avgHr, 150);
      expect(s.maxHr, 150);
      expect(s.hrSampleCount, 30 * 60);
    });

    test('no weight → no Keytel calories, strain unaffected', () {
      final w = _flat(0, 30, 150);
      final s = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: const Profile(ageYears: 30, heightCm: 180, sex: 'm'),
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(s.calories, isNull);
      expect(s.strain, isNotNull);
    });

    test('a full profile over real HR scores both', () {
      final w = _flat(0, 45, 150);
      final s = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(s.isUnscored, isFalse);
      expect(s.avgHr, 150);
      expect(s.maxHr, 150);
      expect(s.strain, isNotNull);
      // 0–21 headline scale.
      expect(s.strain, inInclusiveRange(0.0, 21.0));
      expect(s.calories, greaterThan(0));
      expect(s.zoneMinutes.length, 5);
    });

    test('a longer window at the same intensity scores higher strain', () {
      ManualSessionStats run(int minutes) => computeManualSessionStats(
            hrTs: _flat(0, minutes, 150).ts,
            hrBpm: _flat(0, minutes, 150).bpm,
            profile: _profile,
            hrMax: _hrMax,
            restingHr: 55,
            quietHrr: 0.20,
          );
      // THE WHOLE POINT of the feature: correcting 25 min → 60 min must
      // actually move the number the athlete came here to fix.
      expect(run(60).strain!, greaterThan(run(25).strain!));
      expect(run(60).calories!, greaterThan(run(25).calories!));
    });

    test('off-skin zero samples never drag the average down', () {
      // hrSamplesInRange filters hr>0, but the policy must not depend on that.
      final ts = [for (var i = 0; i < 120; i++) i];
      final bpm = [for (var i = 0; i < 120; i++) i < 60 ? 0 : 150];
      final s = computeManualSessionStats(
        hrTs: ts,
        hrBpm: bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(s.avgHr, 150);
      expect(s.hrSampleCount, 60);

      // ...and neither may they dilute kcal. The estimator bills every sample
      // below the active threshold at the RESTING rate, so a forwarded zero
      // silently bought a second of basal burn that avgHr, strain and the zone
      // bands had all correctly discarded. An identical window containing only
      // the worn minute must score the same.
      final wornOnly = computeManualSessionStats(
        hrTs: [for (var i = 60; i < 120; i++) i],
        hrBpm: List<int>.filled(60, 150),
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(s.calories, wornOnly.calories);
      expect(s.strain, wornOnly.strain);
      expect(s.zoneMinutes, wornOnly.zoneMinutes);
    });
  });

  // ONE strain method across the app. Before this, three things put a number
  // on the same 0–21 dial and disagreed: daily strain used Banister -> log
  // squash, a live session accrued `%HRR * 0.01` per second (uncited,
  // uncapped, 2.18x higher, past 21 after ~50 min at 150 bpm), and an
  // auto-detected session wrote no strain at all.
  group('strainFromPerMinuteHr — the single strain method', () {
    test('a hard hour scores on-scale, nowhere near the old accrual', () {
      final perMin = List<double>.filled(60, 150);
      final s = strainFromPerMinuteHr(perMin,
          profile: _profile, restingHr: 55, hrMax: _hrMax, quietHrr: 0.20)!;

      // The canonical figure for this effort.
      expect(s, closeTo(11.62, 0.05));
      expect(s, lessThanOrEqualTo(21.0));

      // What the retired live accrual produced for the identical hour, so the
      // gap is on the record rather than in a commit message.
      final hrrLive = (150 - 55) / (220 - 30 - 55);
      final legacy = hrrLive * 0.01 * 60 * 60;
      expect(legacy, greaterThan(21.0),
          reason: 'the old live formula left its own scale');
      expect(legacy / s, greaterThan(2.0));
    });

    test('never exceeds 21, even for an absurdly long maximal effort', () {
      // 12 h pinned at 190 bpm — the old accrual would read into the hundreds.
      final s = strainFromPerMinuteHr(List<double>.filled(720, 190),
          profile: _profile, restingHr: 55, hrMax: _hrMax, quietHrr: 0.20)!;
      expect(s, lessThanOrEqualTo(21.0));
    });

    test('monotonic in both duration and intensity', () {
      double at(int minutes, double bpm) => strainFromPerMinuteHr(
          List<double>.filled(minutes, bpm),
          profile: _profile,
          restingHr: 55,
          hrMax: _hrMax, quietHrr: 0.20)!;
      expect(at(60, 150), greaterThan(at(30, 150)));
      expect(at(60, 165), greaterThan(at(60, 150)));
    });

    test('abstains rather than inventing an anchor', () {
      final perMin = List<double>.filled(60, 150);
      // No resting HR.
      expect(
          strainFromPerMinuteHr(perMin,
              profile: _profile, restingHr: null, hrMax: _hrMax, quietHrr: 0.20),
          isNull);
      // No ceiling — no age, OR a strap with no calibrated HRmax (TS-03a: an
      // unknown/unstamped device family REFUSES rather than borrowing gen4's).
      expect(
          strainFromPerMinuteHr(perMin,
              profile: _profile, restingHr: 55, hrMax: null, quietHrr: 0.20),
          isNull);
      // No sex → no Banister weighting constant.
      expect(
          strainFromPerMinuteHr(perMin,
              profile: const Profile(ageYears: 30), restingHr: 55,
              hrMax: _hrMax, quietHrr: 0.20),
          isNull);
      // No HR at all.
      expect(
          strainFromPerMinuteHr(const [],
              profile: _profile, restingHr: 55, hrMax: _hrMax, quietHrr: 0.20),
          isNull);
    });

    test('abstains without this user\'s quiet-waking level', () {
      // The 0.20 population reference used to stand in here. A session is
      // priced on the quiet level of the day it sits in, or not at all.
      final w = _flat(0, 45, 150);
      final none = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: null,
      );
      expect(none.strain, isNull);
      // Everything else about the session is still scored.
      expect(none.avgHr, 150);
      expect(none.calories, isNotNull);
      final priced = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      );
      expect(priced.strain, isNotNull);
      expect(
          strainFromPerMinuteHr(List<double>.filled(60, 150),
              profile: _profile, restingHr: 55, hrMax: _hrMax, quietHrr: null),
          isNull);
    });

    test('is exactly what computeManualSessionStats reports', () {
      // The session scorer must not fork its own copy of the method.
      final w = _flat(0, 45, 150);
      final viaStats = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      ).strain;
      final direct = strainFromPerMinuteHr(hrPerMinute(w.ts, w.bpm),
          profile: _profile, restingHr: 55, hrMax: _hrMax, quietHrr: 0.20);
      expect(viaStats, direct);
    });
  });

  group('buildManualSessionRow', () {
    final scored = computeManualSessionStats(
      hrTs: _flat(1000, 60, 150).ts,
      hrBpm: _flat(1000, 60, 150).bpm,
      profile: _profile,
      hrMax: _hrMax,
      restingHr: 55,
      quietHrr: 0.20,
    );

    test('a new entry is done/manual with a start-keyed id', () {
      final row = buildManualSessionRow(
        startSec: 1000,
        endSec: 1000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 5_000_000,
      );
      expect(row['id'], 'manual:1000');
      expect(row['status'], 'done');
      expect(row['source'], 'manual');
      expect(row['type'], 'run');
      expect(row['duration_min'], 60);
      expect(row['created_at'], 5_000_000);
      expect(row['strain'], isNotNull);
      expect(row['calories'], isNotNull);
    });

    test('re-logging the same window is idempotent on id', () {
      expect(manualSessionId(1000), manualSessionId(1000));
      expect(manualSessionId(1000), isNot(manualSessionId(1001)));
    });

    test('an edit preserves id, source and created_at', () {
      final row = buildManualSessionRow(
        startSec: 2000,
        endSec: 2000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 9_999_999,
        existing: const {
          'id': 'auto:1234',
          'source': 'auto',
          'created_at': 111,
        },
      );
      // Retiming must not re-attribute how the session was captured — the
      // detail screen's AUTO tag reads `source`.
      expect(row['id'], 'auto:1234');
      expect(row['source'], 'auto');
      expect(row['created_at'], 111);
      // ...but the window itself is the new one.
      expect(row['start_ts'], 2000);
      expect(row['duration_min'], 60);
    });

    test('absent stats are written as explicit nulls, not omitted', () {
      // putSession is INSERT-OR-REPLACE: an omitted key on an edit would let a
      // stale value computed for the OLD window survive into the new one.
      final row = buildManualSessionRow(
        startSec: 3000,
        endSec: 3000 + 3600,
        type: 'other',
        stats: const ManualSessionStats(),
        createdAtMs: 1,
      );
      for (final k in ['calories', 'strain', 'max_hr', 'steps', 'hrr_bpm']) {
        expect(row.containsKey(k), isTrue, reason: '$k must be present');
        expect(row[k], isNull, reason: '$k must be explicitly null');
      }
      // An unscored session still records the window the athlete asserted.
      expect(row['duration_min'], 60);
      expect(row['status'], 'done');
    });

    test('steps and hrr are cleared on a retime', () {
      final row = buildManualSessionRow(
        startSec: 4000,
        endSec: 4000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 1,
        existing: const {
          'id': 'w1',
          'source': 'manual',
          'created_at': 2,
          'steps': 4321,
          'hrr_bpm': 22.5,
        },
      );
      // Both described the OLD window; hrr_bpm is refilled by derivation.
      expect(row['steps'], isNull);
      expect(row['hrr_bpm'], isNull);
    });

    test('zone_min_json is a JSON list, empty when there are no zones', () {
      final unscored = buildManualSessionRow(
        startSec: 5000,
        endSec: 5000 + 3600,
        type: 'other',
        stats: const ManualSessionStats(),
        createdAtMs: 1,
      );
      expect(jsonDecode(unscored['zone_min_json'] as String), isEmpty);

      final withZones = buildManualSessionRow(
        startSec: 5000,
        endSec: 5000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 1,
      );
      final decoded = jsonDecode(withZones['zone_min_json'] as String) as List;
      expect(decoded.length, 5);
      expect(decoded.cast<num>().any((v) => v > 0), isTrue);
    });
  });

  group('supersededSuggestionIds', () {
    Map<String, dynamic> sug(String id, int start, int end) =>
        {'id': id, 'start_ts': start, 'end_ts': end};

    test('retires the fragment a wider manual entry covers', () {
      // The reported case: the detector found 25 min inside a 60 min session.
      final ids = supersededSuggestionIds(
        [sug('s1', 1500, 3000)],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, ['s1']);
    });

    test('leaves an unrelated suggestion alone', () {
      final ids = supersededSuggestionIds(
        [sug('s1', 10000, 12000)],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, isEmpty);
    });

    test('a merely adjacent suggestion is not superseded', () {
      final ids = supersededSuggestionIds(
        [sug('s1', 3600, 5000)],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, isEmpty);
    });

    test('malformed rows are skipped, not crashed on', () {
      final ids = supersededSuggestionIds(
        [
          {'id': null, 'start_ts': 0, 'end_ts': 100},
          {'id': 's2', 'start_ts': null, 'end_ts': 100},
          {'id': 's3', 'start_ts': 200, 'end_ts': 100}, // inverted
          sug('s4', 100, 200),
        ],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, ['s4']);
    });
  });
}
