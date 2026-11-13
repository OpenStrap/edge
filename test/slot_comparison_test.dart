// Slot comparison: what a device gives "Every day" (the main band, or the
// active wearable) and "Workouts only" (a workout-armed sensor). Capabilities
// come from the compute layer's eligibility rules: the metric x device
// columns (canonical.dart columnFor/capabilities), the native WHOOP pipeline,
// and the workout-armed sensor set.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart'
    show MetricClass, capabilities, columnFor, kWorkoutArmedSensors;

typedef C = DeviceCapability;
typedef K = CapabilityKind;

// The table's rows, in the order the sheets draw them (owner-approved r4
// mockup): the whole-day rows, then the workout rows. Never blood oxygen.
const _dayRows = <DeviceCapability>[
  C.sleep,
  C.recovery,
  C.strain,
  C.heartRate,
  C.hrv,
  C.respiration,
  C.skinTemperature,
  C.steps,
];
const _workoutRows = <DeviceCapability>[C.workoutHeartRate, C.workoutBeatToBeat];

Set<DeviceCapability> _keys(SlotSide s) => s.sends.keys.toSet();

List<BandEntry> _columnEntries() =>
    [for (final e in kBandRegistry) if (columnFor(e.id) != null) e];

void main() {
  test('the table rows are the eight whole-day rows, then the two workout rows', () {
    // WHY: every sheet and the device card draw the same rows in the same
    // order; a drifting list changes every table at once.
    expect(kDayCapabilities, _dayRows);
    expect(kSessionCapabilities.toList(), _workoutRows);
    expect(kTableRows, [..._dayRows, ..._workoutRows]);
    expect(kTableRows, isNot(contains(C.bloodOxygen)));
  });

  group('WHOOP', () {
    for (final e in [kWhoopGen4, kWhoopGen5]) {
      test('${e.id}: every day, as the main band, sends every row', () {
        // WHY: the native pipeline (onehz_pipeline.dart) computes sleep,
        // recovery, strain, resting HR, HRV, respiration and skin temperature,
        // and the band records workouts.
        final cmp = slotComparisonFor(e);
        expect(cmp.slot, DeviceSlot.everyDay);
        final d = cmp.everyDay.sends;
        expect(d.keys.toSet(), {..._dayRows, ..._workoutRows});
        for (final c in [C.sleep, C.recovery, C.strain, C.heartRate, C.hrv,
            C.respiration, C.workoutHeartRate, C.workoutBeatToBeat]) {
          expect(d[c]?.kind, K.native, reason: '${e.id} $c');
        }
        // a nightly mean, >= 3 prior nights, baseline spread >= 1.
        expect(d[C.skinTemperature]?.kind, K.conditional);
        expect(d[C.skinTemperature]?.reasonKey, kReasonSkinTempNights);
      });

      test('${e.id}: workouts only, read as a heart-rate sensor', () {
        // WHY: a WHOOP kept for workouts is paired under ble_hrs, so it sends
        // heart rate, and beat timing only if the band sends RR intervals.
        final w = slotComparisonFor(e).workoutsOnly.sends;
        expect(w.keys.toSet(), _workoutRows.toSet());
        expect(w[C.workoutHeartRate]?.kind, K.native);
        expect(w[C.workoutBeatToBeat]?.kind, K.conditional);
        expect(w[C.workoutBeatToBeat]?.reasonKey, kReasonUnconfirmed);
      });
    }

    test('steps: WHOOP 4 only during live sessions, WHOOP 5 from its own counter', () {
      // WHY: gen4 has no on-chip counter (derivation_engine.dart
      // _stepCounterModulus), so its steps come only from the strap's 100 Hz
      // pedometer over a live link (live_step_runs.dart). gen5's cumulative
      // counter rides every synced row (decoded_onehz.step_count).
      final g4 = slotComparisonFor(kWhoopGen4).everyDay.sends[C.steps];
      expect(g4?.kind, K.conditional);
      expect(g4?.reasonKey, kReasonLiveSessions);
      expect(slotComparisonFor(kWhoopGen5).everyDay.sends[C.steps]?.kind,
          K.native);
    });
  });

  group('wearables fill every day (the active wearable)', () {
    test('the six columned entries are found (control for the loops below)', () {
      expect({for (final e in _columnEntries()) e.id},
          {'garmin', 'pebble', 'miband234', 'ultrahuman', 'colmi', 'oura'});
    });

    test('Oura: the rows read off kOuraColumn, with their captions', () {
      // WHY: oura_inputs.dart: sleep off the ring's own stages, readiness
      // provisional until 14 nights of baseline, skin temperature after a few
      // nights, strain and steps not decoded; not workout-armed.
      final cmp = slotComparisonFor(kOura);
      expect(cmp.slot, DeviceSlot.everyDay);
      final d = cmp.everyDay.sends;
      expect(d.keys.toSet(), {C.sleep, C.recovery, C.heartRate, C.hrv,
          C.respiration, C.skinTemperature});
      expect(d[C.sleep]?.reasonKey, kReasonOwnStagesRing);
      expect(d[C.recovery]?.reasonKey, kReasonFirstNights);
      expect(d[C.skinTemperature]?.reasonKey, kReasonSkinTempProvisional);
      for (final c in [C.heartRate, C.hrv, C.respiration]) {
        expect(d[c]?.kind, K.native, reason: '$c');
      }
      expect(cmp.workoutsOnly.sends, isEmpty);
    });

    test('every columned wearable: every-day rows follow capabilities(column)', () {
      // WHY: ours -> native (or a stated condition), device -> the device's own
      // reading, estimated -> conditional, unavailable -> not sent.
      for (final e in _columnEntries()) {
        final col = columnFor(e.id)!;
        final cls = capabilities(col);
        final cmp = slotComparisonFor(e);
        expect(cmp.slot, DeviceSlot.everyDay, reason: e.id);
        expect(cmp.workoutsOnly.sends, isEmpty, reason: e.id);
        final sends = cmp.everyDay.sends;
        for (final m in kCapabilityRow.entries) {
          final c = cls[m.value];
          final got = sends[m.key];
          final why = '${e.id} ${m.key} ($c)';
          switch (c) {
            case null || MetricClass.unavailable:
              expect(got, isNull, reason: why);
            case MetricClass.device:
              expect(got?.kind, K.vendorReported, reason: why);
            case MetricClass.estimated:
              expect(got?.kind, K.conditional, reason: why);
            case MetricClass.ours:
              expect(got, isNotNull, reason: why);
              expect(got!.kind, isNot(K.vendorReported), reason: why);
          }
          if (got?.kind == K.conditional) {
            expect(got!.reasonKey?.trim() ?? '', isNotEmpty, reason: why);
          }
        }
        expect(sends.keys.toSet().intersection(_workoutRows.toSet()), isEmpty,
            reason: '${e.id}: a wearable is no workout session source');
      }
    });

    test('Pebble HR rows are Pebble 2 only; SE keeps reported sleep and steps', () {
      final cmp = slotComparisonFor(kPebble);
      final d = cmp.everyDay.sends;
      expect(d.keys.toSet(), {C.sleep, C.recovery, C.strain, C.heartRate, C.steps});
      for (final c in [C.recovery, C.strain, C.heartRate]) {
        expect(d[c]?.kind, K.conditional, reason: 'SE has no HR sensor: $c');
      }
      expect(d[C.strain]?.reasonKey, 'capReasonPebble2Only');
      expect(d[C.heartRate]?.reasonKey, 'capReasonPebble2Only');
      // WHY: Pebble 2's recovery is an estimate; the
      // Pebble 2 only caption must not drop that.
      expect(d[C.recovery]?.reasonKey, 'capReasonPebble2OnlyEstimated');
      expect(d[C.sleep]?.reasonKey, kReasonOwnStages);
      expect(d[C.steps]?.kind, K.vendorReported);
      expect(cmp.workoutsOnly.sends, isEmpty);
    });

    test('hand-read anchors: Garmin', () {
      // garmin_inputs.dart: HRV the watch's own unless a strap gave beats,
      // readiness an estimate without a strap, strain ours, no skin temp.
      final g = slotComparisonFor(kGarmin).everyDay.sends;
      expect(g.containsKey(C.skinTemperature), isFalse);
      expect(g[C.hrv]?.kind, K.vendorReported);
      expect(g[C.recovery]?.kind, K.conditional);
      expect(g[C.strain]?.kind, K.native);
    });
  });

  group('workout sensors fill workouts only', () {
    test('a chest strap: heart rate; beat timing if the strap sends it', () {
      // WHY: kWorkoutArmedSensors arms ble_hrs; RR intervals are optional in
      // the Heart Rate Service.
      final cmp = slotComparisonFor(kBleHrs);
      expect(cmp.slot, DeviceSlot.workoutsOnly);
      expect(cmp.everyDay.sends, isEmpty);
      final w = cmp.workoutsOnly.sends;
      expect(w[C.workoutHeartRate]?.kind, K.native);
      expect(w[C.workoutBeatToBeat]?.reasonKey, kReasonUnconfirmed);
      expect(cmp.workoutsOnly.doesNotSend, _dayRows.toSet());
    });

    test('Polar PMD: its PPI stream is beats, so no "not confirmed" caption', () {
      final w = slotComparisonFor(kPolarPmd).workoutsOnly.sends;
      expect(w[C.workoutBeatToBeat]?.kind, K.native);
      expect(w[C.workoutHeartRate]?.reasonKey, isNull);
      expect(slotComparisonFor(kPolarPmd).slot, DeviceSlot.workoutsOnly);
    });

    test('only the armed sensors and a WHOOP send anything for workouts', () {
      expect(kWorkoutArmedSensors, {'ble_hrs', 'polar_pmd'});
      for (final e in kBandRegistry) {
        final w = _keys(slotComparisonFor(e).workoutsOnly);
        final armed = {'ble_hrs', 'polar_pmd', 'gen4', 'gen5'}.contains(e.id);
        expect(w, armed ? _workoutRows.toSet() : isEmpty, reason: e.id);
      }
    });
  });

  test('"not confirmed" only where the device may not send it: a generic strap, a WHOOP read as one', () {
    // WHY: devices people use (Oura, Polar) carry only factual
    // captions; the unconfirmed one is for RR from the generic profile.
    final unconfirmed = {
      for (final e in kBandRegistry)
        for (final s in DeviceSlot.values)
          for (final m in slotComparisonFor(e).side(s).sends.entries)
            if (m.value.reasonKey == kReasonUnconfirmed) '${e.id}:${m.key.name}',
    };
    expect(unconfirmed, {
      'ble_hrs:workoutBeatToBeat',
      'gen4:workoutBeatToBeat',
      'gen5:workoutBeatToBeat',
    });
  });

  test('Coros, scales and thermometers fit neither column', () {
    // WHY: canonical.dart wearableEnabled() is false for Coros and it has no
    // column; nothing arms it for workouts.
    expect(declaredSignals('coros').map((s) => s.name), contains('rrIntervals'),
        reason: 'positive control: Coros does declare beats');
    for (final e in [kCoros, kThermometer, kMiScale2, kMiScaleComposition]) {
      final cmp = slotComparisonFor(e);
      expect(cmp.slot, isNull, reason: e.id);
      expect(cmp.everyDay.sends, isEmpty, reason: e.id);
      expect(cmp.workoutsOnly.sends, isEmpty, reason: e.id);
    }
  });

  test('no registry entry claims blood oxygen, in either column', () {
    expect(capabilities(columnFor('oura')!)['spo2'], MetricClass.device,
        reason: 'positive control: a column does offer a vendor spo2');
    for (final e in kBandRegistry) {
      final cmp = slotComparisonFor(e);
      for (final s in DeviceSlot.values) {
        expect(cmp.side(s).sends.containsKey(C.bloodOxygen), isFalse,
            reason: '${e.id} $s');
        expect(cmp.side(s).doesNotSend.contains(C.bloodOxygen), isFalse,
            reason: '${e.id} $s');
        expect(capabilityTrace(e, C.bloodOxygen, slot: s), isNull,
            reason: '${e.id} $s');
      }
    }
  });

  test('doesNotSend is the table rows minus sends, for every entry and column', () {
    for (final e in kBandRegistry) {
      final cmp = slotComparisonFor(e);
      for (final s in DeviceSlot.values) {
        final side = cmp.side(s);
        expect(side.doesNotSend, kTableRows.toSet().difference(_keys(side)),
            reason: '${e.id} $s');
      }
    }
  });

  group('nothing fabricated', () {
    test('every claim traces to an eligibility rule in an existing file', () {
      var claims = 0;
      for (final e in kBandRegistry) {
        final cmp = slotComparisonFor(e);
        for (final s in DeviceSlot.values) {
          for (final c in cmp.side(s).sends.keys) {
            claims++;
            final t = capabilityTrace(e, c, slot: s);
            final why = '${e.id} $s $c';
            expect(t, isNotNull, reason: why);
            expect(t!.rule.trim(), isNotEmpty, reason: why);
            expect(File(t.source).existsSync(), isTrue, reason: '$why: ${t.source}');
          }
        }
      }
      expect(claims, greaterThan(20), reason: 'vacuity control');
    });

    test('an every-day claim needs a column or the native WHOOP pipeline', () {
      for (final e in kBandRegistry) {
        final eligible =
            columnFor(e.id) != null || e.id == 'gen4' || e.id == 'gen5';
        if (!eligible) {
          expect(slotComparisonFor(e).everyDay.sends, isEmpty, reason: e.id);
        }
      }
    });

    test('every whole-day capability has a column row', () {
      final rows = {for (final e in _columnEntries()) ...columnFor(e.id)!.keys};
      for (final c in _dayRows) {
        expect(kCapabilityRow[c], isNotNull, reason: '$c');
        expect(rows, contains(kCapabilityRow[c]), reason: '$c');
      }
    });
  });

  test('every label and reason key the table can show has text in every locale', () {
    final keys = <String>{for (final c in kTableRows) kCapabilityLabelKey[c]!};
    for (final e in kBandRegistry) {
      final cmp = slotComparisonFor(e);
      for (final s in DeviceSlot.values) {
        for (final st in cmp.side(s).sends.values) {
          if (st.reasonKey != null) keys.add(st.reasonKey!);
        }
      }
    }
    expect(keys.length, greaterThan(kTableRows.length + 4),
        reason: 'vacuity control: some reason keys were found');
    final arbs = Directory('lib/l10n').listSync().whereType<File>().where(
        (f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path));
    expect(arbs.length, 8);
    for (final f in arbs) {
      final arb = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final bad = [
        for (final k in keys)
          if (arb[k] is! String || (arb[k] as String).trim().isEmpty) k,
      ];
      expect(bad, isEmpty, reason: '${f.path}: $bad');
    }
  });
}
