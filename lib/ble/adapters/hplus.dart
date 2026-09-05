// The HPlus reference GATT profile, as a [BandAdapter]. Not one device — the
// same service, the same two characteristics and the same command byte sit
// behind a whole family of low-cost wrist bands (HPlus itself, and the OEM
// re-skins that share its firmware). One adapter covers all of them.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one, so every
// byte below is verified by the compiler and by
// `test/adapters/hplus_adapter_test.dart` fixtures, never by a real unit. It
// ships EXPERIMENTAL (ASSUMPTIONS R6): `signals` is `const {}` and
// `kAdapterSignals` carries no entry for it beyond the empty map, exactly
// like `kOura`.
//
// THE WIRE SHAPE. Plaintext, no bonding, no encryption, no key material
// anywhere in the protocol — a vendor command channel, not a ratified
// characteristic. No envelope, no CRC, no sequence counter: a notification is
// `[tag, ...payload]`, the tag says what kind of record it is, and that is the
// whole of the framing — a tag-and-payload shape, not the six-characteristic
// WHOOP profile or Oura's cursor-and-key one.
//
// THE INIT SEQUENCE IS WHAT MAKES THIS ADAPTER WORTH WRITING, AND ALSO ITS ONE
// REAL UNKNOWN. The band does not appear to push realtime stats until it has
// been configured — enabling notify alone is not documented as sufficient —
// so this session writes a short, fixed command sequence before it expects to
// hear anything back. Only the ALLDAY_HRM write is load-bearing for streaming;
// the others are documented preconditions the reference always sends
// alongside it. WHETHER THIS MINIMAL SEQUENCE IS ENOUGH, OR WHETHER A GIVEN
// UNIT ALSO WANTS THE FULLER PREFERENCE BLOCK (date/time/gender/age/weight/
// height/goal/units/language/screentime) FIRST, IS NOT KNOWN. It costs nothing
// to send and is data, not a decode risk, so it ships as the first thing to
// try — a silent, permanently-empty stream from here on is the visible failure
// mode if a unit turns out to need more, not a crash and not a wrong number.
//
// HARD INVARIANT COMPLIANCE. The realtime-stats record (tag 0x33) carries
// steps, distance, calories, battery, heart rate and active-time at fixed
// offsets — every field in it is vendor-stated, not hardware-confirmed, so
// none of it becomes a `NeutralSample`. The one exception is the battery
// byte: a wrong offset there shows a wrong PERCENTAGE, never a fabricated
// health metric, which is why it is trusted enough to surface as a
// [BandNote] the same way `oura.dart` surfaces its own battery and firmware
// facts. The firmware-version record (tag 0x18 or 0x2e) carries two raw
// version bytes, not text — decoded into a plain "major.minor" string the
// same way. Everything else — every field of every record, decoded or not —
// is archived verbatim by the host and thrown away by nobody.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// One HPlus-family session. Const: it holds no state of its own — everything
/// a session needs lives inside [run].
class HPlusAdapter extends BandAdapter {
  /// How long to wait for the next notification before ending the session.
  /// A quiet band this long is either done streaming or was never configured
  /// correctly — either way there is nothing left to do but let the host tear
  /// the link down; the outer session (`hplus_link.dart`) also bounds this on
  /// its own collection window, so this is a second, independent backstop
  /// rather than the only one.
  final Duration idleTimeout;

  const HPlusAdapter({this.idleTimeout = const Duration(seconds: 60)});

  @override
  BandEntry get entry => kHPlus;

  /// NOTHING, and that is the honest answer today rather than a placeholder.
  /// The realtime-stats layout is vendor-inferred, not ratified — see this
  /// file's own header — so nothing goes into `NeutralSample.hr` or any other
  /// field.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// The tag naming a realtime-stats record: tag(1) + steps(u16) +
  /// distance(u16) + calories(u32) + battery(u8) + a reserved byte + heart
  /// rate(u8) + active-time(u16), all little-endian. Only [_kBatteryOffset]
  /// of it is decoded here.
  static const int kTagRealtime = 0x33;

  /// Both tags carry a firmware version as two raw bytes, minor then major —
  /// not text — at different offsets each; which one a given unit answers
  /// with is not documented, so both are decoded the same way.
  static const int kTagVersionA = 0x18;
  static const int kTagVersionB = 0x2e;

  /// Offset of the battery byte inside a [kTagRealtime] payload: tag(1) +
  /// steps(u16) + distance(u16) + calories(u32) lands battery at byte 9.
  static const int _kBatteryOffset = 9;

  /// The sentinel for "not measured" on the battery byte.
  static const int _kBatteryUnmeasured = 0xff;

  /// The init sequence, in order. Every write's result is logged; the
  /// sequence continues regardless of a refusal because there is no
  /// protocol-level ACK to gate on here, and a refused write shows up
  /// downstream as a silent, empty session rather than a stuck one.
  static const List<(String label, List<int> cmd)> kInitSequence = [
    ('pref_start', <int>[0x4f, 0x5a]),
    ('pref_start1', <int>[0x4d]),
    // The only write that is actually load-bearing for streaming.
    ('allday_hrm_on', <int>[0x35, 0x0a]),
    ('conf_end', <int>[0x4f]),
  ];

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kHPlusMeasureChar).listen(
          (rec) => inbox.add(Uint8List.fromList(rec.$2)),
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      for (final (label, cmd) in kInitSequence) {
        if (!await link.write(kHPlusControlChar, cmd)) {
          link.log('hplus: $label write refused.');
        }
      }
      while (true) {
        final frame = await inbox.next(idleTimeout);
        if (frame == null) return; // link closed, or nothing for a long time
        if (frame.isEmpty) continue;
        switch (frame[0]) {
          case kTagRealtime:
            final battery = _decodeBattery(frame);
            if (battery != null) yield BandNote('battery', battery);
          case kTagVersionA:
          case kTagVersionB:
            final version = _decodeVersion(frame);
            if (version != null) yield BandNote('firmware', version);
        }
        // Every frame archived verbatim, decoded or not — owner rulings
        // R1-R3: the bytes are banked now so a decoder written when someone
        // owns a unit can be run over them.
        yield SampleBatch(const [], raw: [frame]);
      }
    } finally {
      await sub.cancel();
    }
    // No OffloadCheckpoint, ever. This wire has no stored history to drain —
    // every notification is a live reading, not a flash record — so there is
    // nothing here for the band to be told to forget.
  }

  int? _decodeBattery(Uint8List frame) {
    if (frame.length <= _kBatteryOffset) return null;
    final b = frame[_kBatteryOffset];
    if (b == _kBatteryUnmeasured || b > 100) return null;
    return b;
  }

  /// Two raw bytes, minor then major, at a tag-dependent offset — not text.
  /// Tag 0x18 is `[tag, minor, major]`; tag 0x2e is `[tag, 8 reserved bytes,
  /// minor, major]`. Rendered "major.minor", the ordinary reading of two
  /// version bytes; the reference gives their position, not their meaning.
  String? _decodeVersion(Uint8List frame) {
    final int minorAt;
    switch (frame[0]) {
      case kTagVersionA:
        minorAt = 1;
      case kTagVersionB:
        minorAt = 9;
      default:
        return null;
    }
    final majorAt = minorAt + 1;
    if (frame.length <= majorAt) return null;
    return '${frame[majorAt]}.${frame[minorAt]}';
  }
}

/// The single instance. Const, so it costs nothing to reference.
const HPlusAdapter kHPlusAdapter = HPlusAdapter();

/// Frames off the notify characteristic, buffered so a reply landing before
/// anyone is waiting is not dropped. This wire has no request/reply matching
/// to do, only "the next frame, or nothing".
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
