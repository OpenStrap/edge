// M6 -- per-device live-HR dedupe (spec-m6.md §11.3-§11.4, §13.2 test 10).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;

DeviceState _state(int hr, int atMs) => DeviceState()
  ..connection = 'connected'
  ..liveHr = hr
  ..liveHrAt = atMs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two devices reporting at the SAME stamp yield two samples, not one',
      () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    app.debugFeedEngineState('', _state(58, now));
    app.debugFeedEngineState('ring-A', _state(72, now));

    expect(app.liveHrTrace(''), [58]);
    expect(app.liveHrTrace('ring-A'), [72]);
  });

  test('the per-device cap evicts only its own device\'s trace', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < AppState.liveHrTraceMax + 5; i++) {
      app.debugFeedEngineState('', _state(50 + i, now + i));
    }
    app.debugFeedEngineState('ring-A', _state(99, now + 1000));

    expect(app.liveHrTrace('').length, AppState.liveHrTraceMax);
    expect(app.liveHrTrace('ring-A'), [99]);
  });

  test('liveHrDeviceId follows signal_priority and falls through to the '
      'ladder when the table is silent', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.paired = PairedDevice('r1', 's1', generation: 'gen4');
    app.device.connection = 'connected';
    final now = DateTime.now().millisecondsSinceEpoch;
    app.debugFeedEngineState('', _state(58, now));
    app.debugFeedEngineState('ring-A', _state(72, now));

    // No priority row: falls through to the physics ladder — the primary
    // band, via `rankSources`.
    expect(app.liveHrDeviceId, LocalDb.kPrimaryDeviceId);

    // Two devices ARE streaming in this fixture.
    expect(app.liveHrMultiDevice, isTrue);
  });

  test('single-device install: liveHrMultiDevice is false', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.device.connection = 'connected';
    app.debugFeedEngineState('', _state(58, DateTime.now().millisecondsSinceEpoch));
    expect(app.liveHrMultiDevice, isFalse);
  });

  group('a paired sensor reaches the same trace', () {
    const sensorId = 'hrs-0a1b2c3d';
    // flags 0x00 (no RR), 61 bpm — the plainest frame a strap sends.
    const bpmOnly = <int>[0x00, 61];

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'live_hr_dedupe_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    test('an HRS reading is a second live device, and disarm clears it',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.connection = 'connected';
      app.debugFeedEngineState(
          '', _state(58, DateTime.now().millisecondsSinceEpoch));
      expect(app.liveHrMultiDevice, isFalse);

      // The sensor's own path — no engine state, no second persistence path.
      await HrsLink.instance.ingestForTest(sensorId, [
        (DateTime.now().millisecondsSinceEpoch ~/ 1000, bpmOnly),
      ]);

      expect(app.liveHrTrace(sensorId), [61],
          reason: 'production only ever fed the primary band before this');
      expect(app.liveHrMultiDevice, isTrue);

      await HrsLink.instance.disarm();
      expect(app.liveHrTrace(sensorId), isEmpty);
      expect(app.liveHrMultiDevice, isFalse);
    });
  });
}
