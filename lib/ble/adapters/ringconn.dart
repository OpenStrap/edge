// RingConn (Gen 2 / Gen 2 Air / Gen 3) as a [BandAdapter]: authenticate
// against the ring's own BLE MAC, drain both history channels, bank every
// frame verbatim, decode nothing.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6), so not one byte of this path has been exercised against one. It
// ships EXPERIMENTAL, `signals` stays `const {}`, and nothing this file writes
// becomes a number: its rows carry a non-null `source`, and every derive/export
// read filters `source IS NULL`. That is correct behaviour for an uncalibrated
// decoder, not a limitation to route around.
//
// THE SHAPE IS SIMPLER THAN OURA'S, and for a real reason rather than an
// oversight: the ring tracks its own resume position per channel, so unlike
// `OuraAdapter` this file holds no pairing key, no drain cursor and no time
// anchor. Every connection opens both channels at "now" — that is the same
// behaviour the ring's own vendor app exercises, and it is exactly why there
// is a known limitation to state rather than hide: the ring appears to share
// ONE resume pointer per channel across every bonded client, so whichever
// side (us or the vendor app) opens at "now" first drains the backlog and
// leaves the other side an empty pass. Nothing is lost permanently — the
// ring's own buffer is measured in days — but a sync run right after the
// vendor app's own sync can come back looking emptier than expected.
//
// THE AUTH HANDSHAKE IS A KEYED HASH, NOT VENDOR ENCRYPTION. SM3 is a
// published algorithm (`ringconn.dart` in the protocol package) computed over
// the ring's own BLE MAC — read openly off the standard System ID
// characteristic — and a single-byte challenge. There is no vendor secret, no
// cloud key and nothing installed on the ring; the whole handshake runs fresh
// on every connection with nothing persisted host-side.
//
// WHAT STAYS EXPERIMENTAL, AND WHY IT IS NOT A GAP TO CLOSE HERE: the bulk
// pages this file drains (`0x47` PPG/optical, `0x4c` activity/sleep) carry
// per-field layouts — HR, HRV, SpO2, respiratory rate, step counts — that are
// well-characterised on paper but unverified on real hardware. `run()` reads
// only the STRUCTURAL envelope: the reply tag, the page's remaining-count
// byte, and the fixed record length needed to slice a page and walk the
// stream — never a byte inside a record. Every record, decoded or not, is
// archived verbatim; a future decoder finds them there once someone owns a
// ring to check one against.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// One RingConn session. Not const, unlike [BleHrsAdapter]: [nowSeconds] is
/// injected so a fixture replay is deterministic — the drain cursor this file
/// opens both channels at is derived from wall-clock now, and `DateTime.now()`
/// must not appear directly in an adapter body (see [BandLink]'s own doc).
class RingConnAdapter extends BandAdapter {
  /// Wall-clock now, in Unix seconds.
  final int Function() nowSeconds;

  /// How long to wait for a reply the ring owes us.
  final Duration replyTimeout;

  RingConnAdapter({
    int Function()? nowSeconds,
    this.replyTimeout = const Duration(seconds: 5),
  }) : nowSeconds =
            nowSeconds ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  @override
  BandEntry get entry => kRingConn;

  /// NOTHING. See this file's own header — every per-field layout this ring's
  /// bulk pages carry is unverified against real hardware, so nothing is
  /// claimed until a decoder exists and a real capture has met it.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// A hard ceiling on pages within ONE burst. `remaining` is a single byte,
  /// so a well-behaved burst needs nowhere near this many ACKs to reach
  /// zero — this only catches a ring that never does. There is no trusted
  /// "channel is done" signal on this wire at all (only a low-confidence flag
  /// on the sync-open reply), so this cap and [replyTimeout] are the whole of
  /// what bounds the loop below — never a semantic end.
  static const int _kMaxPagesPerBurst = 512;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kRingConnNotifyChar).listen(
      (rec) {
        final f = parseRingConnFrame(rec.$2);
        if (f != null) inbox.add(f, Uint8List.fromList(rec.$2));
      },
      onDone: inbox.close,
      onError: (Object _) => inbox.close(),
    );
    try {
      final mac = await _readMac(link);
      if (mac == null) {
        link.log('ringconn: could not read the System ID; no MAC, no auth.');
        return;
      }
      final authArchive = <Uint8List>[];
      final authed = await _authenticate(link, inbox, mac, authArchive);
      if (authArchive.isNotEmpty) {
        yield SampleBatch(const [], raw: authArchive);
      }
      if (!authed) return;

      // Two independent channels, each with its own resume pointer on the
      // ring itself — drained one after the other, same command shape with
      // one byte differing (see `ringConnCmdSyncOpen`'s own doc).
      yield* _drainChannel(link, inbox, kRingConnChannelSleep);
      yield* _drainChannel(link, inbox, kRingConnChannelAwake);
    } finally {
      await sub.cancel();
    }
  }

  /// Read the System ID once and recover the ring's own BLE MAC from it, or
  /// null when the characteristic is missing, unreadable, or too short to be
  /// one.
  Future<Uint8List?> _readMac(BandLink link) async {
    final raw = await link.read(kSystemIdUuid);
    if (raw == null || raw.length != 8) return null;
    return ringConnMacFromSystemId(raw);
  }

  /// Status, challenge, SM3, answer. False on any refusal — a session that
  /// carries on unauthenticated gets no further replies at all, which looks
  /// identical to a dead link.
  ///
  /// Every frame walked past — matched or not — is appended to [archive], so
  /// a failed handshake still banks whatever the ring actually said (owner
  /// rulings R1-R3: capture everything).
  Future<bool> _authenticate(
    BandLink link,
    _Inbox inbox,
    List<int> mac,
    List<Uint8List> archive,
  ) async {
    if (!await link.write(kRingConnCommandChar, ringConnCmdStatus())) {
      return false;
    }
    final challengeFrame = await inbox.firstWhere(
      (f) =>
          f.respid == kRingConnRespAuth &&
          f.payload.length >= 2 &&
          f.payload[0] == 0x00,
      replyTimeout,
      onEach: archive.add,
    );
    if (challengeFrame == null) {
      link.log('ringconn: no authentication challenge.');
      return false;
    }
    final response = ringConnAuthResponse(mac, challengeFrame.payload[1]);
    if (!await link.write(
      kRingConnCommandChar,
      ringConnCmdAuthResponse(response),
    )) {
      return false;
    }
    final confirm = await inbox.firstWhere(
      (f) =>
          f.respid == kRingConnRespAuth &&
          f.payload.isNotEmpty &&
          f.payload[0] == 0x01,
      replyTimeout,
      onEach: archive.add,
    );
    if (confirm == null) {
      link.log('ringconn: authentication was not confirmed.');
      return false;
    }
    return true;
  }

  /// Open [channel] at "now" and drain the one burst it hands back.
  ///
  /// OPENS AT "NOW", NEVER AT A STORED CURSOR — this file holds none. See this
  /// file's own header on why that is the app-faithful choice and what it
  /// costs when the vendor app synced first.
  Stream<BandEvent> _drainChannel(
    BandLink link,
    _Inbox inbox,
    int channel,
  ) async* {
    final raw = <Uint8List>[];
    final cursor = ringConnCursor(nowSeconds());
    if (!await link.write(
      kRingConnCommandChar,
      ringConnCmdSyncOpen(cursor, channel),
    )) {
      link.log('ringconn: sync-open refused on channel $channel; skipping '
          'it.');
      if (raw.isNotEmpty) yield SampleBatch(const [], raw: raw);
      return;
    }
    final opened = await inbox.firstWhere(
      (f) => f.respid == kRingConnRespSyncOpen,
      replyTimeout,
      onEach: raw.add,
    );
    if (opened == null) {
      link.log('ringconn: no sync-open reply on channel $channel.');
      if (raw.isNotEmpty) yield SampleBatch(const [], raw: raw);
      return;
    }
    if (!await link.write(kRingConnCommandChar, ringConnCmdFetch())) {
      link.log('ringconn: fetch refused on channel $channel; ending its '
          'drain.');
      if (raw.isNotEmpty) yield SampleBatch(const [], raw: raw);
      return;
    }

    var page = 0;
    for (; page < _kMaxPagesPerBurst; page++) {
      final rec = await inbox.next(replyTimeout);
      if (rec == null) {
        link.log('ringconn: no reply within the timeout on channel '
            '$channel.');
        break;
      }
      final (f, bytes) = rec;
      raw.add(bytes);
      if (ringConnIsBulk(f.respid)) {
        final parsed = parseRingConnBulkPage(f);
        // A page that will not slice cleanly is treated the same as the last
        // page of a burst: there is nothing safe left to do with it, and the
        // bytes are archived above either way.
        if (parsed == null || parsed.remaining == 0) break;
        final ack = f.respid == kRingConnRespBulkPpg
            ? ringConnCmdAckPpg()
            : ringConnCmdAckActivity();
        if (!await link.write(kRingConnCommandChar, ack)) {
          link.log('ringconn: page ack refused on channel $channel; ending '
              'its drain.');
          break;
        }
        continue;
      }
      if (ringConnEndsBurst(f.respid)) break;
      // Anything else is archived above and otherwise ignored — the loop
      // keeps waiting for a frame that IS one of the two.
    }
    // The only exit that is NOT one of the logged breaks above: the loop ran
    // out its full range without the ring ever signalling the burst was
    // done. Every byte received is still archived above — this is a log
    // line about an unusually long burst, not a data-loss report — but it
    // needs to say so, the same as every other early-exit path here does.
    if (page == _kMaxPagesPerBurst) {
      link.log('ringconn: hit the $_kMaxPagesPerBurst-page cap on channel '
          '$channel with no burst-end reply; stopping this session\'s '
          'drain there.');
    }
    if (raw.isNotEmpty) yield SampleBatch(const [], raw: raw);
  }
}

/// The single instance. Not const — see the class doc — but cheap to build:
/// nothing here is session state until [BandAdapter.run] is called.
final RingConnAdapter kRingConnAdapter = RingConnAdapter();

/// Frames off the notify characteristic, buffered so a reply landing before
/// anyone is waiting is not dropped. The same shape as `oura.dart`'s private
/// `_Inbox`, and not shared with it for the same reason `oura_link.dart`'s
/// pairing flow keeps its own tiny copy rather than generalising three call
/// sites' worth of "the next frame, or nothing" into shared plumbing.
class _Inbox {
  final List<(RingConnFrame, Uint8List)> _buf = [];
  Completer<(RingConnFrame, Uint8List)?>? _waiter;
  bool _closed = false;

  void add(RingConnFrame f, Uint8List raw) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete((f, raw));
      return;
    }
    _buf.add((f, raw));
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  /// The next frame, or null on timeout or a closed link.
  Future<(RingConnFrame, Uint8List)?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<(RingConnFrame, Uint8List)?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame satisfying [test], discarding what comes before it.
  /// [onEach] is called for every frame walked past — matched or not — so a
  /// caller can archive the bytes even when they were not the one it was
  /// waiting for. [timeout] bounds the whole search, not each frame.
  Future<RingConnFrame?> firstWhere(
    bool Function(RingConnFrame) test,
    Duration timeout, {
    void Function(Uint8List raw)? onEach,
  }) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final rec = await next(timeout - deadline.elapsed);
      if (rec == null) return null;
      onEach?.call(rec.$2);
      if (test(rec.$1)) return rec.$1;
    }
    return null;
  }
}
