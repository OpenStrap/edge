// The Ultrahuman session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE — not the decode, which is proven against
// constructed fixtures in the protocol package, but the SHAPE of the drain:
//
//   * no auth, no envelope — the first writes are the index-bound requests,
//     not a handshake;
//   * termination is the well-documented result byte, never a guess at the
//     index-response payload — a fetch that answers `0x04`/ok with fewer than
//     7 records ends that PULL, and an `0xee` (empty) or a bookmark past the
//     ring's own latest index ends the DRAIN;
//   * the cursor does not advance until the host has confirmed — the same
//     commit-then-confirm ordering the safe-trim invariant runs on;
//   * every 32-byte record reaches `raw`, verbatim — nothing here decodes one
//     into a sample.
//
// Nothing here has met hardware. It proves the state machine, not the ring.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/ultrahuman.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Short enough that a deliberately-unanswered wait does not stall CI. The
/// shipped values are 5 s and 30 s; only their length is being shortened here.
const Duration _kFast = Duration(milliseconds: 50);

UltrahumanAdapter _adapter({int startIndex = 0}) => UltrahumanAdapter(
      startIndex: startIndex,
      confirmTimeout: _kFast,
      replyTimeout: _kFast,
    );

List<int> _u16le(int v) => <int>[v & 0xff, (v >> 8) & 0xff];

/// One response frame: `[opcode, result, count, payload…, trailer(2)]`.
List<int> _response(int opcode, int result, List<int> payload) => <int>[
      opcode,
      result,
      payload.length ~/ kUltrahumanRecordLen,
      ...payload,
      0xaa,
      0xbb, // trailer — opaque, never checked
    ];

/// One 32-byte record, field-by-field. Bytes 30-31 are undocumented padding —
/// see `ultrahuman.dart` in `protocol` for why.
List<int> _record({int tsA = 1700000000}) {
  final b = ByteData(32);
  b.setUint32(0, tsA, Endian.little);
  b.setUint8(4, 58); // hr
  b.setUint8(5, 42); // hrv
  b.setUint8(6, 97); // spo2
  b.setUint8(7, kUltrahumanMeasureNormal);
  b.setUint32(8, tsA, Endian.little);
  b.setFloat32(12, 34.5, Endian.little);
  b.setFloat32(16, 33.8, Endian.little);
  b.setUint32(20, tsA, Endian.little);
  b.setUint16(24, 12, Endian.little);
  b.setUint16(26, 30, Endian.little);
  b.setUint16(28, 20, Endian.little);
  return b.buffer.asUint8List();
}

/// Drive [adapter] over a replay link, answering each write as the ring would.
/// [extraFeeds] are delivered once, up front — `ReplayBandLink` buffers a
/// notification fed before anyone has subscribed, so this reaches the
/// device-state characteristic the same way a real notify would.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  UltrahumanAdapter adapter,
  List<List<int>> Function(int writeIndex, List<int> value) reply, {
  bool confirmBatches = true,
  List<(String, List<int>)> extraFeeds = const [],
}) async {
  final link = ReplayBandLink();
  for (final (uuid, value) in extraFeeds) {
    link.feed(uuid, value, atSec: 1786000000);
  }
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(
        (e) async {
          events.add(e);
          if (e is OffloadCheckpoint && confirmBatches) await e.confirm();
        },
        onDone: () => done.complete(),
      );
  var served = 0;
  for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
    await Future<void>.delayed(Duration.zero);
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in reply(served, w.$2)) {
        link.feed(kUltrahumanNotifyChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

List<List<int>> _index(int opcode, int index, {int result = kUltrahumanResultOk}) =>
    [_response(opcode, result, _u16le(index))];

void main() {
  test("asks for the ring's index bounds before any history request",
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultEmpty, const [])];
      }
      return const [];
    });
    expect(link.writes[0].$2, ultrahumanCmdGetEarliestIndex());
    expect(link.writes[1].$2, ultrahumanCmdGetLatestIndex());
    final firstHistory =
        link.writes.indexWhere((w) => w.$2.first == kUltrahumanOpGetRecordings);
    expect(firstHistory, greaterThan(1));
  });

  test('one short frame drains everything and ends on its own', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 2);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [
          _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, [
            ..._record(tsA: 1),
            ..._record(tsA: 2),
            ..._record(tsA: 3),
          ]),
        ];
      }
      return const [];
    });
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.first.raw, hasLength(3));
    expect(batches.first.samples, isEmpty,
        reason: 'nothing here decodes a record into a sample');
    expect(batches.first.ephemeral, isFalse);
    final cursor = events
        .whereType<BandNote>()
        .firstWhere((n) => n.key == 'ultrahuman_cursor');
    expect(cursor.value, 3);
    // Only one pull — the drain knew it had reached the ring's latest index.
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1));
  });

  test('a full frame followed by a short one is one pull, one batch',
      () async {
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 9);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [
          // A full frame — exactly 7 — is NOT the end of the pull.
          _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk,
              [for (var n = 0; n < 7; n++) ..._record(tsA: n)]),
          // Then a short one, which is.
          _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk,
              [for (var n = 7; n < 10; n++) ..._record(tsA: n)]),
        ];
      }
      return const [];
    });
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.first.raw, hasLength(10));
    expect(
        events.whereType<BandNote>().firstWhere((n) => n.key == 'ultrahuman_cursor').value,
        10);
  });

  test('a bookmark past the ring\'s latest index is reported, no history '
      'request is ever sent', () async {
    final (events, link) = await _drive(_adapter(startIndex: 10), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 2);
      }
      return const [];
    });
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'ultrahuman_cursor_stranded'),
      isTrue,
    );
    expect(link.writes.any((w) => w.$2.first == kUltrahumanOpGetRecordings),
        isFalse);
  });

  test('a bookmark behind the earliest available index is clamped forward',
      () async {
    final (_, link) = await _drive(_adapter(startIndex: 0), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 5);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 10);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultEmpty, const [])];
      }
      return const [];
    });
    final firstHistory =
        link.writes.firstWhere((w) => w.$2.first == kUltrahumanOpGetRecordings);
    expect(firstHistory.$2, ultrahumanCmdGetRecordings(5));
  });

  test('a fail result ends the session; nothing is yielded after it',
      () async {
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 5);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultFail, const [])];
      }
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('an unconfirmed batch leaves the cursor where it was', () async {
    final (events, link) = await _drive(
      _adapter(),
      (i, v) {
        if (v.first == kUltrahumanOpGetEarliestIndex) {
          return _index(kUltrahumanOpGetEarliestIndex, 0);
        }
        if (v.first == kUltrahumanOpGetLatestIndex) {
          return _index(kUltrahumanOpGetLatestIndex, 5);
        }
        if (v.first == kUltrahumanOpGetRecordings) {
          return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, _record())];
        }
        return const [];
      },
      confirmBatches: false,
    );
    expect(events.whereType<OffloadCheckpoint>(), hasLength(1));
    expect(
        events.whereType<BandNote>().any((n) => n.key == 'ultrahuman_cursor'),
        isFalse);
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1));
  });

  test('battery reaches the host as a note, never as a sample', () async {
    final battery = List<int>.filled(7, 0)..[0] = 71;
    final (events, _) = await _drive(
      _adapter(),
      (i, v) {
        if (v.first == kUltrahumanOpGetEarliestIndex) {
          return _index(kUltrahumanOpGetEarliestIndex, 0);
        }
        if (v.first == kUltrahumanOpGetLatestIndex) {
          return _index(kUltrahumanOpGetLatestIndex, 0);
        }
        if (v.first == kUltrahumanOpGetRecordings) {
          return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, _record())];
        }
        return const [];
      },
      extraFeeds: [(kUltrahumanDeviceStateChar, battery)],
    );
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 71), isTrue);
    expect(events.whereType<SampleBatch>().first.samples, isEmpty,
        reason: 'battery is a note, not folded into a sample');
  });

  test('no destructive opcode is ever written — there is no builder for one',
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, _record())];
      }
      return const [];
    });
    // 0x98 (reset), 0x70 (airplane mode) and 0xd1/0xd2 (power saving) have no
    // builder in `protocol` — this asserts the session never writes anything
    // this file itself did not construct via one of the four real builders.
    const allowed = {
      kUltrahumanOpSetTime,
      kUltrahumanOpGetRecordings,
      kUltrahumanOpGetTime,
      kUltrahumanOpGetEarliestIndex,
      kUltrahumanOpGetLatestIndex,
    };
    expect(link.writes.every((w) => allowed.contains(w.$2.first)), isTrue);
  });
}
