import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  test('startup Unknown and Resetting wait for a usable state', () async {
    final states = StreamController<String>();
    String? result;
    final ready = waitForBleAdapterState(
      states.stream,
      timeout: const Duration(seconds: 2),
    ).then((s) => result = s);
    states.add('unknown');
    states.add('turningOn');
    await Future<void>.delayed(Duration.zero);
    expect(result, isNull, reason: 'startup is not a Bluetooth-off verdict');

    states.add('on');
    await ready;
    expect(result, 'on');
    await states.close();
  });

  test('real blockers are returned without waiting for the deadline', () async {
    for (final state in ['off', 'turningOff', 'unauthorized', 'unavailable']) {
      expect(
        await waitForBleAdapterState(
          Stream.value(state),
          timeout: const Duration(seconds: 2),
        ),
        state,
      );
    }
  });

  test(
    'a startup that never completes times out as Unknown, not Off',
    () async {
      final states = StreamController<String>();
      final ready = waitForBleAdapterState(
        states.stream,
        timeout: const Duration(milliseconds: 10),
      );
      states.add('unknown');
      final result = await ready;
      expect(result, 'unknown');
      expect(classifyBleBlocker(adapterState: result), isNull);
      expect(
        states.hasListener,
        isFalse,
        reason: 'the timed-out probe must release its adapter subscription',
      );
      await states.close();
    },
  );

  test('an ended startup stream remains Unknown', () async {
    expect(
      await waitForBleAdapterState(
        Stream.value('unknown'),
        timeout: const Duration(seconds: 2),
      ),
      'unknown',
    );
  });

  test('an adapter-stream error reaches the caller', () async {
    final error = StateError('adapter unavailable');
    await expectLater(
      waitForBleAdapterState(
        Stream.error(error),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(same(error)),
    );
  });
}
