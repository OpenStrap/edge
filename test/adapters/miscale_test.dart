// The Mi scales' session, replayed through [ReplayBandLink]: user mode, the
// UTC clock, the history handshake and how frames become rows.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/miscale.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final int _nowSec = DateTime.utc(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000;

List<int> _dt(DateTime t) =>
    [t.year & 0xff, t.year >> 8, t.month, t.day, t.hour, t.minute, t.second];

List<int> _bc(int f1, int ohm, int raw, DateTime t) =>
    [0x00, f1, ..._dt(t), ohm & 0xff, ohm >> 8, raw & 0xff, raw >> 8];

List<int> _rec(int flags, int raw, DateTime t) =>
    [flags, raw & 0xff, raw >> 8, ..._dt(t)];

/// Drive [entry]'s adapter: [live] is pushed unprompted, [reply] answers
/// each write. Returns every row and the link.
Future<(List<Observation>, ReplayBandLink)> _drive(
  BandEntry entry, {
  List<List<int>> live = const [],
  List<(String, List<int>)> Function(String uuid, List<int> v)? reply,
  Map<String, List<int>> reads = const {},
}) async {
  final link = ReplayBandLink()..readValues.addAll(reads);
  final adapter = MiScaleAdapter(
    entry,
    nowSeconds: () => _nowSec,
    firstWait: const Duration(milliseconds: 100),
    quiet: const Duration(milliseconds: 50),
    replyTimeout: const Duration(milliseconds: 100),
    historyQuiet: const Duration(milliseconds: 100),
  );
  final liveChar = entry.id == kMiScale2.id
      ? kMiScaleWeightChar
      : kMiScaleBodyCompositionChar;
  for (final f in live) {
    link.feed(liveChar, f, atSec: _nowSec);
  }
  final rows = <Observation>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen((e) {
    if (e is VendorScalars) rows.addAll(e.rows);
  }, onDone: done.complete);
  var served = 0;
  for (var spin = 0; spin < 200 && !done.isCompleted; spin++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    while (served < link.writes.length) {
      final (uuid, v) = link.writes[served++];
      for (final (u, f) in reply?.call(uuid, v) ?? const <(String, List<int>)>[]) {
        link.feed(u, f, atSec: _nowSec);
      }
    }
  }
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (rows, link);
}

List<List<int>> _historyWrites(ReplayBandLink link) => [
      for (final (u, v) in link.writes)
        if (u == kMiScaleHistoryChar) v,
    ];

void main() {
  test('composition: weight from the first stable frame, impedance from the '
      'impedance-stable frame with the same stamp', () async {
    final at = DateTime.utc(2026, 10, 4, 7, 29, 10);
    final (rows, _) = await _drive(kMiScaleComposition, live: [
      _bc(0x20, 0xFFFE, 14368, at), // stable, impedance still measuring
      _bc(0x22, 500, 14368, at), // impedance stable
    ]);
    expect(rows.map((r) => (r.key ?? r.vendorKey, r.value)),
        [('weight', 71.84), ('impedance', 500)]);
    expect(rows.first.at, at, reason: 'stamps are UTC');
  });

  test('both scales set the clock in UTC', () async {
    for (final e in [kMiScaleComposition, kMiScale2]) {
      final (_, link) = await _drive(e);
      final clock = link.writes.where((w) => w.$1 == kCurrentTimeChar).single;
      expect(clock.$2,
          miScaleClockValue(DateTime.utc(2026, 10, 4, 8)), reason: e.id);
    }
  });

  test('mode 3 gets the user-mode command for that scale; another mode none',
      () async {
    for (final (e, cmd) in [
      (kMiScale2, [3, 1, 0, 0, 0]),
      (kMiScaleComposition, [6, 11, 0, 0]),
    ]) {
      var (_, link) = await _drive(e, reads: {kMiScaleModeChar: [3, 0]});
      expect(link.writes.where((w) => w.$1 == kMiScaleModeChar).single.$2, cmd,
          reason: e.id);
      (_, link) = await _drive(e, reads: {kMiScaleModeChar: [1, 0]});
      expect(link.writes.where((w) => w.$1 == kMiScaleModeChar), isEmpty,
          reason: e.id);
    }
    // The composition scale also takes it when the mode cannot be read.
    final (_, link) = await _drive(kMiScaleComposition);
    expect(link.writes.where((w) => w.$1 == kMiScaleModeChar).single.$2,
        [6, 11, 0, 0]);
  });

  test('history: count 0 is stopped without a send, and nothing deletes',
      () async {
    final (_, link) = await _drive(kMiScale2,
        reply: (u, v) => u == kMiScaleHistoryChar && v.first == 0x01
            ? [(kMiScaleHistoryChar, [0x01, 0, 0])]
            : const []);
    expect(_historyWrites(link), [
      [1, 1, 0, 0, 0],
      [3],
    ]);
  });

  test('history: waits for the count, sends, stops; drops a record with an '
      'implausible stamp but keeps a live one', () async {
    final (rows, link) = await _drive(
      kMiScale2,
      live: [_rec(0x20, 14400, DateTime.utc(2026, 10, 4, 7, 59))],
      reply: (u, v) => switch ((u == kMiScaleHistoryChar, v.first)) {
        (true, 0x01) => [(kMiScaleHistoryChar, [0x01, 2, 0])],
        (true, 0x02) => [
            (kMiScaleHistoryChar, [
              ..._rec(0xa2, 14000, DateTime.utc(2000)),
              ..._rec(0xa2, 14200, DateTime.utc(2026, 10, 3, 7)),
            ]),
            (kMiScaleHistoryChar, [0x03]),
          ],
        _ => const [],
      },
    );
    expect(_historyWrites(link), [
      [1, 1, 0, 0, 0],
      [2],
      [3],
    ]);
    expect(rows.map((r) => r.value), unorderedEquals([71.0, 72.0]));
  });

  test('composition history is read back in 13-byte records', () async {
    final (rows, link) = await _drive(
      kMiScaleComposition,
      reply: (u, v) => switch ((u == kMiScaleHistoryChar, v.first)) {
        (true, 0x01) => [(kMiScaleHistoryChar, [0x01, 2, 0])],
        (true, 0x02) => [
            (kMiScaleHistoryChar, [
              ..._bc(0x22, 480, 14000, DateTime.utc(2026, 10, 2, 7)),
              ..._bc(0x22, 490, 14200, DateTime.utc(2026, 10, 3, 7)),
            ]),
            (kMiScaleHistoryChar, <int>[]),
          ],
        _ => const [],
      },
    );
    expect(_historyWrites(link).last, [3]);
    expect(rows.where((r) => r.key == 'weight').map((r) => r.value),
        [70.0, 71.0]);
    expect(rows.where((r) => r.vendorKey == 'impedance').map((r) => r.value),
        [480, 490]);
  });

  test('a scale that never goes quiet still yields its weighing inside the '
      'session budget', () async {
    final at = DateTime.utc(2026, 10, 4, 7, 59);
    final link = ReplayBandLink();
    // Notifies every 20 ms, far inside the 50 ms quiet: without a budget the
    // live phase never ends, and the host's window cancels it unyielded.
    final pump = Timer.periodic(const Duration(milliseconds: 20),
        (_) => link.feed(kMiScaleWeightChar, _rec(0x20, 14400, at),
            atSec: _nowSec));
    addTearDown(pump.cancel);
    final rows = <Observation>[];
    final adapter = MiScaleAdapter(
      kMiScale2,
      nowSeconds: () => _nowSec,
      firstWait: const Duration(milliseconds: 100),
      quiet: const Duration(milliseconds: 50),
      replyTimeout: const Duration(milliseconds: 100),
      historyQuiet: const Duration(milliseconds: 100),
      budget: const Duration(milliseconds: 400),
    );
    await adapter.run(link).forEach((e) {
      if (e is VendorScalars) rows.addAll(e.rows);
    }).timeout(const Duration(seconds: 3));
    expect(rows.map((r) => (r.key, r.value)), [('weight', 72.0)]);
  });

  test("history stamped under another app's local clock is read as local; "
      'under ours, as UTC', () async {
    // Meaningful in a zone off UTC (the freeze runs include Asia/Kolkata and
    // America/New_York); in UTC both readings are the same instant.
    final localNow = DateTime.fromMillisecondsSinceEpoch(_nowSec * 1000);
    List<(String, List<int>)> history(String u, List<int> v) =>
        switch ((u == kMiScaleHistoryChar, v.first)) {
          (true, 0x01) => [(kMiScaleHistoryChar, [0x01, 1, 0])],
          (true, 0x02) => [
              (kMiScaleHistoryChar,
                  _rec(0xa2, 14200, DateTime.utc(2026, 10, 3, 7))),
              (kMiScaleHistoryChar, [0x03]),
            ],
          _ => const [],
        };
    for (final (clock, want) in [
      (localNow, DateTime(2026, 10, 3, 7)),
      (DateTime.utc(2026, 10, 4, 8), DateTime.utc(2026, 10, 3, 7)),
    ]) {
      final (rows, _) = await _drive(kMiScale2,
          reads: {kCurrentTimeChar: _dt(clock)}, reply: history);
      expect(rows.single.at.millisecondsSinceEpoch,
          want.millisecondsSinceEpoch, reason: '$clock');
    }
  });

  test('a local clock set before a daylight-saving change (an hour off local '
      'time) stays local: its history is read as local, the clock rewritten '
      'local', () async {
    // Meaningful in a zone off UTC, like the test above.
    final localNow = DateTime.fromMillisecondsSinceEpoch(_nowSec * 1000);
    final setUnderDst = localNow.add(const Duration(hours: 1));
    List<(String, List<int>)> history(String u, List<int> v) =>
        switch ((u == kMiScaleHistoryChar, v.first)) {
          (true, 0x01) => [(kMiScaleHistoryChar, [0x01, 1, 0])],
          (true, 0x02) => [
              (kMiScaleHistoryChar,
                  _rec(0xa2, 14200, DateTime.utc(2026, 10, 3, 7))),
              (kMiScaleHistoryChar, [0x03]),
            ],
          _ => const [],
        };
    for (final clock in [setUnderDst, localNow.add(const Duration(hours: -1))]) {
      final (rows, link) = await _drive(kMiScale2,
          reads: {kCurrentTimeChar: _dt(clock)}, reply: history);
      expect(rows.single.at.millisecondsSinceEpoch,
          DateTime(2026, 10, 3, 7).millisecondsSinceEpoch, reason: '$clock');
      expect(link.writes.lastWhere((w) => w.$1 == kCurrentTimeChar).$2,
          miScaleClockValue(localNow), reason: '$clock');
    }
  });

  test('the history is never deleted, so it is re-sent: session 2 reads the '
      'clock session 1 wrote and places the same record at the same instant',
      () async {
    // Meaningful off UTC, like the test above.
    List<(String, List<int>)> history(String u, List<int> v) =>
        switch ((u == kMiScaleHistoryChar, v.first)) {
          (true, 0x01) => [(kMiScaleHistoryChar, [0x01, 1, 0])],
          (true, 0x02) => [
              (kMiScaleHistoryChar,
                  _rec(0xa2, 14200, DateTime.utc(2026, 10, 3, 7))),
              (kMiScaleHistoryChar, [0x03]),
            ],
          _ => const [],
        };
    var clock = _dt(DateTime.fromMillisecondsSinceEpoch(_nowSec * 1000));
    final stamps = <int>{};
    for (var session = 1; session <= 3; session++) {
      final (rows, link) = await _drive(kMiScale2,
          reads: {kCurrentTimeChar: clock}, reply: history);
      stamps.add(rows.single.at.millisecondsSinceEpoch);
      clock = link.writes.lastWhere((w) => w.$1 == kCurrentTimeChar).$2;
    }
    expect(stamps, {DateTime(2026, 10, 3, 7).millisecondsSinceEpoch});
  });
}
