// Regression for the headless-re-arm-skips-confirmation bug: when
// armNextScheduledOccurrence's same-epoch dedupe returns epoch: null, the
// re-arm/poll block in runHeadlessSync never runs, so a live ALARM_SET (event
// 56) arriving on that same connection has to be caught by the onEvent
// callback directly, mirroring foreground's unconditional AlarmConfirmation
// self-heal. See handleHeadlessAlarmEvent's doc comment.

import 'dart:io' show sleep;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/sync/background_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ALARM_SET flips alarm_epoch_confirmed to true even with no prior arm',
      () async {
    SharedPreferences.setMockInitialValues({
      'alarm_epoch': 1234,
      'alarm_epoch_confirmed': false,
    });

    await handleHeadlessAlarmEvent(proto.EventId.strapDrivenAlarmSet);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('alarm_epoch_confirmed'), isTrue);
  });

  test('a 56 replayed from an earlier arm does not confirm the current one',
      () async {
    // Wednesday 22:00 arm; the strap re-sends Monday 22:00's ALARM_SET.
    const wedArmMs = 1750284000000;
    const monSec = wedArmMs ~/ 1000 - 2 * 86400;
    SharedPreferences.setMockInitialValues({
      'alarm_epoch': wedArmMs ~/ 1000 + 9 * 3600,
      'alarm_set_at_ms': wedArmMs,
      'alarm_epoch_confirmed': false,
    });

    await handleHeadlessAlarmEvent(proto.EventId.strapDrivenAlarmSet,
        tsSec: monSec);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('alarm_epoch_confirmed'), isFalse);
  });

  test('a 56 stamped after this arm (or with an unset RTC) still confirms',
      () async {
    const armMs = 1750284000000;
    for (final ts in <int?>[armMs ~/ 1000 + 3, armMs ~/ 1000 - 60, 12345]) {
      SharedPreferences.setMockInitialValues({
        'alarm_epoch': armMs ~/ 1000 + 9 * 3600,
        'alarm_set_at_ms': armMs,
        'alarm_epoch_confirmed': false,
      });
      await handleHeadlessAlarmEvent(proto.EventId.strapDrivenAlarmSet,
          tsSec: ts);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('alarm_epoch_confirmed'), isTrue, reason: 'ts=$ts');
    }
  });

  test('an unrelated event id leaves the flag untouched', () async {
    SharedPreferences.setMockInitialValues({
      'alarm_epoch': 1234,
      'alarm_epoch_confirmed': false,
    });

    await handleHeadlessAlarmEvent(57); // strapDrivenAlarmExecuted, not SET

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('alarm_epoch_confirmed'), isFalse);
  });

  test('a 56 that lands while setAlarm still awaits its reply confirms the arm',
      () {
    SharedPreferences.setMockInitialValues({});
    fakeAsync((fa) {
      int? latchAtMs;
      headlessArmAndConfirm(() async {
        // The strap latches mid-write, then the reply wait runs on.
        latchAtMs = DateTime.now().millisecondsSinceEpoch;
        sleep(const Duration(milliseconds: 5));
        await Future<void>.delayed(const Duration(seconds: 5));
        return (epoch: 1750000000, disabled: false, failed: false);
      }, (sinceMs) async => latchAtMs != null && latchAtMs! >= sinceMs);
      fa.elapse(const Duration(seconds: 40));
    });
    return SharedPreferences.getInstance().then((prefs) {
      expect(prefs.getInt('alarm_epoch'), 1750000000);
      expect(prefs.getBool('alarm_epoch_confirmed'), isTrue);
    });
  });
}
