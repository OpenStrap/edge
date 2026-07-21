// Regression tests for the READINESS ring flashing a wrong score (e.g. 100)
// before snapping to the true value on load/refresh.
//
// Root cause: while today's overnight is still building, getToday surfaces the
// LAST settled night's readiness (`showing_prior_overnight`) so the rest of the
// Today screen has data to show. The orbit hero rendered that held-over value as
// the big readiness number, so for the split second before today's real score
// landed the ring showed the prior night's figure and then snapped to today's.
//
// The fix routes the hero (and the once-a-morning recovery story) through
// `TodayData.settledReadinessScore`, which withholds the number until today's
// overnight has actually settled (`overnight_state == 'ready'`). These tests pin
// that gate.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/payloads.dart';

TodayData _today({
  Object? readiness,
  String? overnightState,
  bool showingPrior = false,
}) {
  return TodayData.fromJson({
    'daily': {if (readiness != null) 'readiness': readiness},
    'sleep': const <String, dynamic>{},
    if (overnightState != null)
      'status': {
        'overnight_state': overnightState,
        'showing_prior_overnight': showingPrior,
      },
  });
}

void main() {
  group('TodayData.settledReadinessScore', () {
    test('today overnight SETTLED → the real score is surfaced', () {
      final t = _today(
        readiness: {'value': 73, 'confidence': 0.8, 'tier': 'HIGH'},
        overnightState: 'ready',
      );
      expect(t.settledReadinessScore, 73);
      // Rounds like the hero does.
      final t2 = _today(
        readiness: {'value': 72.6, 'confidence': 0.8},
        overnightState: 'ready',
      );
      expect(t2.settledReadinessScore, 73);
    });

    test('overnight still BUILDING → held-over prior value is withheld (the bug)',
        () {
      // This is the flash: a prior night's 100 surfaced while today computes.
      final t = _today(
        readiness: {'value': 100, 'confidence': 0.8, 'tier': 'HIGH'},
        overnightState: 'building',
        showingPrior: true,
      );
      expect(t.settledReadinessScore, isNull);
    });

    test('overnight MISSING → nothing settled for today → withheld', () {
      final t = _today(
        readiness: {'value': 88, 'confidence': 0.8},
        overnightState: 'missing',
        showingPrior: true,
      );
      expect(t.settledReadinessScore, isNull);
    });

    test('absent readiness → null regardless of overnight state', () {
      expect(_today(overnightState: 'ready').settledReadinessScore, isNull);
      expect(
        _today(
          readiness: {'note': 'need_baseline:have=2,need=5'},
          overnightState: 'ready',
        ).settledReadinessScore,
        isNull,
      );
    });

    test('no status block (synthetic payload) → shows, unchanged behaviour', () {
      final t = _today(readiness: {'value': 82, 'confidence': 0.9});
      expect(t.settledReadinessScore, 82);
    });
  });
}
