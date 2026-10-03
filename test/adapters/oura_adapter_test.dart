// The Oura session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE, and it is not the decode — that is proven with
// the wire format itself, in the protocol package. It is the SHAPE of the
// offload, which is the question that decided
// whether this band belongs behind the adapter seam at all:
//
//   * the ring never trims, so `confirm()` moves a cursor rather than
//     authorising a delete, and a host that never confirms costs a re-read
//     rather than a record;
//   * the cursor does not advance until the host has confirmed — the same
//     commit-then-confirm ordering the safe-trim invariant runs on, expressed
//     in the one currency this band has;
//   * every event frame reaches `raw`, including the ones nothing decodes,
//     because the beat intervals and the hypnogram are in there and a decoder
//     for them does not exist yet.
//
// Nothing here has met hardware. It proves the state machine, not the ring.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Short enough that a deliberately-unanswered wait does not stall CI. The
/// shipped values are 5 s and 30 s; only their length is being shortened here,
/// never which one guards what.
const Duration _kFast = Duration(milliseconds: 50);

/// The key the challenge vector below is answered with.
final List<int> _kKey = _hex('4431967d8bacc2659743142b68391d9a');

OuraAdapter _adapter({int startCursorDs = 0}) => OuraAdapter(
      key: _kKey,
      startCursorDs: startCursorDs,
      confirmTimeout: _kFast,
      replyTimeout: _kFast,
    );

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

/// A frame, header included, ready to feed as one notification.
List<int> _frame(int tag, List<int> payload) => <int>[tag, payload.length, ...payload];

/// A history event: envelope timestamp in deciseconds, then the body.
List<int> _event(int tag, int tsDs, List<int> body) => _frame(tag, <int>[
      tsDs & 0xff,
      (tsDs >> 8) & 0xff,
      (tsDs >> 16) & 0xff,
      (tsDs >> 24) & 0xff,
      ...body,
    ]);

/// The ring's reply to a nonce request, and to a correct answer.
final List<int> _nonceReply =
    _frame(0x2f, _hex('2c') + _hex('0e2d6a0a08c99b4365f458e6e97382'));
final List<int> _authOk = _frame(0x2f, _hex('2e00'));
final List<int> _authBad = _frame(0x2f, _hex('2e01'));

List<int> _summary(int received, int bytesLeft) => _frame(0x11, <int>[
      received,
      0,
      bytesLeft & 0xff,
      (bytesLeft >> 8) & 0xff,
      (bytesLeft >> 16) & 0xff,
      (bytesLeft >> 24) & 0xff,
    ]);

/// A `time_sync` body: Unix seconds, little-endian — 1782043215 = 0x6a37d24f.
List<int> _syncBody(int unix) => <int>[
      unix & 0xff,
      (unix >> 8) & 0xff,
      (unix >> 16) & 0xff,
      (unix >> 24) & 0xff,
    ];

/// Drive [adapter] over a replay link, answering each write as the ring would.
///
/// A replay link records writes but cannot react to them, and this session is a
/// conversation — so the script below waits for the write count to grow and
/// then feeds the reply that write earned. That is the smallest thing that
/// exercises the real `run()` rather than a re-implementation of it.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  OuraAdapter adapter,
  List<List<int>> Function(int writeIndex, List<int> value) reply, {
  bool confirmBatches = true,
}) async {
  final link = ReplayBandLink();
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
        link.feed(kOuraNotifyChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

void main() {
  /// One battery event and one temperature event, then the batch is done.
  List<List<int>> ringWithOneBatch(int i, List<int> v) {
    if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
    if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
    if (v.first == 0x10) {
      // A resumed request must not be answered with the same batch again.
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor > 0) return [_summary(0, 0)];
      return [
        _event(kOuraEvtDebugData, 100, _hex('2456c80f00')),
        _event(kOuraEvtTempPeriod, 200, _hex('6c0d')),
        // Nothing decodes this one. It must still reach `raw`.
        _event(0x60, 300, _hex('0102030405060708090a0b0c0d0e')),
        // Bytes still on the ring, so the drain asks again with the new cursor.
        _summary(3, 512),
      ];
    }
    return const [];
  }

  test('authenticates before it asks for anything', () async {
    final (_, link) = await _drive(_adapter(), ringWithOneBatch);
    expect(link.writes.first.$2, ouraCmdAuthNonce());
    // The answer is the challenge under our key, one AES block, and it goes out
    // before the first history request.
    final answer = link.writes[1].$2;
    expect(answer.first, 0x2f);
    expect(answer.sublist(3),
        ouraAuthResponse(_kKey, _hex('0e2d6a0a08c99b4365f458e6e97382')));
    final firstHistory = link.writes.indexWhere((w) => w.$2.first == 0x10);
    expect(firstHistory, greaterThan(1));
  });

  test('a refused key ends the session without asking for history', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authBad];
      return const [];
    });
    expect(link.writes.any((w) => w.$2.first == 0x10), isFalse);
    expect(events, isEmpty);
    expect(link.logs.any((l) => l.contains('authentication refused')), isTrue);
  });

  test('every event frame reaches raw, decoded or not', () async {
    final (events, _) = await _drive(_adapter(), ringWithOneBatch);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.first.raw, hasLength(3),
        reason: 'the undecoded 0x60 frame must be banked too');
    // Verbatim, header included, so a later decoder sees what the radio saw.
    expect(batches.first.raw!.last,
        Uint8List.fromList(_event(0x60, 300, _hex('0102030405060708090a0b0c0d0e'))));
    // Not ephemeral: history is exactly what is meant to be persisted.
    expect(batches.first.ephemeral, isFalse);
  });

  test('no origin means no sample — the frames are still handed over', () async {
    // The ring stamps on a counter with no documented epoch, and there is no
    // command anywhere that reads its clock back. With neither a stored origin
    // nor a `time_sync` in the drain there is no honest second to put on a
    // reading, and the arrival of the notification is NOT one: it moves by the
    // delivery jitter on every connect, so the same physiological second would
    // be written twice under two keys REPLACE can never collapse.
    final (events, _) = await _drive(_adapter(), ringWithOneBatch);
    final batch = events.whereType<SampleBatch>().first;
    expect(batch.samples, isEmpty);
    expect(batch.raw, hasLength(3), reason: 'the bytes are banked regardless');
  });

  test('an injected origin stamps a session that measures none', () async {
    // 1000 ds = 1782043215, so the reading at 200 ds is 80 seconds earlier.
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      ringWithOneBatch,
    );
    final samples = events.whereType<SampleBatch>().first.samples;
    expect(samples, hasLength(1));
    expect(samples.first.tsEpoch, 1782043215 - 80);
    expect(samples.first.skinTempC, closeTo(34.36, 0.001));
    // A ring second that carried a temperature carried no heart rate. Absent is
    // null; a 0 here would read as the off-skin sentinel downstream.
    expect(samples.first.hr, isNull);
    expect(samples.first.rrMs, isEmpty);
  });

  test('a bookmark past the end of the ring is reported, not mistaken for '
      'an empty ring', () async {
    // The decisecond counter is an uptime, so a ring that reboots restarts it
    // below a bookmark taken before the reboot. Every request from there matches
    // nothing, forever, while the ring quietly fills up — and with no signal it
    // reads exactly like "no new data". `bytesLeft` is what separates them.
    final (events, _) = await _drive(_adapter(startCursorDs: 9391523), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [_summary(0, 4096)];
      return const [];
    });
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isTrue,
    );
  });

  test('battery reaches the host as a note, never as a sample', () async {
    final (events, _) = await _drive(_adapter(), ringWithOneBatch);
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 86), isTrue);
    expect(notes.any((n) => n.key == 'battery_mv' && n.value == 4040), isTrue);
  });

  test('the checkpoint advances a cursor — it does not authorise a delete',
      () async {
    final (events, link) = await _drive(_adapter(), ringWithOneBatch);
    expect(events.whereType<OffloadCheckpoint>(), hasLength(1));
    // The cursor the host is told to persist is the highest envelope stamp in
    // the batch plus one.
    final cursor = events
        .whereType<BandNote>()
        .firstWhere((n) => n.key == 'oura_cursor_ds');
    expect(cursor.value, 301);
    // And the next request actually carries it. Advancing by a flat step
    // instead would strand the drain inside a busy decisecond.
    final requests = link.writes.where((w) => w.$2.first == 0x10).toList();
    expect(requests, hasLength(2));
    expect(requests.last.$2.sublist(2, 6), <int>[301 & 0xff, 1, 0, 0]);
    // Nothing that could delete anything was ever written. There is no such
    // command on this path, and that is the whole reason the seam fits.
    expect(link.writes.any((w) => w.$2.first == 0x1a), isFalse,
        reason: 'factory reset');
    expect(link.writes.any((w) => w.$2.first == 0x03), isFalse,
        reason: 'the RData channel, whose clear op erases flash');
  });

  test('a FULL batch re-reads its last decisecond rather than skipping it',
      () async {
    // The cursor is a timestamp and the cap is a record count, so a full batch
    // may have been cut inside a decisecond that held more records than fitted.
    // Jumping past it would drop the remainder with no gap anything downstream
    // could see. 255 events all stamped 700, then a short batch at 700.
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor == 0) {
        return [
          for (var n = 0; n < 255; n++)
            _event(kOuraEvtTempPeriod, 700, _hex('6c0d')),
          _summary(255, 4096),
        ];
      }
      return [_event(kOuraEvtTempPeriod, 700, _hex('6c0d')), _summary(1, 0)];
    });
    final cursors = events
        .whereType<BandNote>()
        .where((n) => n.key == 'oura_cursor_ds')
        .map((n) => n.value)
        .toList();
    // 700, not 701 — the boundary decisecond is read again. Then 701 once the
    // batch came back short, which is what ends the drain.
    expect(cursors, <Object?>[700, 701]);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(2));
    // The cap is on the wire, not left to a default that could drift from the
    // number the advance compares against.
    expect(link.writes.firstWhere((w) => w.$2.first == 0x10).$2[6], 255);
  });

  test('an unconfirmed batch leaves the cursor where it was', () async {
    // The host committing nothing is the same outcome as the host being slow:
    // the ring keeps everything and the batch is re-read next time. This is the
    // safe half of commit-then-confirm, in the only currency this band has.
    final (events, link) = await _drive(
      _adapter(),
      ringWithOneBatch,
      confirmBatches: false,
    );
    expect(events.whereType<OffloadCheckpoint>(), hasLength(1));
    expect(events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_ds'),
        isFalse);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(1));
  });

  test('a resumed session asks from the bookmark it was given', () async {
    final (_, link) = await _drive(
      _adapter(startCursorDs: 9391523),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const [];
      },
    );
    final first = link.writes.firstWhere((w) => w.$2.first == 0x10);
    expect(first.$2.sublist(2, 6), _hex('a34d8f00'));
  });

  test('a time_sync event re-anchors the batch that carries it', () async {
    // The ring stamps records on a decisecond counter with no documented epoch.
    // A `time_sync` event is the only record carrying both clocks, so it is the
    // only measured bridge — without one the origin is the arrival second.
    const syncUnix = 1782043215;
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor > 0) return [_summary(0, 0)];
        return [
          _event(kOuraEvtTimeSync, 1000, _hex('4fd2376a')),
          // 200 deciseconds — 20 seconds — after the sync.
          _event(kOuraEvtTempPeriod, 1200, _hex('6c0d')),
          _summary(2, 0),
        ];
      }
      return const [];
    });
    final s = events.whereType<SampleBatch>().first.samples.single;
    expect(s.tsEpoch, syncUnix + 20);
    expect(s.skinTempC, closeTo(34.36, 0.001));
    // And the origin is handed back out, so the host persists the one this
    // session measured instead of deriving a second one of its own.
    expect(
      events.whereType<BandNote>().firstWhere((n) => n.key == 'oura_anchor').value,
      '1000,$syncUnix',
    );
    // Still declared as arrival-anchored: one measured bridge in one session
    // does not make the origin stable across sessions, and the time-axis
    // metrics must keep refusing until it is.
    expect(kOura.timeAnchor, TimeAnchor.arrival);
  });

  test('a ring that streams frames forever without a batch summary ends the '
      'session instead of hanging', () async {
    // A batch summary never arrives — `_collectBatch`'s inner loop otherwise
    // has no bound (each frame resets `replyTimeout`'s window), so this would
    // hang the sync forever on a misbehaving or malicious radio.
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          for (var n = 0; n < 5001; n++)
            _event(kOuraEvtDebugData, n, _hex('2456c80f00')),
        ];
      }
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(link.writes.any((w) => w.$2.first == 0x10), isTrue,
        reason: 'the session must have reached the history request at all');
  });

  test('an up-to-date cursor answered with replays ends the session',
      () async {
    // Cursor 5000 = one past the newest event; the ring replays its tail,
    // including an old boot record, which must not read as a reboot.
    final (events, link) = await _drive(_adapter(startCursorDs: 5000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(0x41, 2743, _hex('0400000032020c03')),
          _event(kOuraEvtTempPeriod, 4999, _hex('6c0d')),
          _summary(2, 0),
        ];
      }
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty);
    final keys = events.whereType<BandNote>().map((n) => n.key);
    expect(keys, isNot(contains('oura_cursor_ds')));
    expect(keys, isNot(contains('oura_cursor_stranded')));
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(1));
  });

  test('replays far below the cursor strand the bookmark', () async {
    // The ring's newest event is well below cursor - 1: its counter restarted
    // after the bookmark was taken, even though it reports nothing left.
    final (events, _) = await _drive(_adapter(startCursorDs: 5000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(0x41, 20, _hex('0400000032020c03')),
          _event(kOuraEvtTempPeriod, 800, _hex('6c0d')),
          _summary(2, 0),
        ];
      }
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(
      events.whereType<BandNote>().map((n) => n.key),
      contains('oura_cursor_stranded'),
    );
  });

  test('replays with bytes remaining strand the bookmark, not just an empty '
      'batch', () async {
    final (events, _) = await _drive(_adapter(startCursorDs: 5000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(kOuraEvtTempPeriod, 4999, _hex('6c0d')),
          _summary(1, 4096),
        ];
      }
      return const [];
    });
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isTrue,
      reason: 'replays below the cursor with bytes left mean the bookmark '
          'points past everything the ring holds',
    );
  });

  test('a batch of replays and new events keeps only the new', () async {
    const syncUnix = 1782043215;
    final (events, link) = await _drive(_adapter(startCursorDs: 1000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor > 1000) return [_summary(0, 0)];
        return [
          // Replays below the 1000 we asked from.
          _event(kOuraEvtTempPeriod, 900, _hex('6c0d')),
          // New data at and after the cursor.
          _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
          _event(kOuraEvtTempPeriod, 1100, _hex('6c0d')),
          _summary(3, 512),
        ];
      }
      return const [];
    });
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.raw, hasLength(2));
    expect(batch.samples, hasLength(1));
    final cursor = events
        .whereType<BandNote>()
        .firstWhere((n) => n.key == 'oura_cursor_ds');
    expect(cursor.value, 1101);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(2));
  });
}
