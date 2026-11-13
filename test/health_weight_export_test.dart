import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart'
    show healthDeleteTypes;
import 'package:openstrap_edge/health/health_weight_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Fx {
  final writes = <int>[]; // ts_ms written
  final failAt = <int>{};
  var devices = <Map<String, Object?>>[
    {'id': 'd1', 'adapter_id': 'thermometer'},
  ];
  var enabled = true;
  var weights = <int, num>{};
  var perm = true;
  var permCalls = 0;
  final deletedCursors = <String>[];
  final writeCalls = <int>[]; // every write attempt, failed or not
  final deletes = <int>[]; // window starts (ms) passed to deleteOwn
  Future<bool> Function()? syncEnabled;
  Future<bool> Function(String)? enabledFn;
  Future<bool?> Function()? granted;
  Future<Map<int, num>> Function(String)? loader;
  Future<void> Function(double, DateTime)? onWrite;

  Future<int> run({
    bool reset = false,
    bool forceRetry = false,
    bool Function()? stopped,
  }) => exportScaleWeighings(
    reset: reset,
    forceRetry: forceRetry,
    stopped: stopped,
    syncEnabled: syncEnabled,
    weightGranted: granted,
    loadDevices: () async => devices,
    isEnabled: enabledFn ?? (_) async => enabled,
    loadWeights: loader ?? (_) async => weights,
    deleteCursor: (n) async => deletedCursors.add(n),
    permitted: () async {
      permCalls++;
      return perm;
    },
    deleteOwn: (s, e) async {
      deletes.add(
        s.millisecondsSinceEpoch + kHealthWeightMatchWindow.inMilliseconds,
      );
      return true;
    },
    write: (kg, at) async {
      writeCalls.add(at.millisecondsSinceEpoch);
      await onWrite?.call(kg, at);
      if (failAt.contains(at.millisecondsSinceEpoch)) return false;
      writes.add(at.millisecondsSinceEpoch);
      return true;
    },
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('exportableWeighings', () {
    test('keeps plausible values ascending, skips absent/implausible', () {
      final out = exportableWeighings({
        3000: 72.4,
        1000: 71.9,
        2000: 0,
        4000: 9.9,
        5000: 300.1,
        6000: double.nan,
        7000: double.infinity,
      });
      expect(out.map((w) => w.atMs), [1000, 3000]);
      expect(out.map((w) => w.kg), [71.9, 72.4]);
    });

    test('chained band drops a household weight, keeps the chain', () {
      final out = exportableWeighings({
        1000: 70.0,
        2000: 45.0, // child: >10% off
        3000: 74.0, // within 10% of 70
        4000: 79.0, // within 10% of 74
        5000: 100.0, // adult housemate
      });
      expect(out.map((w) => w.atMs), [1000, 3000, 4000]);
    });

    test('guest seed 20 kg then user weights: re-seeds on the user run', () {
      final out = exportableWeighings({
        1000: 20.0,
        2000: 70.0,
        3000: 71.0,
        4000: 70.0,
      });
      // The seed itself stays in the chain (mirrors weighingChain).
      expect(out.map((w) => w.atMs), [1000, 2000, 3000, 4000]);
    });

    test('lasting >10% step re-seeds retroactively', () {
      final out = exportableWeighings({
        1000: 90.0,
        2000: 79.0,
        3000: 79.0,
        4000: 80.0,
        5000: 80.0,
      });
      expect(out.map((w) => w.atMs), [1000, 2000, 3000, 4000, 5000]);
    });

    test('lone outlier amid the chain is dropped', () {
      final out = exportableWeighings({1000: 70.0, 2000: 120.0, 3000: 71.0});
      expect(out.map((w) => w.atMs), [1000, 3000]);
    });

    test('two-outlier run (<3) is dropped', () {
      final out = exportableWeighings({
        1000: 70.0,
        2000: 120.0,
        3000: 121.0,
        4000: 71.0,
      });
      expect(out.map((w) => w.atMs), [1000, 4000]);
    });

    test('three mutually unrelated outliers do not re-seed', () {
      final out = exportableWeighings({
        1000: 70.0,
        2000: 120.0,
        3000: 40.0,
        4000: 200.0,
        5000: 71.0,
      });
      expect(out.map((w) => w.atMs), [1000, 5000]);
    });

    test('exported ones are filtered but still anchor the chain', () {
      final out = exportableWeighings(
        {1000: 70.0, 2000: 100.0, 3000: 71.0},
        exported: {1000},
      );
      expect(out.map((w) => w.atMs), [3000]);
    });
  });

  group('exportScaleWeighings', () {
    test('device flag off => nothing written', () async {
      final f = _Fx()
        ..enabled = false
        ..weights = {1000: 70};
      expect(await f.run(), 0);
      expect(f.writes, isEmpty);
    });

    test('only healthMeasurement devices', () async {
      final f = _Fx()
        ..devices = [
          {'id': 'w1', 'adapter_id': 'oura'},
        ]
        ..weights = {1000: 70};
      expect(await f.run(), 0);
      expect(f.writes, isEmpty);
    });

    test('late older weighing is exported later; no re-writes', () async {
      final f = _Fx()..weights = {2000: 70, 3000: 71};
      expect(await f.run(), 2);
      expect(await f.run(), 0);
      f.weights = {1000: 70.5, 2000: 70, 3000: 71};
      expect(await f.run(), 1);
      expect(f.writes, [2000, 3000, 1000]);
    });

    test('reset clears state and the legacy cursor, re-sends', () async {
      final f = _Fx()..weights = {1000: 70};
      await f.run();
      expect(await f.run(), 0);
      expect(await f.run(reset: true), 1);
      expect(f.writes, [1000, 1000]);
      expect(f.deletedCursors, contains(healthWeightCursorName('d1')));
    });

    test('failure continues to later weighings; bounded retries', () async {
      final f = _Fx()
        ..weights = {1000: 70, 2000: 71, 3000: 72}
        ..failAt.add(2000);
      expect(await f.run(), 2);
      expect(f.writes, [1000, 3000]);
      for (var i = 0; i < kMaxWeightAttempts + 3; i++) {
        await f.run();
      }
      // Tried exactly kMaxWeightAttempts times, then suppressed.
      expect(f.writeCalls.where((t) => t == 2000).length, kMaxWeightAttempts);
      f.failAt.clear();
      expect(await f.run(), 0);
      expect(f.writes, [1000, 3000]);
      expect(f.writeCalls.where((t) => t == 2000).length, kMaxWeightAttempts);
    });

    test('failure below the cap is retried and succeeds', () async {
      final f = _Fx()
        ..weights = {1000: 70}
        ..failAt.add(1000);
      await f.run();
      f.failAt.clear();
      expect(await f.run(), 1);
    });

    test('permission missing => skipped, nothing recorded', () async {
      final f = _Fx()
        ..weights = {1000: 70}
        ..perm = false;
      expect(await f.run(), 0);
      f.perm = true;
      expect(await f.run(), 1);
    });

    test('permission not consulted when nothing is pending', () async {
      final f = _Fx()..weights = {};
      await f.run();
      expect(f.permCalls, 0);
    });

    test('a hung store ends the run without burning attempts', () async {
      final f = _Fx()
        ..weights = {1000: 70, 2000: 71}
        ..failAt.addAll({1000, 2000});
      var hung = false;
      final calls = <int>[];
      final n = await exportScaleWeighings(
        loadDevices: () async => f.devices,
        isEnabled: (_) async => true,
        loadWeights: (_) async => f.weights,
        deleteCursor: (_) async {},
        stopped: () => hung,
        deleteOwn: (s, e) async => true,
        write: (kg, at) async {
          calls.add(at.millisecondsSinceEpoch);
          hung = true;
          return false;
        },
      );
      expect(n, 0);
      expect(calls, [1000]);
      final prefs = await SharedPreferences.getInstance();
      final att = prefs.getString(healthWeightAttemptsKey('d1'));
      expect(att == null || !att.contains('"1000"'), isTrue, reason: '$att');
      f.failAt.clear();
      expect(await f.run(), 2);
    });

    test('opt-out mid-drain: sync off stops everything', () async {
      final f = _Fx()..weights = {1000: 70, 2000: 71, 3000: 72};
      f.syncEnabled = () async => f.writeCalls.isEmpty;
      expect(await f.run(), 1);
      expect(f.writeCalls, [1000]);
    });

    test('opt-out mid-drain: device flag off stops that device', () async {
      final f = _Fx()
        ..devices = [
          {'id': 'd1', 'adapter_id': 'thermometer'},
          {'id': 'd2', 'adapter_id': 'thermometer'},
        ]
        ..loader = ((id) async =>
            id == 'd1' ? {1000: 70, 2000: 71} : {9000: 70});
      f.enabledFn = (_) async => f.writeCalls.isEmpty;
      // Flag flips off after the first write; d2 shares the adapter flag.
      expect(await f.run(), 1);
      expect(f.writeCalls, [1000]);
    });

    test('one throwing device does not end the others', () async {
      final f = _Fx()
        ..devices = [
          {'id': 'd1', 'adapter_id': 'thermometer'},
          {'id': 'd2', 'adapter_id': 'thermometer'},
        ]
        ..loader = ((id) async =>
            id == 'd1' ? throw StateError('boom') : {5000: 70});
      expect(await f.run(), 1);
      expect(f.writes, [5000]);
    });

    test('exported floor does not swallow a failed pending weighing', () async {
      final f = _Fx()..weights = {100: 70, 200: 70};
      SharedPreferences.setMockInitialValues({
        healthWeightExportedKey('d1'): [
          for (var i = 0; i < kMaxExportedWeighings; i++) 10000 + i,
        ].toString(),
        healthWeightAttemptsKey('d1'): '{"100":2}',
      });
      // 100 is below the floor but failed before: retried. 200 is below the
      // floor with no attempt record: treated as trimmed, not resurrected.
      await f.run();
      expect(f.writes, [100]);
    });

    test('attempt entries for vanished weighings are pruned', () async {
      SharedPreferences.setMockInitialValues({
        healthWeightAttemptsKey('d1'): '{"100":2,"1000":3}',
      });
      final f = _Fx()..weights = {1000: 70};
      f.failAt.add(1000);
      await f.run();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(healthWeightAttemptsKey('d1')), '{"1000":4}');
    });

    test(
      'grant transition clears the caps; no transition keeps them',
      () async {
        final f = _Fx()
          ..weights = {1000: 70}
          ..failAt.add(1000);
        for (var i = 0; i < kMaxWeightAttempts; i++) {
          await f.run();
        }
        expect(f.writeCalls.length, kMaxWeightAttempts);
        f.failAt.clear();
        f.granted = () async => false;
        expect(await f.run(), 0); // still capped
        f.granted = () async => null;
        expect(await f.run(), 0);
        f.granted = () async => true;
        expect(await f.run(), 1); // not-granted -> granted: retried
        expect(f.writes, [1000]);
      },
    );

    test('forceRetry clears the caps', () async {
      final f = _Fx()
        ..weights = {1000: 70}
        ..failAt.add(1000);
      for (var i = 0; i < kMaxWeightAttempts; i++) {
        await f.run();
      }
      f.failAt.clear();
      expect(await f.run(), 0);
      expect(await f.run(forceRetry: true), 1);
    });

    test('per-run cap: the rest stays pending for the next drain', () async {
      final f = _Fx()
        ..weights = {
          for (var i = 0; i < kMaxWeighingsPerRun + 5; i++)
            10000 + i * 1000: 70,
        };
      expect(await f.run(), kMaxWeighingsPerRun);
      expect(await f.run(), 5);
      expect(await f.run(), 0);
    });

    test('a reset is not capped: every weighing gets delete-then-write', () async {
      final f = _Fx()
        ..weights = {
          for (var i = 0; i < kMaxWeighingsPerRun + 5; i++)
            10000 + i * 1000: 70,
        };
      expect(await f.run(), kMaxWeighingsPerRun);
      expect(await f.run(reset: true), kMaxWeighingsPerRun + 5);
    });
  });

  group('delete safety', () {
    test(
      'normal run never deletes; reset deletes only a safe instant',
      () async {
        final f = _Fx()..weights = {1000: 70, 5000: 70};
        await f.run();
        expect(f.deletes, isEmpty);
        await f.run(reset: true);
        expect(f.deletes, [1000, 5000]);
      },
    );

    test(
      'reset does not delete when another scale sample is in the window',
      () async {
        final f = _Fx()
          ..devices = [
            {'id': 'd1', 'adapter_id': 'thermometer'},
            {'id': 'd2', 'adapter_id': 'thermometer'},
          ]
          ..loader = ((id) async =>
              id == 'd1' ? {1000: 70, 5000: 70} : {1300: 71});
        await f.run(reset: true);
        // 1000 and 1300 are 300 ms apart: neither is deleted; 5000 is.
        expect(f.deletes, [5000]);
        expect(f.writes.toSet(), {1000, 1300, 5000});
      },
    );
  });

  group('reset keeps state it did not replace', () {
    test('two exported weighings within the window are not re-sent', () async {
      final f = _Fx()..weights = {1000: 70, 1300: 70};
      expect(await f.run(), 2);
      expect(await f.run(reset: true), 0);
      expect(f.writes, [1000, 1300]);
      expect(await f.run(), 0); // still marked exported
    });

    test('a disabled scale keeps its exported set across a reset', () async {
      final f = _Fx()..weights = {1000: 70};
      await f.run();
      f.enabled = false;
      await f.run(reset: true);
      f.enabled = true;
      expect(await f.run(), 0);
      expect(f.writes, [1000]);
    });
  });

  group('weightWritePermitted', () {
    test('a throwing check is UNKNOWN: still asks once and writes', () async {
      var asked = false;
      var requests = 0;
      Future<bool> go() => weightWritePermitted(
        check: () async => throw StateError('timeout'),
        request: () async => requests++,
        asked: () async => asked,
        markAsked: () async => asked = true,
      );
      expect(await go(), isTrue);
      expect(await go(), isTrue);
      expect(requests, 1);
    });

    test('asks at most once per install', () async {
      var asked = false;
      var requests = 0;
      Future<bool> go() => weightWritePermitted(
        check: () async => false,
        request: () async => requests++,
        asked: () async => asked,
        markAsked: () async => asked = true,
      );
      // hasPermissions is unreliable: never block the write after asking once.
      expect(await go(), isTrue);
      expect(await go(), isTrue);
      expect(requests, 1);
    });

    test('a request that throws leaves the ask unspent and skips', () async {
      var asked = false;
      expect(
        await weightWritePermitted(
          check: () async => false,
          request: () async => throw StateError('no activity'),
          asked: () async => asked,
          markAsked: () async => asked = true,
        ),
        isFalse,
      );
      expect(asked, isFalse);
    });

    test('granted after the request => true', () async {
      var granted = false;
      expect(
        await weightWritePermitted(
          check: () async => granted,
          request: () async => granted = true,
          asked: () async => false,
          markAsked: () async {},
        ),
        isTrue,
      );
    });
  });

  test('WEIGHT is not in the per-day delete/rewrite types', () {
    for (final apple in [true, false]) {
      expect(
        healthDeleteTypes(isApplePlatform: apple),
        isNot(contains(HealthDataType.WEIGHT)),
      );
    }
  });
}
