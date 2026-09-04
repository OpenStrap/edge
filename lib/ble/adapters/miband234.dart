// Mi Band 2, 3 and 4 — the shared "Huami legacy" GATT protocol — as a
// [BandAdapter].
//
// NOTHING HERE HAS MET HARDWARE, same as every other notify-class band on
// this seam. It ships EXPERIMENTAL (ASSUMPTIONS R6): [signals] is `const {}`,
// exactly like [kOura] and [kBleHrs], and `kDerivableSources` does not name
// it. It may pair, connect and bank raw bytes; nothing here can become a
// metric until the owner has held one.
//
// THE HANDSHAKE IS A LOCALLY-GENERATED SECRET, not a vendor one. The band
// holds exactly one 16-byte key at a time and only accepts a NEW one while it
// has none — a factory-reset or never-paired unit. A band already bound to
// another key refuses or silently ignores the install, same shape as the
// Oura ring's own precondition; see `miband_link.dart` for the pairing-side
// wording.
//
// WHY THIS DOES NOT DECODE HEART RATE EVEN THOUGH IT COULD. `ble_hrs.dart`
// already has a verified decoder for the exact bytes the standard HR
// characteristic carries, and reusing it here would be one line. Declined for
// v1 on purpose: nobody has confirmed which variant of this family is on the
// other end of a given pairing (plain Mi Band 2 has no HR sensor at all), and
// stamping a decoded reading under a band nobody has actually touched is the
// declared-but-unverified mistake the signals contract exists to prevent.
// Battery and step bytes get the same treatment for the same reason — every
// optional channel is archived verbatim, undecoded, never turned into a
// [BandNote].
//
// WHY THIS NEVER TOUCHES HISTORY. Fetching and clearing the band's stored
// activity data is a real, stateful, multi-step protocol with its own record
// layout — decodable in principle, but building a state machine this project
// cannot verify for a device with zero decoded metrics buys nothing today.
// This file never writes to that channel, so the band's flash is left
// completely alone: no [OffloadCheckpoint] is ever emitted.

import 'dart:async';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Encrypt one authentication challenge.
///
/// AES-128 in ECB mode, one 16-byte block, no padding — the band's challenge
/// already arrives exactly block-sized, which is simpler than a scheme that
/// has to pad first (contrast `oura.dart`'s `ouraAuthResponse`, which pads a
/// 15-byte nonce). One block only, so ECB's usual objection has nothing to
/// bite on here either.
///
/// Exposed rather than private so a test can pin it against a known AES
/// vector without a radio.
Uint8List miBand234AuthResponse(List<int> key, List<int> challenge) {
  if (key.length != 16 || challenge.length != 16) {
    throw ArgumentError(
        'Mi Band 2/3/4 auth takes a 16-byte key and a 16-byte challenge');
  }
  final out = Uint8List(16);
  ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)))
    ..processBlock(Uint8List.fromList(challenge), 0, out, 0);
  return out;
}

/// Host-side tags distinguishing which optional channel an archived frame
/// came from. NEVER transmitted and never part of `raw_archive.hex` — see
/// `miband_link.dart`'s archive builder, which strips the tag back off
/// before hexing so the stored bytes are exactly what the radio sent.
const int kMiBand234ArchiveBattery = 0xf0;
const int kMiBand234ArchiveSteps = 0xf1;
const int kMiBand234ArchiveHr = 0xf2;

/// One connection to a Mi Band 2, 3 or 4.
class MiBand234Adapter extends BandAdapter {
  /// The 16-byte key this phone generated and either has, or is about to,
  /// install on the band.
  final List<int> key;

  /// True only on the very first connection after pairing installed a key the
  /// band did not have — see [entry]'s own doc. False on every reconnect: a
  /// band that already holds this key does not accept a second install, and
  /// nothing here needs it to.
  final bool needsKeyWrite;

  /// How long to wait for a reply the band owes us.
  final Duration replyTimeout;

  MiBand234Adapter({
    required this.key,
    this.needsKeyWrite = false,
    this.replyTimeout = const Duration(seconds: 5),
  });

  @override
  BandEntry get entry => kMiBand234;

  /// NOTHING. See this file's own header for why HR, battery and steps are
  /// each archived rather than declared.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kHuami234AuthChar).listen(
          (rec) => inbox.add(Uint8List.fromList(rec.$2)),
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      if (!await _authenticate(link, inbox)) return;
      yield* _subscribeOptional(link);
    } finally {
      await sub.cancel();
    }
  }

  /// Install-then-prove. False on any refusal — a session that carries on
  /// unauthenticated would sit waiting on channels the band will never answer.
  Future<bool> _authenticate(BandLink link, _Inbox inbox) async {
    if (needsKeyWrite) {
      if (!await link.write(kHuami234AuthChar, <int>[0x01, 0x08, ...key])) {
        return false;
      }
      final sent = await inbox.firstWhere(
        (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x01,
        replyTimeout,
      );
      if (sent == null || sent[2] != 0x01) {
        link.log('miband234: key install refused or unanswered.');
        return false;
      }
    }
    if (!await link.write(kHuami234AuthChar, <int>[0x02, 0x08])) return false;
    final challengeFrame = await inbox.firstWhere(
      (f) => f.length >= 19 && f[0] == 0x10 && f[1] == 0x02,
      replyTimeout,
    );
    if (challengeFrame == null || challengeFrame[2] != 0x01) {
      link.log('miband234: no usable authentication challenge.');
      return false;
    }
    final answer =
        miBand234AuthResponse(key, challengeFrame.sublist(3, 19));
    if (!await link.write(kHuami234AuthChar, <int>[0x03, 0x08, ...answer])) {
      return false;
    }
    final result = await inbox.firstWhere(
      (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x03,
      replyTimeout,
    );
    if (result == null || result[2] != 0x01) {
      // Worth naming, because the remedies differ: 0x04 means the wrong key
      // (or a band still bound to another one); silence means the band
      // stopped answering mid-handshake.
      link.log('miband234: authentication refused '
          '(status ${result == null ? "none" : result[2]}).');
      return false;
    }
    return true;
  }

  /// Best-effort subscribe to whatever optional channel this unit exposes,
  /// and forward every notification verbatim. Ends when the link ends — there
  /// is no completion signal on any of these channels to wait for, unlike the
  /// history drain this file deliberately never opens.
  Stream<BandEvent> _subscribeOptional(BandLink link) {
    final controller = StreamController<BandEvent>();
    const channels = <(String uuid, int archiveTag)>[
      (kHuami234BatteryChar, kMiBand234ArchiveBattery),
      (kHuami234StepsChar, kMiBand234ArchiveSteps),
      (kHeartRateMeasurementUuid, kMiBand234ArchiveHr),
    ];
    var open = channels.length;
    void endOne() {
      open--;
      if (open <= 0 && !controller.isClosed) controller.close();
    }

    for (final (uuid, tag) in channels) {
      link.notify(uuid).listen(
        (rec) {
          if (controller.isClosed) return;
          // The tag is prepended for the archive builder to key `reason`
          // and `packet_type` on, and stripped back off before hexing — see
          // `miband_link.dart`. Never part of what a decoder would see as
          // the wire bytes.
          controller.add(SampleBatch(
            const [],
            raw: [Uint8List.fromList([tag, ...rec.$2])],
          ));
        },
        onDone: endOne,
        onError: (Object _) => endOne(),
      );
    }
    return controller.stream;
  }
}

/// The single instance a fresh session needs no per-band state to construct
/// beyond the key, so unlike [MiBand234Adapter] this file has no const
/// singleton — every connection's key and `needsKeyWrite` differ.
///
/// Frames off the auth characteristic, buffered so a reply landing before
/// anyone is waiting is not dropped. Same shape as `oura.dart`'s private
/// `_Inbox`, kept separate rather than shared: three replies, once per
/// connection, is not worth a shared abstraction.
class _Inbox {
  final List<Uint8List> _buf = [];
  Completer<Uint8List?>? _waiter;
  bool _closed = false;

  void add(Uint8List f) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(f);
      return;
    }
    _buf.add(f);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  Future<Uint8List?> _next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<Uint8List?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame satisfying [test], discarding what comes before it.
  /// [timeout] bounds the whole search, not each frame.
  Future<Uint8List?> firstWhere(
    bool Function(Uint8List) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final rec = await _next(timeout - deadline.elapsed);
      if (rec == null) return null;
      if (test(rec)) return rec;
    }
    return null;
  }
}
