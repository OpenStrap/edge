// A strap double tap through AppState: which action the single double-tap
// mapping runs, and the two guards in front of it. The tap travels the real
// engine event path; the dispatcher's clock is faked so each boundary is
// exact.
//
//  * Recency: a tap whose strap timestamp is more than 6 s behind the phone is
//    a drained/historical one and is skipped; a timestamp that is not a
//    plausible past time (unset RTC: zero, in the future, more than a day old)
//    cannot be judged and falls through to the debounce alone.
//  * Debounce: one action per 2 s, however many events the band sends.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_dispatch.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ActionChannel channel;
  late HapticSpy haptics;
  setUpAll(() => gestureDbSetUp(_db));
  tearDownAll(() => gestureDbTearDown(_db));
  setUp(() {
    BleEngine.resetBandClaimForTest();
    channel = ActionChannel();
    haptics = HapticSpy();
  });
  tearDown(() {
    channel.dispose();
    haptics.dispose();
    BleEngine.resetBandClaimForTest();
  });

  GestureRig newRig() {
    final rig = GestureRig();
    addTearDown(rig.dispose);
    return rig;
  }

  group('the mapping', () {
    test('nothing is mapped by default: a tap runs nothing', () async {
      final rig = newRig();
      expect(rig.app.gestureSettings.doubleTap, DeviceAction.none);
      rig.doubleTap();
      await settleMs(100);
      expect(channel.performed, isEmpty);
      expect(haptics.calls, isEmpty);
    });

    for (final a in [
      DeviceAction.mediaPlayPause,
      DeviceAction.mediaNext,
      DeviceAction.volumeUp,
      DeviceAction.torch,
      DeviceAction.ringPhone,
      DeviceAction.broadcastToTasker,
    ]) {
      test('a native action goes to the platform channel by its wire id '
          '(${a.id})', () async {
        final rig = newRig();
        await rig.map(a);
        rig.doubleTap();
        await until(() => channel.performed.isNotEmpty, what: 'native perform');
        expect(channel.performed, [a.id]);
      });
    }

    test('a native action that fails is not retried and does not throw',
        () async {
      final rig = newRig();
      channel.ok = false;
      await rig.map(DeviceAction.torch);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await settleMs(100);
      expect(channel.performed, ['torch']);
    });

    test('in-app actions never reach the platform channel', () async {
      for (final a in [
        DeviceAction.markMoment,
        DeviceAction.workoutToggle,
        DeviceAction.logWater,
      ]) {
        final rig = newRig();
        await rig.map(a);
        rig.doubleTap();
        await settleMs(150);
        expect(channel.performed, isEmpty, reason: a.id);
        await rig.app.stopWorkout();
        await rig.dispose();
        await settleMs(100);
        BleEngine.resetBandClaimForTest();
      }
    });

    test('an event that is not a double tap runs nothing, whatever is mapped',
        () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      for (final id in [3, 9, 56, 57, 13, 15]) {
        rig.event(id);
      }
      await settleMs(100);
      expect(channel.performed, isEmpty);
    });

    test('the mapping is read live: changing it between taps changes what '
        'the next tap does', () async {
      final rig = newRig();
      await rig.map(DeviceAction.mediaNext);
      rig.doubleTap();
      await until(() => channel.performed.length == 1);
      rig.advance(const Duration(seconds: 3));
      await rig.map(DeviceAction.volumeUp);
      rig.doubleTap();
      await until(() => channel.performed.length == 2);
      rig.advance(const Duration(seconds: 3));
      await rig.map(DeviceAction.none);
      rig.doubleTap();
      await settleMs(100);
      expect(channel.performed, ['media_next', 'volume_up']);
    });
  });

  group('recency window (6 s)', () {
    test('a tap that is 0 and 6 seconds old runs', () async {
      for (final age in [0, 6]) {
        final rig = newRig();
        await rig.map(DeviceAction.torch);
        channel.performed.clear();
        rig.doubleTapAged(Duration(seconds: age));
        await until(() => channel.performed.isNotEmpty, what: 'age $age');
        expect(channel.performed, ['torch'], reason: 'age $age');
        await rig.dispose();
      }
    });

    test('a tap that is 7 seconds, a minute or an hour old is stale: skipped, '
        'logged, and it does not spend the debounce', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      for (final age in [const Duration(seconds: 7), const Duration(minutes: 1),
          const Duration(hours: 1), const Duration(hours: 23)]) {
        rig.doubleTapAged(age);
      }
      await settleMs(100);
      expect(channel.performed, isEmpty);
      expect(
          rig.app.logLines.where((l) => l.contains('ignoring stale double-tap')),
          hasLength(4));
      rig.doubleTap(); // same instant: the stale ones did not use the debounce
      await until(() => channel.performed.isNotEmpty);
      expect(channel.performed, ['torch']);
    });

    test('a timestamp that is not a plausible past time falls through to the '
        'debounce: unset (0), in the future, a day or more old', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      final cases = <int>[
        0,
        rig.nowSec + 3600,
        rig.nowSec - 86400,
        rig.nowSec - 86400 * 40,
      ];
      for (final ts in cases) {
        channel.performed.clear();
        rig.doubleTap(atSec: ts);
        await until(() => channel.performed.isNotEmpty, what: 'ts $ts');
        expect(channel.performed, ['torch'], reason: 'ts $ts');
        rig.advance(const Duration(seconds: 3));
      }
      expect(rig.app.logLines.where((l) => l.contains('stale')), isEmpty);
    });

    test('just inside the one-day cap is still judged stale', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.doubleTap(atSec: rig.nowSec - 86399);
      await settleMs(100);
      expect(channel.performed, isEmpty);
    });
  });

  group('debounce (2 s)', () {
    test('a second tap inside the window is dropped, even with a fresh '
        'timestamp', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.doubleTap();
      await until(() => channel.performed.length == 1);
      rig.advance(const Duration(milliseconds: 1900));
      rig.doubleTap();
      rig.doubleTap();
      await settleMs(100);
      expect(channel.performed, ['torch']);
    });

    test('a tap at 2 s runs again; the window restarts from the one that '
        'ran', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.doubleTap();
      await until(() => channel.performed.length == 1);
      rig.advance(const Duration(seconds: 2));
      rig.doubleTap();
      await until(() => channel.performed.length == 2);
      rig.advance(const Duration(milliseconds: 1500));
      rig.doubleTap(); // 1.5 s after the second: dropped
      await settleMs(100);
      expect(channel.performed, hasLength(2));
    });

    test('the debounce is per AppState: another one has its own window',
        () async {
      final a = newRig();
      await a.map(DeviceAction.torch);
      a.doubleTap();
      await until(() => channel.performed.length == 1);
      BleEngine.resetBandClaimForTest();
      final b = GestureRig(start: a.now);
      addTearDown(b.dispose);
      await b.map(DeviceAction.torch);
      b.doubleTap(); // GestureDispatcher.now now follows b, same instant
      await until(() => channel.performed.length == 2);
    });
  });
}
