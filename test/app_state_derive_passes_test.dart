// The post-drain derive pass AppState runs for the scheduler: which engine
// calls a light and a heavy pass make, what a failure does, and exactly which
// signals (notifyListeners ticks, insightsRevision) a pass emits and in what
// order.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState make({RescoreRepo? repo}) {
    final a = AppState.forTesting();
    addTearDown(a.dispose);
    a.debugRescanRecent = (_) async => 0;
    if (repo != null) a.repo = repo;
    return a;
  }

  group('engine calls', () {
    test('a light pass asks the engine for a light run and never rescans',
        () async {
      final app = make();
      final calls = <bool>[];
      var rescans = 0;
      app.debugDeriveRun = deriveHook(calls: calls);
      app.debugRescanRecent = (_) async => rescans++;
      await app.debugAfterDrain();
      expect(calls, [false]);
      expect(rescans, 0);
    });

    test('a heavy pass runs the engine heavy, then the baseline rescan once',
        () async {
      final app = make();
      final calls = <bool>[];
      var rescans = 0;
      app.debugDeriveRun = deriveHook(calls: calls);
      app.debugRescanRecent = (_) async => rescans++;
      await app.debugAfterDrain(heavy: true);
      expect(calls, [true]);
      expect(rescans, 1);
    });

    test('the engine is handed a Profile built from the user map', () async {
      final app = make();
      Profile? seen;
      app.debugDeriveRun = (profile, {bool heavy = false, onDayDone}) async {
        seen = profile;
        return 0;
      };
      await app.debugAfterDrain();
      expect(seen, isA<Profile>());
    });

    test('the rescan is awaited: the pass stays open until it finishes',
        () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      final gate = Completer<int>();
      var entered = false;
      app.debugRescanRecent = (_) {
        entered = true;
        return gate.future;
      };
      var done = false;
      final pass = app.debugAfterDrain(heavy: true).then((_) => done = true);
      await until(() => entered, what: 'rescan entered');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse, reason: 'the scheduler job is still held');
      gate.complete(0);
      await pass;
      expect(done, isTrue);
    });
  });

  group('failures are swallowed', () {
    test('an engine failure does not throw, publishes nothing and skips the '
        'rescan', () async {
      final app = make();
      var rescans = 0;
      app.debugDeriveRun = deriveHook(throws: StateError('boom'));
      app.debugRescanRecent = (_) async => rescans++;
      final log = SignalLog(app);
      await app.debugAfterDrain(heavy: true);
      expect(log.events, isEmpty);
      expect(rescans, 0);
    });

    test('a rescan failure does not throw and leaves the pass\'s own signals '
        'in place', () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      app.debugRescanRecent = (_) async => throw StateError('rescan');
      final log = SignalLog(app);
      await app.debugAfterDrain(heavy: true);
      expect(log.events, ['r', 't']);
    });

    test('a session-rescore failure is swallowed and the pass still '
        'publishes', () async {
      final repo = RescoreRepo(throwsOnRescore: true);
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook();
      final log = SignalLog(app);
      await app.debugAfterDrain();
      expect(repo.rescoreCalls, 1);
      expect(log.events, ['r', 't']);
    });
  });

  group('session rescore', () {
    test('every pass rescores recent sessions once, light or heavy',
        () async {
      final repo = RescoreRepo(fixed: 2);
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook();
      await app.debugAfterDrain();
      await app.debugAfterDrain(heavy: true);
      expect(repo.rescoreCalls, 2);
    });

    test('with no repository the pass still runs and publishes', () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      final log = SignalLog(app);
      await app.debugAfterDrain();
      expect(log.events, ['r', 't']);
    });
  });

  group('signals', () {
    test('a pass that computed no day: one revision bump, then one tick',
        () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      final log = SignalLog(app);
      await app.debugAfterDrain();
      expect(log.events, ['r', 't']);
      expect(app.insightsRevision.value, 1);
    });

    test('one day: the day tick (first and last), then revision, then the '
        'end tick', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final log = SignalLog(app);
      await app.debugAfterDrain();
      expect(log.events, ['t', 'r', 't']);
    });

    test('days notify on the first, every third and the last only; revision '
        'moves once, at the end', () async {
      final app = make();
      app.debugDeriveRun =
          deriveHook(days: [for (var i = 7; i >= 1; i--) 'd$i']);
      final log = SignalLog(app);
      await app.debugAfterDrain();
      // Days 1, 3, 6 and 7 tick; then the revision; then the final tick.
      expect(log.events, ['t', 't', 't', 't', 'r', 't']);
      expect(app.insightsRevision.value, 1);
    });

    test('two days: first and last both tick', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
      final log = SignalLog(app);
      await app.debugAfterDrain();
      expect(log.events, ['t', 't', 'r', 't']);
    });

    test('a heavy rescan that refreshed days ticks again but does not bump '
        'the revision', () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      app.debugRescanRecent = (_) async => 3;
      final log = SignalLog(app);
      await app.debugAfterDrain(heavy: true);
      expect(log.events, ['r', 't', 't']);
      expect(app.insightsRevision.value, 1);
    });

    test('a heavy rescan that refreshed nothing adds no tick', () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      app.debugRescanRecent = (_) async => 0;
      final log = SignalLog(app);
      await app.debugAfterDrain(heavy: true);
      expect(log.events, ['r', 't']);
    });

    test('the revision is already bumped while the rescan is still running',
        () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      final gate = Completer<int>();
      app.debugRescanRecent = (_) => gate.future;
      final pass = app.debugAfterDrain(heavy: true);
      await until(() => app.insightsRevision.value == 1,
          what: 'revision bumped before the rescan finished');
      gate.complete(0);
      await pass;
      expect(app.insightsRevision.value, 1);
    });

    test('repeated passes advance the revision one per pass', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      await app.debugAfterDrain();
      await app.debugAfterDrain(heavy: true);
      expect(app.insightsRevision.value, 3);
    });
  });
}
