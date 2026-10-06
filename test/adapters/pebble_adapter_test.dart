// The Pebble 2 session through [ReplayBandLink]: PPoGATT transport ACKs and
// resets, inner-frame reassembly, the phone handshake, and health data
// logging — commit before ACK, NACK what cannot be read, carry step totals.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/pebble.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

List<int> u16(int v) => [v & 0xff, v >> 8];
List<int> u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24];

/// The watch's packets for one inner frame, serials from [serial].
List<List<int>> watch(int endpoint, List<int> payload, int serial) =>
    pebblePpogattPackets(pebbleFrame(endpoint, payload), serial);

final DateTime _day = DateTime(2026, 10, 4);
int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// A v7 steps item: [n] minutes from [from], 10 steps and 60 bpm each.
List<int> stepsItem(DateTime from, int n) => [
      ...u16(7), ...u32(_sec(from)), 0, 13, n,
      for (var i = 0; i < n; i++) ...[10, 0, ...u16(100), 5, 0, 0, 0, 0, 0, 0, 0, 60],
    ];

/// Runs [adapter], feeding [arrivals]; confirms every checkpoint, recording
/// the phone's writes (PPoGATT payloads, reassembled into inner frames) at
/// the moment each confirm ran.
Future<(List<BandEvent>, ReplayBandLink, List<(int, List<int>)>)> drive(
  PebbleAdapter adapter,
  List<List<int>> arrivals,
) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen((e) async {
    events.add(e);
    if (e is OffloadCheckpoint) await e.confirm();
  }, onDone: done.complete);
  for (final a in arrivals) {
    link.feed(kPebblePpogattReadUuid, a, atSec: 1800000000);
  }
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  final sent = <(int, List<int>)>[];
  final frames = PebbleFrameReassembler();
  for (final (_, w) in link.writes) {
    if (w.isNotEmpty && (w[0] & 7) == 0) {
      sent.addAll(frames.add(w.sublist(1)));
    }
  }
  return (events, link, sent);
}

PebbleAdapter _adapter({Map<DateTime, int> prior = const {}, int hw = 0}) =>
    PebbleAdapter(
      nowSeconds: () => _sec(_day.add(const Duration(hours: 12))),
      priorSteps: prior,
      stepsHighWater: hw,
    );

void main() {
  test('declares hrSparse and the registry mirrors it', () {
    expect(kPebbleAdapter.signals.keys, [InputSignal.hrSparse]);
    expect(kAdapterSignals['pebble'], kPebbleAdapter.signals);
  });

  test('every data packet is ACKed at the transport layer', () async {
    final (_, link, _) = await drive(_adapter(), [
      [0x18, 0, 1, 0, 9], // serial 3, half a frame
    ]);
    expect(link.writes.first.$2, [0x19]);
  });

  test('a reset with a body gets the three-byte reply, a bare one one byte',
      () async {
    final (_, a, _) = await drive(_adapter(), [
      [0x0A, 0x01],
    ]);
    expect(a.writes.single.$2, [0x03, 0x19, 0x19]);
    final (_, b, _) = await drive(_adapter(), [
      [0x0A],
    ]);
    expect(b.writes.single.$2, [0x03]);
  });

  test('the version request is answered, then time and session report',
      () async {
    final (_, _, sent) =
        await drive(_adapter(), watch(kPebbleEndpointPhoneVersion, [0x00], 0));
    expect(sent.map((f) => f.$1), [
      kPebbleEndpointPhoneVersion,
      kPebbleEndpointTime,
      kPebbleEndpointDatalog,
    ]);
    expect(sent[0].$2, pebblePhoneVersionReply());
    expect(sent[2].$2, kPebbleDatalogReportSessions);
  });

  test('steps session: HR samples and daily steps, ACK only after commit',
      () async {
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(9 + 13 * 3)];
    final data = [2, 5, ...u32(0), ...u32(0),
        ...stepsItem(_day.add(const Duration(hours: 8)), 3)];
    final (events, _, sent) = await drive(_adapter(), [
      ...watch(kPebbleEndpointDatalog, open, 0),
      ...watch(kPebbleEndpointDatalog, data, 3),
    ]);
    final samples = [
      for (final b in events.whereType<SampleBatch>()) ...b.samples
    ];
    expect(samples.map((s) => s.hr), [60, 60, 60]);
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    expect(rows.single.key, 'steps');
    expect(rows.single.value, 30);
    final ackIndex = events.indexWhere((e) => e is OffloadCheckpoint);
    final batchIndex = events.indexWhere(
        (e) => e is SampleBatch && e.samples.isNotEmpty);
    expect(batchIndex, lessThan(ackIndex), reason: 'commit before ACK');
    expect(sent.map((f) => f.$2), [
      pebbleDatalogAck(5), // open
      pebbleDatalogAck(5), // data, sent by the checkpoint's confirm
    ]);
    expect(events.whereType<BandNote>().last.value,
        _sec(_day.add(const Duration(hours: 8, minutes: 2))));
  });

  test('step totals carry forward and an already-counted minute is not '
      'counted twice', () async {
    final at = _day.add(const Duration(hours: 8));
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(9 + 13 * 3)];
    final data = [2, 5, ...u32(0), ...u32(0), ...stepsItem(at, 3)];
    final (events, _, _) = await drive(
      _adapter(prior: {_day: 1000}, hw: _sec(at)), // first minute counted
      [...watch(kPebbleEndpointDatalog, open, 0),
       ...watch(kPebbleEndpointDatalog, data, 3)],
    );
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    expect(rows.single.value, 1020);
  });

  test('an unknown record version is NACKed, so the watch keeps it',
      () async {
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(13)];
    final bad = [...u16(99), ...List.filled(11, 0)];
    final (events, _, sent) = await drive(_adapter(), [
      ...watch(kPebbleEndpointDatalog, open, 0),
      ...watch(kPebbleEndpointDatalog, [2, 5, ...u32(0), ...u32(0), ...bad], 3),
    ]);
    expect(sent.last.$2, pebbleDatalogNack(5));
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('sleep overlays become per-night stage minutes', () async {
    final open = [1, 6, ...List.filled(16, 0), ...u32(1), ...u32(84), 0,
        ...u16(18)];
    List<int> overlay(int type, DateTime start, int minutes) =>
        [...u16(1), ...u16(0), ...u16(type), ...u32(0), ...u32(_sec(start)),
          ...u32(minutes * 60)];
    final night = DateTime(2026, 10, 3, 23, 10);
    final (events, _, _) = await drive(_adapter(), [
      ...watch(kPebbleEndpointDatalog, open, 0),
      ...watch(kPebbleEndpointDatalog, [2, 6, ...u32(0), ...u32(0),
        ...overlay(kPebbleOverlaySleep, night, 460),
        ...overlay(kPebbleOverlayDeepSleep, night.add(const Duration(minutes: 30)), 90),
      ], 4),
    ]);
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    final last = {for (final r in rows) r.vendorKey: r.value};
    expect(last, {'sleep_deep_min': 90, 'sleep_light_min': 370});
    final h = events.whereType<VendorHypnogram>().last;
    expect(h.epochs.map((e) => (e.stage, (e.endSec - e.startSec) ~/ 60)),
        [('light', 30), ('deep', 90), ('light', 340)]);
  });
}
