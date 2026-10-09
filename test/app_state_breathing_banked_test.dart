// A breathing session that IS banked. The rule is "at least 60 s of wall
// clock", read from the session's clock (AppState.breathingNow, a test-only
// replacement for DateTime.now), so this file moves a virtual clock past the
// minute and checks everything that depends on it:
//
//   A  a resonance session in a pre / post quiet window, with a target:
//      seconds clamped to the target, coherence + confidence taken from the
//      last recompute, stop AWAITS the insert (the window's UPDATE lands on
//      that row), and closing the window writes pre / post RMSSD from the
//      frames each stretch buffered;
//   B  an open-ended session on a pattern the score is not rated for, no
//      window: the full elapsed seconds, coherence and confidence NULL (a
//      score exists but is not rated for this pattern), insert off the stop
//      path.
//
// Both run side by side on two AppStates over the one stretch of virtual time,
// and a third and fourth pin the 59.999 s / 60 s boundary. A last test pins
// that a window around a session too short to bank has nothing to attach to.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_breathing_banked.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    await workoutDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    spies.dispose();
    await workoutDbTearDown(_db);
  });

  test('a session of a minute or more is banked, clamped to its target, '
      'scored only for a rated pattern, with the windows attached', () async {
    var clock = DateTime.utc(2026, 10, 5, 8);
    DateTime now() => clock;
    final probe = TimerProbe();
    await probe.run(() async {
      final hr = hr28Frame(7);
      void feed(AppState app, int n) {
        for (var i = 0; i < n; i++) {
          app.debugOnLiveFrame(0x28, hr, 1790000000 + i);
        }
      }

      final rated = kBreathPatterns.firstWhere((p) => p.coherenceRated);
      final unrated = kBreathPatterns.firstWhere((p) => !p.coherenceRated);

      // A: window, then a rated session with a one-minute target.
      final a = AppState.forTesting()..breathingNow = now;
      final repoA = BreathRepo();
      a.repo = repoA;
      a.device.connection = 'connected';
      await a.openBreathingWindow();
      feed(a, 3); // the PRE window
      await a.startBreathingSession(
          pattern: rated, target: const Duration(seconds: 60));
      final aStarted = a.breathingStartedAt!.millisecondsSinceEpoch;
      feed(a, 5); // the paced block
      final aTimer = probe.active(kBreathRecompute).single;
      aTimer.fire();
      await settleMs(50);
      expect(a.breathingResult!['ok'], isTrue);

      clock = clock.add(const Duration(milliseconds: 5));

      // B: no window, an unrated pattern, no target.
      final b = AppState.forTesting()..breathingNow = now;
      final repoB = BreathRepo();
      b.repo = repoB;
      b.device.connection = 'connected';
      await b.startBreathingSession(pattern: unrated);
      final bStarted = b.breathingStartedAt!.millisecondsSinceEpoch;
      feed(b, 4);
      probe.active(kBreathRecompute).last.fire();
      await settleMs(50);
      expect(b.breathingResult!['ok'], isTrue);

      // Well past A's target, so the clamp is what holds its seconds at 60.
      clock = clock.add(const Duration(milliseconds: 90500));

      await a.stopBreathingSession();
      await b.stopBreathingSession();
      // A's insert was awaited by its stop (a window is open); B's was not.
      final rowA = (await LocalDb.breathingSessions())
          .singleWhere((r) => r['started_at'] == aStarted);
      expect(rowA['pattern'], rated.key);
      expect(rowA['seconds'], 60,
          reason: 'clamped to the target: any overshoot is suspension');
      expect(rowA['coherence'], 72.0);
      expect(rowA['confidence'], 0.8);
      expect(rowA['ended_at'] - rowA['started_at'], 90505,
          reason: 'the clamp changes the banked seconds, not the end stamp');
      expect(rowA['pre_rmssd'], isNull, reason: 'the windows land on close');
      expect(rowA['post_rmssd'], isNull);

      await settleMs(100);
      final rowB = (await LocalDb.breathingSessions())
          .singleWhere((r) => r['started_at'] == bStarted);
      expect(rowB['pattern'], unrated.key);
      expect(rowB['seconds'], 90, reason: 'no target: the full elapsed seconds');
      expect(rowB['coherence'], isNull,
          reason: 'a pattern the score is not rated for banks none');
      expect(rowB['confidence'], isNull);

      // A's post window: frames after the stop, then close. spotCheck (the
      // fake repo's answer is the frame count) stands in for RMSSD.
      feed(a, 2);
      await a.closeBreathingWindow();
      final afterClose = (await LocalDb.breathingSessions())
          .singleWhere((r) => r['started_at'] == aStarted);
      expect(afterClose['pre_rmssd'], 3.0,
          reason: 'the frames the window held when pacing began');
      expect(afterClose['post_rmssd'], 2.0,
          reason: 'the paced block\'s own 5 frames are not in either window');
      expect(afterClose['seconds'], 60);

      // The boundary: 59.999 s is not a session, 60 s exactly is.
      final c = AppState.forTesting()..breathingNow = now;
      c.repo = BreathRepo();
      c.device.connection = 'connected';
      await c.startBreathingSession(pattern: unrated);
      final cStarted = c.breathingStartedAt!.millisecondsSinceEpoch;
      clock = clock.add(const Duration(milliseconds: 59999));
      await c.stopBreathingSession();

      clock = clock.add(const Duration(seconds: 1));
      final d = AppState.forTesting()..breathingNow = now;
      d.repo = BreathRepo();
      d.device.connection = 'connected';
      await d.startBreathingSession(pattern: unrated);
      final dStarted = d.breathingStartedAt!.millisecondsSinceEpoch;
      clock = clock.add(const Duration(seconds: 60));
      await d.stopBreathingSession();

      await settleMs(100);
      final rows = await LocalDb.breathingSessions();
      expect(rows.where((r) => r['started_at'] == cStarted), isEmpty,
          reason: 'one millisecond short of a minute banks nothing');
      expect(
          rows.singleWhere((r) => r['started_at'] == dStarted)['seconds'], 60);

      await finish(a);
      await finish(b);
      await finish(c);
      await finish(d);
    });
  });

  test('a window around a session too short to bank has nothing to attach '
      'to: closing it writes no pre / post pair and no row exists', () async {
    var clock = DateTime.utc(2026, 10, 5, 9);
    final app = AppState.forTesting()..breathingNow = () => clock;
    app.repo = BreathRepo();
    app.device.connection = 'connected';
    await app.openBreathingWindow();
    feedFrames(app, 0x28, hr28Frame(), 3);
    await app.startBreathingSession(
        pattern: kBreathPatterns.firstWhere((p) => !p.coherenceRated));
    feedFrames(app, 0x28, hr28Frame(), 2);
    clock = clock.add(const Duration(seconds: 30));
    await app.stopBreathingSession();
    feedFrames(app, 0x28, hr28Frame(), 2);
    await app.closeBreathingWindow();
    await settleMs(100);
    expect(await LocalDb.breathingSessions(), isEmpty);
    await finish(app);
  });
}
