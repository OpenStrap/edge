// Replay a scripted Colmi ring through the REAL [ColmiAdapter] and assert
// what each history walk decodes into — the mandatory adapter test
// (MULTIBAND_PLAN §3.3.3): every declared signal appears, every vendor value
// is attributed, and nothing lands in the future.
//
// "Now" is a fixed LOCAL wall-clock instant and every expectation is built
// from the same local calendar the adapter uses, so this passes in any zone.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/colmi.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _now = DateTime(2026, 10, 4, 12, 0);
final int _nowSec = _now.millisecondsSinceEpoch ~/ 1000;
DateTime _at(int daysAgo, int minute) =>
    DateTime(_now.year, _now.month, _now.day - daysAgo, 0, minute);
int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
int _bcd(int v) => ((v ~/ 10) << 4) | (v % 10);

/// One Service B reply with a correct CRC (same layout as a request).
List<int> _big(int type, List<int> payload) =>
    colmiBigDataRequest(type, payload);

/// A ring that holds: today 2 activity slots + a stale HR slot from the
/// future; yesterday HR, HRV, SpO2 and temperature; stress today; one night
/// that began yesterday evening. Every other day answers "no data".
List<List<int>> _ring(List<int> w, {bool splitBig = true, bool badCrc = false}) {
  final cmd = w[0];
  final day = cmd == kColmiCmdBigData ? 0 : w[1];
  switch (cmd) {
    case kColmiCmdSetTime:
      // Byte 9 = 1: this ring serves sleep over the big-data request.
      return [colmiFrame(kColmiCmdSetTime, [0, 0, 0, 0, 0, 0, 0, 0, 1])];
    case kColmiCmdBattery:
      return [colmiFrame(kColmiCmdBattery, [87])];
    case kColmiCmdActivityHistory:
      if (day != 0) return [colmiFrame(cmd, [0xff])];
      final d = [_bcd(_now.year % 100), _bcd(_now.month), _bcd(_now.day)];
      return [
        colmiFrame(cmd, [0xf0]),
        colmiFrame(cmd, [...d, 28, 0, 2, 5, 0, 0x2c, 0x01, 0, 0]), // 300
        colmiFrame(cmd, [...d, 29, 1, 2, 5, 0, 0xc8, 0x00, 0, 0]), // 200
      ];
    case kColmiCmdHrHistory:
      final isToday = w[1] != 0 &&
          (w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24)) % 86400 != 0;
      if (isToday) {
        // Slot 0 (00:00) is real; page 13's first slot is 12:40, after
        // "now" (12:00) — a leftover from yesterday, must be dropped.
        return [
          colmiFrame(cmd, [0, 14]),
          colmiFrame(cmd, [1, 0, 0, 0, 0, 58]),
          colmiFrame(cmd, [13, 99]),
        ];
      }
      if ((w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24)) ==
          _sec(_at(1, 0)) + _at(1, 0).timeZoneOffset.inSeconds) {
        return [
          colmiFrame(cmd, [0, 3]),
          colmiFrame(cmd, [1, 0, 0, 0, 0, 60, 0, 62]),
          colmiFrame(cmd, [2, 70, 10]), // 10 bpm: implausible, dropped
        ];
      }
      return [colmiFrame(cmd, [0xff])];
    case kColmiCmdHrvHistory:
      if (w[1] != 1) return [colmiFrame(cmd, [0xff])];
      return [
        colmiFrame(cmd, [0, 3, 30]),
        colmiFrame(cmd, [1, 1, 40, 42]),
        colmiFrame(cmd, [2]),
      ];
    case kColmiCmdStressHistory:
      if (w[1] != 0) return [colmiFrame(cmd, [0xff])];
      return [
        colmiFrame(cmd, [0, 3, 30]),
        colmiFrame(cmd, [1, 0, 30, 50]),
        colmiFrame(cmd, [2]),
      ];
    case kColmiCmdBigData:
      final List<int> r;
      switch (w[1]) {
        case kColmiBigSpo2:
          r = _big(kColmiBigSpo2, [
            1, for (var h = 0; h < 24; h++) ...(h == 3 ? [95, 98] : [0, 0]),
            0, for (var h = 0; h < 24; h++) ...[0, 0],
          ]);
        case kColmiBigSleep:
          // daysAgo 0: 23:00 the evening before -> 06:00.
          r = _big(kColmiBigSleep, [
            1, 0, 14, 0x64, 0x05, 0x68, 0x01, //
            kColmiStageLight, 120, kColmiStageDeep, 60, kColmiStageRem, 60,
            kColmiStageAwake, 30, kColmiStageLight, 150,
          ]);
        case kColmiBigTemperature:
          // One reply per day: yesterday's readings, then an empty today.
          final days = [
            _big(kColmiBigTemperature, [
              1, 30, for (var k = 0; k < 48; k++) k == 4 ? 150 : (k == 5 ? 160 : 0),
            ]),
            _big(kColmiBigTemperature, [0, 30, for (var k = 0; k < 48; k++) 0]),
          ];
          return [
            for (final d in days)
              ...(splitBig ? [d.sublist(0, 20), d.sublist(20)] : [d]),
          ];
        default:
          return const [];
      }
      if (badCrc && w[1] == kColmiBigSpo2) r[4] ^= 0xff;
      return splitBig ? [r.sublist(0, 20), r.sublist(20)] : [r];
  }
  return const [];
}

Future<({List<BandEvent> events, ReplayBandLink link})> _run({
  bool splitBig = true,
  bool badCrc = false,
  // Answers a write in place of [_ring] when it returns non-null.
  List<List<int>>? Function(List<int> w)? override,
}) async {
  final link = ReplayBandLink();
  final adapter = ColmiAdapter(
    nowSeconds: () => _nowSec,
    firstReplyTimeout: const Duration(milliseconds: 100),
    quietTimeout: const Duration(milliseconds: 20),
  );
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  unawaited(() async {
    var served = 0;
    while (!done.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      while (served < link.writes.length) {
        final (char, value) = link.writes[served++];
        final notify =
            char == kColmiCommandChar ? kColmiBigNotifyChar : kColmiNotifyChar;
        for (final f in override?.call(value) ??
            _ring(value, splitBig: splitBig, badCrc: badCrc)) {
          link.feed(notify, f, atSec: _nowSec);
        }
      }
    }
  }());
  await done.future.timeout(const Duration(seconds: 20));
  await sub.cancel();
  await link.close();
  return (events: events, link: link);
}

List<NeutralSample> _samples(List<BandEvent> e) =>
    [for (final b in e.whereType<SampleBatch>()) ...b.samples];
List<Observation> _rows(List<BandEvent> e) =>
    [for (final v in e.whereType<VendorScalars>()) ...v.rows];
Observation _row(List<BandEvent> e, String name, DateTime at) =>
    _rows(e).singleWhere(
        (o) => (o.vendorKey ?? o.key) == name && o.at == at,
        orElse: () => throw StateError('no $name at $at in ${_rows(e).map((o) => '${o.vendorKey ?? o.key}@${o.at}')}'));

void main() {
  late List<BandEvent> events;
  late ReplayBandLink link;
  setUpAll(() async {
    final r = await _run();
    events = r.events;
    link = r.link;
  });

  test('declares hrSparse and kAdapterSignals mirrors it', () {
    expect(kColmiAdapter.signals.keys, [InputSignal.hrSparse]);
    expect(kAdapterSignals['colmi'], kColmiAdapter.signals);
  });

  test('sets the ring clock first, in local wall clock', () {
    final (char, first) = link.writes.first;
    expect(char, kColmiWriteChar);
    expect(first, colmiSetTimeRequest(_now));
  });

  test('battery note', () {
    expect(
        events.whereType<BandNote>().map((n) => (n.key, n.value)),
        contains(('battery', 87)));
  });

  test('HR history: ring-stamped, plausible, never in the future', () {
    final s = _samples(events);
    expect(s.every((x) => x.anchor == TimeAnchor.measured), isTrue);
    expect(s.every((x) => x.tsEpoch <= _nowSec), isTrue);
    expect(
      {for (final x in s) x.tsEpoch: x.hr},
      {
        _sec(_at(0, 0)): 58,
        _sec(_at(1, 0)): 60,
        _sec(_at(1, 10)): 62,
        _sec(_at(1, 45)): 70,
      },
    );
  });

  test('every declared signal appears in the emitted samples', () {
    expect(_samples(events).any((x) => x.hr != null), isTrue);
  });

  test('steps: one daily total, our comparable key', () {
    final o = _row(events, 'steps', _at(0, 0));
    expect(o.key, 'steps');
    expect(o.value, 500);
  });

  test('ring-computed values are vendor-keyed daily means, attributed', () {
    expect(_row(events, 'hrv_avg', _at(1, 0)).value, 41);
    expect(_row(events, 'stress_avg', _at(0, 0)).value, 40);
    expect(_row(events, 'spo2_avg', _at(1, 0)).value, 96.5);
    expect(_row(events, 'skin_temp_avg', _at(1, 0)).value, closeTo(35.5, 1e-9));
    for (final o in _rows(events)) {
      expect(o.sourceKind, ObservationSource.vendor);
      expect(o.attribution, kColmiAttribution);
      if (o.key != 'steps') expect(o.vendorKey, isNotNull);
    }
  });

  test('sleep: hypnogram from the evening before, stage minutes at wake', () {
    final h = events.whereType<VendorHypnogram>().single;
    expect(h.source, 'colmi');
    expect(h.epochs.first.startSec, _sec(_at(1, 23 * 60)));
    expect(h.epochs.last.endSec, _sec(_at(0, 6 * 60)));
    expect(h.epochs.map((e) => e.stage),
        ['light', 'deep', 'rem', 'wake', 'light']);
    for (var i = 1; i < h.epochs.length; i++) {
      expect(h.epochs[i].startSec, h.epochs[i - 1].endSec);
    }
    final wake = _at(0, 6 * 60);
    expect(_row(events, 'sleep_light_min', wake).value, 270);
    expect(_row(events, 'sleep_deep_min', wake).value, 60);
    expect(_row(events, 'sleep_wake_min', wake).value, 30);
  });

  test('every reply is archived: service A frames and whole big replies', () {
    final raw = [
      for (final b in events.whereType<SampleBatch>()) ...?b.raw,
    ];
    // SpO2, sleep, and two temperature days.
    expect(raw.where((f) => f[0] == kColmiCmdBigData), hasLength(4));
    expect(raw.where((f) => f[0] != kColmiCmdBigData).every(colmiFrameValid),
        isTrue);
  });

  test('a big reply with a CRC mismatch is kept, decoded and logged',
      () async {
    final r = await _run(badCrc: true);
    expect(_row(r.events, 'spo2_avg', _at(1, 0)).value, 96.5);
    expect(r.link.logs.any((m) => m.contains('CRC mismatch')), isTrue);
    expect(r.events.whereType<VendorHypnogram>(), hasLength(1));
  });

  test('the clock write carries the language byte', () {
    expect(link.writes.first.$2[7], 1);
  });

  test('stress is walked for every day of the window, like HRV', () {
    final stress = [
      for (final (c, v) in link.writes)
        if (c == kColmiWriteChar && v[0] == kColmiCmdStressHistory) v[1],
    ];
    expect(stress, [for (var d = 0; d < kColmiHistoryDays; d++) d]);
  });

  test('temperature: every per-day reply is read, not just the first',
      () async {
    final r = await _run(override: (w) {
      if (w[0] != kColmiCmdBigData || w[1] != kColmiBigTemperature) {
        return null;
      }
      return [
        for (final (ago, b) in [(2, 140), (1, 150)])
          _big(kColmiBigTemperature, [ago, 60, b]),
      ];
    });
    expect(_row(r.events, 'skin_temp_avg', _at(2, 0)).value,
        closeTo(34.0, 1e-9));
    expect(_row(r.events, 'skin_temp_avg', _at(1, 0)).value,
        closeTo(35.0, 1e-9));
  });

  test('HR slot interval comes from page 0, not a fixed 5 minutes', () async {
    final y = _at(1, 0);
    final yTs = _sec(y) + y.timeZoneOffset.inSeconds;
    final r = await _run(override: (w) {
      if (w[0] != kColmiCmdHrHistory) return null;
      final ts = w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24);
      if (ts != yTs) return [colmiFrame(w[0], [0xff])];
      return [
        colmiFrame(w[0], [0, 3, 10]),
        colmiFrame(w[0], [1, 0, 0, 0, 0, 60, 0, 62]),
        colmiFrame(w[0], [2, 70]),
      ];
    });
    expect({for (final x in _samples(r.events)) x.tsEpoch: x.hr}, {
      _sec(_at(1, 0)): 60,
      _sec(_at(1, 20)): 62,
      _sec(_at(1, 90)): 70,
    });
  });

  test('a walk is dated by the day its page 1 names', () async {
    final r = await _run(override: (w) {
      if (w[0] != kColmiCmdHrvHistory) return null;
      if (w[1] != 1) return [colmiFrame(w[0], [0xff])];
      // Asked for yesterday, answered for the day before.
      return [colmiFrame(w[0], [0, 2, 30]), colmiFrame(w[0], [1, 2, 40, 42])];
    });
    expect(_row(r.events, 'hrv_avg', _at(2, 0)).value, 41);
    expect(_rows(r.events).where((o) => o.vendorKey == 'hrv_avg'),
        hasLength(1));
    expect(r.link.logs.any((m) => m.contains('HRV for 1 days ago')), isTrue);
  });

  test('an HR walk is dated by the stamp on its page 1', () async {
    final y = _at(1, 0), d2 = _at(2, 0);
    final yTs = _sec(y) + y.timeZoneOffset.inSeconds;
    final s = _sec(d2) + d2.timeZoneOffset.inSeconds;
    final r = await _run(override: (w) {
      if (w[0] != kColmiCmdHrHistory) return null;
      final ts = w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24);
      if (ts != yTs) return [colmiFrame(w[0], [0xff])];
      // Asked for yesterday, stamped for the day before.
      return [
        colmiFrame(w[0], [0, 2, 5]),
        colmiFrame(w[0], [1, s & 0xff, (s >> 8) & 0xff, (s >> 16) & 0xff,
            (s >> 24) & 0xff, 60, 0, 62]),
      ];
    });
    expect({for (final x in _samples(r.events)) x.tsEpoch: x.hr}, {
      _sec(_at(2, 0)): 60,
      _sec(_at(2, 10)): 62,
    });
    expect(r.link.logs.any((m) => m.contains('HR for 1 days ago')), isTrue);
  });

  test('a rejected request (cmd | 0x80) ends the walk and is logged',
      () async {
    final r = await _run(override: (w) => w[0] == kColmiCmdBattery
        ? [colmiFrame(kColmiCmdBattery | kColmiErrorFlag)]
        : null);
    expect(r.link.logs.any((m) => m.contains('rejected command 0x3')),
        isTrue);
    expect(r.events.whereType<BandNote>(), isEmpty);
  });

  test('naps: asked for, drained, kept out of the night', () async {
    final r = await _run(override: (w) {
      if (w[0] != kColmiCmdBigData || w[1] != kColmiBigSleep) return null;
      expect(w.sublist(6), [0xff, 0x01]);
      return [
        ..._ring(w, splitBig: false),
        // 13:00 nap, 40 min asleep then a 20-min gap.
        _big(kColmiBigNap, [1, 0, 8, 0x0c, 0x03, 0x48, 0x03, 2, 40, 0, 20]),
      ];
    });
    final h = r.events.whereType<VendorHypnogram>().single;
    expect(h.epochs.first.startSec, _sec(_at(1, 23 * 60)));
    expect(h.epochs.last.endSec, _sec(_at(0, 6 * 60)));
    final nap = _row(r.events, 'nap_min', _at(0, 13 * 60 + 60));
    expect(nap.value, 40);
    // The nap reply did not swallow the temperature reply after it.
    expect(_row(r.events, 'skin_temp_avg', _at(1, 0)).value,
        closeTo(35.5, 1e-9));
  });

  test('a night starts the sum of its blocks before its end', () async {
    final r = await _run(override: (w) {
      if (w[0] != kColmiCmdBigData || w[1] != kColmiBigSleep) return null;
      // Start field says 22:00, but the blocks only cover 60 min to 06:00.
      return [
        _big(kColmiBigSleep, [
          1, 0, 6, 0x28, 0x05, 0x68, 0x01, kColmiStageDeep, 60, //
        ]),
      ];
    });
    final h = r.events.whereType<VendorHypnogram>().single;
    expect(h.epochs.single.startSec, _sec(_at(0, 5 * 60)));
    expect(h.epochs.single.endSec, _sec(_at(0, 6 * 60)));
  });

  test('a ring without big-data sleep is asked per day on Service A',
      () async {
    final r = await _run(override: (w) {
      if (w[0] == kColmiCmdSetTime) return [colmiFrame(kColmiCmdSetTime)];
      if (w[0] == kColmiCmdSleepDetails) {
        return [
          colmiFrame(w[0], [0xf0]),
          colmiFrame(w[0], [0x26, 0x10, 0x04, 88, 0, 1, 1, 2, 3, 4, 5, 6, 7]),
        ];
      }
      return null;
    });
    final writes = r.link.writes.map((x) => x.$2).toList();
    expect(
        writes.where((v) => v[0] == kColmiCmdBigData && v[1] == kColmiBigSleep),
        isEmpty);
    expect(writes.where((v) => v[0] == kColmiCmdSleepDetails).map((v) => v[1]),
        [for (var d = 0; d < kColmiHistoryDays; d++) d]);
    final raw = [for (final b in r.events.whereType<SampleBatch>()) ...?b.raw];
    expect(raw.where((f) => f[0] == kColmiCmdSleepDetails), isNotEmpty);
  });
}
