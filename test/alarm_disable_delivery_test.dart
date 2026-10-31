// A DISABLE_ALARM write that never reaches the band (write timeout, GATT
// error, link not ready) must not be reported as a cancel. The strap keeps
// its armed epoch and buzzes; if the app forgets the epoch on a failed write,
// nothing ever re-sends the disable.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';

BleEngine _engine(bool delivered, List<Uint8List> writes) {
  final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
  engine.debugInstallFakeLink(
    onWrite: (f) async {
      writes.add(f);
      return delivered;
    },
    listening: true,
  );
  return engine;
}

void main() {
  test('disableAlarm reports whether the write reached the band', () async {
    final failed = <Uint8List>[];
    expect(await _engine(false, failed).disableAlarm(), isFalse);
    expect(failed, isNotEmpty);

    final ok = <Uint8List>[];
    expect(await _engine(true, ok).disableAlarm(), isTrue);
  });

  test('every day off + failed disable keeps the armed epoch for a retry',
      () async {
    final writes = <Uint8List>[];
    final r = await armNextScheduledOccurrence(
      engine: _engine(false, writes),
      schedule: fillDefaultAlarmSchedule(const []),
      currentArmedEpoch: 1800000000,
    );
    expect(writes, isNotEmpty, reason: 'the disable was attempted');
    expect(r.disabled, isFalse,
        reason: 'the caller clears its armed epoch on disabled:true');
    expect(r.epoch, isNull);
    expect(r.failed, isTrue);
  });

  test('a failed arm is told apart from an arm that already matches',
      () async {
    final schedule = fillDefaultAlarmSchedule([
      for (var d = 0; d < 7; d++)
        AlarmScheduleEntry(weekday: d, hour: 7, minute: 0, enabled: true),
    ]);
    final now = DateTime(2026, 10, 20, 22);
    final writes = <Uint8List>[];
    final failed = await armNextScheduledOccurrence(
      engine: _engine(false, writes),
      schedule: schedule,
      currentArmedEpoch: null,
      now: now,
    );
    expect(writes, isNotEmpty, reason: 'the arm was attempted');
    expect(failed.epoch, isNull);
    expect(failed.failed, isTrue);

    final next = nextAlarmOccurrence(schedule, now)!;
    final same = await armNextScheduledOccurrence(
      engine: _engine(false, []),
      schedule: schedule,
      currentArmedEpoch: next.millisecondsSinceEpoch ~/ 1000,
      now: now,
    );
    expect(same.epoch, isNull);
    expect(same.failed, isFalse, reason: 'nothing to write is not a failure');
  });

  test('every day off + delivered disable reports disabled', () async {
    final r = await armNextScheduledOccurrence(
      engine: _engine(true, []),
      schedule: fillDefaultAlarmSchedule(const []),
      currentArmedEpoch: 1800000000,
    );
    expect(r.disabled, isTrue);
    expect(r.failed, isFalse);
  });
}
