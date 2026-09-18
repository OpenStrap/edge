// THE SOURCE LADDER — steps resolved PER WINDOW, never per day.
//
// The bug this pins, measured on a real MG export: the gen5 on-chip counter
// took the WHOLE day and published 622 steps against the phone's 18,856,
// because the strap only covered the hours it was syncing. The naive fix —
// "the better sensor wins each span" — has its own measured failure: a band
// coverage span means "a live link existed", not "the pedometer was counting",
// and on 2026-08-08 the band claimed 9.35 h for 216 steps while the phone had
// 11 h for 7,775. Handing the band that span loses ~7,000 steps.
//
// So: rank per span, gait density decides whether a band span outranks the
// phone at all, overlaps are counted ONCE, and the on-chip counter — a
// whole-day cumulative total with no window behind it — enters only when no
// span source covered the day.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/live_coverage_policy.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show stepSensorLabel;

const _t0 = 1_786_000_000; // arbitrary local midnight

CoverageSpan _band(int fromSec, int toSec, int steps) => CoverageSpan(
      startTs: _t0 + fromSec,
      endTs: _t0 + toSec,
      steps: steps,
      fromBand: true,
    );

CoverageSpan _phone(int fromSec, int toSec, int steps) => CoverageSpan(
      startTs: _t0 + fromSec,
      endTs: _t0 + toSec,
      steps: steps,
      fromBand: false,
    );

const _h = 3600;

/// A 1 Hz substrate carrying [counters] (`-1` = this hardware has no counter).
///
/// STAMPED `gen5`, as every real substrate carrying this column is (ingest
/// writes `decoded_onehz.device_family`). Since BANDAGNOSTIC C13 the stamp is
/// what establishes the counter's BEHAVIOUR — cumulative, wraps at 65536, no
/// midnight reset — and an unstamped one abstains rather than sum deltas off a
/// counter that might reset at midnight and lose the day's pre-sync prefix.
Substrate _sub(List<int> counters, {int step = 600, String? family = 'gen5'}) {
  final n = counters.length;
  return Substrate(
    deviceFamily: family,
    tsSec: [for (var i = 0; i < n; i++) _t0 + i * step],
    hr: List<int>.filled(n, 60),
    rrTsMs: const [],
    rrMs: const [],
    ax: List<double>.filled(n, 0),
    ay: List<double>.filled(n, 0),
    az: List<double>.filled(n, 1),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    stepCount: counters,
  );
}

/// Run the real derivation path and hand back (bundle.steps, scalars).
(Map<String, dynamic>, Map<String, dynamic>) _derive(
  Substrate sub, {
  required int liveStepsReal,
  required int liveStepsFromStrap,
}) {
  final bundle = <String, dynamic>{};
  final scalars = <String, dynamic>{};
  DerivationEngine.applyDayActivity(
    bundle: bundle,
    scalars: scalars,
    daySub: sub,
    profile: const Profile(ageYears: 35, sex: 'm', weightKg: 75, heightCm: 178),
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    // Wear/coverage is not what this test measures — the substrate's own span
    // is the day. See wear_coverage_test.dart for the denominator itself.
    dayStartSec: sub.tsSec.first,
    dayCalendarEndSec: sub.tsSec.last + 1,
    dataNowSec: sub.tsSec.last + 1,
    liveStepsReal: liveStepsReal,
    liveStepsFromStrap: liveStepsFromStrap,
  );
  return ((bundle['steps'] as Map).cast<String, dynamic>(), scalars);
}

void main() {
  group('resolveDaySteps — spans sum, overlaps are counted once', () {
    test('a strap session and a phone-covered evening simply add up', () {
      // 40 min of strap at 100 spm, then an hour of phone hours later.
      final r = resolveDaySteps([
        _band(8 * _h, 8 * _h + 2400, 4000),
        _phone(12 * _h, 13 * _h, 1200),
      ]);
      expect(r.total, 5200);
      expect(r.strap, 4000);
      expect(r.phone, 1200);
      expect(r.mixed, isTrue);
      expect(r.dominant, 'strap');
    });

    test('A REAL OVERLAP IS NOT DOUBLE-COUNTED: a strap run inside a '
        'phone-covered hour contributes its minutes, the phone the rest', () {
      // The phone counted the whole 09:00–10:00 hour, 4,000 steps. The strap
      // streamed 09:10–09:40 and counted 3,000 of them at 100 spm. The day is
      // 4,000 — NOT 7,000, and not 3,000 either.
      final r = resolveDaySteps([
        _phone(9 * _h, 10 * _h, 4000),
        _band(9 * _h + 600, 9 * _h + 2400, 3000),
      ]);
      expect(r.total, 4000, reason: 'the same walk must not be counted twice');
      expect(r.strap, 3000, reason: 'the strap owns the minutes it supervised');
      expect(r.phone, 1000, reason: 'the phone keeps only the rest of the hour');
    });

    test('a PARTIAL overlap only costs the overlapping half', () {
      // Band 09:30–10:30 (3,000 steps); phone 09:00–10:00 (4,000). Half the
      // band span sits inside the phone hour, so the phone gives up half the
      // band's count and keeps the rest.
      final r = resolveDaySteps([
        _phone(9 * _h, 10 * _h, 4000),
        _band(9 * _h + 1800, 10 * _h + 1800, 3000),
      ]);
      expect(r.strap, 3000);
      expect(r.phone, 2500);
      expect(r.total, 5500);
    });

    test('2026-08-08: a wide band span with no gait in it does NOT take the '
        'day from the phone', () {
      // Measured: band 9.35 h / 216 steps (0.4 spm — a link that existed, not
      // a pedometer that was counting) against phone 11 h / 7,775 (11.8 spm).
      final r = resolveDaySteps([
        _band(0, (9.35 * _h).round(), 216),
        _phone(0, 11 * _h, 7775),
      ]);
      expect(r.total, 7775, reason: 'the day must not lose ~7,000 steps');
      expect(r.strap, 0);
      expect(r.dominant, 'phone');
    });

    test('2026-08-13: an 11-minute strap walk inside a phone-covered day '
        'neither takes the day nor inflates it', () {
      // Measured: band 0.19 h / 1,140 steps (101.6 spm — real walking) against
      // phone 14 h / 18,856. Whole-day precedence would have published 1,140.
      final r = resolveDaySteps([
        _band(10 * _h, 10 * _h + 684, 1140),
        _phone(6 * _h, 20 * _h, 18856),
      ]);
      expect(r.strap, 1140, reason: 'those minutes were the strap\'s');
      expect(r.total, 18856, reason: 'the phone counted the same walk');
    });

    test('a band-only day is unchanged — every span keeps its count', () {
      final r = resolveDaySteps([
        _band(0, 600, 120),
        _band(1000, 1600, 80),
      ]);
      expect(r.total, 200);
      expect(r.phone, 0);
      expect(r.dominant, 'strap');
    });

    test('two rows from the SAME sensor are summed, not competed', () {
      // Overlapping band rows are one sensor reporting twice — the append-only
      // semantics `live_coverage` has always had, and what re-import
      // idempotency relies on.
      final r = resolveDaySteps([
        _band(0, 3600, 3000),
        _band(1800, 5400, 3000),
      ]);
      expect(r.total, 6000);
    });

    test('THE SPANS COME BACK CREDITED, so a day screen draws what the total '
        'counted and not the raw rows', () {
      // Same case as the double-count test above: the phone's hour keeps only
      // the 1,000 steps the ladder left it, or a screen drawing the rows would
      // show the strap's walk twice under a total that counts it once.
      final r = resolveDaySteps([
        _phone(9 * _h, 10 * _h, 4000),
        _band(9 * _h + 600, 9 * _h + 2400, 3000),
      ]);
      expect(r.spans.map((s) => (s.startTs - _t0, s.steps, s.fromBand)), [
        (9 * _h, 1000, false),
        (9 * _h + 600, 3000, true),
      ], reason: 'time order, credited counts');
      // A span the ladder took everything back from is not drawn at all: it
      // contributed no steps, and an empty bar on a timeline is a claim.
      final swallowed = resolveDaySteps([
        _phone(9 * _h, 10 * _h, 3000),
        _band(9 * _h, 10 * _h, 3000),
      ]);
      expect(swallowed.spans.length, 1);
      expect(swallowed.spans.single.fromBand, isTrue);
    });

    test('ISSUE #366: a confirmed-motionless phone hour vetoes a wrist '
        'false-positive that never overlapped a real walk', () {
      // WHOOP 4 has no on-chip counter — its only "band" contribution outside
      // a tracked walk/run is this passive-wear arm-motion counter. 22 spm
      // over an hour of chores (OxWalk's measured false-positive range) used
      // to be credited in full and simply SUMMED onto the phone's real count,
      // because a confirmed-zero hour was never persisted to compete with it.
      final r = resolveDaySteps([
        _phone(9 * _h, 10 * _h, 0), // phone: motionless that hour
        _band(9 * _h, 10 * _h, 1320), // band: 1320/60min = 22 spm (chores)
        _phone(14 * _h, 15 * _h, 3000), // the day's one real walk
      ]);
      expect(r.total, 3000, reason: 'the chores hour must not add anything');
      expect(r.strap, 0);
    });

    test('a real gait-density band span survives even inside a confirmed-'
        'still phone hour (phone left behind, band kept counting)', () {
      final r = resolveDaySteps([
        _phone(9 * _h, 10 * _h, 0),
        _band(9 * _h + 600, 9 * _h + 720, 200), // 200 steps / 2 min = 100 spm
      ]);
      expect(r.total, 200, reason: 'gait-density steps are not chores noise');
      expect(r.strap, 200);
    });

    test('a partial overlap with a confirmed-still hour only voids its own '
        'share', () {
      // Band span is half inside the still hour (0-3600) and half outside it,
      // at a chores-range density (20 spm over 20 min = 400... use a small
      // density instead so it doesn't clear the gait floor).
      final r = resolveDaySteps([
        _phone(0, _h, 0),
        _band(_h - 600, _h + 600, 8), // 8 steps / 20 min = 24 spm
      ]);
      // Half the span (600s of 1200s) sits inside the still hour and is
      // voided; the other half survives.
      expect(r.strap, 4);
    });

    test('no confirmed-still hour anywhere leaves the ladder untouched', () {
      final r = resolveDaySteps([
        _band(9 * _h, 9 * _h + 600, 30), // 30/10min = 180 spm, real gait
      ]);
      expect(r.total, 30);
    });

    test('nothing covered anything → nothing, and no dominant sensor', () {
      expect(resolveDaySteps(const []).total, 0);
      expect(resolveDaySteps(const []).dominant, isNull);
      // A legacy zero-width row still carries a real count and keeps it.
      expect(resolveDaySteps([_band(0, 0, 1230)]).total, 1230);
    });
  });

  group('the gen5 on-chip counter is a whole-day FALLBACK, not a day-winner',
      () {
    // A cumulative counter advancing 622 over the day. `step: 600` keeps each
    // delta inside hardwareStepsFromCounter's plausibility budget.
    final gen5 = _sub([0, 300, 622]);

    test('622 on-chip steps NEVER override 18,856 windowed phone steps', () {
      final (steps, scalars) = _derive(
        gen5,
        liveStepsReal: 18856,
        liveStepsFromStrap: 0,
      );
      expect(scalars['steps'], 18856.0, reason: 'the whole-day-precedence bug');
      expect(steps['value'], 18856);
      expect(steps['source'], 'phone');
      // The counter is still disclosed — it is just not the answer.
      expect(steps['band_measured'], 622);
      expect(steps['by_source'], {'phone': 18856});
    });

    test('it DOES answer when no span source covered the day at all', () {
      final (steps, scalars) = _derive(
        gen5,
        liveStepsReal: 0,
        liveStepsFromStrap: 0,
      );
      expect(scalars['steps'], 622.0);
      expect(steps['source'], 'strap_counter');
      expect(steps['by_source'], {'strap_counter': 622});
    });

    test('a mixed day names both sensors and splits them', () {
      final (steps, _) = _derive(
        gen5,
        liveStepsReal: 5200,
        liveStepsFromStrap: 4000,
      );
      expect(steps['value'], 5200);
      expect(steps['source'], 'mixed');
      expect(steps['by_source'], {'strap': 4000, 'phone': 1200});
      expect(steps['inputs_used'], ['band_pedometer_100hz', 'phone_pedometer']);
    });

    // THE DISCLOSURE CONTRACT, end to end: what the derivation writes is what
    // the card reads. `inputs_used` names the SENSOR, so a phone count can
    // never render as the wrist's or the other way round.
    test('the card can name the sensor off the envelope the derive wrote', () {
      String? label(int total, int strap) =>
          stepSensorLabel(Metric.parse(_derive(
            gen5,
            liveStepsReal: total,
            liveStepsFromStrap: strap,
          ).$1));

      expect(label(5200, 4000), 'Strap + phone');
      expect(label(4000, 4000), 'Strap');
      expect(label(4000, 0), 'Phone');
      expect(label(0, 0), 'Strap', reason: 'the on-chip counter is the strap');
      expect(
        stepSensorLabel(Metric.parse(
            _derive(_sub([-1, -1]), liveStepsReal: 0, liveStepsFromStrap: 0).$1)),
        isNull,
        reason: 'nothing counted — the card must not name a sensor',
      );
    });

    test('no counter and no coverage stays ABSENT, never a zero', () {
      final (steps, scalars) = _derive(
        _sub([-1, -1, -1]), // gen4: this hardware cannot count steps
        liveStepsReal: 0,
        liveStepsFromStrap: 0,
      );
      expect(scalars.containsKey('steps'), isFalse);
      expect(steps['value'], isNull);
      expect(steps['source'], isNull);
      expect(steps['tier'], isNull);
      expect(steps['by_source'], isEmpty);
    });
  });
}
