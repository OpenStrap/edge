// ScreenWake with owners: the display is held while ANY owner remains, a
// failed platform enable is retried by the next transition, and concurrent
// hold/release keep their order through the serialized chain.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('openstrap/edge_tracking');
  final calls = <bool>[];
  bool answer = true;

  setUp(() {
    ScreenWake.resetForTest();
    ScreenWake.platformOverride = 'android';
    calls.clear();
    answer = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.arguments['on'] as bool);
          return answer;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    ScreenWake.resetForTest();
  });

  test(
    'one owner releasing while another remains keeps the display held',
    () async {
      await ScreenWake.hold('workout');
      await ScreenWake.hold('ecg');
      expect(calls, [
        true,
      ], reason: 'the second hold is a no-op on the platform');
      await ScreenWake.releaseOwner('workout');
      expect(ScreenWake.isHeld, isTrue);
      expect(calls, [true]);
      await ScreenWake.releaseOwner('ecg');
      expect(ScreenWake.isHeld, isFalse);
      expect(calls, [true, false]);
    },
  );

  test(
    'a failed enable leaves the owner recorded and the next transition retries',
    () async {
      answer = false;
      await ScreenWake.hold('ecg');
      expect(ScreenWake.isHeld, isFalse);
      expect(ScreenWake.owners, {'ecg'});
      answer = true;
      await ScreenWake.hold('ecg');
      expect(ScreenWake.isHeld, isTrue);
      expect(calls, [true, true]);
    },
  );

  test('concurrent hold/release resolve in order and never end held', () async {
    final a = ScreenWake.hold('ecg');
    final b = ScreenWake.releaseOwner('ecg');
    await Future.wait([a, b]);
    expect(ScreenWake.isHeld, isFalse);
    expect(ScreenWake.owners, isEmpty);
    // The owner set is reconciled when each link of the chain runs, so a
    // hold immediately undone may never reach the platform at all — and if
    // it did, the release followed it.
    expect(calls.isEmpty || calls.last == false, isTrue);
  });

  test('releasing an owner that never held is harmless', () async {
    await ScreenWake.releaseOwner('nobody');
    expect(calls, isEmpty);
    expect(ScreenWake.isHeld, isFalse);
  });
}
