@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/ed2a_recalc_fixture.dart';

void main() {
  setUpAll(edInit);
  setUp(() => edFresh('ed2b_d35.db'));
  tearDown(edDrop);

  for (final signal in [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
    test('$signal inclusive endpoint is covered by the ownership read and spans', () async {
      final end = edStart + 600;
      final db = await LocalDb.instance;
      // This interval starts exactly at the inclusive last sample. A query
      // ending at `end` silently omits it, even if resolution is later fixed.
      await db.insert('device_coverage', {'device_id': '', 'signal': signal.name,
        'start_ts': end, 'end_ts': end + 1});
      final (ownership, _) = await DerivationEngine().debugResolveOwnership(edStart, end);
      expect(spanAt(ownership[signal]!, end)?.deviceId, '',
          reason: 'both coverage query and resolution must extend through to+1');
      expect(ownership[signal]!.last.end, end + 1);
    });
  }

  test('non-owner last-second HR does not leak into a single-second load', () async {
    await edRows(edStart, edStart + 601, hr: 61);
    await edRows(edStart + 600, edStart + 601, hr: 199, id: 'unranked');
    final db = await LocalDb.instance;
    await db.insert('device_coverage', {'device_id': '', 'signal': 'hr1Hz',
      'start_ts': edStart, 'end_ts': edStart + 601});
    final e = DerivationEngine()..debugDisableSubstrateRetention = true;
    final last = await e.debugLoadOwnedSubstrate(edStart + 600, edStart + 600, day: edDay);
    expect(last.hr, [61], reason: 'a zero-width half-open resolver must not disable the filter');
  });

  test('non-owner last-second RR beats are excluded by the same inclusive ownership', () async {
    await edRows(edStart, edStart + 601, hr: 61);
    final db = await LocalDb.instance;
    await db.insert('device_coverage', {'device_id': '', 'signal': 'rrIntervals',
      'start_ts': edStart, 'end_ts': edStart + 601});
    for (final id in ['', 'unranked']) {
      await db.insert('decoded_rr', {'device_id': id,
        'ts_ms': (edStart + 600) * 1000, 'rec_ts': edStart + 600,
        'rr_ts_ms': (edStart + 600) * 1000, 'beat_index': 0,
        'rr_ms': id.isEmpty ? 900 : 1500});
    }
    final last = await DerivationEngine().debugLoadOwnedSubstrate(
        edStart + 600, edStart + 600, day: edDay);
    expect(last.rrMs, [900], reason: 'the other device must not add a beat at to');
  });

  test('same endpoint loaded alone or inside a larger range has identical owner data', () async {
    await edRows(edStart, edStart + 601, hr: 61);
    await edRows(edStart + 600, edStart + 601, hr: 199, id: 'unranked');
    final db = await LocalDb.instance;
    await db.insert('device_coverage', {'device_id': '', 'signal': 'hr1Hz',
      'start_ts': edStart, 'end_ts': edStart + 601});
    final e = DerivationEngine()..debugDisableSubstrateRetention = true;
    final wide = await e.debugLoadOwnedSubstrate(edStart, edStart + 601, day: edDay);
    final alone = await e.debugLoadOwnedSubstrate(edStart + 600, edStart + 600, day: edDay);
    expect(jsonEncode(alone.toJson()),
        jsonEncode(wide.slice(edStart + 600, edStart + 601).toJson()));
  });

  test('interior ownership stays primary and absent owner stays absent (guard)', () async {
    await edRows(edStart, edStart + 600, hr: 61);
    await edRows(edStart, edStart + 600, hr: 199, id: 'unranked');
    final db = await LocalDb.instance;
    await db.insert('device_coverage', {'device_id': '', 'signal': 'hr1Hz',
      'start_ts': edStart, 'end_ts': edStart + 600});
    final sub = await DerivationEngine().debugLoadOwnedSubstrate(edStart, edStart + 600, day: edDay);
    expect(sub.hr, everyElement(61));
    final (ownership, _) = await DerivationEngine().debugResolveOwnership(edStart - 60, edStart - 1);
    expect(ownership[InputSignal.hr1Hz], everyElement(predicate<OwnedSpan>((s) => s.deviceId == null)));
  });
}
