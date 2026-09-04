// The Casio session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE. There is no decode to pin — this adapter decodes
// nothing — so the whole content of this test is the SHAPE of the probe: the
// right tags go out, in order, and every reply that comes back is banked
// verbatim into `raw`, whether or not it arrived at all. Every payload byte
// below is a doc-labelled fixture invented for this test, never a real
// capture — nobody on this project owns a Casio watch.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/casio.dart';

/// Short enough that a deliberately-unanswered wait does not stall CI.
const Duration _kFast = Duration(milliseconds: 30);

/// Drive [adapter] over a replay link, answering each write as the watch
/// would. A replay link records writes but cannot react to them, so this
/// polls for new writes across REAL wall-clock time (not just the microtask
/// queue) until the session ends — a deliberately-unanswered tag waits out
/// [CasioAdapter.replyTimeout] for real, and the next tag's write only lands
/// after that, so the loop must still be there to serve it.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  CasioAdapter adapter,
  List<int>? Function(int tag) reply,
) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: () => done.complete());
  var served = 0;
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!done.isCompleted && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    while (served < link.writes.length) {
      final tag = link.writes[served].$2.first;
      final r = reply(tag);
      if (r != null) link.feed(kCasioAllFeaturesChar, r, atSec: 1786000000);
      served++;
    }
  }
  await done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

void main() {
  test('writes every probe tag, in order, and none of them touch settings',
      () async {
    final (_, link) = await _drive(
      const CasioAdapter(replyTimeout: _kFast),
      (tag) => <int>[tag, 0xAA, 0xBB],
    );
    expect(link.writes.map((w) => w.$2.first).toList(),
        CasioAdapter.kProbeTags);
    for (final w in link.writes) {
      expect(w.$1, kCasioReadRequestChar);
    }
  });

  test('every reply is banked into raw verbatim, decoded or not', () async {
    final (events, _) = await _drive(
      const CasioAdapter(replyTimeout: _kFast),
      (tag) => <int>[tag, 0xAA, 0xBB],
    );
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.samples, isEmpty,
        reason: 'nothing here is ever decoded into a NeutralSample');
    expect(batch.raw, hasLength(CasioAdapter.kProbeTags.length));
    expect(batch.raw!.first, Uint8List.fromList(<int>[0x10, 0xAA, 0xBB]));
    expect(batch.ephemeral, isFalse);
    // No stored history exists on this wire, so nothing is ever trimmed.
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('a tag with no reply is skipped, not stalled on forever', () async {
    final (events, link) = await _drive(
      const CasioAdapter(replyTimeout: _kFast),
      (tag) => tag == 0x23 ? null : <int>[tag, 0x01],
    );
    // Every tag was still asked for, even the one nothing answered.
    expect(link.writes.map((w) => w.$2.first).toList(),
        CasioAdapter.kProbeTags);
    final batch = events.whereType<SampleBatch>().single;
    // One reply short of the full probe set — the unanswered tag is simply
    // absent from `raw`, never a placeholder frame.
    expect(batch.raw, hasLength(CasioAdapter.kProbeTags.length - 1));
  });

  test('the module id reply surfaces a byte count, never a decoded field',
      () async {
    final (events, _) = await _drive(
      const CasioAdapter(replyTimeout: _kFast),
      (tag) => tag == 0x26 ? <int>[0x26, 0x01, 0x02, 0x03] : <int>[tag],
    );
    final note = events
        .whereType<BandNote>()
        .firstWhere((n) => n.key == 'casio_module_id_len');
    expect(note.value, 3);
  });

  test('declares no signal and stays out of the framed offload engine', () {
    expect(kCasioAdapter.signals, isEmpty);
    expect(kCasio.isFramed, isFalse);
    expect(declaredSignals('casio'), isEmpty);
  });
}
