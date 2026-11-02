// A household routine starts in an order that keeps its two references on the
// same span: phone access, then a starting phone total from a completed flush,
// and only then the band baseline and the clock.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/step_calibration_fit.dart';
import 'package:openstrap_edge/ui2/profile/step_calibration.dart';

void main() {
  test('the band baseline is taken only after the phone total resolves',
      () async {
    final order = <String>[];
    final total = Completer<int?>();
    final started = beginCalibrationRoutine(
      category: StepCategory.everyday,
      ensurePhoneAccess: () async {
        order.add('access');
        return true;
      },
      runningTotalPlatform: true,
      startTotal: () {
        order.add('total asked');
        return total.future;
      },
      bandTotalNow: () {
        order.add('band');
        return 300;
      },
      nowMs: () => 1000,
    );
    await Future<void>.delayed(Duration.zero);
    expect(order, ['access', 'total asked']);
    total.complete(5000);
    final out = await started;
    expect(order, ['access', 'total asked', 'band']);
    expect(out.startTotal, 5000);
    expect(out.session!.bandRawSteps, 0);
  });

  test('no starting total refuses to start', () async {
    var band = false;
    final out = await beginCalibrationRoutine(
      category: StepCategory.everyday,
      ensurePhoneAccess: () async => true,
      runningTotalPlatform: true,
      startTotal: () async => null,
      bandTotalNow: () {
        band = true;
        return 0;
      },
      nowMs: () => 0,
    );
    expect(out.session, isNull);
    expect(out.refusal, RoutineStartRefusal.phoneNotReady);
    expect(band, isFalse);
  });

  test('no phone access refuses before asking for a total', () async {
    var asked = false;
    final out = await beginCalibrationRoutine(
      category: StepCategory.everyday,
      ensurePhoneAccess: () async => false,
      runningTotalPlatform: true,
      startTotal: () async {
        asked = true;
        return 1;
      },
      bandTotalNow: () => 0,
      nowMs: () => 0,
    );
    expect(out.refusal, RoutineStartRefusal.noPhoneAccess);
    expect(asked, isFalse);
  });

  test('a walk routine needs nothing from the phone', () async {
    final out = await beginCalibrationRoutine(
      category: StepCategory.brisk,
      ensurePhoneAccess: () async => fail('not asked for a walk'),
      runningTotalPlatform: true,
      startTotal: () async => fail('not asked for a walk'),
      bandTotalNow: () => 10,
      nowMs: () => 0,
    );
    expect(out.session, isNotNull);
    expect(out.refusal, isNull);
  });
}
