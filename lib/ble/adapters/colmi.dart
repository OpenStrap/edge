// Colmi smart ring family as a [BandAdapter]: connect, walk the day-cursor
// history commands, bank every reply byte, decode nothing into a signal.
//
// THE WIRE. A fixed 16-byte frame with no envelope beyond itself: byte 0 is
// the command id, bytes 1-14 are the command's own zero-padded payload, byte
// 15 is the low byte of the sum of bytes 0-14. No CRC beyond that one-byte
// sum, no sequence numbers, no session state carried across writes except
// whatever the ring itself buffers. Every reply — including an unprompted
// battery push — arrives on the notify characteristic tagged by the same
// command id it went out under.
//
// NO HANDSHAKE OF ANY KIND. No pairing key, no nonce, no challenge-response,
// no bonding requirement this protocol itself asks for. Connect, discover,
// subscribe, start writing — the same honest floor as `ble_hrs.dart`'s
// no-handshake case, except this band also has a command channel.
//
// SERVICE A ONLY. A second GATT service on the same ring (sleep + SpO2 "big
// data") is length-prefixed and reassembles across several notify frames —
// real reassembly logic this adapter does not implement, and deliberately: it
// is the one piece of this protocol with real complexity, and nothing derives
// from any of this ring's bytes yet regardless. Deferred to a later PR.
//
// REQUEST-PAYLOAD ASSUMPTIONS, NAMED RATHER THAN HIDDEN. The day-cursor walks
// below are a direct transcription of what is known: a day offset, a
// 5-byte little-endian timestamp alongside it for the HR walk specifically,
// and BCD-encoded date bytes for the activity walk. The exact BYTE POSITIONS
// within a payload are this file's own reasonable reading of that, not an
// independently confirmed fact — getting one wrong costs a request the ring
// answers with nothing, never a corrupted write, since every command here is
// a read request and nothing in this protocol acknowledges or deletes on our
// say-so. The battery reply's value byte (payload[0], i.e. frame byte 1) is
// the same kind of reasonable-not-confirmed reading. A real capture is what
// would upgrade any of this from "a request that may return data" to a
// decoder — which is exactly why none of it is decoded into a signal.
//
// EXPERIMENTAL, and it stays that way: nobody on this project owns a Colmi
// ring, so not a byte of this path has met hardware (ASSUMPTIONS R6).
// `signals` is `const {}`, matching `kOura`'s empty map — not `hrSparse` even
// though the ring plainly measures heart rate, because nothing here has
// checked a decode against real bytes. Every frame this adapter receives is
// archived verbatim; nothing is translated into `decoded_onehz` or any other
// analytics-facing column.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Set date/time. Payload layout unconfirmed — not sent by [run] (see the
/// header). Kept as a named opcode for a later PR once it is.
const int kColmiCmdSetTime = 0x01;

/// Battery level. Same id answers a request and an unprompted push.
const int kColmiCmdBattery = 0x03;

/// Set phone name (cosmetic). Payload layout unconfirmed — not sent by [run].
const int kColmiCmdSetPhoneName = 0x04;

/// Buzzes the ring. Not sent by [run] — nothing here needs the ring to
/// physically identify itself.
const int kColmiCmdFindDevice = 0x50;

/// Manual/live heart-rate request, single reply. Not sent by [run]: a live
/// request is a workout-time concern this adapter's history-walk shape does
/// not cover, and nothing decodes the reply anyway.
const int kColmiCmdLiveHeartRate = 0x69;

/// HR history walk. Reply packets hold up to 13 5-minute-bucketed bpm bytes;
/// this adapter does not decode them, only banks them.
const int kColmiCmdHrHistory = 0x15;

/// Stress history walk, 30-minute buckets.
const int kColmiCmdStressHistory = 0x37;

/// HRV history walk, 30-minute buckets.
const int kColmiCmdHrvHistory = 0x39;

/// Activity history walk. The date bytes in its request are BCD-encoded —
/// the one genuinely odd wire quirk in this protocol: a byte `0x24` means
/// "24", not 36.
const int kColmiCmdActivityHistory = 0x43;

/// Build one 16-byte Colmi frame: `[cmd][payload, zero-padded to 14][sum]`.
/// [payload] is at most 14 bytes; anything shorter is zero-padded, matching
/// the wire format's own "zero-padded" description.
Uint8List colmiFrame(int cmd, [List<int> payload = const <int>[]]) {
  assert(payload.length <= 14,
      'Colmi payload is 14 bytes; got ${payload.length}.');
  final f = Uint8List(16)..[0] = cmd;
  f.setRange(1, 1 + payload.length, payload);
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    sum += f[i];
  }
  f[15] = sum & 0xff;
  return f;
}

/// One BCD-encoded byte: `0x24` for the value 24, per the activity walk's own
/// documented quirk.
int colmiBcd(int value) => ((value ~/ 10) << 4) | (value % 10);

/// [value] as 5 little-endian bytes (lowest byte first).
List<int> _leBytes5(int value) =>
    List<int>.generate(5, (i) => (value >> (8 * i)) & 0xff);

/// The adapter. Holds no secret and no persistent cursor — every connect
/// re-walks the same small rolling window, which is safe because the ring
/// keeps its own history regardless of what the host reads (there is no
/// ACK/trim command anywhere in this protocol).
class ColmiAdapter extends BandAdapter {
  /// Wall-clock now, in Unix seconds. Injected so a fixture replay is
  /// deterministic — `DateTime.now()` does not appear below.
  final int Function() nowSeconds;

  /// How long to wait for the FIRST reply to a request.
  final Duration firstReplyTimeout;

  /// How long to wait after the last reply before deciding a command is done
  /// answering. There is no length-prefix or terminator to key off on Service
  /// A (that is Service B's job, deferred), so "nothing new for this long" is
  /// the only honest way to end a multi-packet reply here.
  final Duration quietTimeout;

  ColmiAdapter({
    int Function()? nowSeconds,
    this.firstReplyTimeout = const Duration(seconds: 5),
    this.quietTimeout = const Duration(milliseconds: 800),
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  @override
  BandEntry get entry => kColmi;

  /// NOTHING. See the header: a decode with no capture to check it against is
  /// a guess, and a declared-but-absent signal is worse than a missing one.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// How many days back the history walk goes on each connect. A rolling
  /// window, not a full-history drain — this ring has no cursor for the host
  /// to resume from, and none is needed: it never forgets on our say-so.
  static const int _kHistoryDays = 7;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kColmiNotifyChar).listen(
          (rec) => inbox.add(Uint8List.fromList(rec.$2)),
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      if (await link.write(kColmiWriteChar, colmiFrame(kColmiCmdBattery))) {
        final frames =
            await _collect(inbox, kColmiCmdBattery, firstReplyTimeout, quietTimeout);
        if (frames.isNotEmpty) {
          yield BandNote('battery', frames.last[1]);
          yield SampleBatch(const [], raw: frames);
        }
      } else {
        link.log('colmi: battery request refused.');
      }

      for (var day = 0; day < _kHistoryDays; day++) {
        final dayTs = nowSeconds() - day * 86400;

        for (final cmd in const [
          kColmiCmdHrHistory,
          kColmiCmdStressHistory,
          kColmiCmdHrvHistory,
        ]) {
          final payload = cmd == kColmiCmdHrHistory
              ? <int>[day, ..._leBytes5(dayTs)]
              : <int>[day];
          if (!await link.write(kColmiWriteChar, colmiFrame(cmd, payload))) {
            link.log('colmi: write refused for '
                '0x${cmd.toRadixString(16)} (day $day).');
            continue;
          }
          final frames = await _collect(inbox, cmd, firstReplyTimeout, quietTimeout);
          if (frames.isNotEmpty) yield SampleBatch(const [], raw: frames);
        }

        final date =
            DateTime.fromMillisecondsSinceEpoch(dayTs * 1000, isUtc: false);
        final activityPayload = <int>[
          colmiBcd(date.year % 100),
          colmiBcd(date.month),
          colmiBcd(date.day),
        ];
        if (await link.write(
            kColmiWriteChar, colmiFrame(kColmiCmdActivityHistory, activityPayload))) {
          final frames = await _collect(
              inbox, kColmiCmdActivityHistory, firstReplyTimeout, quietTimeout);
          if (frames.isNotEmpty) yield SampleBatch(const [], raw: frames);
        } else {
          link.log('colmi: write refused for activity history (day $day).');
        }
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Every reply frame tagged [cmd], collected until [quiet] passes with
  /// nothing new arriving (bounded by [first] for the very first one).
  /// Anything tagged a different command id — an unsolicited battery push
  /// landing mid-walk, say — is dropped here rather than requeued: this
  /// protocol is a strict sequential request/reply, so cross-talk during one
  /// command's collection window is not expected.
  static Future<List<Uint8List>> _collect(
    _Inbox inbox,
    int cmd,
    Duration first,
    Duration quiet,
  ) async {
    final out = <Uint8List>[];
    var timeout = first;
    while (true) {
      final f = await inbox.next(timeout);
      if (f == null) return out;
      // Every real frame is exactly 16 bytes; a short one is a truncated
      // notification, not this protocol's own reply, and dropped rather than
      // indexed — `f[0]` and, at the call site, `frames.last[1]` would
      // otherwise be a RangeError away from ending the whole sync early.
      if (f.length == 16 && f[0] == cmd) out.add(f);
      timeout = quiet;
    }
  }
}

/// The single instance. Holds no per-ring state, so — like [BleHrsAdapter] —
/// nothing stops one shared instance driving every Colmi session.
final ColmiAdapter kColmiAdapter = ColmiAdapter();

/// Frames off the notify characteristic, buffered so a reply landing before
/// anyone is waiting is not dropped. Same shape as `oura.dart`'s `_Inbox`,
/// simplified: this file never needs to look inside a frame to know which
/// batch it belongs to, only its command-id tag.
class _Inbox {
  final List<Uint8List> _buf = [];
  Completer<Uint8List?>? _waiter;
  bool _closed = false;

  void add(Uint8List frame) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(frame);
      return;
    }
    _buf.add(frame);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  /// The next frame, or null on timeout or a closed link.
  Future<Uint8List?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<Uint8List?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }
}
