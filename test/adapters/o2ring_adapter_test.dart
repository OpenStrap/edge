// The O2Ring session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE — the shape of the one request/reply round trip,
// not the decode itself (that lives in the protocol package). One command
// out, one archived batch back, no sample ever produced.
//
// Nothing here has met hardware. It proves the state machine, not the ring.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/o2ring.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

const Duration _kFast = Duration(milliseconds: 50);

/// Drive [adapter] over a replay link, answering the one write it makes.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  O2RingAdapter adapter,
  List<List<int>> Function(int writeIndex, List<int> value) reply,
) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(
        events.add,
        onDone: () => done.complete(),
      );
  var served = 0;
  for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
    await Future<void>.delayed(Duration.zero);
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in reply(served, w.$2)) {
        link.feed(kO2RingNotifyChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

const String _kInfoJson = '{"CurBAT":"75%",'
    '"FileList":"20260116233312.vld,20260115221045.vld",'
    '"Model":"O2Ring","SN":"ABC123"}';

void main() {
  test('writes INFO and nothing else', () async {
    final (_, link) = await _drive(
      const O2RingAdapter(replyTimeout: _kFast),
      (i, v) => [buildO2RingCommand(kO2RingCmdInfo, data: _kInfoJson.codeUnits)],
    );
    expect(link.writes, hasLength(1));
    expect(link.writes.single.$2, o2ringCmdInfo());
  });

  test('the INFO reply is archived verbatim and never becomes a sample',
      () async {
    final reply = buildO2RingCommand(kO2RingCmdInfo, data: _kInfoJson.codeUnits);
    final (events, _) = await _drive(
      const O2RingAdapter(replyTimeout: _kFast),
      (i, v) => [reply],
    );
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.first.samples, isEmpty);
    expect(batches.first.raw, equals([Uint8List.fromList(reply)]));
    expect(batches.first.ephemeral, isFalse);
  });

  test('battery, model, serial and the file list reach the host as notes, '
      'never as a sample', () async {
    final reply = buildO2RingCommand(kO2RingCmdInfo, data: _kInfoJson.codeUnits);
    final (events, _) = await _drive(
      const O2RingAdapter(replyTimeout: _kFast),
      (i, v) => [reply],
    );
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 75), isTrue);
    expect(notes.any((n) => n.key == 'model' && n.value == 'O2Ring'), isTrue);
    expect(notes.any((n) => n.key == 'serial' && n.value == 'ABC123'), isTrue);
    expect(
      notes.any((n) =>
          n.key == 'o2ring_files' &&
          n.value == '20260116233312.vld,20260115221045.vld'),
      isTrue,
    );
  });

  test('a reply split across several notifications is reassembled before '
      'it is parsed or archived', () async {
    final reply = buildO2RingCommand(kO2RingCmdInfo, data: _kInfoJson.codeUnits);
    // Chunked as a real 20-byte-MTU link would deliver it — several
    // notifications, none of them a complete frame on its own.
    final chunks = [
      for (var i = 0; i < reply.length; i += 20)
        reply.sublist(i, (i + 20).clamp(0, reply.length)),
    ];
    expect(chunks.length, greaterThan(1),
        reason: 'the fixture must actually exercise fragmentation');
    final (events, _) = await _drive(
      const O2RingAdapter(replyTimeout: _kFast),
      (i, v) => chunks,
    );
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.raw, equals([Uint8List.fromList(reply)]));
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'model' && n.value == 'O2Ring'), isTrue);
  });

  test('a silent ring ends the session with nothing banked', () async {
    final (events, link) = await _drive(
      const O2RingAdapter(replyTimeout: _kFast),
      (i, v) => const [],
    );
    expect(events, isEmpty);
    expect(link.writes, hasLength(1));
  });

  test('a refused write ends the session without waiting out the timeout',
      () async {
    final link = ReplayBandLink()..writeSucceeds = false;
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub = const O2RingAdapter(replyTimeout: _kFast).run(link).listen(
          events.add,
          onDone: () => done.complete(),
        );
    await done.future.timeout(const Duration(seconds: 2));
    await sub.cancel();
    expect(events, isEmpty);
  });

  test('declares no signals — nothing here becomes a metric', () {
    expect(const O2RingAdapter().signals, isEmpty);
    expect(kO2Ring.id, 'o2ring');
    expect(declaredSignals(kO2Ring.id), isEmpty);
  });

  test('an unparsable reply is still archived, but yields no notes',
      () async {
    final junk = <int>[0xAA, 0x14, 0xEB, 0, 0, 1, 0, 0x00, 0xFF];
    final (events, _) = await _drive(
      const O2RingAdapter(replyTimeout: _kFast),
      (i, v) => [junk],
    );
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.raw, equals([Uint8List.fromList(junk)]));
    expect(events.whereType<BandNote>(), isEmpty);
  });
}
