import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/state/gesture_controller.dart';

void main() {
  late DateTime now;
  late DateTime Function() originalNow;

  setUp(() {
    now = DateTime(2026, 10, 5, 12);
    originalNow = GestureDispatcher.now;
    GestureDispatcher.now = () => now;
  });

  tearDown(() {
    GestureDispatcher.now = originalNow;
  });

  test('routes live events through one dispatcher bound to its settings', () {
    final settings = GestureSettings()..doubleTap = DeviceAction.markMoment;
    var momentCalls = 0;
    var workoutCalls = 0;
    var waterCalls = 0;
    final controller = GestureController(
      settings: settings,
      log: (_) {},
      onMarkMoment: () async {
        momentCalls++;
      },
      onWorkoutToggle: () async {
        workoutCalls++;
      },
      onLogWater: () async {
        waterCalls++;
      },
    );

    controller.onEvent(14, now.millisecondsSinceEpoch ~/ 1000, 'first');
    expect(momentCalls, 1);
    expect(workoutCalls, 0);
    expect(waterCalls, 0);

    controller.onEvent(14, now.millisecondsSinceEpoch ~/ 1000, 'duplicate');
    expect(momentCalls, 1);

    now = now.add(const Duration(seconds: 2));
    settings.doubleTap = DeviceAction.workoutToggle;
    controller.onEvent(14, now.millisecondsSinceEpoch ~/ 1000, 'second');
    expect(momentCalls, 1);
    expect(workoutCalls, 1);

    now = now.add(const Duration(seconds: 2));
    settings.doubleTap = DeviceAction.logWater;
    controller.onEvent(14, now.millisecondsSinceEpoch ~/ 1000, 'third');
    expect(waterCalls, 1);
  });
}
