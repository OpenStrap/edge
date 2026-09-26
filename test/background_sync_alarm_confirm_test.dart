// Regression for the headless-re-arm-skips-confirmation bug: when
// armNextScheduledOccurrence's same-epoch dedupe returns epoch: null, the
// re-arm/poll block in runHeadlessSync never runs, so a live ALARM_SET (event
// 56) arriving on that same connection has to be caught by the onEvent
// callback directly, mirroring foreground's unconditional AlarmConfirmation
// self-heal. See handleHeadlessAlarmEvent's doc comment.

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

  test('an unrelated event id leaves the flag untouched', () async {
    SharedPreferences.setMockInitialValues({
      'alarm_epoch': 1234,
      'alarm_epoch_confirmed': false,
    });

    await handleHeadlessAlarmEvent(57); // strapDrivenAlarmExecuted, not SET

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('alarm_epoch_confirmed'), isFalse);
  });
}
