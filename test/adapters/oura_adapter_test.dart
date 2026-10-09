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
import 'package:openstrap_edge/data/observation.dart';
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

List<int> _summary(int received, int bytesLeft, {int progress = 0}) =>
    _frame(0x11, <int>[
      received,
      progress,
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
  /// Header 0x00, then `00 55 aa ff`: MSB-first 2-bit codes, four epochs each
  /// of deep, light, rem, awake, so 2.0 min per stage.
  List<int> hypnogramBody() => _hex('000055aaff');

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
    expect(events.map((e) => (e as BandNote).key), ['oura_auth_refused']);
    expect(link.logs.any((l) => l.contains('authentication refused')), isTrue);
  });

  test('a ring that never answers the key is NOT reported as a refusal',
      () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      return const [];
    });
    expect(link.writes.any((w) => w.$2.first == 0x10), isFalse);
    expect(events, isEmpty,
        reason: 'silence must not drive the re-pair remedy');
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

  test('a drain that reaches the ring\'s end says so, exactly once', () async {
    // The three honest ends of a drain: an empty up-to-date answer, a replay
    // tail that stops at the cursor, and a batch with nothing left. Each must
    // end the session with `oura_drain_ok` — the host\'s only signal that
    // "connected" also means "synced".
    final (empty, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [_summary(0, 0)];
      return const [];
    });
    expect(
      empty.whereType<BandNote>().where((n) => n.key == 'oura_drain_ok'),
      hasLength(1),
    );

    // A replayed tail that stops exactly at the cursor (maxDs + 1 == cursor)
    // with nothing left is an up-to-date ring, not a stranded one.
    final (replayed, _) = await _drive(_adapter(startCursorDs: 5000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(kOuraEvtTempPeriod, 4999, _hex('6c0d')),
          _summary(1, 0),
        ];
      }
      return const [];
    });
    expect(
      replayed
          .whereType<BandNote>()
          .where((n) => n.key == 'oura_drain_ok'),
      hasLength(1),
    );
    expect(
      replayed.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isFalse,
    );
  });

  test('an unconfirmed batch never claims the drain reached its end',
      () async {
    // Speicherfehler-Analogon: the host never confirms the checkpoint (its
    // durable commit failed or never landed), so the cursor stays put and
    // the session ends WITHOUT `oura_drain_ok` — the data is not lost (the
    // next sync re-reads), but this session must not report success.
    final (events, link) = await _drive(
      _adapter(),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtTempPeriod, 100, _hex('6c0d')),
            _summary(1, 0),
          ];
        }
        return const [];
      },
      confirmBatches: false,
    );
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_drain_ok'),
      isFalse,
      reason: 'the batch was never confirmed — no durable commit, no success',
    );
    // The ADAPTER-level truth: with no confirmation and no host error
    // observation available at this seam, the only honest note is the
    // generic unconfirmed-checkpoint one — the commit's own outcome is
    // not named here (the host reports that separately when it has it).
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_batch_unconfirmed'),
      isTrue,
      reason: 'no confirm and no observed host error leaves the generic '
          'unconfirmed note as the honest report',
    );
    // And the cursor note never moved either: partial data stays banked,
    // the bookmark stays put.
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_ds'),
      isFalse,
    );
    expect(link.writes, isNotEmpty);
  });

  test('a drain that ends early never claims it reached the end', () async {
    // A refused notify-flags write, an unanswered history request and a
    // refused authentication all end `run()` without `oura_drain_ok` — the
    // host must be able to tell "synced to the end" from "connected and
    // got nothing".
    final link = ReplayBandLink()..writeSucceeds = false;
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub = _adapter()
        .run(link)
        .listen(events.add, onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    await sub.cancel();
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_drain_ok'),
      isFalse,
      reason: 'every write refused — nothing was synced',
    );

    final (silent, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      // 0x1c = notify-flags write: never answered, 0x10 times out.
      return const [];
    });
    expect(
      silent.whereType<BandNote>().any((n) => n.key == 'oura_drain_ok'),
      isFalse,
      reason: 'the history request never came back',
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

  test('a cursor past the newest event is answered with replays, and the '
      'session ends instead of looping', () async {
    // The ring answers a cursor past its newest event with its last few
    // events again; treating them as new would loop forever.
    final (events, link) = await _drive(_adapter(startCursorDs: 5000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        // Replays only: everything is stamped below the 5000 we asked from.
        return [
          _event(kOuraEvtTempPeriod, 4900, _hex('6c0d')),
          // The last event the previous sync read, so the cursor is 5000.
          _event(kOuraEvtTempPeriod, 4999, _hex('6c0d')),
          _summary(2, 0),
        ];
      }
      return const [];
    });
    // The replays are not banked as a batch — they are not new data, and the
    // bytes are already in the archive from whatever earlier sync wrote them.
    expect(events.whereType<SampleBatch>(), isEmpty);
    // And the cursor never moved on their strength.
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_ds'),
      isFalse,
    );
    // ONE history request, then the session ended — not a loop of them.
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(1));
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isFalse,
      reason: 'a tail ending at cursor - 1 is an up-to-date ring',
    );
  });

  test('an old boot record in the replayed tail is not a new reboot', () async {
    // A boot record below the cursor was already read by an earlier sync;
    // only `bytesLeft > 0` means stranded.
    final (events, _) = await _drive(_adapter(startCursorDs: 2801), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          // The pre-reboot boot record, below the bookmark a previous
          // session already advanced past it.
          _event(0x41, 2743, _hex('0400000032020c03')),
          _event(kOuraEvtTempPeriod, 2800, _hex('6c0d')),
          // And nothing left — an up-to-date cursor.
          _summary(2, 0),
        ];
      }
      return const [];
    });
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isFalse,
      reason: 'an up-to-date cursor must not be reset because its replayed '
          'tail still carries the old boot record',
    );
    expect(events.whereType<SampleBatch>(), isEmpty);
  });

  test('replays with bytes remaining strand the bookmark, not just an empty '
      'batch', () async {
    // After a reboot the counter restarts below the bookmark and the ring
    // answers with pre-reboot events; bytes left is what marks it stranded.
    final (events, _) = await _drive(_adapter(startCursorDs: 5000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(kOuraEvtTempPeriod, 4900, _hex('6c0d')),
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

  test('every delivered event is kept, and the cursor follows the last one',
      () async {
    // Nothing is filtered by stamp: a replayed event is the same bytes and the
    // same row again, which collapses downstream.
    const syncUnix = 1782043215;
    final (events, link) = await _drive(_adapter(startCursorDs: 1000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(kOuraEvtTempPeriod, 900, _hex('6c0d')),
          _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
          _event(kOuraEvtTempPeriod, 1100, _hex('6c0d')),
          _summary(3, 0),
        ];
      }
      return const [];
    });
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.raw, hasLength(3));
    expect(batch.samples.map((s) => s.tsEpoch), [syncUnix - 10, syncUnix + 10]);
    final cursor = events
        .whereType<BandNote>()
        .firstWhere((n) => n.key == 'oura_cursor_ds');
    expect(cursor.value, 1101);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(1),
        reason: 'bytesLeft 0 ends the drain after this batch');
  });

  test('a batch crossing a reboot archives every frame and moves the cursor '
      'to the last delivered stamp, not the largest', () async {
    final (events, link) = await _drive(_adapter(startCursorDs: 1000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor != 1000) return [_summary(0, 0)];
      return [
        _event(kOuraEvtTempPeriod, 1000, _hex('6c0d')),
        _event(kOuraEvtTempPeriod, 1005, _hex('6c0d')),
        _event(kOuraEvtTempPeriod, 3, _hex('6c0d')),
        _event(kOuraEvtTempPeriod, 4, _hex('6c0d')),
        _summary(4, 512),
      ];
    });
    expect(events.whereType<SampleBatch>().first.raw, hasLength(4));
    final requests = link.writes.where((w) => w.$2.first == 0x10).toList();
    expect(requests[1].$2.sublist(2, 6), <int>[5, 0, 0, 0]);
  });

  // ── Notification boundaries ─────────────────────────────────────────
  test(
      'a frame split across two notifications is NOT reassembled — the '
      'documented boundary is the notification',
      () async {
    // NO REASSEMBLY ACROSS NOTIFICATIONS, pinned as today's documented
    // behaviour: one notification carries exactly one frame, and no capture
    // in this project shows a frame split across notifications. A split
    // header or payload is therefore an UNRECOGNISED delivery: the first
    // fragment banks nothing (its declared length runs past the end), and
    // the second fragment, starting mid-payload, is not a frame either.
    // If a real capture ever shows cross-notification fragmentation, the
    // fix is a session-local continuation buffer in `run()`'s notify
    // listener — THIS test is what flips then.
    const syncUnix = 1782043215;
    final whole = _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix));
    // Split the frame mid-payload: header + first two body bytes, then the
    // remaining three.
    final head = whole.sublist(0, 6);
    final tail = whole.sublist(6);
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [head, tail];
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty,
        reason: 'a split frame banks nothing — no invented sample');
    expect(
      events.whereType<BandNote>().where((n) => n.key == 'oura_drain_ok'),
      isEmpty,
        reason: 'the drain never reached its end on split frames');
  });

  test('a summary split across two notifications never ends the batch',
      () async {
    // The batch summary is a frame like any other: split, it is not a
    // summary. The batch honestly times out instead of ending on a
    // mis-parsed half.
    const syncUnix = 1782043215;
    final anchor = _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix));
    final whole = _summary(1, 0);
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          [anchor, whole.sublist(0, 4)].expand((x) => x).toList(),
          [whole.sublist(4)].expand((x) => x).toList(),
        ];
      }
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(
      events.whereType<BandNote>().where((n) => n.key == 'oura_drain_ok'),
      isEmpty);
  });

  test('an unknown opcode banks nothing, decodes nothing', () async {
    // Unknown opcodes below the event range are command responses; the
    // parser accepts a WELL-FORMED unknown frame (length honest) and the
    // batch machinery ignores it: no sample, no batch, no invented
    // interpretation. A frame whose length LIES (declared length past the
    // end) is refused by the parser itself: same refusal, different line.
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          // Well-formed but unknown: parseable, ignored downstream.
          _frame(0x3f, _hex('010203')),
        ];
      }
      return const [];
    });
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(events.whereType<BandNote>().where((n) => n.key == 'oura_drain_ok'),
        isEmpty);
  });

  test(
      'a truncated frame does not desync the NEXT notification — each '
      'notification is parsed from byte zero',
      () async {
    // There is no continuation buffer (see the split-frame test): a
    // notification whose one frame declares more bytes than were delivered
    // is dropped (not archived, not decoded), and the next notification is
    // parsed from byte zero.
    const syncUnix = 1782043215;
    final anchor = _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix));
    final temp = _event(kOuraEvtTempPeriod, 1100, _hex('6c0d'));
    final cut = <int>[0x69, 0x05, 0x01, 0x02]; // length 5, only 2 delivered
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [anchor, cut, temp, _summary(2, 0)];
      return const [];
    });
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.samples, hasLength(1),
        reason: 'the frame after the cut banks — the cut desyncs nothing');
    expect(batch.raw, hasLength(2),
        reason: 'the cut frame is neither archived nor decoded');
    expect(
      events.whereType<BandNote>().where((n) => n.key == 'oura_drain_ok'),
      hasLength(1));
  });

  // ── The ring's own sleep staging, banked as vendor scalars ──────────────

  test('an empty batch with bytes left steps the cursor one decisecond and '
      'asks again before anything is reset', () async {
    final (events, link) = await _drive(_adapter(startCursorDs: 700), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor == 700) return [_summary(0, 4096)];
      return [_event(kOuraEvtTempPeriod, 720, _hex('6c0d')), _summary(1, 0)];
    });
    final cursors = [
      for (final w in link.writes)
        if (w.$2.first == 0x10) w.$2[2] | (w.$2[3] << 8),
    ];
    expect(cursors, [700, 701]);
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isFalse,
    );
    expect(events.whereType<SampleBatch>().single.raw, hasLength(1));
  });

  test('sleep analysis in progress with nothing left asks again from the new '
      'cursor', () async {
    final (events, link) = await _drive(
      OuraAdapter(
        key: _kKey,
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
        firstFrameTimeout: _kFast,
        analysisPollDelay: Duration.zero,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const [];
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor == 0) {
          return [
            _event(kOuraEvtTempPeriod, 200, _hex('6c0d')),
            _summary(1, 0, progress: 40),
          ];
        }
        return [
          _event(kOuraEvtSleepPhaseData, 300, hypnogramBody()),
          _summary(1, 0),
        ];
      },
    );
    final cursors = events
        .whereType<BandNote>()
        .where((n) => n.key == 'oura_cursor_ds')
        .map((n) => n.value);
    expect(cursors, [201, 301]);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(2));
  });

  test('a summary too short to carry bytes-left still ends the batch', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      return [
        _event(kOuraEvtTempPeriod, 200, _hex('6c0d')),
        _frame(0x11, const [1]),
      ];
    });
    expect(events.whereType<SampleBatch>().single.raw, hasLength(1));
    expect(link.logs.any((l) => l.contains('no batch summary')), isFalse);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(1));
  });

  test('a GetEvent the ring rejects as unsupported ends at once, by name',
      () async {
    final watch = Stopwatch()..start();
    final (events, link) = await _drive(
      OuraAdapter(
        key: _kKey,
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
        firstFrameTimeout: const Duration(seconds: 30),
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_hex('300110')];
        return const [];
      },
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(link.logs.any((l) => l.contains('GetEvent (0x10) as unsupported')),
        isTrue);
  });

  test('auth rejected as unsupported is logged as that, not as silence',
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f) return [_hex('30012f')];
      return const [];
    });
    expect(link.logs.any((l) => l.contains('auth (0x2f) as unsupported')),
        isTrue);
    expect(link.writes.any((w) => w.$2.first == 0x10), isFalse);
  });

  test('the first frame of a batch gets the long window, later ones the short',
      () async {
    final adapter = OuraAdapter(
      key: _kKey,
      confirmTimeout: const Duration(seconds: 2),
      replyTimeout: _kFast,
      firstFrameTimeout: const Duration(seconds: 2),
    );
    final link = ReplayBandLink();
    final events = <BandEvent>[];
    final done = Completer<void>();
    adapter.run(link).listen((e) async {
      events.add(e);
      if (e is OffloadCheckpoint) await e.confirm();
    }, onDone: done.complete);
    var served = 0;
    final clock = Stopwatch()..start();
    while (!done.isCompleted && clock.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      while (served < link.writes.length) {
        final v = link.writes[served++].$2;
        List<List<int>> out = const [];
        if (v.first == 0x2f && v[2] == 0x2b) out = [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) out = [_authOk];
        if (v.first == 0x10) {
          // Slower than replyTimeout, well inside firstFrameTimeout.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          out = [_event(kOuraEvtTempPeriod, 200, _hex('6c0d')), _summary(1, 0)];
        }
        for (final f in out) {
          link.feed(kOuraNotifyChar, f, atSec: 1786000000);
        }
      }
    }
    await link.close();
    expect(events.whereType<SampleBatch>(), hasLength(1));
  });

  test('the clock set carries the timezone, and is forced only with no origin',
      () async {
    List<int> syncWrite(ReplayBandLink l) =>
        l.writes.firstWhere((w) => w.$2.first == 0x12).$2;
    final (_, bare) = await _drive(
      OuraAdapter(
        key: _kKey,
        nowSeconds: () => 1782043215,
        tzHalfHours: () => 11,
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      ringWithOneBatch,
    );
    expect(syncWrite(bare),
        ouraCmdSyncTime(1782043215, tzHalfHours: 11, force: true));
    final (_, anchored) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        nowSeconds: () => 1782043215,
        tzHalfHours: () => -10,
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      ringWithOneBatch,
    );
    expect(syncWrite(anchored), ouraCmdSyncTime(1782043215, tzHalfHours: -10));
    expect(syncWrite(anchored)[1], 0x09);
  });

  test('a skipped clock set is reported, and never becomes an origin',
      () async {
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        nowSeconds: () => 1782043215,
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const [];
        return [
          _event(kOuraEvtTimeSyncSkipped, 900,
              _hex('4fd2376a00000000') + const [0x0b, 0x01]),
          _event(kOuraEvtTempPeriod, 950, _hex('6c0d')),
          _summary(2, 0),
        ];
      },
    );
    final notes = events.whereType<BandNote>();
    expect(
        notes
            .firstWhere((n) => n.key == 'oura_time_sync_skipped')
            .value,
        kOuraSkipReasonPpgMeasuring);
    expect(notes.any((n) => n.key == 'oura_anchor'), isFalse);
    expect(events.whereType<SampleBatch>().single.samples, isEmpty);
  });

  test('a ring start that restarted the counter drops the old origin; the '
      'new boot is stamped from its own time_sync', () async {
    const t0 = 1782043215;
    const t1 = 1782050000;
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor != 0) return [_summary(0, 0)];
      return [
        _event(kOuraEvtTimeSync, 5000000, _syncBody(t0)),
        _event(kOuraEvtRingStart, 10, const [4, 0, 0, 0, 0x02]),
        _event(kOuraEvtTempPeriod, 50, _hex('6c0d')),
        _event(kOuraEvtTimeSync, 100, _syncBody(t1)),
        _summary(4, 0),
      ];
    });
    final s = events.whereType<SampleBatch>().single.samples.single;
    expect(s.tsEpoch, t1 - 5, reason: 'not t0 - 499996');
    expect(
        events
            .whereType<BandNote>()
            .where((n) => n.key == 'oura_anchor')
            .map((n) => n.value),
        ['5000000,$t0', null, '100,$t1']);
  });

  test('a ring start with the reset bit clear but stamped below the origin '
      'still drops it', () async {
    const t0 = 1782043215;
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor != 0) return [_summary(0, 0)];
      return [
        _event(kOuraEvtTimeSync, 5000000, _syncBody(t0)),
        _event(kOuraEvtRingStart, 10, const [4, 0, 0, 0, 0x00]),
        _event(kOuraEvtTempPeriod, 50, _hex('6c0d')),
        _summary(3, 0),
      ];
    });
    expect(events.whereType<SampleBatch>().single.samples, isEmpty);
    expect(
        events
            .whereType<BandNote>()
            .where((n) => n.key == 'oura_anchor')
            .map((n) => n.value),
        ['5000000,$t0', null]);
  });

  test('a ring start above the origin with the reset bit set still drops it',
      () async {
    const t0 = 1782043215;
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor != 0) return [_summary(0, 0)];
      return [
        _event(kOuraEvtTimeSync, 1000, _syncBody(t0)),
        _event(kOuraEvtRingStart, 2000, const [4, 0, 0, 0, 0x02]),
        _event(kOuraEvtTempPeriod, 2050, _hex('6c0d')),
        _summary(3, 0),
      ];
    });
    expect(events.whereType<SampleBatch>().single.samples, isEmpty,
        reason: 'not stamped t0 + 105 from the dead boot');
    expect(
        events
            .whereType<BandNote>()
            .where((n) => n.key == 'oura_anchor')
            .map((n) => n.value),
        ['1000,$t0', null]);
  });

  test('a ring start with the reset bit clear above the origin keeps it',
      () async {
    const t0 = 1782043215;
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
      if (cursor != 0) return [_summary(0, 0)];
      return [
        _event(kOuraEvtTimeSync, 1000, _syncBody(t0)),
        _event(kOuraEvtRingStart, 2000, const [4, 0, 0, 0, 0x00]),
        _event(kOuraEvtTempPeriod, 2050, _hex('6c0d')),
        _summary(3, 0),
      ];
    });
    expect(events.whereType<SampleBatch>().single.samples.single.tsEpoch,
        t0 + 105);
  });

  test('a skip of a clock set whose time_sync also arrived is not reported',
      () async {
    const now = 1782043215;
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        nowSeconds: () => now,
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const [];
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor != 0) return [_summary(0, 0)];
        return [
          _event(kOuraEvtTimeSyncSkipped, 900,
              _hex('4fd2376a00000000') + const [0x0b, 0x01]),
          _event(kOuraEvtTimeSync, 950, _syncBody(now)),
          _summary(2, 0),
        ];
      },
    );
    final notes = events.whereType<BandNote>();
    expect(notes.any((n) => n.key == 'oura_time_sync_skipped'), isFalse);
    expect(notes.any((n) => n.key == 'oura_anchor'), isTrue);
  });

  test('a batch whose next cursor is the one asked for is no progress: it '
      'steps, then strands, instead of re-asking forever', () async {
    // Newer events, then a new-boot tail landing on cursor - 1, bytes left.
    final (events, link) = await _drive(_adapter(startCursorDs: 1000), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first != 0x10) return const [];
      return [
        _event(kOuraEvtTempPeriod, 1005, _hex('6c0d')),
        _event(kOuraEvtTempPeriod, 999, _hex('6c0d')),
        _summary(2, 512),
      ];
    });
    final cursors = [
      for (final w in link.writes)
        if (w.$2.first == 0x10) w.$2[2] | (w.$2[3] << 8),
    ];
    expect(cursors.first, 1000);
    expect(cursors[1], 1001, reason: 'a 1 ds step, not the same request');
    expect(cursors.length, lessThan(10));
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'oura_cursor_stranded'),
      isTrue,
    );
  });


  // ── The ring's own sleep staging, banked as vendor scalars ──────────────

  test('a hypnogram event with an anchor banks per-stage minutes as vendor '
      'scalars', () async {
    // 1000 ds = 1782043215, and the hypnogram sits 20 seconds later.
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtSleepPhaseDetails, 1200, hypnogramBody()),
            _summary(1, 0),
          ];
        }
        return const [];
      },
    );
    final scalars = events.whereType<VendorScalars>().single;
    expect(scalars.rows, hasLength(4));
    final byKey = {
      for (final o in scalars.rows) o.vendorKey: o,
    };
    for (final stage in ['deep', 'light', 'rem', 'awake']) {
      final o = byKey['sleep_${stage}_min']!;
      expect(o.value, 2.0);
      expect(o.unit, 'min');
      expect(o.attribution, 'Oura');
      expect(o.sourceKind, ObservationSource.vendor);
      expect(o.key, isNull, reason: 'their staging, their name — vendorKey');
    }
    final at = byKey['sleep_deep_min']!.at;
    expect(at.millisecondsSinceEpoch ~/ 1000, 1782043215 + 20);
  });

  test('a data page also becomes an epoch series in stages4, ending at its '
      'stamp; the information carrier does not', () async {
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtSleepPhaseInformation, 1100, hypnogramBody()),
            _event(kOuraEvtSleepPhaseData, 1200, hypnogramBody()),
            _summary(2, 0),
          ];
        }
        return const [];
      },
    );
    final hyp = events.whereType<VendorHypnogram>().single;
    expect(hyp.source, 'oura');
    expect(hyp.epochs.map((e) => e.stage),
        [for (final s in ['deep', 'light', 'rem', 'wake']) ...List.filled(4, s)]);
    expect(hyp.epochs.last.endSec, 1782043215 + 20);
    expect(hyp.epochs.first.startSec, 1782043215 + 20 - 16 * 30);
  });

  test('a hypnogram decoded before any origin is held, then stamped by the '
      'sync that finally carries one', () async {
    // Two batches in ONE session: the hold is adapter state, and a sync in
    // the same batch as the hypnogram would stamp it without holding.
    const syncUnix = 1782043215;
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor > 0) {
          return [
            _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
            _summary(1, 0),
          ];
        }
        return [
          _event(kOuraEvtSleepPhaseData, 900, hypnogramBody()),
          _summary(1, 512),
        ];
      }
      return const [];
    });
    final scalars = events.whereType<VendorScalars>().single;
    expect(scalars.rows, hasLength(4));
    for (final o in scalars.rows) {
      expect(o.at.millisecondsSinceEpoch ~/ 1000, syncUnix - 10);
      expect(o.value, 2.0);
    }
  });

  test('a details page and a data page with the same index count once; '
      "each page's minutes sit at its own stamp", () async {
    // 0x4e and 0x5a are pages of ONE buffer: the same index is the same 52
    // epochs, and the later one replaces the earlier. Rows are keyed by
    // (ts_ms, vendorKey), so distinct pages sharing a stamp must be summed.
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtSleepPhaseData, 1200, hypnogramBody()),
            _event(kOuraEvtSleepPhaseData, 1205, _hex('010055aaff')),
            // Page 0 again, on the details carrier: replaces the 1200 page.
            _event(kOuraEvtSleepPhaseDetails, 1300, hypnogramBody()),
            _event(kOuraEvtSleepPhaseData, 1300, _hex('020055aaff')),
            _summary(4, 0),
          ];
        }
        return const [];
      },
    );
    final rows = events.whereType<VendorScalars>().single.rows;
    final deep = {
      for (final o in rows)
        if (o.vendorKey == 'sleep_deep_min') o.at.millisecondsSinceEpoch: o.value,
    };
    const base = 1782043215 * 1000;
    // Page 1 at its own stamp; pages 0 (the replacement) and 2 share 1300.
    expect(deep, {base + 20500: 2.0, base + 30000: 4.0});
  });

  test("a re-read that sees more of the night stamps a page where it did "
      'before, so the row replaces itself', () async {
    Future<Map<int, num>> drain(List<List<int>> pages) async {
      final (events, _) = await _drive(
        OuraAdapter(
          key: _kKey,
          anchor: (1000, 1782043215),
          confirmTimeout: _kFast,
          replyTimeout: _kFast,
        ),
        (i, v) {
          if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
          if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
          if (v.first == 0x10) return [...pages, _summary(pages.length, 0)];
          return const [];
        },
      );
      return {
        for (final o in events.whereType<VendorScalars>().single.rows)
          if (o.vendorKey == 'sleep_deep_min') o.at.millisecondsSinceEpoch: o.value,
      };
    }

    final page0 = _event(kOuraEvtSleepPhaseData, 1200, hypnogramBody());
    final first = await drain([page0]);
    final again = await drain(
        [page0, _event(kOuraEvtSleepPhaseData, 1300, _hex('010055aaff'))]);
    const base = 1782043215 * 1000;
    expect(first, {base + 20000: 2.0});
    expect(again[base + 20000], 2.0,
        reason: 'the same key, so the night is not counted twice');
    expect(again.keys, hasLength(2));
  });

  test('a sleep summary starts a new night, so the same page index counts '
      'again after it', () async {
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtSleepPhaseData, 1200, hypnogramBody()),
            _event(kOuraEvtSleepSummary1, 1250, const [0, 0]),
            _event(kOuraEvtSleepPhaseData, 1300, hypnogramBody()),
            _summary(3, 0),
          ];
        }
        return const [];
      },
    );
    final deep = events
        .whereType<VendorScalars>()
        .single
        .rows
        .where((o) => o.vendorKey == 'sleep_deep_min');
    expect(deep, hasLength(2));
  });

  test('0x4b is archived but never staged', () async {
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtSleepPhaseInformation, 1200, hypnogramBody()),
            _summary(1, 0),
          ];
        }
        return const [];
      },
    );
    expect(events.whereType<VendorScalars>(), isEmpty);
    expect(events.whereType<VendorHypnogram>(), isEmpty);
    expect(events.whereType<SampleBatch>().single.raw, hasLength(1));
  });

  test('a decisecond a full batch cuts is stamped once, by the re-read, even '
      'when the re-read re-anchors', () async {
    // Batch 1 is full and ends inside 1300 with one of its two carriers. Batch
    // 2 re-reads 1300 and carries a fresh time_sync whose sub-second phase
    // differs, so 1300 maps to a different ts_ms under each anchor.
    const base = 1782043215;
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, base),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const [];
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor == 0) {
          return [
            for (var n = 0; n < 254; n++)
              _event(kOuraEvtTempPeriod, 1100, _hex('6c0d')),
            _event(kOuraEvtSleepPhaseDetails, 1300, hypnogramBody()),
            _summary(255, 4096),
          ];
        }
        return [
          _event(kOuraEvtSleepPhaseDetails, 1300, hypnogramBody()),
          _event(kOuraEvtSleepPhaseData, 1300, _hex('010055aaff')),
          _event(kOuraEvtTimeSync, 1405, _syncBody(base + 40)),
          _summary(3, 0),
        ];
      },
    );
    final deep = [
      for (final b in events.whereType<VendorScalars>())
        for (final o in b.rows)
          if (o.vendorKey == 'sleep_deep_min')
            (o.at.millisecondsSinceEpoch, o.value),
    ];
    // Under the new anchor: (base + 40) s + (1300 - 1405) ds = base + 29.5 s.
    expect(deep, [((base * 1000) + 29500, 4.0)]);
  });

  test('a full batch with nothing left decodes its last decisecond', () async {
    // No bytes left means nothing was cut and no re-read comes, so leaving
    // 1300 to one would never decode it.
    const base = 1782043215;
    final (events, link) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, base),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const [];
        return [
          for (var n = 0; n < 254; n++)
            _event(kOuraEvtTempPeriod, 1100, _hex('6c0d')),
          _event(kOuraEvtSleepPhaseDetails, 1300, hypnogramBody()),
          _summary(255, 0),
        ];
      },
    );
    expect(
        events
            .whereType<VendorScalars>()
            .expand((b) => b.rows)
            .any((o) => o.vendorKey == 'sleep_deep_min'),
        isTrue);
    final cursors = events
        .whereType<BandNote>()
        .where((n) => n.key == 'oura_cursor_ds')
        .map((n) => n.value);
    expect(cursors, <Object?>[1301]);
    expect(link.writes.where((w) => w.$2.first == 0x10), hasLength(1));
  });

  test('a hypnogram no origin ever reaches is dropped, not guessed', () async {
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) {
        return [
          _event(kOuraEvtSleepPhaseDetails, 900, hypnogramBody()),
          _summary(1, 0),
        ];
      }
      return const [];
    });
    expect(events.whereType<VendorScalars>(), isEmpty);
    final batch = events.whereType<SampleBatch>().single;
    expect(batch.raw, hasLength(1),
        reason: 'the hypnogram frame itself is banked regardless');
  });

  test('heart rate, beats, the ring RMSSD and SpO2 are stamped off the '
      'origin; an implausible beat cuts the run before it', () async {
    // 1000 ds = 1782043215. Beats 1000 ms each: an 11-bit interval is the
    // high byte (125), two middle bits (0) and a low bit (0).
    List<int> ibiBody(List<int> ibis) => [
          for (final i in ibis) i >> 3,
          for (final i in ibis) i & 1,
          ((ibis[0] >> 1) & 3) << 6 |
              ((ibis[1] >> 1) & 3) << 4 |
              ((ibis[2] >> 1) & 3) << 2 |
              ((ibis[3] >> 1) & 3),
          ((ibis[4] >> 1) & 3) << 6 | ((ibis[5] >> 1) & 3) << 4,
        ];
    final (events, _) = await _drive(
      OuraAdapter(
        key: _kKey,
        anchor: (1000, 1782043215),
        confirmTimeout: _kFast,
        replyTimeout: _kFast,
      ),
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            // Two 5-minute pairs, the second ending at the event; a zero
            // RMSSD is no reading.
            _event(kOuraEvtHrv, 7000, [52, 40, 54, 0]),
            // A burst: one HR, the mean; a zero bpm is no reading.
            _event(kOuraEvtAohr, 8000, [1, 0, 3, 70, 1, 0, 0, 74, 1]),
            _event(kOuraEvtSpo2, 9000, [0, 96, 98, 0xff]),
            _event(kOuraEvtSpo2, 9010, [0, 97, 40]),
            _event(kOuraEvtIbiAmplitude, 9500,
                ibiBody([200, 1000, 1000, 1000, 1000, 1000])),
            _summary(5, 0),
          ];
        }
        return const [];
      },
    );
    final samples = events.whereType<SampleBatch>().single.samples;
    expect({for (final s in samples) if (s.hr != null) s.tsEpoch: s.hr}, {
      1782043215 + 600 - 300: 52,
      1782043215 + 600: 54,
      1782043215 + 700: 72,
    });
    final beat = samples.singleWhere((s) => s.rrMs.isNotEmpty);
    expect(beat.rrMs, List.filled(5, 1000),
        reason: 'the 200 ms interval and every beat before it are cut');
    final end = (1782043215 + 850) * 1000;
    expect(beat.beatTsMs, [for (var k = 4; k >= 0; k--) end - 1000 * k]);
    expect(beat.anchor, TimeAnchor.measured);
    final rows = {
      for (final o in events.whereType<VendorScalars>().single.rows)
        o.vendorKey: o,
    };
    expect(rows['hrv_avg']!.value, 40);
    expect(rows['hrv_avg']!.at.millisecondsSinceEpoch ~/ 1000,
        1782043215 + 600);
    expect(rows['spo2_avg']!.value, 97, reason: '96, 98, 97; 40 is no reading');
    expect(rows['spo2_avg']!.at.millisecondsSinceEpoch ~/ 1000,
        1782043215 + 800, reason: "stamped at the batch's first reading");
    expect(rows['spo2_avg']!.attribution, 'Oura');
  });
}
