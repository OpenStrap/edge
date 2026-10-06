// The Ultrahuman session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE — not the decode, which is proven against
// constructed fixtures in the protocol package, but the SHAPE of the drain:
//
//   * no auth, no envelope — the first writes are the index-bound requests,
//     not a handshake;
//   * a pull ends when a record's own index reaches the ring's latest index,
//     on `0xee`, or on any other non-ok result — never on frame size, which
//     depends on the MTU;
//   * the cursor is the ring's own record index, a wrapping u16;
//   * the cursor does not advance until the host has confirmed — the same
//     commit-then-confirm ordering the safe-trim invariant runs on;
//   * every 32-byte record reaches `raw`, verbatim;
//   * each record decodes into an HR sample and daily vendor values, and the
//     bookmark is the first record of the latest day seen.
//
// Nothing here has met hardware. It proves the state machine, not the ring.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/adapters/ultrahuman.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Short enough that a deliberately-unanswered wait does not stall CI. The
/// shipped values are 5 s and 30 s; only their length is being shortened here.
const Duration _kFast = Duration(milliseconds: 50);

UltrahumanAdapter _adapter({int startIndex = kUltrahumanFirstIndex}) =>
    UltrahumanAdapter(
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

/// One 32-byte record, field-by-field; [index] is the ring's own record
/// index at bytes 30-31.
List<int> _record({int tsA = 1700000000, int index = 1}) {
  final b = ByteData(32);
  b.setUint32(0, tsA, Endian.little);
  b.setUint8(4, 58); // hr
  b.setUint8(5, 42); // hrv
  b.setUint8(6, 97); // spo2
  b.setUint8(7, kUltrahumanHrQualityLegacy);
  b.setUint32(8, tsA, Endian.little);
  b.setFloat32(12, 34.5, Endian.little);
  b.setFloat32(16, 25.0, Endian.little);
  b.setUint32(20, tsA, Endian.little);
  b.setUint16(24, 12, Endian.little);
  b.setUint16(26, 30, Endian.little);
  b.setUint8(28, 20);
  b.setUint8(29, 1);
  b.setUint16(30, index, Endian.little);
  return b.buffer.asUint8List();
}

/// [records] as frames of [perFrame] records each, the way a ring at a
/// smaller MTU sends them.
List<List<int>> _frames(List<List<int>> records, int perFrame) => [
      for (var i = 0; i < records.length; i += perFrame)
        _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, [
          for (final r in records.sublist(
              i, (i + perFrame).clamp(0, records.length)))
            ...r
        ]),
    ];

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
  test("sets the ring's clock, then asks for its index bounds before any "
      'history request',
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 5);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultEmpty, const [])];
      }
      return const [];
    });
    expect(link.writes[0].$2.first, kUltrahumanOpSetTime);
    expect(link.writes[1].$2, ultrahumanCmdGetEarliestIndex());
    expect(link.writes[2].$2, ultrahumanCmdGetLatestIndex());
    final firstHistory =
        link.writes.indexWhere((w) => w.$2.first == kUltrahumanOpGetRecordings);
    expect(firstHistory, greaterThan(2));
  });

  test('the drain ends when a record reaches the latest index', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 3);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [
          _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, [
            ..._record(tsA: 1, index: 1),
            ..._record(tsA: 2, index: 2),
            ..._record(tsA: 3, index: 3),
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
    expect(cursor.value, 4);
    // Only one pull — the drain knew it had reached the ring's latest index.
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1));
  });

  test('frames shorter than 7 records do not end the pull (smaller MTU)',
      () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 12);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        // Five records per notification, as at an MTU near 185.
        return _frames(
            [for (var n = 1; n <= 12; n++) _record(tsA: n, index: n)], 5);
      }
      return const [];
    });
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.first.raw, hasLength(12));
    expect(
        events.whereType<BandNote>().firstWhere((n) => n.key == 'ultrahuman_cursor').value,
        13);
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1),
        reason: 'one request streams the whole range');
  });

  test('the cursor follows the records\' own indices, not their count',
      () async {
    final (events, _) = await _drive(_adapter(startIndex: 5), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 9);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        // The ring skips 7 and 8.
        return _frames([
          _record(tsA: 5, index: 5),
          _record(tsA: 6, index: 6),
          _record(tsA: 9, index: 9),
        ], 7);
      }
      return const [];
    });
    expect(
        events.whereType<BandNote>().firstWhere((n) => n.key == 'ultrahuman_cursor').value,
        10);
  });

  test('a wrapped ring keeps its cursor and drains across 65535 -> 0',
      () async {
    final (events, link) = await _drive(_adapter(startIndex: 65534), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 40000);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return _frames([
          for (final n in [65534, 65535, 0, 1]) _record(tsA: n, index: n),
        ], 7);
      }
      return const [];
    });
    final history =
        link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings);
    expect(history.map((w) => w.$2), [ultrahumanCmdGetRecordings(65534)]);
    expect(events.whereType<SampleBatch>().single.raw, hasLength(4));
    expect(
        events.whereType<BandNote>().firstWhere((n) => n.key == 'ultrahuman_cursor').value,
        2);
    expect(events.whereType<BandNote>().any((n) => n.key.contains('stranded')),
        isFalse);
  });

  test('a bookmark past latest+1 restarts from the earliest index',
      () async {
    final (events, link) = await _drive(_adapter(startIndex: 10), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 2);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return _frames(
            [_record(tsA: 1, index: 1), _record(tsA: 2, index: 2)], 7);
      }
      return const [];
    });
    expect(
        link.writes
            .firstWhere((w) => w.$2.first == kUltrahumanOpGetRecordings)
            .$2,
        ultrahumanCmdGetRecordings(1));
    expect(events.whereType<BandNote>().any((n) => n.key.contains('stranded')),
        isFalse);
    expect(
        events.whereType<BandNote>().firstWhere((n) => n.key == 'ultrahuman_cursor').value,
        3);
  });

  test('a bookmark at latest+1 is up to date: no request, nothing stranded',
      () async {
    final (events, link) = await _drive(_adapter(startIndex: 3), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 2);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultEmpty, const [])];
      }
      return const [];
    });
    expect(events.whereType<BandNote>().any((n) => n.key.contains('stranded')),
        isFalse);
    expect(link.writes.any((w) => w.$2.first == kUltrahumanOpGetRecordings),
        isFalse);
  });

  test('a bookmark of 0 after a latest of 65535 is up to date, not re-anchored',
      () async {
    final (_, link) = await _drive(_adapter(startIndex: 0), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1000);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 65535);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultEmpty, const [])];
      }
      return const [];
    });
    expect(link.writes.any((w) => w.$2.first == kUltrahumanOpGetRecordings),
        isFalse);
  });

  test('a stream past one checkpoint is banked in batches from one request',
      () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 1000);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return _frames(
            [for (var n = 1; n <= 1000; n++) _record(tsA: n, index: n)], 7);
      }
      return const [];
    });
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1),
        reason: 'the second batch keeps reading the same stream');
    expect(events.whereType<SampleBatch>().map((b) => b.raw!.length),
        [700, 300]);
    expect(
        events
            .whereType<BandNote>()
            .where((n) => n.key == 'ultrahuman_cursor')
            .map((n) => n.value),
        [701, 1001]);
  });

  test('a non-ok result other than 0xff is a failure: the cursor stays and '
      'nothing is reported stranded', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 5);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, 0x03, const [])]; // busy
      }
      return const [];
    });
    expect(events.whereType<BandNote>().map((n) => n.key),
        isNot(contains('ultrahuman_cursor_stranded')));
    expect(events.whereType<BandNote>().map((n) => n.key),
        isNot(contains('ultrahuman_cursor')));
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1));
  });

  test('a bookmark behind the earliest available index is clamped forward',
      () async {
    final (_, link) = await _drive(_adapter(startIndex: 1), (i, v) {
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

  test('a fail frame after good ones banks the good records instead of '
      'discarding them', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 9);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [
          // A full (7-record) ok frame, then a fail — not the first frame.
          _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk,
              [for (var n = 1; n <= 7; n++) ..._record(tsA: n, index: n)]),
          _response(kUltrahumanOpGetRecordings, kUltrahumanResultFail, const []),
        ];
      }
      return const [];
    });
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1),
        reason: 'the 7 good records from frame 0 must not be discarded');
    expect(batches.first.raw, hasLength(7));
    expect(
        events.whereType<BandNote>().firstWhere((n) => n.key == 'ultrahuman_cursor').value,
        8,
        reason: 'the cursor must advance past the banked records so a retry '
            'does not re-request them');
    // The failure still ends the drain — only one pull is ever sent.
    expect(link.writes.where((w) => w.$2.first == kUltrahumanOpGetRecordings),
        hasLength(1));
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
          return _index(kUltrahumanOpGetLatestIndex, 1);
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
    expect(
        events
            .whereType<SampleBatch>()
            .expand((b) => b.samples)
            .every((x) => x.hr != null && x.skinTempC == null),
        isTrue,
        reason: 'battery is a note, not folded into a sample');
  });

  test('no destructive opcode is ever written — there is no builder for one',
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kUltrahumanOpGetEarliestIndex) {
        return _index(kUltrahumanOpGetEarliestIndex, 0);
      }
      if (v.first == kUltrahumanOpGetLatestIndex) {
        return _index(kUltrahumanOpGetLatestIndex, 1);
      }
      if (v.first == kUltrahumanOpGetRecordings) {
        return [_response(kUltrahumanOpGetRecordings, kUltrahumanResultOk, _record())];
      }
      return const [];
    });
    // 0x17 (device reset), 0x98 (software reset), 0x70 (airplane mode) and
    // 0xd1-0xd4 (power saving) have no builder in `protocol` — this asserts the session never writes anything
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

  group('decoding', () {
    // Fixed LOCAL wall-clock "now"; every timestamp below is built from the
    // same local calendar, so this passes in any zone.
    final now = DateTime(2026, 10, 4, 12, 0);
    int sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    final yesterday = DateTime(2026, 10, 3);
    final today = DateTime(2026, 10, 4);

    List<int> rec({
      required DateTime at,
      int hr = 60,
      int hrv = 40,
      int spo2 = 97,
      int quality = kUltrahumanHrQualityLegacy,
      int steps = 100,
      int sdnn = 51,
      double skin = 34.5,
      double ambient = 22.0,
      int tempQuality = 1,
      required int index,
    }) {
      final b = ByteData(32);
      final ts = sec(at);
      b.setUint32(0, ts, Endian.little);
      b.setUint8(4, hr);
      b.setUint8(5, hrv);
      b.setUint8(6, spo2);
      b.setUint8(7, quality);
      b.setUint32(8, ts, Endian.little);
      b.setFloat32(12, skin, Endian.little);
      b.setFloat32(16, ambient, Endian.little);
      b.setUint32(20, ts, Endian.little);
      b.setUint16(26, steps, Endian.little);
      b.setUint8(28, sdnn);
      b.setUint8(29, tempQuality);
      b.setUint16(30, index, Endian.little);
      return b.buffer.asUint8List();
    }

    // Two of yesterday's records, one not-on-finger, then two of today's.
    // Ring indices 10..14.
    final records = [
      rec(
          at: yesterday.add(const Duration(hours: 22)),
          hr: 58,
          hrv: 44,
          index: 10),
      rec(
          at: yesterday.add(const Duration(hours: 23)),
          hr: 54,
          hrv: 48,
          index: 11),
      // Off the finger: a plausible HR byte, but the quality byte says no.
      rec(
          at: yesterday.add(const Duration(hours: 23, minutes: 30)),
          quality: kUltrahumanHrQualityNoContact,
          hr: 90,
          hrv: 200,
          steps: 0,
          index: 12),
      rec(
          at: today.add(const Duration(hours: 1)),
          hr: 52,
          spo2: 95,
          index: 13),
      rec(
          at: today.add(const Duration(hours: 9)),
          hr: 75,
          spo2: 99,
          steps: 400,
          index: 14),
      // Charging, with the temperature sensor's own quality at zero.
      rec(
          at: today.add(const Duration(hours: 10)),
          quality: kUltrahumanHrQualityCharging,
          hr: 80,
          skin: 40.0,
          tempQuality: 0,
          steps: 0,
          index: 15),
    ];

    Future<List<BandEvent>> drive() async {
      final (events, _) = await _drive(
        UltrahumanAdapter(
          startIndex: 10,
          replyTimeout: _kFast,
          confirmTimeout: _kFast,
          nowSeconds: () => sec(now),
        ),
        (i, v) {
          if (v.first == kUltrahumanOpGetEarliestIndex) {
            return _index(kUltrahumanOpGetEarliestIndex, 0);
          }
          if (v.first == kUltrahumanOpGetLatestIndex) {
            return _index(kUltrahumanOpGetLatestIndex, 15);
          }
          if (v.first == kUltrahumanOpGetRecordings) {
            return [
              _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk,
                  [for (final r in records) ...r]),
            ];
          }
          return const [];
        },
      );
      return events;
    }

    test('declares hrSparse and kAdapterSignals mirrors it', () {
      expect(_adapter().signals.keys, [InputSignal.hrSparse]);
      expect(kAdapterSignals['ultrahuman'], _adapter().signals);
    });

    test('HR becomes ring-stamped samples; no-contact and charging are skipped',
        () async {
      final samples = [
        for (final b in (await drive()).whereType<SampleBatch>()) ...b.samples
      ];
      expect({for (final s in samples) s.tsEpoch: s.hr}, {
        sec(yesterday.add(const Duration(hours: 22))): 58,
        sec(yesterday.add(const Duration(hours: 23))): 54,
        sec(today.add(const Duration(hours: 1))): 52,
        sec(today.add(const Duration(hours: 9))): 75,
      });
      expect(samples.every((s) => s.anchor == TimeAnchor.measured), isTrue);
    });

    test('daily values: steps under our key, the rest vendor-keyed means',
        () async {
      final rows = [
        for (final v in (await drive()).whereType<VendorScalars>()) ...v.rows
      ];
      num at(String name, DateTime day) => rows
          .singleWhere((o) => (o.vendorKey ?? o.key) == name && o.at == day)
          .value;
      expect(at('steps', yesterday), 200);
      expect(at('steps', today), 500);
      expect(at('hrv_avg', yesterday), 46);
      expect(at('spo2_avg', today), 97);
      expect(at('skin_temp_avg', today), closeTo(34.5, 1e-4),
          reason: 'the skin sensor alone, not averaged with the ambient one');
      expect(rows.where((o) => o.vendorKey == 'stress_avg'), isEmpty,
          reason: 'the record has no stress field');
      for (final o in rows) {
        expect(o.attribution, kUltrahumanAttribution);
        expect(o.sourceKind, ObservationSource.vendor);
      }
    });

    test('the bookmark is the first record of the latest day seen', () async {
      final notes = (await drive())
          .whereType<BandNote>()
          .where((n) => n.key == 'ultrahuman_cursor')
          .map((n) => n.value);
      // Records 10-12 are yesterday, 13-15 today: resume from 13, so the
      // next session re-reads today in full.
      expect(notes.last, 13);
    });

    test('a record stamped before the clock was ever set is not filed on 1970',
        () async {
      final (events, _) = await _drive(
        UltrahumanAdapter(
          replyTimeout: _kFast,
          confirmTimeout: _kFast,
          nowSeconds: () => sec(now),
        ),
        (i, v) => v.first == kUltrahumanOpGetRecordings
            ? [
                _response(kUltrahumanOpGetRecordings, kUltrahumanResultOk,
                    rec(at: DateTime.utc(1970, 1, 2), index: 1)),
                _response(
                    kUltrahumanOpGetRecordings, kUltrahumanResultEmpty, const []),
              ]
            : const [],
      );
      expect(events.whereType<SampleBatch>().expand((b) => b.samples), isEmpty);
      expect(events.whereType<VendorScalars>(), isEmpty);
    });
  });
}
