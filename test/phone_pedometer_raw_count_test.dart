// The calibration's household reference on Android is the step sensor's own
// running total, read at the start and end of a routine after a flush. These
// pin the Dart side of that: the value passes through, a platform without it
// (iOS) answers null, and the settle wait only happens when a flush was made.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/health/phone_pedometer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(phoneStepsChannel, null));

  test('rawCount passes the sensor total through', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      if (c.method == 'rawCount') return 12345;
      return null;
    });
    expect(await PhonePedometer().rawCount(), 12345);
  });

  test('a platform without a running total answers null', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      throw MissingPluginException();
    });
    expect(await PhonePedometer().rawCount(), isNull);
    // And flushing there reports nothing to flush rather than throwing.
    expect(await PhonePedometer().flushPending(), isNull);
  });

  test('flush is asked of the platform', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      calls.add(c.method);
      return false;
    });
    await PhonePedometer().flushPending();
    expect(calls, ['flush']);
  });

  group('the routine reference', () {
    final t = DateTime(2026, 10, 31, 12);
    Future<int?> neverRead() async => fail('must not be read');

    test('android uses the difference of two flushed totals', () async {
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: 1000,
            flush: () async => true,
            total: () async => 1240,
            interval: (_) => neverRead(),
            now: () => t,
            markEnd: (_) {},
          ),
          240);
    });

    test('android without a starting total refuses, never prorates', () async {
      var prorated = false;
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: null,
            flush: () async => true,
            total: () async => 1240,
            interval: (_) async {
              prorated = true;
              return 99;
            },
            now: () => t,
            markEnd: (_) {},
          ),
          isNull);
      expect(prorated, isFalse);
    });

    test('android without an ending total or a completed flush refuses',
        () async {
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: 1000,
            flush: () async => true,
            total: () async => null,
            interval: (_) => neverRead(),
            now: () => t,
            markEnd: (_) {},
          ),
          isNull);
      expect(
          await routinePhoneReference(
            runningTotalPlatform: true,
            startTotal: 1000,
            flush: () async => false,
            total: () async => 1240,
            interval: (_) => neverRead(),
            now: () => t,
            markEnd: (_) {},
          ),
          isNull);
    });

    test('android marks the end after the flush and before the total',
        () async {
      final order = <String>[];
      await routinePhoneReference(
        runningTotalPlatform: true,
        startTotal: 1000,
        flush: () async {
          order.add('flushed');
          return true;
        },
        total: () async {
          order.add('total');
          return 1240;
        },
        interval: (_) => neverRead(),
        now: () => t,
        markEnd: (_) => order.add('end'),
      );
      expect(order, ['flushed', 'end', 'total']);
    });

    test('elsewhere the query and the band end at the same instant', () async {
      DateTime? marked, queried;
      expect(
          await routinePhoneReference(
            runningTotalPlatform: false,
            startTotal: null,
            flush: () async => null,
            total: neverRead,
            interval: (end) async {
              queried = end;
              return 57;
            },
            now: () => t,
            markEnd: (end) => marked = end,
          ),
          57);
      expect(marked, t);
      expect(queried, t);
    });
  });

  test('a refused flush gives no total', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      if (c.method == 'flush') return false;
      if (c.method == 'rawCount') return 5000;
      return null;
    });
    expect(await PhonePedometer().flushPending(), isFalse);
    expect(await PhonePedometer().flushedTotal(), isNull);
  });

  test('a flush that completes late is still accepted', () async {
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      if (c.method == 'flush') {
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        return true;
      }
      if (c.method == 'rawCount') return 5000;
      return null;
    });
    expect(await PhonePedometer().flushedTotal(), 5000);
  });

  test('a flush that never completes is refused', () async {
    final never = Completer<Object?>();
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      if (c.method == 'flush') return never.future;
      if (c.method == 'rawCount') return 5000;
      return null;
    });
    final p = PhonePedometer(flushTimeout: const Duration(milliseconds: 200));
    expect(await p.flushPending(), isFalse);
    expect(await p.flushedTotal(), isNull);
  });

  test('access is requested even when the status reads as allowed', () async {
    // iOS reports notDetermined as allowed; only a request raises the prompt.
    final calls = <String>[];
    messenger.setMockMethodCallHandler(phoneStepsChannel, (c) async {
      calls.add(c.method);
      return true;
    });
    expect(await PhonePedometer().ensureAccess(), isTrue);
    expect(calls, contains('requestPermission'));
  });
}
