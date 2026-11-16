import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

class _TwoWorkouts extends GuideFakeRepo {
  final deleted = <String>[];
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final data = await super.getWorkouts(range: range);
    final first = (data['workouts'] as List).single as Map<String, dynamic>;
    return {'workouts': [first, {...first, 'id': 'session-2'}]};
  }
  @override
  Future<void> deleteWorkout(String id) async { deleted.add(id); }
}

void main() {
  setUpAll(() => r2OpenDb('guide_review_regression.db'));
  tearDownAll(LocalDb.close);

  // why: bed time and falling asleep describe different sleep-window bounds.
  test('Hindi sleep guide asks for bed time in both instructions', () {
    final l = lookupAppLocalizations(const Locale('hi'));
    expect(l.guideFixTimesStep1('नींद', 'बदलें', 'खुद तय करें'), contains('बिस्तर पर कब गए'));
    expect(l.guideFixTimesAskBody, contains('बिस्तर पर कब गए'));
  });

  // why: multiple enabled days repeat Wake time; every offered row must work.
  for (final reducedMotion in [false, true]) {
    testWidgets('alarm offers both wake rows and completes on the second, reduced=$reducedMotion', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: reducedMotion);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final m = await pumpR2Scene(t, R2Scene('alarm-schedule', 'set-wake-time', page: () => AlarmScreenView(
        connected: true, schedule: fillDefaultAlarmSchedule([
          const AlarmScheduleEntry(weekday: 0, hour: 7, minute: 30),
          const AlarmScheduleEntry(weekday: 1, hour: 8, minute: 0),
        ]))), repo: GuideFakeRepo());
      await settleLiveGuide(t, frames: 30);
      expect(MediaQuery.of(t.element(find.byType(LiveGuideOverlay))).disableAnimations, reducedMotion);
      expect(m.run.currentStep?.id, 'set-wake-time');
      final rows = find.text(r2Locale.alarmWakeTimeRowTitle);
      expect(rows, findsNWidgets(2));
      await t.tapAt(t.getCenter(rows.last));
      await settleLiveGuide(t);
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(m.run.state, isA<GuideFinished>());
      await disposeR2(t, m);
    });
  }

  // why: alsoTap bins are real completion choices, not just readable controls.
  testWidgets('deleting the second workout completes the guide', (t) async {
    final repo = _TwoWorkouts();
    final m = await pumpR2Scene(t, const R2Scene('delete-workout', 'delete-session', history: true), repo: repo, size: const Size(412, 1500));
    await settleLiveGuide(t, frames: 30);
    final bins = find.bySemanticsLabel(r2Locale.workoutDeleteSessionLabel);
    expect(bins, findsNWidgets(2));
    await t.tapAt(t.getCenter(bins.last));
    await settleLiveGuide(t);
    expect(find.byType(BottomSheet), findsOneWidget);
    await t.tap(find.text('Remove'));
    await settleLiveGuide(t);
    expect(repo.deleted, ['session-2']);
    expect(m.run.state, isA<GuideFinished>());
    await disposeR2(t, m);
  });

  // why: pre-existing manual times must not hide the instructions for editing them.
  testWidgets('manual sleep starts at change times and advances after its target tap', (t) async {
    final m = await pumpR2Scene(t, const R2Scene('fix-sleep-times', 'change-times'), repo: GuideFakeRepo(sleepSource: 'manual'));
    await settleLiveGuide(t, frames: 30);
    expect(m.run.currentStep?.id, 'change-times');
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    await t.tapAt(overlay.targetRect!.center);
    await settleLiveGuide(t);
    expect(find.byType(TimePickerDialog), findsOneWidget);
    m.app.navigator.pop();
    await settleLiveGuide(t, frames: 30);
    expect(m.run.currentStep?.id, 'back-to-automatic');
    await disposeR2(t, m);
  });
}
