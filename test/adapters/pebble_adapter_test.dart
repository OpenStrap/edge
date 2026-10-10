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
  // Answer before closing: a closed link refuses the ACK write.
  await pumpEventQueue();
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  final sent = <(int, List<int>)>[];
  final frames = PebbleFrameReassembler();
  for (final (_, w) in ppogattWrites(link)) {
    if (w.isNotEmpty && (w[0] & 7) == 0) {
      sent.addAll(frames.add(w.sublist(1)));
    }
  }
  return (events, link, sent);
}

Iterable<(String, List<int>)> ppogattWrites(ReplayBandLink link) =>
    link.writes.where((w) => w.$1 == kPebblePpogattWriteUuid);

PebbleAdapter _adapter({
  Map<DateTime, int> prior = const {},
  int hw = 0,
  List<PebbleOverlay> overlays = const [],
}) =>
    PebbleAdapter(
      nowSeconds: () => _sec(_day.add(const Duration(hours: 12))),
      priorSteps: prior,
      stepsHighWater: hw,
      priorOverlays: overlays,
    );

List<int> _overlay(int type, DateTime start, int minutes) =>
    [...u16(1), ...u16(0), ...u16(type), ...u32(0), ...u32(_sec(start)),
      ...u32(minutes * 60)];

/// An overlay session (sid 6) carrying [items].
List<List<int>> _overlays(List<List<int>> items, {List<int>? uuid}) => [
      ...watch(kPebbleEndpointDatalog, [1, 6, ...uuid ?? List.filled(16, 0),
          ...u32(1), ...u32(84), 0, ...u16(18)], 0),
      ...watch(kPebbleEndpointDatalog,
          [2, 6, ...u32(0), ...u32(0), for (final i in items) ...i], 4),
    ];

void main() {
  test('declares hrSparse, steps and its stages; the registry mirrors it', () {
    expect(kPebbleAdapter.signals.keys, [
      InputSignal.hrSparse,
      InputSignal.steps,
      InputSignal.deviceStages,
    ]);
    expect(kAdapterSignals['pebble'], kPebbleAdapter.signals);
  });

  test('every data packet is ACKed at the transport layer', () async {
    final (_, link, _) = await drive(_adapter(), [
      [0x18, 0, 1, 0, 9], // serial 3, half a frame
    ]);
    expect(ppogattWrites(link).first.$2, [0x19]);
  });

  test('a reset with a body gets the three-byte reply, a bare one one byte',
      () async {
    final (_, a, _) = await drive(_adapter(), [
      [0x0A, 0x01],
    ]);
    expect(ppogattWrites(a).single.$2, [0x03, 0x19, 0x19]);
    final (_, b, _) = await drive(_adapter(), [
      [0x0A],
    ]);
    expect(ppogattWrites(b).single.$2, [0x03]);
  });

  test('the session writes the client-only pairing trigger, then subscribes '
      'to connection parameters, connectivity and MTU before PPoGATT',
      () async {
    final link = ReplayBandLink();
    final sub = _adapter().run(link).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(link.writes.first.$1, kPebblePairingTriggerUuid);
    expect(link.writes.first.$2, [0x11]);
    for (final u in [
      kPebbleConnParamsUuid,
      kPebbleConnectivityUuid,
      kPebbleMtuUuid,
      kPebblePpogattReadUuid,
    ]) {
      expect(link.isListening(u), isTrue, reason: u);
    }
    await link.close();
    await sub.cancel();
    expect(link.isListening(kPebbleMtuUuid), isFalse);
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
    // The high-water mark rides the same write as the step rows.
    expect(events.whereType<VendorScalars>().single.cursors,
        {'pebble_steps_hw': '${_sec(_day.add(const Duration(hours: 8, minutes: 2)))}'});
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

  test('a NACKed message advances nothing: its re-send counts in full',
      () async {
    final at = _day.add(const Duration(hours: 8));
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(9 + 13 * 3)];
    final bad = [...u16(99), ...List.filled(9 + 13 * 3 - 2, 0)];
    final (events, _, sent) = await drive(_adapter(), [
      ...watch(kPebbleEndpointDatalog, open, 0),
      // A readable item, then one this build cannot read: NACKed whole.
      ...watch(kPebbleEndpointDatalog,
          [2, 5, ...u32(0), ...u32(0), ...stepsItem(at, 3), ...bad], 3),
      // The watch re-sends the readable part.
      ...watch(kPebbleEndpointDatalog,
          [2, 5, ...u32(0), ...u32(0), ...stepsItem(at, 3)], 9),
    ]);
    expect(sent[1].$2, pebbleDatalogNack(5));
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    expect(rows.single.value, 30, reason: 'the minutes were not counted yet');
  });

  test('a watch app logging under a health tag is banked raw and ACKed, '
      'never read as health', () async {
    final open = [1, 5, ...List.filled(15, 0), 0x42, ...u32(1), ...u32(81), 0,
        ...u16(9 + 13 * 3)];
    final data = [2, 5, ...u32(0), ...u32(0),
        ...stepsItem(_day.add(const Duration(hours: 8)), 3)];
    final (events, _, sent) = await drive(_adapter(), [
      ...watch(kPebbleEndpointDatalog, open, 0),
      ...watch(kPebbleEndpointDatalog, data, 3),
    ]);
    expect([for (final b in events.whereType<SampleBatch>()) ...b.samples],
        isEmpty);
    expect(events.whereType<VendorScalars>(), isEmpty);
    expect(events.whereType<SampleBatch>().where((b) => b.raw != null),
        isNotEmpty);
    expect(sent.last.$2, pebbleDatalogAck(5));
  });

  test('a deep period arriving a session after its night still splits it',
      () async {
    final night = DateTime(2026, 10, 3, 23, 10);
    final (first, _, _) = await drive(
        _adapter(), _overlays([_overlay(kPebbleOverlaySleep, night, 460)]));
    final carried = decodePebbleOverlays(
        first.whereType<VendorScalars>().last.cursors['pebble_overlays']);
    expect(carried.map((o) => (o.type, o.startSec)),
        [(kPebbleOverlaySleep, _sec(night))]);
    final (second, _, _) = await drive(
        _adapter(overlays: carried),
        _overlays([_overlay(kPebbleOverlayDeepSleep,
            night.add(const Duration(minutes: 30)), 90)]));
    final rows = [for (final v in second.whereType<VendorScalars>()) ...v.rows];
    expect({for (final r in rows) r.vendorKey: r.value},
        {'sleep_deep_min': 90, 'sleep_light_min': 370, 'sleep_in_bed_min': 460});
    expect(second.whereType<VendorHypnogram>().last.epochs.map((e) => e.stage),
        ['light', 'deep', 'light']);
  });

  test('a carried night keeps its deep periods, so a later session '
      're-emits it whole', () async {
    final a = DateTime(2026, 10, 1, 23);
    final (first, _, _) = await drive(_adapter(), _overlays([
      _overlay(kPebbleOverlaySleep, a, 480),
      _overlay(kPebbleOverlayDeepSleep, a.add(const Duration(minutes: 90)), 60),
      _overlay(kPebbleOverlaySleep, DateTime(2026, 10, 3, 22, 30), 480),
    ]));
    final carried = decodePebbleOverlays(
        first.whereType<VendorScalars>().last.cursors['pebble_overlays']);
    final (second, _, _) = await drive(_adapter(overlays: carried),
        _overlays([_overlay(kPebbleOverlayNap, DateTime(2026, 10, 4, 10), 20)]));
    final wake = a.add(const Duration(minutes: 480));
    final rows = [
      for (final v in second.whereType<VendorScalars>())
        for (final r in v.rows)
          if (r.at == wake) r,
    ];
    expect({for (final r in rows) r.vendorKey: r.value},
        {'sleep_deep_min': 60, 'sleep_light_min': 420, 'sleep_in_bed_min': 480});
  });

  test('a far-future overlay does not prune the carried nights', () async {
    final night = DateTime(2026, 10, 3, 23, 10);
    final (events, _, _) = await drive(_adapter(), _overlays([
      _overlay(kPebbleOverlaySleep, night, 460),
      _overlay(kPebbleOverlaySleep, DateTime(2030, 1, 1), 60),
    ]));
    final carried = decodePebbleOverlays(
        events.whereType<VendorScalars>().last.cursors['pebble_overlays']);
    expect(carried.map((o) => (o.type, o.startSec)),
        [(kPebbleOverlaySleep, _sec(night))]);
  });

  test('a re-sent deep period is not counted twice', () async {
    final night = DateTime(2026, 10, 3, 23, 10);
    final deep = PebbleOverlay(kPebbleOverlayDeepSleep,
        _sec(night.add(const Duration(minutes: 30))), 90 * 60);
    final (events, _, _) = await drive(
        _adapter(overlays: [
          PebbleOverlay(kPebbleOverlaySleep, _sec(night), 460 * 60),
          deep,
        ]),
        _overlays([_overlay(kPebbleOverlayDeepSleep,
            night.add(const Duration(minutes: 30)), 90)]));
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    expect({for (final r in rows) r.vendorKey: r.value}['sleep_deep_min'], 90);
  });

  test('naps, walks and runs are banked as the watch reported them', () async {
    final noon = DateTime(2026, 10, 3, 13);
    final (events, _, _) = await drive(_adapter(), _overlays([
      _overlay(kPebbleOverlayNap, noon, 40),
      _overlay(kPebbleOverlayDeepNap, noon.add(const Duration(minutes: 10)), 15),
      _overlay(kPebbleOverlayWalk, noon.add(const Duration(hours: 2)), 25),
      _overlay(kPebbleOverlayRun, noon.add(const Duration(hours: 4)), 30),
    ]));
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    expect({for (final r in rows) r.vendorKey: r.value},
        {'nap_min': 40, 'nap_deep_min': 15, 'walk_min': 25, 'run_min': 30});
    expect(rows.firstWhere((r) => r.vendorKey == 'nap_min').at,
        noon.add(const Duration(minutes: 40)));
    expect(events.whereType<VendorHypnogram>(), isEmpty,
        reason: 'naps never join the night');
  });

  test('sleep overlays become per-night stage minutes', () async {
    final night = DateTime(2026, 10, 3, 23, 10);
    final (events, _, _) = await drive(_adapter(), _overlays([
      _overlay(kPebbleOverlaySleep, night, 460),
      _overlay(kPebbleOverlayDeepSleep, night.add(const Duration(minutes: 30)), 90),
    ]));
    final rows = [for (final v in events.whereType<VendorScalars>()) ...v.rows];
    final last = {for (final r in rows) r.vendorKey: r.value};
    expect(last, {'sleep_deep_min': 90, 'sleep_light_min': 370, 'sleep_in_bed_min': 460});
    final h = events.whereType<VendorHypnogram>().last;
    expect(h.epochs.map((e) => (e.stage, (e.endSec - e.startSec) ~/ 60)),
        [('light', 30), ('deep', 90), ('light', 340)]);
  });
}
