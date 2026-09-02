// M6 -- per-device live-HR dedupe (spec-m6.md §11.3-§11.4, §13.2 test 10).

import 'package:flutter_test/flutter_test.dart';
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
}
