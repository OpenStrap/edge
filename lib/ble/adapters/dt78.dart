// DT78 / DT92 / DT66 and the wider tail of WearFit-2.0-compatible OEM clones,
// as a [BandAdapter].
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one of these
// watches, so only the envelope itself and the two report codes with a real
// worked byte example — battery and device info — are read at all, and
// neither becomes anything more than a [BandNote]. Every frame this watch
// sends — the health bundle, steps, sleep, the two connect-event pushes — is
// banked to `raw_archive` verbatim and none of it is decoded. It ships
// EXPERIMENTAL (ASSUMPTIONS R6), `signals` is `const {}`, and it is excluded
// from `kDerivableSources`: nothing here can become a number until someone
// has held one of these to cross-check a decode against.
//
// NO HANDSHAKE. There is no pairing key, no nonce, no challenge/response and
// no bonding requirement anywhere in this protocol — the whole of what a
// working client does after service discovery is request an MTU and enable
// notifications, both of which happen above this seam. This file's [run]
// starts polling the moment it is subscribed.
//
// THE FRAME, transcribed from the format's own worked examples:
//
//   AB 00 [len] FF [cmd] [mode] [args...]
//
// `len` is a u8 counting every byte from the `FF` marker to the end of the
// frame inclusive — the only integrity signal this format has, since there is
// no checksum or CRC anywhere in it. Nothing states that one GATT
// notification carries exactly one frame, so [_Dt78Reader] buffers across
// notifications and only emits once a declared length has actually arrived.
//
// WRITE TYPE. Both reference clients write host->watch without response
// (Android sets `WRITE_TYPE_NO_RESPONSE` explicitly), while this repo's
// shared link write is with-response by construction (`gatt_link.dart`) —
// that is what triggers WHOOP's bonding, and it is untested here against a
// real DT78 characteristic that may not expose the with-response property.
// Left as-is rather than widening the shared link for one unverified band;
// worth checking against real hardware before this ships past EXPERIMENTAL.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// One parsed frame off the notify characteristic.
class Dt78Frame {
  final int cmd;
  final int mode;

  /// Bytes after the mode byte — empty for a bare poll's reply header alone.
  final List<int> args;

  /// The whole frame verbatim, preamble included — what `raw_archive` gets.
  final Uint8List raw;

  const Dt78Frame(this.cmd, this.mode, this.args, this.raw);
}

/// Build one bare host->watch poll: `AB 00 03 FF [cmd] [mode]`. Every request
/// this adapter sends is exactly this shape — none carries an argument.
Uint8List buildDt78Poll(int cmd, int mode) =>
    Uint8List.fromList(<int>[0xAB, 0x00, 3, 0xFF, cmd, mode]);

/// Buffers an accumulating notify byte stream into complete [Dt78Frame]s.
///
/// Hand-rolled rather than reusing a shared reassembler: there is no other
/// length-prefixed-with-no-checksum format in this codebase to share one
/// with, and the whole of what this needs is "wait for `len` more bytes,
/// then hand back one frame".
class _Dt78Reader {
  final List<int> _buf = <int>[];

  /// Feed newly-arrived bytes; returns every frame that is now complete.
  List<Dt78Frame> feed(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Dt78Frame>[];
    while (true) {
      final start = _findPreamble();
      if (start == null) {
        // Nothing but noise buffered. Bounded so a stream that never
        // resyncs cannot grow this forever.
        if (_buf.length > 512) _buf.clear();
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < 3) break; // the length byte has not arrived yet
      final len = _buf[2];
      if (len < 3) {
        // No real frame is shorter than `FF, cmd, mode` — this is not a
        // length byte, it is a stray 0xAB/0x00 pair. Drop it and keep
        // scanning.
        _buf.removeAt(0);
        continue;
      }
      final total = 3 + len;
      if (_buf.length < total) break; // waiting on the rest of this frame
      final frame = Uint8List.fromList(_buf.sublist(0, total));
      _buf.removeRange(0, total);
      if (frame[3] == 0xFF) {
        out.add(Dt78Frame(
          frame[4],
          frame[5],
          frame.sublist(6),
          frame,
        ));
      }
      // else: the length happened to land on something that is not really a
      // frame boundary — dropped, and the loop resumes scanning from
      // whatever preamble candidate is left in the buffer.
    }
    return out;
  }

  int? _findPreamble() {
    for (var i = 0; i + 1 < _buf.length; i++) {
      if (_buf[i] == 0xAB && _buf[i + 1] == 0x00) return i;
    }
    return null;
  }
}

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class Dt78Adapter extends BandAdapter {
  const Dt78Adapter();

  @override
  BandEntry get entry => kDt78;

  /// NOTHING. The watch plainly emits heart rate, SpO2, blood pressure, steps
  /// and sleep, and none of it is declared here: `0x31`/`0x32` are single- or
  /// two-byte values with one worked example each and zero real captures to
  /// check a decode against, and `0x51`/`0x52` are the source doc's own
  /// best-effort guesses on undetermined byte widths. A declared-but-absent
  /// signal is worse than a missing one (see [BandAdapter.signals]), so
  /// nothing is claimed until a decoder exists and a real capture has met it.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final reader = _Dt78Reader();
    final frames = StreamController<Dt78Frame>();
    final sub = link.notify(kDt78NotifyChar).listen(
          (rec) {
            for (final f in reader.feed(rec.$2)) {
              frames.add(f);
            }
          },
          onDone: frames.close,
          onError: (Object _) => frames.close(),
        );
    try {
      // One poll each, fire-and-forget — a refused write just means that
      // one reply never arrives, not a reason to end the session. Device
      // info and battery first (matching both reference clients' own
      // connect-time behaviour), then the health bundle and steps.
      await link.write(kDt78WriteChar, buildDt78Poll(0x92, 0x80));
      await link.write(kDt78WriteChar, buildDt78Poll(0x91, 0x80));
      await link.write(kDt78WriteChar, buildDt78Poll(0x32, 0x01));
      await link.write(kDt78WriteChar, buildDt78Poll(0x51, 0x80));

      await for (final f in frames.stream) {
        switch (f.cmd) {
          case 0x91:
            // `[charging?, level]` per the format's own worked example
            // (`AB 00 05 FF 91 80 00 50` → level 0x50 = 80). Close enough to
            // bank as a note; never a health signal.
            if (f.args.length >= 2) yield BandNote('battery', f.args[1]);
            break;
          case 0x92:
            yield BandNote('device_info', f.args);
            break;
          case 0x20:
          case 0x87:
            // Watch-initiated connect pushes ("connection" / "connection
            // response"). Nothing replies to these; logged so they are
            // visible rather than silently dropped.
            link.log('dt78: connect event 0x${f.cmd.toRadixString(16)}');
            break;
        }
        // Every frame, decoded or not — the health bundle, steps, sleep and
        // anything else this watch ever sends lives here undecoded, so a
        // decoder written when someone owns one of these can be run over it.
        yield SampleBatch(const [], raw: <Uint8List>[f.raw]);
      }
    } finally {
      await sub.cancel();
      await frames.close();
    }
    // No OffloadCheckpoint, ever. There is no trim-on-ack or fetch-by-range
    // in this protocol — the watch is only ever polled, never told to
    // forget anything.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const Dt78Adapter kDt78Adapter = Dt78Adapter();
