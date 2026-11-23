// The Amazfit Scale's live-only session through [ReplayBandLink]: UTC clock,
// finished weighings become `weight` rows, nothing else is written.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/miscale.dart';
import 'package:openstrap_edge/ble/scale_presence.dart';
import 'package:openstrap_edge/ble/session_link.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final int _nowSec = DateTime.utc(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000;

List<int> _rec(int flags, int raw, DateTime t) {
  final packed = t.year |
      (t.month << 13) |
      (t.day << 17) |
      (t.hour << 22) |
      (t.minute << 28) |
      (t.second << 34);
  return [
    flags & 0xff, flags >> 8,
    for (var k = 0; k < 5; k++) (packed >> (8 * k)) & 0xff,
    raw & 0xff, raw >> 8,
    ...List<int>.filled(11, 0),
  ];
}

const _done = 0x0008 | (1 << 9);

Future<(List<Observation>, ReplayBandLink)> _drive(List<List<int>> live) async {
  final link = ReplayBandLink();
  for (final f in live) {
    link.feed(kAmazfitScaleMeasureChar, f, atSec: _nowSec);
  }
  final rows = <Observation>[];
  final done = Completer<void>();
  final sub = AmazfitScaleAdapter(
    nowSeconds: () => _nowSec,
    firstWait: const Duration(milliseconds: 100),
    quiet: const Duration(milliseconds: 50),
  ).run(link).listen((e) {
    if (e is VendorScalars) rows.addAll(e.rows);
  }, onDone: done.complete);
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (rows, link);
}

void main() {
  test('registry: a scale, found by its exact name, on the session path', () {
    expect(kAmazfitScale.kind, DeviceKind.scale);
    expect(kAmazfitScale.category, DeviceCategory.healthMeasurement);
    expect([
      for (final e in kBandRegistry)
        if (e.nameMatcher?.call('amazfit scale') ?? false) e.id,
    ], ['amazfit_scale']);
    expect(SessionLink.forId('amazfit_scale')?.entry, kAmazfitScale);
    expect(kAutoSyncAdapters, contains('amazfit_scale'));
  });

  test('finished weighings become weight rows at their UTC stamp; the clock '
      'is the only write', () async {
    final at = DateTime.utc(2026, 10, 4, 7, 29, 10);
    final (rows, link) = await _drive([
      _rec(0x0008, 14000, at), // still measuring
      [..._rec(_done, 14400, at), ..._rec(_done, 14400, at)], // repeated
    ]);
    expect([for (final r in rows) (r.key, r.value, r.unit, r.at)],
        [('weight', 72.0, 'kg', at)]);
    expect(rows.single.sourceKind, ObservationSource.vendor);
    expect(link.writes.map((w) => w.$1), [kAmazfitScaleClockChar]);
    expect(link.writes.single.$2,
        miScaleClockValue(DateTime.fromMillisecondsSinceEpoch(_nowSec * 1000,
            isUtc: true)));
  });

  test('nothing finished: no rows', () async {
    final (rows, _) = await _drive([
      _rec(0x0008 | (2 << 9), 14400, DateTime.utc(2026, 10, 4, 7)),
    ]);
    expect(rows, isEmpty);
  });
}
