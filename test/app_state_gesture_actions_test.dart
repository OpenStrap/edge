// The in-app double-tap actions AppState owns: log a glass of water and mark a
// moment (both read-modify-write the day's journal through the repository
// seam). The tap travels the real engine path; the dispatcher clock is faked
// so back-to-back taps get past the debounce without sleeping.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/gestures/device_action.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_actions.db';

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

  Future<(GestureRig, FakeJournalRepo)> newRig(DeviceAction a) async {
    final rig = GestureRig();
    addTearDown(rig.dispose);
    final repo = FakeJournalRepo();
    rig.app.repo = repo;
    await rig.map(a);
    return (rig, repo);
  }

  /// One tap, past the debounce of the one before it.
  Future<void> tap(GestureRig rig) async {
    rig.advance(const Duration(seconds: 3));
    rig.doubleTap();
  }

  /// Let a finished action release its latch (it clears in a `finally` right
  /// after the haptic), so a following tap is judged on the latch alone.
  Future<void> latchSettles() => settleMs(30);

  final water = kJournalFieldsByKey['water_ml']!;
  double? waterOf(FakeJournalRepo r) =>
      r.metrics[todayLabel()]?['water_ml']?.value;

  group('log water', () {
    test('a tap adds one step of the journal field spec to today, keeps the '
        'day\'s other fields, and plays a haptic', () async {
      final (rig, repo) = await newRig(DeviceAction.logWater);
      repo.metrics[todayLabel()] = {
        'caffeine_mg': JournalMetricValue(95),
        'water_ml': JournalMetricValue(500),
      };
      await tap(rig);
      await until(() => repo.metricPosts.isNotEmpty, what: 'water write');
      await until(() => haptics.calls.isNotEmpty, what: 'haptic');
      expect(repo.metricPosts.single.date, todayLabel());
      expect(repo.metricPosts.single.fields['water_ml']!.value,
          500 + water.step);
      expect(repo.metricPosts.single.fields['caffeine_mg']!.value, 95,
          reason: 'postJournalMetrics replaces the whole day');
      expect(haptics.calls, ['HapticFeedbackType.mediumImpact']);
      expect(channel.performed, isEmpty);
    });

    test('an empty day starts from zero; repeated taps accumulate', () async {
      final (rig, repo) = await newRig(DeviceAction.logWater);
      for (var i = 1; i <= 3; i++) {
        await tap(rig);
        await until(() => repo.metricPosts.length == i, what: 'write $i');
        await latchSettles();
      }
      expect(waterOf(repo), 3 * water.step);
    });

    test('the total is clamped at the spec maximum', () async {
      final (rig, repo) = await newRig(DeviceAction.logWater);
      repo.metrics[todayLabel()] = {'water_ml': JournalMetricValue(water.max - 100)};
      await tap(rig);
      await until(() => repo.metricPosts.isNotEmpty);
      expect(waterOf(repo), water.max);
    });

    test('without a repository the tap does nothing', () async {
      final rig = GestureRig();
      addTearDown(rig.dispose);
      await rig.map(DeviceAction.logWater);
      rig.app.repo = null;
      await tap(rig);
      await settleMs(100);
      expect(haptics.calls, isEmpty);
    });

    test('a failing read clears the write latch: the next tap still logs, '
        'with no haptic for the failed one', () async {
      final (rig, repo) = await newRig(DeviceAction.logWater);
      repo.getMetricsThrows = StateError('read blew up');
      await tap(rig);
      await until(() => rig.app.logLines
          .any((l) => l.startsWith('[gesture] log water failed')));
      expect(repo.metricPosts, isEmpty);
      expect(haptics.calls, isEmpty);
      await latchSettles();
      repo.getMetricsThrows = null;
      await tap(rig);
      await until(() => repo.metricPosts.length == 1, what: 'recovered write');
      expect(waterOf(repo), water.step);
    });

    test('a failing write clears the write latch the same way', () async {
      final (rig, repo) = await newRig(DeviceAction.logWater);
      repo.postMetricsThrows = StateError('write blew up');
      await tap(rig);
      await until(() => rig.app.logLines
          .any((l) => l.startsWith('[gesture] log water failed')));
      expect(haptics.calls, isEmpty);
      await latchSettles();
      repo.postMetricsThrows = null;
      await tap(rig);
      await until(() => repo.metricPosts.length == 1);
      expect(waterOf(repo), water.step,
          reason: 'the failed write stored nothing, so no glass is counted');
    });

    test('a tap that lands while the previous write is still in flight is '
        'dropped by the latch, so no glass is lost or double-counted',
        () async {
      final (rig, repo) = await newRig(DeviceAction.logWater);
      repo.metricsReadGate = Completer<void>();
      await tap(rig);
      await until(() => repo.calls.contains('getJournalMetrics'));
      await tap(rig); // past the debounce, first write still blocked
      await tap(rig);
      await settleMs(100);
      expect(repo.calls.where((c) => c == 'getJournalMetrics'), hasLength(1));
      repo.metricsReadGate!.complete();
      await until(() => repo.metricPosts.length == 1);
      await settleMs(100);
      expect(repo.metricPosts, hasLength(1));
      expect(waterOf(repo), water.step);
      repo.metricsReadGate = null;
      await tap(rig); // the latch is back down
      await until(() => repo.metricPosts.length == 2);
      expect(waterOf(repo), 2 * water.step);
    });
  });

  group('mark moment', () {
    final stamp = RegExp(r'^moment \d\d:\d\d$');

    test('stamps a timestamped tag on today with an empty note when the day '
        'has no journal yet', () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      await tap(rig);
      await until(() => repo.journalPosts.isNotEmpty);
      await until(() => haptics.calls.isNotEmpty);
      final post = repo.journalPosts.single;
      expect(post.date, todayLabel());
      expect(post.tags, hasLength(1));
      expect(post.tags.single, matches(stamp));
      expect(post.note, '');
      expect(repo.calls.first, 'getJournal:7d');
      expect(haptics.calls, ['HapticFeedbackType.mediumImpact']);
    });

    test('existing tags and note survive, in order; other days are not '
        'touched', () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      repo.entries.addAll([
        {'date': '2000-01-01', 'tags': ['old'], 'note': 'another day'},
        {'date': todayLabel(), 'tags': ['gym', 'sauna'], 'note': 'felt good'},
      ]);
      await tap(rig);
      await until(() => repo.journalPosts.isNotEmpty);
      final post = repo.journalPosts.single;
      expect(post.date, todayLabel());
      expect(post.tags.take(2), ['gym', 'sauna']);
      expect(post.tags, hasLength(3));
      expect(post.tags.last, matches(stamp));
      expect(post.note, 'felt good');
    });

    test('a journal read that fails starts the day clean and still posts',
        () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      repo.getJournalThrows = StateError('no journal');
      await tap(rig);
      await until(() => repo.journalPosts.isNotEmpty);
      expect(repo.journalPosts.single.tags.single, matches(stamp));
      expect(repo.journalPosts.single.note, '');
    });

    test('a failing post is logged, plays no haptic, and the next tap works',
        () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      repo.postJournalThrows = StateError('write blew up');
      await tap(rig);
      await until(() => rig.app.logLines
          .any((l) => l.startsWith('[gesture] mark moment failed')));
      expect(haptics.calls, isEmpty);
      await latchSettles();
      repo.postJournalThrows = null;
      await tap(rig);
      await until(() => repo.journalPosts.length == 1);
    });

    test('without a repository the tap does nothing', () async {
      final rig = GestureRig();
      addTearDown(rig.dispose);
      await rig.map(DeviceAction.markMoment);
      rig.app.repo = null;
      await tap(rig);
      await settleMs(100);
      expect(haptics.calls, isEmpty);
    });
  });
}
