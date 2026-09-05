// The band registry is the ONE place the BLE engine's device-specific facts
// live (change-list D1/D2/D3). Every value here used to be a literal in
// `ble_engine.dart`, so this pins them at exactly what the engine did before —
// a wrong offset does not throw, it silently reads the wrong byte.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  test('ids are unique and stable — they are stamped as device_family', () {
    expect(
        kBandRegistry.map((e) => e.id).toList(),
        <String>[
          'gen4',
          'gen5',
          'ble_hrs',
          'oura',
          'pebble',
          'makibeshr3',
          'id115',
          'smaq2oss',
          'xwatch',
          'tlw64',
          'dafit',
          'o2ring',
          'zetime',
          'wearfit',
          'ringconn',
          'dt78',
          'lefun',
          'hplus',
          'pinetime',
          'qhybrid',
          'colmi',
          'casio',
          'jyou',
          'watch9',
        ]);
  });

  test('D1 — the scan service list is exactly the two WHOOP services', () {
    // [kFramedBands], not the whole registry: the scan filter and the
    // discovery match are about the band the OFFLOAD ENGINE drives. A
    // notify-only sensor matching there would be handed to `_doConnect`.
    expect(kFramedBands.map((e) => e.service).toList(), <String>[
      GattProfile.gen4.service,
      GattProfile.gen5.service,
    ]);
    expect(kFramedBands.map((e) => e.servicePrefix).toList(),
        <String>['61080001', 'fd4b0001']);
  });

  test('D2 — a WHOOP link requires its four command/notify characteristics',
      () {
    for (final e in kFramedBands) {
      expect(e.requiredCharacteristics, <String>[
        e.gatt!.cmdTo,
        e.gatt!.cmdFrom,
        e.gatt!.events,
        e.gatt!.data,
      ]);
    }
  });

  test('D10 — a generic HRS entry has one service and one notify char', () {
    expect(kBleHrs.isFramed, isFalse);
    expect(kBleHrs.service, kHeartRateServiceUuid);
    expect(kBleHrs.servicePrefix, '0000180d');
    expect(kBleHrs.requiredCharacteristics, [kHeartRateMeasurementUuid]);
    // The two halves that could NOT be expressed — see the registry header.
    expect(kBleHrs.gatt, isNull, reason: 'GattProfile is six WHOOP UUIDs');
    expect(kBleHrs.wire, isNull, reason: 'BandProfile is a framed envelope');
  });

  test('a PineTime entry filters on its OWN service, not the shared HRS one',
      () {
    expect(kPineTime.isFramed, isFalse);
    expect(kPineTime.service, kPineTimeMotionService);
    expect(kPineTime.servicePrefix, '00030000');
    // Distinct from kBleHrs's own scan filter — two rows sharing one service
    // is the collision `HrsLink.scanForAny` treats as a registry bug.
    expect(kPineTime.service, isNot(kBleHrs.service));
    // Both required, even though they sit on two different GATT services —
    // `GattBandLink` matches a characteristic across every discovered
    // service, not only the scan-filter one.
    expect(kPineTime.requiredCharacteristics,
        [kPineTimeStepCountChar, kHeartRateMeasurementUuid]);
  });

  test('D3 — frameOpcodeIndex lands on the opcode of a real built frame', () {
    // This is the byte the dangerous-opcode block reads. If it moves, the
    // block silently stops blocking.
    for (final e in kFramedBands) {
      final raw = buildCommand(7, Cmd.rebootStrap, const <int>[0x01], e.wire!);
      expect(raw[e.frameOpcodeIndex], Cmd.rebootStrap, reason: e.id);
    }
    expect(kWhoopGen4.frameOpcodeIndex, 6); // 4-byte header + 2
    expect(kWhoopGen5.frameOpcodeIndex, 10); // 8-byte header + 2
  });

  test('D3 — historical inner offsets are unchanged from the old literals',
      () {
    for (final e in kFramedBands) {
      expect(e.innerVersionOffset, 1, reason: e.id); // inner[1]
      expect(e.innerCounterOffset, 3, reason: e.id); // u32(inner, 3)
    }
    // A band with no envelope has no inner payload, and -1 throws rather than
    // reading a plausible-looking wrong byte.
    expect(kBleHrs.innerVersionOffset, -1);
    expect(kBleHrs.innerCounterOffset, -1);
  });

  test('a band declares what its timestamps ARE', () {
    // Not cosmetic: the frequency-domain and per-hour metrics have to refuse
    // on an arrival anchor, and this is the fact they refuse on.
    expect(kWhoopGen4.timeAnchor, TimeAnchor.measured);
    expect(kWhoopGen5.timeAnchor, TimeAnchor.measured);
    expect(kBleHrs.timeAnchor, TimeAnchor.arrival);
    expect(kPebble.timeAnchor, TimeAnchor.arrival);
  });

  test('Pebble 2 / Pebble 2 SE — one scan-filter service, five required '
      'characteristics, no envelope', () {
    expect(kPebble.isFramed, isFalse);
    expect(kPebble.service, kPebbleServiceUuid);
    expect(kPebble.servicePrefix, '0000fed9');
    expect(kPebble.requiredCharacteristics, <String>[
      kPebblePairingTriggerUuid,
      kPebbleConnectivityUuid,
      kPebbleMtuUuid,
      kPebblePpogattReadUuid,
      kPebblePpogattWriteUuid,
    ]);
    expect(kPebble.gatt, isNull);
    expect(kPebble.wire, isNull);
    expect(() => kPebble.commands, throwsA(isA<TypeError>()));
  });

  test('bandEntryFor maps a wire profile back to its entry', () {
    expect(bandEntryFor(BandProfile.gen4).id, 'gen4');
    expect(bandEntryFor(BandProfile.gen5).id, 'gen5');
  });

  // ── the isGen5 split (D4/D9) ────────────────────────────────────────────
  // Each expectation below is the LITERAL that used to sit in the matching arm
  // of an `if (session.band.isGen5)` in `ble_engine.dart`. Nothing here is
  // derived: a wrong entry does not throw, it sends the wrong bytes to a band
  // nobody can test against.

  test('D9 — the gen4 arm of every branch that moved, transcribed', () {
    final c = kWhoopGen4.commands;
    expect(c.hello, Cmd.getHelloHarvard); //  getHello()
    expect(c.helloBody, const <int>[0x00]); //  getHello()
    expect(c.getAdvertisingName, Cmd.getAdvertisingNameHarvard);
    expect(c.getAdvertisingNameBody, const <int>[0x00]);
    expect(c.setAdvertisingName, Cmd.setAdvertisingNameHarvard);
    expect(c.r10R11Realtime, Cmd.sendR10R11Realtime); //  live on/off/re-arm
    expect(c.opticalDataIsLiveToggle, isTrue); //  enableLiveStreams()
    expect(c.offloadBody, const <int>[0x00]); //  _offloadPayload
    expect(kWhoopGen4.preRegistrationDelay, Duration.zero);
    expect(kWhoopGen4.postRegistrationDelay, Duration.zero);
    expect(kWhoopGen4.setClockDriftGated, isFalse); //  unconditional SET_CLOCK
    expect(kWhoopGen4.burstCountGateEnforced, isFalse); //  advisory only
    expect(kWhoopGen4.logsConsoleOutput, isFalse);
  });

  test('D9 — the gen5 arm of every branch that moved, transcribed', () {
    final c = kWhoopGen5.commands;
    expect(c.hello, Cmd.getHello);
    expect(c.helloBody, const <int>[0x01]);
    expect(c.getAdvertisingName, Cmd.getCustomAdvertisingName);
    expect(c.getAdvertisingNameBody, const <int>[revision1]);
    expect(c.setAdvertisingName, Cmd.setCustomAdvertisingName);
    // NULL, not 0x3F: a WHOOP 5 answers Unknown/Unhandled, and null is what
    // the four live-stream paths read to omit the toggle entirely.
    expect(c.r10R11Realtime, isNull);
    // FALSE is the safety boundary: the same opcode is the SAVE-to-history
    // toggle here, so arming it for live writes a persistent save-enable.
    expect(c.opticalDataIsLiveToggle, isFalse);
    expect(c.offloadBody, const <int>[]);
    expect(kWhoopGen5.preRegistrationDelay, kGen5PreRegistrationDelay);
    expect(kWhoopGen5.postRegistrationDelay, kGen5PostRegistrationDelay);
    expect(kWhoopGen5.setClockDriftGated, isTrue);
    expect(kWhoopGen5.burstCountGateEnforced, isTrue);
    expect(kWhoopGen5.logsConsoleOutput, isTrue);
  });

  test('the two bands genuinely differ everywhere the branch said they did',
      () {
    // The failure this catches is a copy-paste row: a gen5 entry that silently
    // carries gen4's opcodes still compiles and still passes every "is it the
    // right value" assertion written against ONE band.
    final a = kWhoopGen4.commands;
    final b = kWhoopGen5.commands;
    expect(a.hello, isNot(b.hello));
    expect(a.getAdvertisingName, isNot(b.getAdvertisingName));
    expect(a.setAdvertisingName, isNot(b.setAdvertisingName));
    expect(a.r10R11Realtime, isNot(b.r10R11Realtime));
    expect(a.offloadBody, isNot(b.offloadBody));
  });

  test('a notify-only sensor has no command table at all', () {
    // Same rule as the -1 offsets: throwing beats answering with a
    // plausible-looking WHOOP default that would be written to a chest strap.
    expect(() => kBleHrs.commands, throwsA(isA<TypeError>()));
  });
}
