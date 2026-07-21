// Pure-logic tests for the on-device wake alarm:
//   - the exact SET_ALARM_TIME byte layouts (rich 20-byte firing form + short
//     7-byte time-only form) and the RUN/DISABLE bodies (AlarmPayloads), and
//   - the strap-event confirmation state machine (AlarmConfirmation).
// No BLE / DB — everything here is deterministic.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/sync/sync_policy.dart' show ClockRef;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

void main() {
  group('AlarmPayloads byte layout', () {
    // A hand-computed vector:
    //   sec    = 0x01020304 = 16909060  → LE [04 03 02 01]
    //   subsec = (500 * 32768) ~/ 1000 = 16384 = 0x4000 → LE [00 40]
    final when = DateTime.fromMillisecondsSinceEpoch(16909060 * 1000 + 500,
        isUtc: true);

    test('subsecOf uses the 1/32768 s formula', () {
      expect(AlarmPayloads.subsecOf(when), 16384);
      // 0 ms → 0 subsec; 999 ms → the top of the range.
      expect(
          AlarmPayloads.subsecOf(
              DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true)),
          0);
      expect(
          AlarmPayloads.subsecOf(
              DateTime.fromMillisecondsSinceEpoch(1999, isUtc: true)),
          (999 * 32768) ~/ 1000);
    });

    test('rich (20B) = marker + index + u32 sec LE + u16 subsec LE + haptics', () {
      final p = AlarmPayloads.rich(when);
      expect(p.length, 20);
      expect(p, <int>[
        0x04, // rich-form marker
        0x00, // index
        0x04, 0x03, 0x02, 0x01, // sec LE
        0x00, 0x40, // subsec LE (16384)
        47, 152, 0, 0, 0, 0, 0, 0, // 8 waveform effects
        0, 0, // loop control u16 LE
        7, // overall loop
        30, // duration seconds
      ]);
    });

    test('rich honours a custom index + custom 12-byte haptics', () {
      final custom = List<int>.generate(12, (i) => i + 1);
      final p = AlarmPayloads.rich(when, index: 3, haptics: custom);
      expect(p[0], 0x04);
      expect(p[1], 3);
      expect(p.sublist(8), custom);
    });

    test('simple (7B) = 0x01 + u32 sec LE + u16 subsec LE (ACKs, never fires)', () {
      final p = AlarmPayloads.simple(when);
      expect(p.length, 7);
      expect(p, <int>[0x01, 0x04, 0x03, 0x02, 0x01, 0x00, 0x40]);
    });

    test('RUN_ALARM + DISABLE_ALARM bodies are both [0x01]', () {
      expect(AlarmPayloads.runNow, <int>[0x01]);
      expect(AlarmPayloads.disable, <int>[0x01]);
    });

    test('default haptics match the stock wake-buzz pattern', () {
      expect(AlarmPayloads.defaultHaptics,
          <int>[47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30]);
    });
  });

  group('AlarmPayloads.toStrapFrame (RTC-frame arming)', () {
    // Wall-clock target with a non-zero sub-second so we can assert it survives.
    final wall = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000 + 250,
        isUtc: true);

    test('uncorrelated (drift 0) → wall target unchanged', () {
      expect(AlarmPayloads.toStrapFrame(wall, 0).millisecondsSinceEpoch,
          wall.millisecondsSinceEpoch);
    });

    test('strap RTC behind wall (drift +90) → armed epoch = wall − 90', () {
      final r = AlarmPayloads.toStrapFrame(wall, 90);
      expect(r.millisecondsSinceEpoch ~/ 1000, 1750000000 - 90);
      // whole-second shift keeps the sub-second remainder intact
      expect(AlarmPayloads.subsecOf(r), AlarmPayloads.subsecOf(wall));
    });

    test('strap RTC ahead of wall (drift −30) → armed epoch = wall + 30', () {
      expect(AlarmPayloads.toStrapFrame(wall, -30).millisecondsSinceEpoch ~/ 1000,
          1750000000 + 30);
    });

    test('rich() encodes the strap-frame epoch, not the raw wall epoch', () {
      // On a strap whose RTC is 90s behind, arming the raw wall epoch would fire
      // 90s late (or never, for a large offset); the rich payload must carry the
      // shifted (wall − drift) seconds.
      final p = AlarmPayloads.rich(AlarmPayloads.toStrapFrame(wall, 90));
      final sec = p[2] | (p[3] << 8) | (p[4] << 16) | (p[5] << 24);
      expect(sec, 1750000000 - 90);
    });
  });

  group('ClockRef.driftSec + reconnect fallback (stale-correlation guard)', () {
    final wall = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000,
        isUtc: true);

    test('driftSec = wall − device (positive when the strap RTC is behind)', () {
      expect(const ClockRef(device: 1000, wall: 1090).driftSec, 90);
      expect(const ClockRef(device: 1100, wall: 1070).driftSec, -30);
      expect(const ClockRef(device: 1000, wall: 1000).driftSec, 0);
    });

    test('no correlation yet (just after reconnect) → drift 0 → raw wall epoch', () {
      // On reconnect _clockRef is nulled until THIS session's GET_CLOCK reply, so
      // the arm must fall back to the raw epoch rather than reuse the previous
      // session's offset. This mirrors engine.setAlarm's `_clockRef?.driftSec ?? 0`.
      const ClockRef? ref = null;
      final driftSec = ref?.driftSec ?? 0;
      expect(driftSec, 0);
      expect(
          AlarmPayloads.toStrapFrame(wall, driftSec).millisecondsSinceEpoch ~/ 1000,
          1750000000);
    });

    test('correlated session → arms in the strap frame using the offset', () {
      const ref = ClockRef(device: 1749999910, wall: 1750000000); // strap 90s behind
      final driftSec = ref.driftSec; // 90
      expect(driftSec, 90);
      expect(
          AlarmPayloads.toStrapFrame(wall, driftSec).millisecondsSinceEpoch ~/ 1000,
          1750000000 - 90);
    });
  });

  group('AlarmConfirmation state machine', () {
    test('event ids match the protocol EventId names', () {
      expect(AlarmConfirmation.kEvtSet, proto.EventId.strapDrivenAlarmSet);
      expect(AlarmConfirmation.kEvtStrapExecuted,
          proto.EventId.strapDrivenAlarmExecuted);
      expect(AlarmConfirmation.kEvtAppExecuted,
          proto.EventId.appDrivenAlarmExecuted);
      expect(AlarmConfirmation.kEvtDisabled,
          proto.EventId.strapDrivenAlarmDisabled);
      expect(AlarmConfirmation.kEvtHapticsFired, proto.EventId.hapticsFired);
    });

    test('a fresh alarm is neither pending nor confirmed', () {
      final a = AlarmConfirmation();
      expect(a.confirmed, isFalse);
      expect(a.isPending(0), isFalse);
      expect(a.isUnconfirmed(0), isFalse);
    });

    test('after SET → PENDING inside the grace window, then UNCONFIRMED', () {
      final a = AlarmConfirmation(graceMs: 6000);
      a.set(1750000000, 0);
      expect(a.confirmed, isFalse);
      expect(a.isPending(0), isTrue);
      expect(a.isPending(5999), isTrue);
      expect(a.isUnconfirmed(5999), isFalse);
      // grace elapsed with no confirm event → soft-warning state.
      expect(a.isPending(6000), isFalse);
      expect(a.isUnconfirmed(6000), isTrue);
    });

    test('event 56 confirms (and clears pending/unconfirmed)', () {
      final a = AlarmConfirmation(graceMs: 6000);
      a.set(1750000000, 0);
      final eff = a.onEvent(AlarmConfirmation.kEvtSet, 100);
      expect(eff, AlarmEffect.confirmed);
      expect(a.confirmed, isTrue);
      expect(a.lastEventId, 56);
      expect(a.isPending(10000), isFalse);
      expect(a.isUnconfirmed(10000), isFalse);
    });

    test('events 57/58 mark FIRED with a timestamp', () {
      for (final id in [
        AlarmConfirmation.kEvtStrapExecuted,
        AlarmConfirmation.kEvtAppExecuted,
      ]) {
        final a = AlarmConfirmation();
        a.set(1750000000, 0);
        final eff = a.onEvent(id, 4242);
        expect(eff, AlarmEffect.fired);
        expect(a.firedAt, 4242);
        expect(a.lastEventId, id);
      }
    });

    test('event 59 clears the alarm', () {
      final a = AlarmConfirmation();
      a.set(1750000000, 0);
      a.onEvent(AlarmConfirmation.kEvtSet, 10);
      final eff = a.onEvent(AlarmConfirmation.kEvtDisabled, 20);
      expect(eff, AlarmEffect.cleared);
      expect(a.confirmed, isFalse);
      expect(a.targetEpoch, isNull);
      expect(a.lastEventId, 59);
    });

    test('an unrelated event returns null and changes nothing', () {
      final a = AlarmConfirmation();
      a.set(1750000000, 0);
      expect(a.onEvent(proto.EventId.wristOn, 5), isNull);
      expect(a.confirmed, isFalse);
      expect(a.targetEpoch, 1750000000);
    });
  });
}
