// A Casio G-Shock / current-generation Casio smartwatch, speaking the 2C/2D
// "all-features" GATT scheme, as a [BandAdapter].
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Casio watch,
// so every byte below is verified by the compiler and by the fixtures in
// `test/adapters/casio_adapter_test.dart`, never by a real device. It ships
// EXPERIMENTAL (ASSUMPTIONS R6): `signals` is `const {}` and `kAdapterSignals`
// carries no entry for it beyond the empty map, exactly like `kOura` and
// `kBleHrs`.
//
// THE WIRE SHAPE IS THE SIMPLEST ONE THIS SEAM HAS SEEN. One request
// characteristic, one response characteristic, no envelope, no CRC, no
// sequence counter, and no stored history to drain — closer to a plain notify
// sensor than to anything WHOOP-shaped. The host writes a one-byte feature tag
// and the watch answers on notify with `[featureTag, ...payload]`; there is
// nothing to ACK and nothing to trim.
//
// WHAT THIS SESSION DOES AND DOES NOT DO. It writes a small, fixed set of
// harmless, read-only feature tags — version info, app info, watch name,
// module id, BLE features — and banks every reply verbatim. It never writes
// the clock, an alarm, a reminder or any other setting: those are
// control-plane writes with device-specific side effects, and a pairs-only
// adapter has no business making them. No field of any reply is decoded; a
// module-id BYTE COUNT is the one thing surfaced as a [BandNote], because it
// is pure device metadata (not a measurement) and unambiguous without a
// decoder.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// One Casio session. Const: it holds no state of its own — everything a
/// session needs lives inside [run].
class CasioAdapter extends BandAdapter {
  /// How long to wait for a reply to one request before moving on. A watch
  /// that never answers a given tag costs one skipped probe, not a stalled
  /// session — there is no retry and no escalation here.
  final Duration replyTimeout;

  const CasioAdapter({this.replyTimeout = const Duration(seconds: 3)});

  @override
  BandEntry get entry => kCasio;

  /// NOTHING, and that is the honest answer today rather than a placeholder.
  /// This adapter decodes no field of any reply — every response is banked
  /// raw and undecoded until someone has actually held one of these watches.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// The harmless, read-only feature-request tags this session proves the
  /// link with. Every one is a plain info read: none sets the clock, an
  /// alarm, a reminder or any other watch state.
  static const List<int> kProbeTags = <int>[
    0x10, // BLE features
    0x20, // version info
    0x22, // app info
    0x23, // watch name
    0x26, // module id
  ];

  /// The one probe tag whose reply length is worth naming — a byte count is
  /// pure device metadata, never a measurement.
  static const int _kModuleIdTag = 0x26;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kCasioAllFeaturesChar).listen(
          (rec) => inbox.add(Uint8List.fromList(rec.$2)),
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    final raw = <Uint8List>[];
    try {
      for (final tag in kProbeTags) {
        if (!await link.write(kCasioReadRequestChar, <int>[tag])) {
          link.log(
              'casio: request 0x${tag.toRadixString(16)} refused; skipping.');
          continue;
        }
        final resp = await inbox.next(replyTimeout);
        if (resp == null) {
          link.log(
              'casio: no reply to request 0x${tag.toRadixString(16)}.');
          continue;
        }
        raw.add(resp);
        if (tag == _kModuleIdTag && resp.length > 1) {
          yield BandNote('casio_module_id_len', resp.length - 1);
        }
      }
    } finally {
      await sub.cancel();
    }
    // No samples, ever — nothing is decoded. The frames are handed over so a
    // future decoder, written when someone owns one of these watches, has
    // something to run over.
    if (raw.isNotEmpty) yield SampleBatch(const [], raw: raw);
    // No OffloadCheckpoint: there is no stored history on this wire to trim.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const CasioAdapter kCasioAdapter = CasioAdapter();

/// Frames off the notify characteristic, buffered so a reply landing before
/// anyone is waiting is not dropped. Same minimal shape as `oura.dart`'s own
/// inbox — this wire has no auth handshake to search past, so there is no
/// `firstWhere`, only "the next frame, or nothing".
class _Inbox {
  final List<Uint8List> _buf = [];
  Completer<Uint8List?>? _waiter;
  bool _closed = false;

  void add(Uint8List v) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(v);
      return;
    }
    _buf.add(v);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

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
