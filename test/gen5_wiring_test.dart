// Wiring the band generation actually reaches the wire, plus the two
// historical-ingest routing bugs that quietly threw a user's records away.
//
// What each group here is standing in for:
//   - the plausibility-drop path used to write the record NOWHERE, so a record
//     we merely mistrusted fared worse than one we could not parse at all —
//     and the batch-ACK then let the band trim those bytes for good;
//   - only v24/v12/v10 were routed to the R24 decoder, so every other version
//     the decoder can read (v7/v9/v18/v25) was archived as undecodable — a real
//     export carried ~50k readable v25 records filed that way;
//   - the alarm bodies are generation-specific, and the gen4 forms are
//     hardware-verified, so the gen5 additions must not disturb them.

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

int _wallNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A gen4 historical record inner: `[0x2f][version][…][counter@3][ts@7]`.
/// Zero-filled elsewhere, which the v24 field map reads as a (0,0,0) accel —
/// finite, and v24/v12 are the trusted path so no plausibility gate applies.
Uint8List _gen4Inner({
  required int version,
  required int ts,
  required int counter,
  int length = 89,
  // Only v24/v12 are decoded verbatim; every other version is gated on
  // physiological plausibility, so those need a real HR byte and a ~1 g accel
  // vector (float32 LE at 36/40/44).
  int? hrOffset,
  int hr = 0,
}) {
  final inner = Uint8List(length);
  inner[0] = PacketType.historicalData;
  inner[1] = version;
  final view = ByteData.sublistView(inner);
  view.setUint32(3, counter, Endian.little);
  view.setUint32(7, ts, Endian.little);
  if (hrOffset != null) {
    inner[hrOffset] = hr;
    view.setFloat32(36, 0.0, Endian.little);
    view.setFloat32(40, 0.0, Endian.little);
    view.setFloat32(44, 1.0, Endian.little);
  }
  return inner;
}

/// v25 has its own layout: time + gravity only, gated on a gravity magnitude of
/// roughly 1 g at inner[69/71/73] (i16 / 16384).
Uint8List _v25Inner({required int ts, required int counter}) {
  final inner = _gen4Inner(version: 25, ts: ts, counter: counter, length: 80);
  final view = ByteData.sublistView(inner);
  view.setInt16(69, 0, Endian.little); // gx = 0.0
  view.setInt16(71, 0, Endian.little); // gy = 0.0
  view.setInt16(73, 16384, Endian.little); // gz = 1.0 → |g| = 1.0
  return inner;
}

class _Ingest {
  final samples = <Sample?>[];
  final archives = <ArchiveRecord>[];
  late final BleEngine engine;

  _Ingest({BandProfile band = BandProfile.gen4}) {
    engine = BleEngine(
      onRecord: (sample, raw) async => samples.add(sample),
      onState: (_) {},
    );
    engine.debugInstallFakeLink(
      onWrite: (_) async => true,
      band: band,
      onArchive: (a) async => archives.add(a),
    );
  }

  void feed(Uint8List inner) =>
      engine.debugIngestHistoricalFrame(Frame(inner, true, true));
}

/// Captures every outgoing frame and decodes it back to `[opcode, ...body]`.
class _Wire {
  final frames = <Uint8List>[];
  final BandProfile band;
  late final BleEngine engine;

  _Wire({required this.band}) {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(
      onWrite: (f) async {
        frames.add(f);
        return true;
      },
      band: band,
    );
  }

  /// The inner of the last frame written, minus the packet-type and seq bytes:
  /// `[opcode, ...body]`. Asserts the frame really was built for [band] — a
  /// gen4-framed frame does not parse against the gen5 envelope at all, which
  /// is precisely how high-frequency sync failed silently.
  List<int> get lastCommand {
    final parsed = parseFrame(frames.last, profile: band);
    expect(parsed, isNotNull, reason: 'frame must parse under $band');
    expect(parsed!.valid, isTrue, reason: 'header + payload CRCs must pass');
    return parsed.inner.sublist(2);
  }

  /// [lastCommand] truncated to [length]: `buildFrame` pads the inner out to a
  /// 4-byte boundary, so trailing zeros are envelope, not body.
  List<int> lastCommandOf(int length) => lastCommand.sublist(0, length);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('P0 — a plausibility-dropped record is archived, never discarded', () {
    test('an implausibly-old record lands in the archive as gate_dropped', () {
      final h = _Ingest();
      // 2001: decodable, but far below the plausible-epoch floor, so the
      // RecordGate refuses it.
      h.feed(_gen4Inner(version: 24, ts: 1000000000, counter: 7));

      expect(h.samples, isEmpty, reason: 'the gate still refuses to bank it');
      expect(h.archives, hasLength(1),
          reason: 'OLD BEHAVIOUR: a bare return — the bytes went nowhere at '
              'all, and the batch-ACK then let the band trim them');
      expect(h.archives.single.reason, 'gate_dropped');
      expect(h.archives.single.counter, 7);
    });

    test('an admitted record is banked and NOT archived', () {
      final h = _Ingest();
      h.feed(_gen4Inner(version: 24, ts: _wallNow() - 3600, counter: 8));

      expect(h.samples, hasLength(1));
      expect(h.archives, isEmpty);
    });

    test('the no-progress trim gate still fires once drops archive', () {
      // The knock-on: `hadDurableRows` counts banked RECORDS, not archives.
      // Were it to count archives, a drop-only burst would always look
      // "durable" and the band would be told it may trim flash we never
      // decoded.
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
          hadDurableRows: false,
          droppedThisBurst: 3,
        ),
        TrimAckVerdict.blockedNoDurableProgress,
      );
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
          hadDurableRows: true,
          droppedThisBurst: 3,
        ),
        TrimAckVerdict.send,
        reason: 'a mixed burst that banked something may still ACK',
      );
    });

    test('a gate-dropped record is neither durable progress nor offload progress',
        () {
      // The two tests above pass `hadDurableRows` in as a literal, so the thing
      // that actually COMPUTES it has never been covered — and it has been
      // patched twice. Both halves belong to the same rule: a record we dropped
      // for implausibility is archived (so it is not lost) but must not look
      // like progress, or the band gets told it may trim flash we never read
      // and the wandered-RTC remedy never surfaces.
      DrainController drain() => DrainController(
            onRecord: (_, _) async {},
            onRecordsBatch: null,
            onCommit: (_, _, _, {archives, deviceFamily}) async {},
            onArchive: (_) async {},
            log: (_) {},
          );
      ArchiveRecord archive(String reason) => ArchiveRecord(
            counter: 1,
            hex: '2f18${reason.hashCode.toRadixString(16)}',
            packetType: 0x2F,
            capturedAt: 0,
            reason: reason,
          );

      final dropped = drain()..onUndecodableRecord(archive('gate_dropped'));
      expect(dropped.bufferedProgressArchives, 0);
      expect(dropped.recordsThisOffload, 0,
          reason: 'a drop-only burst must leave `banked` false at COMPLETE');

      final undecodable = drain()..onUndecodableRecord(archive('undecodable_v22'));
      expect(undecodable.bufferedProgressArchives, 1,
          reason: 'a version we cannot read IS progress once it is set aside');
      expect(undecodable.recordsThisOffload, 1);
    });
  });

  group('P0 — every gen4 version the decoder can read is decoded', () {
    test('v25 is still archived — it has no heart rate to bank', () {
      // The other versions here decode into 1 Hz rows; v25 deliberately does
      // not. It carries a timestamp and a gravity vector and nothing else, and
      // the decoder reports hr 0 because the record has no HR field. hr is NOT
      // NULL in decoded_onehz and 0 is the off-skin sentinel, so banking v25
      // would claim the band was off the wrist for every one of those seconds
      // — while the real gravity makes the accel-coverage gate accept the
      // window. Archiving keeps the bytes for a re-decode once hr is nullable.
      final ts = _wallNow() - 7200;
      final h = _Ingest();
      h.feed(_v25Inner(ts: ts, counter: 4242));

      expect(h.samples, isEmpty, reason: 'no fabricated hr 0 row');
      expect(h.archives, hasLength(1), reason: 'bytes kept, nothing lost');
      expect(h.archives.single.reason, 'undecodable_rec_v25');
      expect(h.archives.single.counter, 4242);
    });

    test('v9 and v7 decode too', () {
      final ts = _wallNow() - 600;
      // HR offset moves per version; the rest of the field map is shared.
      for (final entry in {7: 27, 9: 17}.entries) {
        final h = _Ingest();
        h.feed(_gen4Inner(
          version: entry.key,
          ts: ts,
          counter: 11,
          hrOffset: entry.value,
          hr: 61,
        ));
        expect(h.samples, hasLength(1), reason: 'v${entry.key} must decode');
        expect(h.samples.single!.hr, 61);
        expect(h.archives, isEmpty,
            reason: 'v${entry.key} must not be archived');
      }
    });

    test('a genuinely unknown version is still archived', () {
      final h = _Ingest();
      h.feed(_gen4Inner(version: 99, ts: _wallNow() - 60, counter: 12));

      expect(h.samples, isEmpty);
      expect(h.archives.single.reason, 'undecodable_rec_v99');
    });

    test('a gen5 v18 is not routed through the gen4 field map', () {
      // Same version byte, completely different layout. The gen5 branch claims
      // it first; these zeroed bytes are not a valid gen5 v18, so it archives
      // rather than yielding a fabricated gen4-shaped sample.
      final h = _Ingest(band: BandProfile.gen5);
      h.feed(_gen4Inner(version: 18, ts: _wallNow() - 60, counter: 13));

      expect(h.samples, isEmpty);
      expect(h.archives.single.reason, 'undecodable_rec_v18');
    });
  });

  group('P1 — alarm bodies are generation-correct', () {
    test('gen4 forms are byte-identical (hardware-verified — do not change)',
        () {
      expect(AlarmPayloads.disableForBand(isGen5: false), <int>[0x01]);
      expect(AlarmPayloads.getPayloadForBand(isGen5: false), <int>[0x01]);
      expect(AlarmPayloads.disable, <int>[0x01]);
      // gen4 arms with the rev-1 9-byte body (the official app's wire form);
      // the exact layout is pinned against the wire capture in alarm_test.
      final when = DateTime.now();
      expect(AlarmPayloads.setPayloadForBand(when, isGen5: false),
          AlarmPayloads.rev1(when));
    });

    test('gen5 disable is revision 2 + an alarm id', () {
      expect(AlarmPayloads.disableForBand(isGen5: true), <int>[0x02, 0xFF]);
      expect(AlarmPayloads.disableForBand(isGen5: true, id: 1), <int>[0x02, 1]);
    });

    test('gen5 get-alarm is revision 4 + the alarm id', () {
      expect(AlarmPayloads.getPayloadForBand(isGen5: true), <int>[0x04, 1]);
      expect(AlarmPayloads.getPayloadForBand(isGen5: true, id: 0),
          <int>[0x04, 0]);
      // The default id is the slot the gen5 SET arms.
      expect(AlarmPayloads.setPayloadForBand(DateTime.now(), isGen5: true)[1],
          AlarmPayloads.gen5Slot);
    });

    test('the engine writes the gen4 alarm bodies unchanged', () async {
      final w = _Wire(band: BandProfile.gen4);
      await w.engine.disableAlarm();
      expect(w.lastCommandOf(2), <int>[Cmd.disableAlarm, 0x01]);
      await w.engine.getAlarm();
      expect(w.lastCommandOf(2), <int>[Cmd.getAlarmTime, 0x01]);
    });

    test('the engine writes the gen5 alarm bodies', () async {
      final w = _Wire(band: BandProfile.gen5);
      await w.engine.disableAlarm();
      expect(w.lastCommandOf(3), <int>[Cmd.disableAlarm, 0x02, 0xFF]);
      await w.engine.getAlarm();
      expect(w.lastCommandOf(3), <int>[Cmd.getAlarmTime, 0x04, 1]);
    });
  });

  group('P1 — band-specific opcodes and framing', () {
    test('strap rename uses the opcodes each generation implements', () async {
      final g4 = _Wire(band: BandProfile.gen4);
      await g4.engine.setStrapName('band');
      expect(g4.lastCommand.first, Cmd.setAdvertisingNameHarvard);
      await g4.engine.getStrapName();
      expect(g4.lastCommand.first, Cmd.getAdvertisingNameHarvard);

      final g5 = _Wire(band: BandProfile.gen5);
      await g5.engine.setStrapName('band');
      expect(g5.lastCommand.first, Cmd.setCustomAdvertisingName,
          reason: 'gen5 does not implement the gen4 advertising-name opcodes');
      await g5.engine.getStrapName();
      expect(g5.lastCommand.first, Cmd.getCustomAdvertisingName);
    });

    test('high-frequency sync is framed for the session band', () async {
      final w = _Wire(band: BandProfile.gen5);
      await w.engine.applyHighFreqWakeWindow(
        enabled: true,
        targetWake: DateTime.now().add(const Duration(hours: 1)),
      );
      // The assertion that matters is inside lastCommand: a gen4-framed frame
      // does not parse under the gen5 envelope, so the strap could never act
      // on it — while the engine claimed the mode had engaged.
      expect(w.lastCommand.first, Cmd.enterHighFreqSync);
    });

    test('the mode is not claimed when the write fails', () async {
      final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      engine.debugInstallFakeLink(onWrite: (_) async => false);
      await engine.applyHighFreqWakeWindow(
        enabled: true,
        targetWake: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(engine.offloadSnapshot['high_freq_requested'], isFalse);
    });

    test('INIT no longer re-sends the hello — it belongs to connect setup',
        () async {
      // The pinned order is hello FIRST, during setup, so its timestamp can
      // drive the clock decision and its identity fields are available to
      // everything after. Sending it again at INIT would be a second identity
      // exchange after every consumer has already run.
      final w = _Wire(band: BandProfile.gen5);
      await w.engine.sendInit();
      final opcodes = w.frames
          .map((f) => parseFrame(f, profile: BandProfile.gen5))
          .where((p) => p != null && p.valid)
          .map((p) => p!.inner[2])
          .toList();
      expect(opcodes, isNot(contains(Cmd.getHello)));
      expect(opcodes, contains(Cmd.sendHistoricalData));
    });

    test('the wake window uses the pinned 180 s / 7200 s Smart Alarm values',
        () async {
      // ENTER_HIGH_FREQ_SYNC(96) body `02 b4 00 20 1c` — rev 2, then
      // interval 180 s and duration 7200 s as u16 LE. The old 61 s/90 min
      // defaults were picked only to clear gen5's "> 60" floor.
      final w = _Wire(band: BandProfile.gen5);
      await w.engine.applyHighFreqWakeWindow(
        enabled: true,
        targetWake: DateTime.now().add(const Duration(hours: 2)),
      );
      expect(w.lastCommandOf(6), <int>[
        Cmd.enterHighFreqSync,
        0x02, // revision
        0xb4, 0x00, // interval 180 s, u16 LE
        0x20, 0x1c, // duration 7200 s, u16 LE
      ]);
    });

    test('gen5 reads the clock with the established GET_CLOCK(11), empty body',
        () async {
      // Opcode 147 ("GET_CLOCK_GEN5") is not an established WHOOP opcode.
      // The confirmed gen5 contract is the shared opcode 11 with an EMPTY
      // body — hardware-confirmed on a real WHOOP 5.
      final w = _Wire(band: BandProfile.gen5);
      await w.engine.getClock();
      expect(w.lastCommandOf(1), <int>[Cmd.getClock]);
      expect(Cmd.getClock, 11);
    });

    test('gen5 sets the clock with the established SET_CLOCK(10), 8-byte body',
        () async {
      // <u32 whole seconds><u32 subseconds>, no revision byte — the form that
      // returned SUCCESS from a real WHOOP 5. A wrong clock write is silent:
      // the RTC never latches and every alarm is then armed against it.
      final w = _Wire(band: BandProfile.gen5);
      await w.engine.setClock();
      // setClock() reads the RTC back afterwards, so SET is not the last frame.
      final set = w.frames
          .map((f) => parseFrame(f, profile: BandProfile.gen5))
          .where((p) => p != null && p.valid)
          .map((p) => p!.inner.sublist(2))
          .firstWhere((c) => c.first == Cmd.setClock);
      expect(Cmd.setClock, 10);
      // opcode + 8 body bytes (the frame is 4-byte padded beyond that).
      expect(set.sublist(0, 9).length, 9);
      // Subseconds are a u16 in the low half of the second u32; top 2 bytes 0.
      expect(set.sublist(7, 9), <int>[0, 0]);
    });
  });

  group('P0 — an unset strap RTC is visible to the clock policy', () {
    test('an implausibly-low clock_epoch reaches shouldSetClock', () {
      final logs = <String>[];
      final engine = BleEngine(
        onRecord: (_, _) async {},
        onState: (_) {},
        log: logs.add,
      );
      // A strap whose RTC was never set. This is the exact reading
      // ClockPolicy.shouldSetClock was written for, and it used to be dropped
      // by the decoder before the policy ever saw it.
      engine.debugAbsorbDecoded(Decoded('cmd_response', {'clock_epoch': 100}));

      expect(ClockPolicy.shouldSetClock(100, _wallNow()), isTrue);
      expect(engine.clockRef, isNull,
          reason: 'a factory-epoch clock must not become the alarm '
              'correlation — the drift would be decades');
      expect(logs.where((l) => l.contains('never set')), isNotEmpty);
    });
  });


  group('the dangerous-opcode block sits on _write, not only on _send', () {
    // Nine call sites build their own frame and hand it to the lowest-level
    // write, bypassing `_send` entirely. All were benign, but the guard against
    // FORCE_TRIM (whose full-erase form is two 0xFEFEFEFE args), REBOOT and
    // POWER_CYCLE was bypassable by construction rather than by an audited
    // opt-out, on BOTH generations (the header length differs, the opcode's
    // position within the inner frame does not).
    for (final (label, band) in [
      ('gen4', BandProfile.gen4),
      ('gen5', BandProfile.gen5),
    ]) {
      test('a framed destructive opcode never reaches the radio ($label)',
          () {
        final sent = <Uint8List>[];
        final engine = BleEngine(
          onRecord: (_, _) async {},
          onState: (_) {},
          log: (_) {},
        );
        engine.debugInstallFakeLink(
          onWrite: (f) async {
            sent.add(f);
            return true;
          },
          band: band,
        );

        for (final opcode in dangerousCmds) {
          final frame = buildCommand(1, opcode, const [], band);
          expect(engine.debugWriteRaw(frame), completion(isFalse),
              reason: 'opcode 0x${opcode.toRadixString(16)} must be refused');
        }
      });
    }

    test('an ordinary command still goes out', () async {
      final sent = <Uint8List>[];
      final engine = BleEngine(
        onRecord: (_, _) async {},
        onState: (_) {},
        log: (_) {},
      );
      engine.debugInstallFakeLink(
        onWrite: (f) async {
          sent.add(f);
          return true;
        },
      );
      final ok = await engine.debugWriteRaw(
        buildCommand(1, Cmd.getBatteryLevel, const [], BandProfile.gen4),
      );
      expect(ok, isTrue);
      expect(sent, hasLength(1));
    });
  });

  _events();
  _bootstrap();
  _burstOrdering();
}

/// A type-48 EVENT inner:
/// `[0x30][u8 seq][u16 id][u32 unix][u16 subsec][u16 body len][body…]`
///. Built directly rather than through
/// `buildFrame` because the engine's receive path consumes inners.
Uint8List _eventInner(int id, List<int> body, {int ts = 1786000000}) {
  final inner = Uint8List(12 + body.length);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  final view = ByteData.sublistView(inner);
  view.setUint16(2, id, Endian.little);
  view.setUint32(4, ts, Endian.little);
  view.setUint16(8, 0, Endian.little);
  view.setUint16(10, body.length, Endian.little);
  inner.setRange(12, inner.length, body);
  return inner;
}

void _events() {
  group('P1 — the band volunteers condition and haptics events (T6)', () {
    ({BleEngine engine, List<String> logs}) rig() {
      final logs = <String>[];
      final engine = BleEngine(
        onRecord: (_, _) async {},
        onState: (_) {},
        log: logs.add,
      );
      // These event bodies are gen5-scoped in the protocol decoder; a gen4
      // link keeps them numeric and un-decoded.
      engine.debugInstallFakeLink(
        onWrite: (_) async => true,
        band: BandProfile.gen5,
      );
      return (engine: engine, logs: logs);
    }

    test('STRAP_CONDITION_REPORT(29) is logged, and only logged', () {
      final r = rig();
      // pages behind 4321, backlog 45.6, SoC 87.2%, flash 3, charging, wrist 2.
      r.engine.debugProcessImmediateFrame(Frame(
        _eventInner(EventId.strapConditionReport, <int>[
          0xE1, 0x10, 0x00, 0x00, // u32 page backlog = 4321
          0xC8, 0x01, // u16 backlog tenths = 456
          0x68, 0x03, // u16 state-of-charge tenths = 872
          0x03, // flash
          0x01, // charging
          0x02, // wrist tri-state
        ], ts: 1786000123),
        true,
        true,
      ));

      final line = r.logs
          .where((l) => l.contains('[SYNC] strap condition report'))
          .single;
      expect(line, contains('pages_behind=4321'));
      expect(line, contains('soc=87.2'));
      expect(line, contains('charging=true'));
    });

    test('a condition report is observability only — it starts no offload', () {
      final r = rig();
      r.engine.debugProcessImmediateFrame(Frame(
        _eventInner(EventId.strapConditionReport,
            <int>[0xFF, 0xFF, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0]),
        true,
        true,
      ));
      // A five-figure backlog is exactly the reading that would tempt a sync
      // trigger. The backfill policy stays the only thing that starts one.
      expect(r.engine.offloadActive, isFalse);
      expect(r.engine.offloadSnapshot['history_requests'], 0);
    });

    test('HAPTICS_TERMINATED(100) code 2 records the wearer double-tap', () {
      final r = rig();
      r.engine.debugProcessImmediateFrame(Frame(
        _eventInner(EventId.hapticsTerminated,
            <int>[1, HapticsTermination.userDoubleTap],
            ts: 1786000456),
        true,
        true,
      ));

      final snap = r.engine.offloadSnapshot;
      expect(snap['last_haptics_termination'], 'user_double_tap');
      expect(snap['last_haptics_termination_ts'], 1786000456);
      expect(
          r.logs.where(
              (l) => l.contains('[ALARM]') && l.contains('user_double_tap')),
          isNotEmpty);
    });

    test('an expiry and a dismissal are not the same recorded cause', () {
      final r = rig();
      r.engine.debugProcessImmediateFrame(Frame(
        _eventInner(
            EventId.hapticsTerminated, <int>[1, HapticsTermination.expired]),
        true,
        true,
      ));
      expect(r.engine.offloadSnapshot['last_haptics_termination'], 'expired');
    });
  });
}

// ── T11: the doc-01 bootstrap sequence ──────────────────────────────────────
//
// specifies the exact order — and the exact silences —
// between the bond and READY. Four of its steps were missing here:
//   - the two observed client delays (600 ms before notification registration,
//     500 ms after the last CCC write);
//   - the ≥2 s clock gate: this app wrote SET_CLOCK on EVERY connect, where the
//     pinned bootstrap makes no BLE write at all below two whole seconds of
//     drift;
//   - GET_ADVERTISING_NAME(141) as the final pre-READY command (sent, never a
//     readiness gate);
//   - the charging follow-up, GET_BATTERY_PACK_INFO(151) ×5, 5 s apart, which
//     must never touch READY and must never run off the charger.
// All four are gen5-only: the pinned bootstrap is WHOOP 5's, and gen4's
// flow is hardware-proven, so these tests also pin gen4's *absence* of them.

/// A gen4/gen5 link with no radio behind it that records every command written
/// and can answer selected opcodes from inside the write itself.
class _BootstrapLink {
  final logs = <String>[];
  final commands = <({int seq, int opcode, List<int> body})>[];
  final afterSupersede = <int>[];
  final BandProfile band;

  /// Answers to inject as the reply to a written command. Injected from INSIDE
  /// the write, i.e. before `_sendAwaited` has even returned — the ordering
  /// the correlation contract demands.
  Decoded? Function(int seq, int opcode)? replyTo;

  late final BleEngine engine;

  _BootstrapLink({this.band = BandProfile.gen5}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    engine.debugInstallFakeLink(
      band: band,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        commands.add((seq: inner[1], opcode: inner[2], body: inner.sublist(3)));
        final reply = replyTo?.call(inner[1], inner[2]);
        if (reply != null) engine.debugAbsorbDecoded(reply);
        return true;
      },
    );
  }

  List<int> get opcodes => commands.map((c) => c.opcode).toList();
  int count(int opcode) => opcodes.where((o) => o == opcode).length;
  bool logged(String needle) => logs.any((l) => l.contains(needle));

  /// Replace the live session. A task that captured the old session now sees
  /// `_session != session` — exactly what a dropped-and-reconnected link looks
  /// like from inside a background loop.
  void supersedeSession() {
    engine.debugInstallFakeLink(
      band: band,
      onWrite: (frame) async {
        afterSupersede.add(parseFrame(frame, profile: band)!.inner[2]);
        return true;
      },
    );
  }
}

/// A revision-1 gen5 hello body, parsed by
/// the real protocol decoder so the timestamp and charge bit under test are the
/// ones a band would actually produce.
Uint8List _gen5HelloBody({required int tsSeconds, bool charging = false}) {
  final body = Uint8List(Gen5HelloInfo.semanticBodyLen);
  final v = ByteData.sublistView(body);
  body[0] = 1; // hello revision
  v.setUint32(1, 730, Endian.little); // 73.0% → 73
  body[5] = charging ? 1 : 0; // charge-status bitfield, bit 0 = charging
  v.setUint32(6, tsSeconds, Endian.little);
  const serial = 'W5AB12CD34';
  for (var i = 0; i < serial.length; i++) {
    body[14 + i] = serial.codeUnitAt(i);
  }
  v.setUint32(87, 82, Endian.little); // optical discriminator ⇒ WHOOP 5
  body[91] = 50;
  body[92] = 40;
  body[93] = 1; // firmware 50.40.1
  body[102] = 1; // on wrist
  return body;
}

Decoded _helloReply(int seq, {required int tsSeconds, bool charging = false}) =>
    Decoded('cmd_response', {
      'opcode': Cmd.getHello,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
      'gen5_hello': Gen5HelloInfo.parse(
        _gen5HelloBody(tsSeconds: tsSeconds, charging: charging),
      )!,
    });

Decoded _packReply(int seq, {required String address, String name = ''}) =>
    Decoded('cmd_response', {
      'opcode': Cmd.getBatteryPackInfo,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
      'battery_pack_info': BatteryPackInfoResponse(
        revision: 1,
        attached: true,
        identifier: address,
        name: name,
        batteryPackTypeRaw: 12, // puffin
        statusRaw: 0,
      ),
    });

/// Run the real post-registration bootstrap to completion under [async].
/// Returns whether it reported success.
bool _runBootstrap(_BootstrapLink link, FakeAsync async) {
  bool? ok;
  link.engine.debugBootstrapAfterRegistration().then((v) => ok = v);
  // Long enough for the 500 ms delay plus every awaited step's own timeout
  // (the 3 s clock read on gen4, the 5 s command timeout on gen5), but short
  // of the charging follow-up's first 5 s retry gap.
  async.elapse(const Duration(seconds: 4));
  return ok ?? false;
}

void _bootstrap() {
  group('T11 — the two delays', () {
    test('gen5 writes nothing for 500 ms after the last CCC write', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: _wallNow())
            : null;
        link.engine.debugBootstrapAfterRegistration();

        async.elapse(const Duration(milliseconds: 499));
        expect(link.commands, isEmpty,
            reason: '500 ms after registration, before the '
                'higher-level state machine runs');
        async.elapse(const Duration(milliseconds: 2));
        expect(link.opcodes.first, Cmd.getHello,
            reason: 'and GET_HELLO is the first thing out after it');
      });
    });

    test('the delays are the observed 600/500 ms and gen5-only', () {
      expect(BleEngine.kGen5PreRegistrationDelay,
          const Duration(milliseconds: 600));
      expect(BleEngine.kGen5PostRegistrationDelay,
          const Duration(milliseconds: 500));
      fakeAsync((async) {
        final link = _BootstrapLink(band: BandProfile.gen4);
        link.engine.debugBootstrapAfterRegistration();
        async.flushMicrotasks();
        expect(link.opcodes, [Cmd.getClock],
            reason: 'gen4 keeps its proven flow: no delay, straight to the '
                'clock read');
      });
    });

    test('a link that dies during the delay abandons setup', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        bool? ok;
        link.engine.debugBootstrapAfterRegistration().then((v) => ok = v);
        // The link is replaced (reconnected) while the bootstrap sleeps.
        link.supersedeSession();
        async.elapse(const Duration(seconds: 1));

        expect(ok, isFalse);
        expect(link.commands, isEmpty,
            reason: 'nothing may go out on a session that is gone');
        expect(link.logged('link dropped during the post-registration delay'),
            isTrue);
      });
    });
  });

  group('T11 — the ≥2 s SET_CLOCK gate', () {
    test('BootstrapClockGate: below two whole seconds, no correction', () {
      expect(BootstrapClockGate.toleranceSeconds, 2);
      expect(BootstrapClockGate.needsCorrection(0), isFalse);
      expect(BootstrapClockGate.needsCorrection(1), isFalse);
      expect(BootstrapClockGate.needsCorrection(-1), isFalse);
      expect(BootstrapClockGate.needsCorrection(2), isTrue,
          reason: 'the threshold is inclusive: "at 2 or more, send one"');
      expect(BootstrapClockGate.needsCorrection(-2), isTrue,
          reason: 'the doc compares the ABSOLUTE delta');
      expect(BootstrapClockGate.needsCorrection(null), isTrue,
          reason: 'no correlation at all — an unset band RTC must never be '
              'left uncorrected');
    });

    test('a band whose clock agrees is not written to at all', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: _wallNow())
            : null;
        expect(_runBootstrap(link, async), isTrue);

        expect(link.count(Cmd.setClock), 0,
            reason: 'below 2 s, succeed with NO BLE write');
        expect(link.count(Cmd.getClock), 0,
            reason: 'and no read-back either — nothing was written');
        expect(link.logged('no correction needed'), isTrue);
      });
    });

    test('a band 3 s out gets exactly one SET_CLOCK', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: _wallNow() - 3)
            : null;
        expect(_runBootstrap(link, async), isTrue);

        expect(link.count(Cmd.setClock), 1,
            reason: 'at 2 or more, send ONE SET_CLOCK');
        expect(link.opcodes.indexOf(Cmd.setClock),
            greaterThan(link.opcodes.indexOf(Cmd.getHello)),
            reason: 'the clock decision comes after hello supplies the time');
      });
    });

    test('an UNSET RTC gets exactly one SET_CLOCK, not two', () {
      fakeAsync((async) {
        // Factory-epoch hello timestamp: below the plausible floor, so it is
        // never correlated (drift == null) and needsCorrection(null) is true.
        // Before the bootstrap-window fix, BOTH writers fired — the absorb
        // handler's own re-correction on the hello reply AND the bootstrap
        // clock step — sending a fresh band two SET_CLOCKs back to back,
        // against the one-SET_CLOCK-per-bootstrap rule.
        final link = _BootstrapLink();
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: 1000)
            : null;
        expect(_runBootstrap(link, async), isTrue);

        expect(link.count(Cmd.setClock), 1,
            reason: 'ONE SET_CLOCK per bootstrap — the absorb '
                'handler must stand down inside the bootstrap window');
      });
    });

    test('the phone-clock deferral still beats the drift gate', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        // A plausible strap RTC two days AHEAD of us: the phone is the suspect
        // party, and the read is too far out to be correlated — so the drift is
        // null and the gate alone would write. The deferral must win.
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: _wallNow() + 2 * 86400)
            : null;
        expect(_runBootstrap(link, async), isTrue);

        expect(BootstrapClockGate.needsCorrection(null), isTrue,
            reason: 'the gate would have written…');
        expect(link.count(Cmd.setClock), 0, reason: '…and must not have');
        expect(link.engine.historyPausedForClock, isTrue);
      });
    });

    test('gen4 keeps its unconditional SET_CLOCK', () {
      fakeAsync((async) {
        final link = _BootstrapLink(band: BandProfile.gen4);
        expect(_runBootstrap(link, async), isTrue);

        expect(link.opcodes, [Cmd.getClock, Cmd.setClock, Cmd.getClock],
            reason: 'read → unconditional write → read-back, unchanged');
      });
    });
  });

  group('T11 — GET_ADVERTISING_NAME is the final pre-READY step', () {
    test('gen5 sends it last, after the clock step', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: _wallNow() - 3)
            : null;
        expect(_runBootstrap(link, async), isTrue);

        expect(link.opcodes.last, Cmd.getCustomAdvertisingName);
        expect(link.commands.last.body.first, revision1,
            reason: 'body 01');
      });
    });

    test('an unanswered name read does not fail setup', () {
      fakeAsync((async) {
        final link = _BootstrapLink();
        link.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, tsSeconds: _wallNow())
            : null;
        // Nothing ever answers opcode 141 here.
        expect(_runBootstrap(link, async), isTrue,
            reason: 'the response content and result are NOT a '
                'readiness gate');
        async.elapse(const Duration(seconds: 6));
        expect(link.logged('GET_ADVERTISING_NAME went unanswered'), isTrue);
        expect(link.engine.pendingCommandCount, 0,
            reason: 'the unawaited response is still consumed');
      });
    });

    test('gen4 sends no advertising-name read during setup', () {
      fakeAsync((async) {
        final link = _BootstrapLink(band: BandProfile.gen4);
        expect(_runBootstrap(link, async), isTrue);
        expect(link.opcodes, isNot(contains(Cmd.getCustomAdvertisingName)));
        expect(link.opcodes, isNot(contains(Cmd.getAdvertisingNameHarvard)));
      });
    });
  });

  group('T11 — the charging follow-up, opcode 151', () {
    /// Bootstrap a gen5 link whose hello reports [charging], answering
    /// GET_BATTERY_PACK_INFO with [packAddress] when one is given.
    _BootstrapLink chargingRig(
      FakeAsync async, {
      required bool charging,
      String? packAddress,
      String packName = '',
    }) {
      final link = _BootstrapLink();
      link.replyTo = (seq, op) {
        if (op == Cmd.getHello) {
          return _helloReply(seq, tsSeconds: _wallNow(), charging: charging);
        }
        if (op == Cmd.getBatteryPackInfo && packAddress != null) {
          return _packReply(seq, address: packAddress, name: packName);
        }
        return null;
      };
      expect(_runBootstrap(link, async), isTrue,
          reason: 'the follow-up never blocks READY');
      return link;
    }

    test('BatteryPackInfoGate: only a real address/name is usable', () {
      expect(
          BatteryPackInfoGate.usable(
              identifier: '00:00:00:00:00:00', name: 'Puffin'),
          isFalse,
          reason: 'the all-zero address identifies nothing');
      expect(BatteryPackInfoGate.usable(identifier: '', name: ''), isFalse);
      expect(BatteryPackInfoGate.usable(identifier: '   ', name: '  '), isFalse);
      expect(
          BatteryPackInfoGate.usable(
              identifier: 'aa:bb:cc:dd:ee:ff', name: ''),
          isTrue);
      expect(BatteryPackInfoGate.usable(identifier: '', name: 'Puffin'), isTrue);
      expect(
          BatteryPackInfoGate.usable(
              identifier: '', name: '00:00:00:00:00:00'),
          isFalse,
          reason: 'the sentinel leaking through the NAME field is still '
              '"no pack yet"');
    });

    test('it never runs when the band is not charging', () {
      fakeAsync((async) {
        final link = chargingRig(async, charging: false);
        async.elapse(const Duration(seconds: 40));
        expect(link.count(Cmd.getBatteryPackInfo), 0,
            reason: 'this lookup does not run on a non-charging '
                'READY transition');
      });
    });

    test('a charging band is asked five times, five seconds apart', () {
      fakeAsync((async) {
        final link =
            chargingRig(async, charging: true, packAddress: '00:00:00:00:00:00');
        expect(link.count(Cmd.getBatteryPackInfo), 1);
        expect(link.commands.last.body.first, revision1,
            reason: 'body 01');

        for (var expected = 2; expected <= 5; expected++) {
          async.elapse(const Duration(seconds: 5));
          expect(link.count(Cmd.getBatteryPackInfo), expected);
        }
        // the fifth unusable attempt is followed by the delay too.
        async.elapse(const Duration(seconds: 5));
        expect(link.count(Cmd.getBatteryPackInfo), BleEngine.kBatteryPackInfoAttempts,
            reason: 'five attempts, and no sixth');
        expect(link.logged('no usable GET_BATTERY_PACK_INFO reply'), isTrue);
        expect(link.engine.offloadSnapshot['battery_pack_address'], isNull,
            reason: 'an all-zero address is never stored as a reading');
      });
    });

    test('a usable reply stops the retries and reaches the snapshot', () {
      fakeAsync((async) {
        final link = chargingRig(
          async,
          charging: true,
          packAddress: 'aa:bb:cc:dd:ee:ff',
          packName: 'Puffin',
        );
        async.elapse(const Duration(seconds: 40));

        expect(link.count(Cmd.getBatteryPackInfo), 1,
            reason: 'the first usable answer ends the task');
        final snap = link.engine.offloadSnapshot;
        expect(snap['battery_pack_address'], 'aa:bb:cc:dd:ee:ff');
        expect(snap['battery_pack_name'], 'Puffin');
        expect(snap['battery_pack_attached'], isTrue);
        expect(snap['battery_pack_type'], 'puffin');
        expect(snap['battery_pack_ts'], isNotNull);
      });
    });

    test('it dies with the session', () {
      fakeAsync((async) {
        final link =
            chargingRig(async, charging: true, packAddress: '00:00:00:00:00:00');
        expect(link.count(Cmd.getBatteryPackInfo), 1);

        link.supersedeSession();
        async.elapse(const Duration(seconds: 40));

        expect(link.count(Cmd.getBatteryPackInfo), 1,
            reason: 'the loop checks the session before every attempt');
        expect(link.afterSupersede, isEmpty,
            reason: 'and never writes onto the new link either');
      });
    });

    test('gen4 never starts the follow-up', () {
      fakeAsync((async) {
        final link = _BootstrapLink(band: BandProfile.gen4);
        expect(_runBootstrap(link, async), isTrue);
        async.elapse(const Duration(seconds: 40));
        expect(link.opcodes, isNot(contains(Cmd.getBatteryPackInfo)));
      });
    });
  });
}

// ── T14: burst count membership must follow the band's arrival order ─────────
//
// every complete type-47/48/50/53/54/55 frame the
// band sends between HISTORY_START and HISTORY_END counts exactly once toward
// `HISTORY_END.expected_count` (= its own data_pkt_cnt + event_pkt_cnt).
//
// Data frames arrive on the data characteristic and are handled by the ONE
// serialized offload queue, together with both markers. Events and console
// logs arrive on the events characteristic — over the SAME ACL link, so their
// true position in the stream is their arrival order — and used to have their
// burst count applied at notification time instead. That reorders the count
// relative to the markers: a member could be tallied while the queue still had
// the PREVIOUS burst open (where the next HISTORY_START's rearm wipes it), so
// its own burst came up short by exactly those frames, every single retry.
//
// On a real WHOOP 5, earlier bursts carried a
// growing console surplus (console=5, 7, 9 …) while the burst behind them went
// `expected=52, actual=48, breakdown={V18=42, events=1, console=5}` and then,
// after the strap's adaptive burst-size drop, `expected=16, actual=12,
// breakdown={V18=12}` on every one of 15 attempts.

/// A gen5 v18 inner `Gen5V18Decoder` accepts: HR inside 25..230, dynamic
/// acceleration inside 0..8 g and a 1 g gravity vector.
Uint8List _gen5V18Inner({required int ts, required int counter}) {
  final inner = Uint8List(kGen5V18InnerLen);
  final v = ByteData.sublistView(inner);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, ts, Endian.little);
  inner[14] = 64; // heart rate
  v.setFloat32(33, 0.5, Endian.little); // dynamic acceleration
  v.setFloat32(45, 1.0, Endian.little); // gravity z → |g| = 1.0
  return inner;
}

/// A type-50 CONSOLE_LOGS inner (protocol's `parseConsoleLog` envelope).
/// A type-47 inner that will NOT decode to a 1 Hz sample: a valid shared
/// header (counter + unix) under a revision edge has no Sample mapping for.
Uint8List _rawHistInner({required int rev, required int counter}) {
  final inner = Uint8List(24);
  inner[0] = PacketType.historicalData;
  inner[1] = rev;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, 1786000000, Endian.little);
  return inner;
}

Uint8List _consoleInner(int index, {int ts = 1786000000}) {
  const text = 'BLE_CMD: Command Link Valid';
  final inner = Uint8List(12 + text.length);
  inner[0] = PacketType.consoleLogs;
  inner[1] = index;
  final v = ByteData.sublistView(inner);
  v.setUint16(2, 2, Endian.little); // console logs ride event id 2
  v.setUint32(4, ts, Endian.little);
  v.setUint16(10, text.length, Endian.little);
  inner.setRange(12, inner.length, text.codeUnits);
  return inner;
}

/// A type-49 METADATA HISTORY_START inner.
Uint8List _historyStart() =>
    Uint8List.fromList(<int>[PacketType.metadata, 0x01, SyncMeta.historyStart]);

Uint8List _historyComplete() => Uint8List.fromList(
    <int>[PacketType.metadata, 0x03, SyncMeta.historyComplete]);

/// A type-49 METADATA HISTORY_END inner: `expected_count` u32 @9 and the
/// 8-byte trim token @13:21 the result echoes verbatim.
Uint8List _historyEnd({required int expected, required int token}) {
  final inner = Uint8List(24);
  inner[0] = PacketType.metadata;
  inner[1] = 0x02;
  inner[2] = SyncMeta.historyEnd;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 1786000000, Endian.little); // strap clock
  v.setUint32(9, expected, Endian.little);
  v.setUint32(13, token, Endian.little); // marker A
  v.setUint32(17, 0x18, Endian.little); // marker B / batch id
  return inner;
}

/// A gen5 link that feeds inbound frames through the REAL receive path —
/// [FrameRoutePolicy] and the serialized offload queue included — and captures
/// every outgoing command.
class _Burst {
  final logs = <String>[];
  final frames = <Uint8List>[];
  late final BleEngine engine;

  _Burst() {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    connect();
  }

  /// Stand up a fresh session on the same engine (a reconnect, as far as
  /// everything session-scoped is concerned).
  void connect() => engine.debugInstallFakeLink(
        onWrite: (f) async {
          frames.add(f);
          return true;
        },
        band: BandProfile.gen5,
      );

  void rx(Uint8List inner, {String role = 'data'}) =>
      engine.debugReceiveFrame(Frame(inner, true, true), role: role);

  /// Opcodes of every command written to the link so far.
  List<int> get opcodes => frames
      .map((f) => parseFrame(f, profile: BandProfile.gen5))
      .where((p) => p != null && p.valid)
      .map((p) => p!.inner[2])
      .toList();

  /// The `traffic=` field of each HistoryEnd line, in order — i.e. the
  /// all-types tally the count gate judged for each burst that passed it.
  List<int> get acceptedCounts => logs
      .where((l) => l.contains('[SYNC] HistoryEnd batch='))
      .map((l) => int.parse(
          RegExp(r'traffic=(\d+)').firstMatch(l)!.group(1)!))
      .toList();

  List<String> get shortLines =>
      logs.where((l) => l.contains('Burst packet-count SHORT')).toList();
}

void _burstOrdering() {
  group('T14 — burst count members are counted in ARRIVAL order', () {
    final ts = _wallNow() - 3600;

    test(
      'event and console members delivered between the last data frame and '
      'HISTORY_END are counted — the gate passes',
      () async {
        final b = _Burst();
        b.rx(_historyStart());
        for (var i = 0; i < 12; i++) {
          b.rx(_gen5V18Inner(ts: ts + i, counter: 1000 + i));
        }
        // The two members the band counted in the same burst, on the OTHER
        // characteristic, after the last data frame and before the terminal.
        b.rx(_eventInner(29, <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            role: 'events');
        b.rx(_consoleInner(1), role: 'events');
        b.rx(_historyEnd(expected: 14, token: 0x8601));
        await pumpEventQueue();

        expect(b.shortLines, isEmpty,
            reason: '12 data + 1 event + 1 console IS the band\'s 14');
        expect(b.acceptedCounts, <int>[14]);
      },
    );

    test(
      'THE FIELD SCENARIO: members that arrive while the queue still has the '
      'previous burst open count into THEIR burst, not the open one',
      () async {
        // One synchronous GATT flurry — the queue has processed nothing past
        // burst A's HISTORY_START when burst B's members land. Counting them at
        // notification time (the old path) credited them to A, and B then went
        // permanently short by exactly those four frames: the 16/12 signature
        // from the field log.
        final b = _Burst();
        b.rx(_historyStart());
        for (var i = 0; i < 2; i++) {
          b.rx(_gen5V18Inner(ts: ts + i, counter: 2000 + i));
        }
        b.rx(_historyEnd(expected: 2, token: 0x8601));
        b.rx(_historyStart());
        for (var i = 0; i < 12; i++) {
          b.rx(_gen5V18Inner(ts: ts + 100 + i, counter: 2100 + i));
        }
        b.rx(_eventInner(29, <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            role: 'events');
        b.rx(_eventInner(123, <int>[1, 6, 0]), role: 'events');
        b.rx(_consoleInner(1), role: 'events');
        b.rx(_consoleInner(2), role: 'events');
        b.rx(_historyEnd(expected: 16, token: 0x8602));
        await pumpEventQueue();

        expect(b.shortLines, isEmpty,
            reason: 'burst B counted 12 data + 2 events + 2 console = 16/16; '
                'the old immediate path counted 12 and failed forever');
        expect(b.acceptedCounts, <int>[2, 16],
            reason: 'burst A must NOT be inflated by B\'s members either — '
                'that surplus is what the field log showed growing (console='
                '5, 7, 9 …) while the burst behind it starved');
      },
    );

    test('a straggler arriving after the result does not contaminate the NEXT '
        'burst', () async {
      final b = _Burst();
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts, counter: 3000));
      b.rx(_historyEnd(expected: 1, token: 0x8601));
      // Late: the band put this on the wire after the burst's terminal.
      b.rx(_consoleInner(9), role: 'events');
      await pumpEventQueue();

      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts + 1, counter: 3001));
      b.rx(_historyEnd(expected: 1, token: 0x8602));
      await pumpEventQueue();

      expect(b.shortLines, isEmpty);
      expect(b.acceptedCounts, <int>[1, 1],
          reason: 'the straggler belongs to the burst that was open when it '
              'arrived; HISTORY_START rearms the stats, so it can never be '
              'spent on the next burst\'s gate');
    });

    test(
        'a type-47 frame we cannot decode still counts — deep buffers and '
        'unknown revisions are burst members', () async {
      final b = _Burst();
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts, counter: 4000));
      // A gen5 deep buffer (v22 research telemetry: identified, archived, not
      // a 1 Hz sample) and a future firmware's unknown revision. The band
      // counted both when it wrote expected=3 — "unknown revisions still
      // count" is the membership rule, and an R22-enabled strap puts one of these
      // in most bursts, so leaving them uncounted starves the gate exactly
      // like the mis-binned event frames did.
      b.rx(_rawHistInner(rev: 22, counter: 4001));
      b.rx(_rawHistInner(rev: 99, counter: 4002));
      b.rx(_historyEnd(expected: 3, token: 0x8601));
      await pumpEventQueue();

      expect(b.shortLines, isEmpty,
          reason: '1 decoded + 2 archived type-47 frames ARE the band\'s 3');
      expect(b.acceptedCounts, <int>[3]);
    });
  });

  group('T14 — the 15th failed validation is terminal for the session', () {
    final ts = _wallNow() - 3600;

    /// One short burst, then marker-only re-offers of its END — the band
    /// re-offers the terminal roughly every 2.5 s WITHOUT resending frames,
    /// so the attempt count accumulates on one HISTORY_START.
    Future<void> stuckAfterFifteen(_Burst b) async {
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts, counter: 4001));
      for (var i = 1; i <= kBurstValidationAttemptLimit; i++) {
        b.rx(_historyEnd(expected: 5, token: 0x8600));
        await pumpEventQueue();
      }
    }

    test('15 failures abort ONCE, then the re-offered burst is dropped without '
        'validating or aborting again', () async {
      final b = _Burst();
      await stuckAfterFifteen(b);

      expect(b.shortLines, hasLength(kBurstValidationAttemptLimit));
      expect(
        b.opcodes.where((o) => o == Cmd.abortHistoricalTransmits).length,
        1,
        reason: 'ONE abort at the boundary — ',
      );
      // Attempts 1..14 send a failure result; the 15th deliberately does not.
      expect(
        b.opcodes.where((o) => o == Cmd.historicalDataResult).length,
        kBurstValidationAttemptLimit - 1,
      );
      expect(b.engine.historyStuckThisSession, isTrue);

      // The band does not know the session is over and re-offers the burst
      // roughly every 2.5 s. Each re-offer used to re-enter validation — which
      // was already past the limit — and abort again: 14+ aborts in 12 s on a
      // real strap.
      final before = b.opcodes.length;
      for (var i = 0; i < 4; i++) {
        b.rx(_historyEnd(expected: 5, token: 0x8600));
        await pumpEventQueue();
      }
      expect(b.shortLines, hasLength(kBurstValidationAttemptLimit),
          reason: 'no further validation at all');
      expect(b.opcodes.length, before, reason: 'and no further link traffic');
      expect(
        b.logs.where((l) => l.contains('terminal (Stuck)')).length,
        1,
        reason: 'logged once, quietly — the re-offers are silent after that',
      );
      expect(b.engine.offloadSnapshot['stuck_markers_dropped'], greaterThan(0));
    });

    test('a same-session drain trigger is refused; a new session drains',
        () async {
      final b = _Burst();
      await stuckAfterFifteen(b);

      expect(await b.engine.debugStartHistoricalRefresh(), isFalse,
          reason: 'continuation belongs to a later connection, not to a '
              'retry on this one');
      expect(b.engine.offloadSnapshot['stuck_refreshes_refused'], 1);

      // A reconnect is the remedy: the latch is session-scoped, so the next
      // connection drains normally from the band\'s own checkpoint.
      b.connect();
      expect(b.engine.historyStuckThisSession, isFalse);
      final shortBefore = b.shortLines.length;
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts, counter: 5000));
      b.rx(_historyEnd(expected: 1, token: 0x8800));
      await pumpEventQueue();
      expect(b.shortLines, hasLength(shortBefore),
          reason: 'the fresh session validated its burst normally');
      expect(b.acceptedCounts.last, 1);
    });

    test('HISTORY_COMPLETE still completes the drain after Stuck', () async {
      final b = _Burst();
      await stuckAfterFifteen(b);
      expect(b.engine.historyStuckThisSession, isTrue);

      b.rx(_historyComplete());
      await pumpEventQueue();
      expect(
        b.logs.any((l) => l.contains('HistoryComplete — backlog drained')),
        isTrue,
        reason: 'COMPLETE ACKs nothing and must not be swallowed by the '
            'latch, or every awaitComplete waiter runs out its timeout',
      );
    });
  });

  group('#260 review — burst boundaries the gate must respect', () {
    final ts = _wallNow() - 3600;

    test('a new HISTORY_START starts a fresh validation cycle', () async {
      final b = _Burst();
      // Burst A fails three times (slack stays 0 through attempt 3).
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts, counter: 4100));
      for (var i = 0; i < 3; i++) {
        b.rx(_historyEnd(expected: 5, token: 0x8620));
        await pumpEventQueue();
      }
      expect(b.shortLines, hasLength(3));

      // Burst B delivers 1 frame against expected 3. With burst A's three
      // failures inherited, attempt 4's slack of 2 would ACCEPT 1/3 and let
      // the band trim two frames never tallied. A fresh burst's first
      // attempt demands every frame.
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts + 1, counter: 4101));
      b.rx(_historyEnd(expected: 3, token: 0x8621));
      await pumpEventQueue();
      expect(b.shortLines, hasLength(4),
          reason: 'burst B is judged at attempt one, slack zero');
      expect(b.acceptedCounts, isEmpty);
    });

    test('chatter after HISTORY_END cannot push a short burst over the line',
        () async {
      final b = _Burst();
      b.rx(_historyStart());
      b.rx(_gen5V18Inner(ts: ts, counter: 4200));
      b.rx(_historyEnd(expected: 3, token: 0x8630));
      await pumpEventQueue();
      expect(b.shortLines, hasLength(1)); // 1 of 3 — refused

      // Two console lines land during the re-offer window — numerically
      // exactly the two frames the tally is missing, but they are NOT part
      // of the window the band counted.
      b.rx(_consoleInner(1), role: 'events');
      b.rx(_consoleInner(2), role: 'events');
      b.rx(_historyEnd(expected: 3, token: 0x8630));
      await pumpEventQueue();
      expect(b.shortLines, hasLength(2),
          reason: 're-validation judges the tally frozen at the terminal');
      expect(b.acceptedCounts, isEmpty);
    });

    test('console chatter does not keep a stalled offload alive', () {
      fakeAsync((async) {
        final b = _Burst();
        b.rx(_historyStart());
        b.rx(_gen5V18Inner(ts: _wallNow() - 3600, counter: 4300));
        async.flushMicrotasks();

        // 55 s of chatter-only traffic. Each console line is a count member
        // riding the offload queue, and each used to re-arm the idle
        // watchdog — so a strap that stalled mid-burst but kept logging
        // never hit the timeout.
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 11));
          b.rx(_consoleInner(10 + i), role: 'events');
          async.flushMicrotasks();
        }
        expect(b.opcodes, isNot(contains(Cmd.abortHistoricalTransmits)));

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(b.opcodes, contains(Cmd.abortHistoricalTransmits),
            reason: 'the fuse measures real drain progress, not chatter');
      });
    });

    test('gen4 keeps the advisory-only count behaviour', () async {
      final logs = <String>[];
      final frames = <Uint8List>[];
      final engine = BleEngine(
        onRecord: (_, _) async {},
        onState: (_) {},
        log: logs.add,
      );
      engine.debugInstallFakeLink(
        onWrite: (f) async {
          frames.add(f);
          return true;
        },
        band: BandProfile.gen4,
      );
      engine.debugReceiveFrame(Frame(_historyStart(), true, true),
          role: 'data');
      engine.debugReceiveFrame(
        Frame(_gen4Inner(version: 24, ts: _wallNow() - 3600, counter: 9000),
            true, true),
        role: 'data',
      );
      engine.debugReceiveFrame(
          Frame(_historyEnd(expected: 5, token: 0x9900), true, true),
          role: 'data');
      await pumpEventQueue();

      expect(logs.any((l) => l.contains('ADVISORY, gen4')), isTrue,
          reason: 'the mismatch is still visible');
      expect(logs.any((l) => l.contains('Burst packet-count SHORT')), isFalse,
          reason: 'but never refused — gen4 count semantics are unpinned');
      final ops = frames
          .map((f) => parseFrame(f))
          .where((p) => p != null && p.valid)
          .map((p) => p!.inner[2]);
      expect(ops, isNot(contains(Cmd.abortHistoricalTransmits)));
      expect(engine.historyStuckThisSession, isFalse);
    });
  });
}
