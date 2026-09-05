// The Ultrahuman Ring Air as a [BandAdapter]: no auth, no envelope, drain its
// history by record index, bank every byte, decode nothing into a signal.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). Unlike Oura, this protocol
// has no key exchange and no vendor account anywhere in it — the reason this
// still ships EXPERIMENTAL is not a missing credential, it is that not one
// byte of it has been checked against a real capture. HRV, activity level and
// stress carry no documented scale; the response's two trailing bytes are an
// unverified "likely a checksum"; and the 32-byte record's documented field
// table only fills 30 of its bytes (see `ultrahuman.dart` in `protocol`). A
// decoder that is confidently wrong is worse than one that stays silent, so
// `signals` is `const {}` and every record is archived verbatim instead of
// decoded into a [NeutralSample].
//
// FETCH-BY-INDEX, LIKE OURA'S FETCH-BY-CURSOR BUT SIMPLER. `0x04` asks for
// recordings starting at a record index, and nothing in this protocol deletes
// on read or acknowledges a fetch — the host's only state is a bookmark, and
// re-reading a range is idempotent. That is the "fetch-by-range: `confirm()`
// advances the adapter's own cursor" row in [OffloadCheckpoint]'s own table.
//
// TERMINATION IS THE ONE WELL-DOCUMENTED SIGNAL: the result byte (`0x00` ok /
// `0xee` empty / `0xff` fail). `0x07`/`0x08` (earliest/latest index) are used
// only as a best-effort clamp and progress hint — their RESPONSE PAYLOAD SHAPE
// is not documented anywhere, so this file reads it as a u16-LE index (the
// same width the request field itself uses) and treats a failure to parse it
// as "no hint available", never as a reason to stop draining. The drain loop
// itself never depends on either index being known.
//
// NO DESTRUCTIVE COMMAND IS REACHABLE FROM HERE. Reset (`0x98`), airplane mode
// and the power-saving toggle have no builder in `protocol`'s `ultrahuman.dart`
// and this file writes nothing it did not get from a builder there.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// One session. Not const: it holds the cursor to resume from, which belongs
/// to the host (see `ultrahuman_link.dart`) the same way Oura's cursor and
/// anchor do.
class UltrahumanAdapter extends BandAdapter {
  /// Record index to resume the drain from. 0 asks for everything the ring
  /// still holds (or as much of it as the ring's own earliest index allows —
  /// see the earliest-index clamp in [run]).
  final int startIndex;

  /// How long to wait for a reply the ring owes us.
  final Duration replyTimeout;

  /// How long to wait for the host to commit a batch and call `confirm`.
  /// Expiring is SAFE: the cursor does not move, so the batch is re-read.
  final Duration confirmTimeout;

  UltrahumanAdapter({
    this.startIndex = 0,
    this.replyTimeout = const Duration(seconds: 5),
    this.confirmTimeout = const Duration(seconds: 30),
  });

  @override
  BandEntry get entry => kUltrahuman;

  /// NOTHING. HR, HRV, SpO2, skin temperature, activity, steps and stress are
  /// all in the wire record and none of them is declared here — see the
  /// module doc for why. A declared-but-absent signal is worse than a missing
  /// one (see [BandAdapter.signals]); nothing is claimed until a decoder
  /// exists and a real capture has met it.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// A full notification carries exactly 7 records; fewer than that is the
  /// LAST frame of one `0x04` pull, not a truncated one — there is no other
  /// terminator inside a pull.
  static const int _kMaxRecordsPerFrame = 7;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kUltrahumanNotifyChar).listen(
          (rec) {
            final r = parseUltrahumanResponse(rec.$2);
            if (r != null) inbox.add(r);
          },
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );

    // Best-effort battery, on a SEPARATE service this ring is not required to
    // expose (`kUltrahuman.requiredCharacteristics` does not include it) — a
    // ring that never notifies here simply never gets a `battery` note.
    // Checked at yield points below rather than turned into its own event
    // stream: one link.notify per characteristic already drives everything
    // this session needs, and a second `yield*` source would have to be
    // merged with the first one's timing-sensitive collection loop for a
    // single scalar nobody is waiting on in real time.
    int? pendingBatteryPct;
    final stateSub = link.notify(kUltrahumanDeviceStateChar).listen((rec) {
      final pct = _deviceStateBatteryPct(rec.$2);
      if (pct != null) pendingBatteryPct = pct;
    });

    try {
      // Both best-effort and both OPTIONAL — see the module doc on why the
      // drain loop below never depends on either succeeding.
      final earliest =
          await _getIndex(link, inbox, kUltrahumanOpGetEarliestIndex);
      final latest = await _getIndex(link, inbox, kUltrahumanOpGetLatestIndex);

      var cursor = startIndex;
      if (latest != null && cursor > latest) {
        // THE RING'S OWN COUNTER RESTARTED BELOW OUR BOOKMARK — the same
        // shape as Oura's decisecond-uptime reboot case (see `oura.dart`).
        // Every request from here matches nothing forever, and it looks
        // exactly like "no new data" while the ring quietly fills up. The
        // host's remedy is to drop the bookmark; see `ultrahuman_link.dart`.
        link.log('ultrahuman: the bookmark ($cursor) is past the ring\'s '
            'latest index ($latest).');
        yield const BandNote('ultrahuman_cursor_stranded');
        return;
      }
      if (earliest != null && cursor < earliest) {
        // Old records this ring no longer holds. Not recoverable — just skip
        // forward to what it does hold, rather than spending requests on
        // indices it will only ever answer empty.
        link.log('ultrahuman: bookmark ($cursor) is behind the ring\'s '
            'earliest index ($earliest); skipping forward.');
        cursor = earliest;
      }

      // A misbehaving ring answering forever would otherwise spin here.
      for (var pull = 0; pull < 5000; pull++) {
        if (!await link.write(
            kUltrahumanWriteChar, ultrahumanCmdGetRecordings(cursor))) {
          link.log('ultrahuman: history request refused; ending the drain.');
          return;
        }
        final got = await _collectPull(inbox);
        if (pendingBatteryPct != null) {
          yield BandNote('battery', pendingBatteryPct);
          pendingBatteryPct = null;
        }
        if (got.records.isEmpty) {
          if (got.failed) {
            link.log('ultrahuman: the ring reported a failure; ending the '
                'drain.');
            return;
          }
          final remaining = latest == null ? null : latest - cursor + 1;
          if (remaining != null && remaining > 0) {
            link.log('ultrahuman: the ring answered $cursor with nothing but '
                'reports $remaining record(s) still ahead of it.');
            yield const BandNote('ultrahuman_cursor_stranded');
          }
          return;
        }

        yield SampleBatch(const [], raw: got.raw);

        final newCursor = cursor + got.records.length;
        final done = Completer<bool>();
        yield OffloadCheckpoint(
          () async {
            if (!done.isCompleted) done.complete(true);
            return true;
          },
          remaining: latest == null
              ? null
              : (latest - newCursor + 1).clamp(0, 1 << 31),
        );
        final confirmed =
            await done.future.timeout(confirmTimeout, onTimeout: () => false);
        if (!confirmed) {
          link.log('ultrahuman: batch was not confirmed; leaving the cursor '
              'where it is.');
          return;
        }
        cursor = newCursor;
        yield BandNote('ultrahuman_cursor', cursor);
        if (got.failed) {
          // The records already banked above are real — only the frame AFTER
          // them failed. Advancing past them (already done, two lines up)
          // means a retry only re-requests from the point of actual failure,
          // instead of re-fetching and re-discarding the same good frames
          // forever.
          link.log('ultrahuman: the ring reported a failure after '
              '${got.records.length} record(s) this pull; ending the drain.');
          return;
        }
        if (latest != null && cursor > latest) return;
      }
    } finally {
      await sub.cancel();
      await stateSub.cancel();
    }
  }

  /// Ask for [opcode] (earliest or latest index) and read its own u16-LE
  /// payload back. Null on any refusal, timeout or unparsable reply — never a
  /// guess, since neither is load-bearing for the drain to terminate
  /// correctly. See the module doc for why this response shape is read this
  /// way at all.
  Future<int?> _getIndex(BandLink link, _Inbox inbox, int opcode) async {
    final cmd = opcode == kUltrahumanOpGetEarliestIndex
        ? ultrahumanCmdGetEarliestIndex()
        : ultrahumanCmdGetLatestIndex();
    if (!await link.write(kUltrahumanWriteChar, cmd)) return null;
    final r = await inbox.firstWhere((f) => f.opcode == opcode, replyTimeout);
    if (r == null || !r.ok || r.payload.length < 2) return null;
    return r.payload[0] | (r.payload[1] << 8);
  }

  /// Collect every `0x04` notification belonging to one request, stopping at
  /// the first short (< 7 records) frame — the only terminator inside a pull
  /// — or a `fail`/`empty` result, or a reply gap.
  Future<_Pull> _collectPull(_Inbox inbox) async {
    final records = <UltrahumanRecord>[];
    final raw = <Uint8List>[];
    // A misbehaving ring streaming full frames forever would otherwise spin
    // here — same shape as the outer `pull < 5000` guard in [run].
    for (var frame = 0; frame < 1000; frame++) {
      final r = await inbox.next(kUltrahumanOpGetRecordings, replyTimeout);
      if (r == null) break; // no more frames arrived — end of this pull
      // A fail frame carries no records of its own, but anything ALREADY
      // collected from earlier ok frames this same pull is still good data —
      // bank it (like the empty branch below) rather than discarding it, so a
      // ring that fails partway through a pull doesn't force the drain to
      // re-fetch and re-discard the same good frames forever.
      if (r.result == kUltrahumanResultFail) {
        return _Pull(records, raw, failed: true);
      }
      if (r.result == kUltrahumanResultEmpty) break; // nothing from here on
      final frameRecords = parseUltrahumanRecords(r.payload);
      records.addAll(frameRecords);
      for (var off = 0;
          off + kUltrahumanRecordLen <= r.payload.length;
          off += kUltrahumanRecordLen) {
        raw.add(
            Uint8List.sublistView(r.payload, off, off + kUltrahumanRecordLen));
      }
      if (frameRecords.length < _kMaxRecordsPerFrame) break;
    }
    return _Pull(records, raw);
  }

  /// 7-byte device-state payload: `[battery%, 4 unknown, chargeState,
  /// tempC]`. Only the battery percent is read — the 4 unknown bytes and the
  /// charge/temperature fields have no confirmed layout, and archiving them
  /// under a name that might be wrong is worse than not naming them at all.
  static int? _deviceStateBatteryPct(List<int> value) {
    if (value.length < 7) return null;
    final pct = value[0];
    return (pct >= 0 && pct <= 100) ? pct : null;
  }
}

class _Pull {
  final List<UltrahumanRecord> records;
  final List<Uint8List> raw;
  final bool failed;
  const _Pull(this.records, this.raw, {this.failed = false});
}

/// Response frames off the notify characteristic, buffered so a reply landing
/// before anyone is waiting is not dropped. Same shape as `oura.dart`'s
/// private `_Inbox`, and hand-rolled for the same reason: the whole of what
/// this session needs is "the next frame [matching X], or nothing".
class _Inbox {
  final List<UltrahumanResponse> _buf = [];
  Completer<UltrahumanResponse?>? _waiter;
  bool _closed = false;

  void add(UltrahumanResponse r) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(r);
      return;
    }
    _buf.add(r);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  /// The next buffered frame, or null on timeout or a closed link.
  Future<UltrahumanResponse?> _next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<UltrahumanResponse?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame with opcode [opcode], discarding anything else that
  /// arrives first. [timeout] bounds the whole search, not each frame.
  Future<UltrahumanResponse?> next(int opcode, Duration timeout) =>
      firstWhere((f) => f.opcode == opcode, timeout);

  Future<UltrahumanResponse?> firstWhere(
    bool Function(UltrahumanResponse) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final r = await _next(timeout - deadline.elapsed);
      if (r == null) return null;
      if (test(r)) return r;
    }
    return null;
  }
}
