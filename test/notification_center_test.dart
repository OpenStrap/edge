// Unit tests for the notification gating + id partitioning — the pure logic that
// decides whether an event reaches the OS and which id it lands on. No plugins:
// we construct NotificationPrefs/NotificationEvent directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/tap_router.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

NotificationEvent _ev(NotifCategory c, NotifPriority p) => NotificationEvent(
      dedupeKey: '2026-06-27:${c.name}',
      category: c,
      priority: p,
      title: 't',
      body: 'b',
      date: '2026-06-27',
    );

/// The auto-detected-workout prompt exactly as `derivation_engine` emits it —
/// reminders channel, normal priority, and a route carrying the bout's id.
NotificationEvent _autoWorkout({String? route, NotifPriority? priority}) =>
    NotificationEvent(
      dedupeKey: '2026-06-27:1750000000:auto_workout',
      category: NotifCategory.reminders,
      priority: priority ?? NotifPriority.normal,
      title: 'Did you work out?',
      body: 'We spotted ~42 min of elevated activity. Tap to log it.',
      date: '2026-06-27',
      route: route ?? workoutSuggestionRoute('2026-06-27:1750000000'),
    );

void main() {
  group('quiet hours window', () {
    const p = NotificationPrefs(quietStartMin: 22 * 60, quietEndMin: 7 * 60);
    test('wraps midnight', () {
      expect(p.inQuietHours(23 * 60), isTrue); // 23:00
      expect(p.inQuietHours(2 * 60), isTrue); // 02:00
      expect(p.inQuietHours(6 * 60 + 59), isTrue); // 06:59
      expect(p.inQuietHours(7 * 60), isFalse); // 07:00 exclusive end
      expect(p.inQuietHours(12 * 60), isFalse); // noon
      expect(p.inQuietHours(22 * 60), isTrue); // 22:00 inclusive start
    });
    test('non-wrapping window', () {
      const d = NotificationPrefs(quietStartMin: 1 * 60, quietEndMin: 5 * 60);
      expect(d.inQuietHours(3 * 60), isTrue);
      expect(d.inQuietHours(6 * 60), isFalse);
      expect(d.inQuietHours(0), isFalse);
    });
    test('disabled quiet hours never matches', () {
      const d = NotificationPrefs(quietEnabled: false);
      expect(d.inQuietHours(2 * 60), isFalse);
    });
  });

  group('the four classes', () {
    test('classOf recognises exactly four, and nothing else', () {
      // The exception: health findings and the band's own failures.
      expect(classOf(_ev(NotifCategory.health, NotifPriority.critical)),
          NotifClass.exception);
      expect(classOf(_ev(NotifCategory.device, NotifPriority.normal)),
          NotifClass.exception);
      // The alarm, and only the alarm, claims reminders+critical.
      expect(classOf(_ev(NotifCategory.reminders, NotifPriority.critical)),
          NotifClass.alarm);
      // The detected workout, and it alone, claims reminders+normal — by
      // ROUTE, so the pair keeps meaning "no" for anything else that lands on
      // it. It was emitted on `recovery` and dropped: written, never told.
      expect(classOf(_autoWorkout()), NotifClass.prompt);
      // Everything that used to make up the other nineteen kinds.
      expect(classOf(_ev(NotifCategory.recovery, NotifPriority.normal)), isNull);
      expect(classOf(_ev(NotifCategory.reminders, NotifPriority.low)), isNull);
      expect(
          classOf(_ev(NotifCategory.reminders, NotifPriority.normal)), isNull);
      // The route is what opens the gate, not the channel: a new nudge on the
      // same channel is still refused.
      expect(classOf(_autoWorkout(route: '/workouts')), isNull);
      // BOTH halves, not either. The route alone was enough until now, so a
      // low-priority event carrying it walked through a gate documented as
      // reminders + NORMAL only.
      expect(classOf(_autoWorkout(priority: NotifPriority.low)), isNull);
    });

    test('the id-carrying payload is what actually gets classified', () {
      // The real emit carries `?id=…`. Every route check in the system is an
      // equality test, so a path-blind one silently classifies the live
      // notification as null — the same "written, never told" failure in a new
      // place. Both halves of the gate are checked on the real payload.
      final e = _autoWorkout();
      expect(e.route, contains('?id='));
      expect(classOf(e), NotifClass.prompt);
      expect(
          const NotificationPrefs(autoDetectEnabled: false)
              .shouldFireOs(e, 12 * 60),
          isFalse);
    });
  });

  group('the scheduler allow-list', () {
    // The OS fires a zonedSchedule with no Dart running, so shouldFireOs never
    // sees one. What may be SCHEDULED is a separate, narrower list: a slot the
    // user asked for by name, at a time or interval they picked.
    test('allows the lookback, the hydration band, the sweep and the nudge', () {
      expect(NotificationService.maySchedule(NotificationService.idWeeklyRecap),
          isTrue);
      // The movement nudge earned its place by growing an off switch
      // (NotificationPrefs.movementEnabled). Refused here for as long as it had
      // none, which is why issue #123 never fired for anyone — the cancel on
      // every foreground resume was the visible half of it.
      expect(NotificationService.maySchedule(NotificationService.idStillness),
          isTrue);
      expect(NotificationService.maySchedule(NotificationService.idEveningBrief),
          isTrue);
      for (var i = 0; i < NotificationService.maxWaterSlots; i++) {
        expect(
            NotificationService.maySchedule(NotificationService.idWaterBase + i),
            isTrue,
            reason: 'water slot $i');
      }
    });

    test('refuses everything else, including the ids either side of the band',
        () {
      for (final id in [
        // The AI journal prompt is STILL refused: the daily check-in owns
        // that moment now, and two prompts for one journal is how people
        // mute everything.
        NotificationService.idJournalLog,
        NotificationService.idLowBattery,
        NotificationService.idWaterBase - 1,
        NotificationService.idWaterBase + NotificationService.maxWaterSlots,
      ]) {
        expect(NotificationService.maySchedule(id), isFalse, reason: '$id');
      }
    });

    test('wind-down and the morning briefing earned their places', () {
      // Wind-down: armed only from a LEARNED bedtime behind its own switch
      // (NotificationCenter.windDownSlot); morning brief: only for a BYOK user
      // with their own AI morning switch on (aiReminderPlan).
      expect(
          NotificationService.maySchedule(NotificationService.idWindDown),
          isTrue);
      expect(
          NotificationService.maySchedule(NotificationService.idMorningBrief),
          isTrue);
    });
  });

  group('shouldFireOs', () {
    const p = NotificationPrefs(); // defaults: all on, quiet 22–07, override on
    test('fires outside quiet hours', () {
      expect(p.shouldFireOs(_ev(NotifCategory.device, NotifPriority.normal),
          12 * 60), isTrue);
    });
    test('suppresses non-critical inside quiet hours', () {
      // The 23:30 "band is on the charger" buzz — the reason device alerts had
      // to stop writing straight to the plugin.
      expect(p.shouldFireOs(_ev(NotifCategory.device, NotifPriority.normal),
          2 * 60), isFalse);
    });
    test('the detected-workout prompt reaches the OS, and is not shouty', () {
      final e = _autoWorkout();
      // The whole point: it fires. A test that only asserts the suggestion row
      // was written passes on the build where this never reached anyone.
      expect(p.shouldFireOs(e, 12 * 60), isTrue);
      // A prompt, not an alarm: 02:00 is not the time to ask about a workout.
      expect(p.shouldFireOs(e, 2 * 60), isFalse);
      // Unrelated reminder preferences do not disable activity prompts.
      expect(
          const NotificationPrefs(remindersEnabled: false)
              .shouldFireOs(e, 12 * 60),
          isTrue);
    });
    test('a kind that is not one of the four never fires, quiet or not', () {
      for (final minute in [2 * 60, 12 * 60]) {
        expect(
            p.shouldFireOs(
                _ev(NotifCategory.recovery, NotifPriority.normal), minute),
            isFalse);
        expect(
            p.shouldFireOs(
                _ev(NotifCategory.reminders, NotifPriority.low), minute),
            isFalse);
      }
    });
    // The auto-detect off switch (issues #102, #149). The detector has never
    // had one — the row is written, the notification is emitted, and nothing
    // anywhere could stop either.
    test('the detected-workout prompt is silenced by its own switch', () {
      const on = NotificationPrefs();
      const off = NotificationPrefs(autoDetectEnabled: false);
      const e = NotificationEvent(
        dedupeKey: '2026-06-27:auto_workout:1',
        // health, so the three-class rule is not what is being measured here:
        // the point is that the switch outranks a category that WOULD fire.
        category: NotifCategory.health,
        priority: NotifPriority.normal,
        title: 'Did you work out?',
        body: 'b',
        date: '2026-06-27',
        route: kRouteWorkoutSuggestion,
      );
      expect(on.shouldFireOs(e, 12 * 60), isTrue);
      expect(off.shouldFireOs(e, 12 * 60), isFalse);
      // and it silences nothing else
      expect(
          off.shouldFireOs(_ev(NotifCategory.health, NotifPriority.normal),
              12 * 60),
          isTrue);
    });
    test('critical overrides quiet hours when allowed', () {
      expect(p.shouldFireOs(_ev(NotifCategory.health, NotifPriority.critical),
          2 * 60), isTrue);
    });
    test('critical respects quiet hours when override is off', () {
      const d = NotificationPrefs(criticalOverridesQuiet: false);
      expect(d.shouldFireOs(_ev(NotifCategory.health, NotifPriority.critical),
          2 * 60), isFalse);
    });
    test('disabled category never fires', () {
      const d = NotificationPrefs(healthEnabled: false);
      expect(d.shouldFireOs(_ev(NotifCategory.health, NotifPriority.critical),
          12 * 60), isFalse);
      const e = NotificationPrefs(deviceEnabled: false);
      expect(e.shouldFireOs(_ev(NotifCategory.device, NotifPriority.normal),
          12 * 60), isFalse);
    });
    test('the alarm is never silenced by quiet hours or a category switch', () {
      // It is armed FOR a time inside the quiet window, and its off switch is
      // cancelling it — not a preference the user can trip by accident.
      const off = NotificationPrefs(
        remindersEnabled: false,
        criticalOverridesQuiet: false,
      );
      expect(
          off.shouldFireOs(
              _ev(NotifCategory.reminders, NotifPriority.critical), 6 * 60),
          isTrue);
    });
  });

  group('osId partitioning', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      NotificationIds.instance.resetForTest();
    });

    test('categories land in disjoint bands', () async {
      final ids = NotificationIds.instance;
      final health =
          await ids.idFor(_ev(NotifCategory.health, NotifPriority.critical));
      final recovery =
          await ids.idFor(_ev(NotifCategory.recovery, NotifPriority.normal));
      final reminders =
          await ids.idFor(_ev(NotifCategory.reminders, NotifPriority.low));
      expect(health ~/ 100000, equals(3));
      expect(recovery ~/ 100000, equals(2));
      expect(reminders ~/ 100000, equals(4));
    });
    test('same logical event yields a stable id (replace, not stack)', () async {
      final a = NotificationEvent(
          dedupeKey: '2026-06-27:illness',
          category: NotifCategory.health,
          title: 'x',
          body: 'y',
          date: '2026-06-27');
      final b = NotificationEvent(
          dedupeKey: '2026-06-27:illness',
          category: NotifCategory.health,
          title: 'different title',
          body: 'different body',
          date: '2026-06-27');
      expect(await NotificationIds.instance.idFor(a),
          equals(await NotificationIds.instance.idFor(b)));
    });
  });

  group('water interval is pickable', () {
    // 08:00–22:00 waking window, quiet hours off.
    const base = NotificationPrefs(waterEnabled: true, quietEnabled: false);
    test('every offered choice reaches the slots and changes the count', () {
      final counts = {
        for (final (min, _) in NotificationSettingsView.waterEvery)
          min: NotificationCenter.waterSlotMinutes(
                  base.copyWith(waterIntervalMin: min))
              .length,
      };
      // in bounds, and a shorter interval is never fewer slots
      for (final (min, _) in NotificationSettingsView.waterEvery) {
        expect(min, greaterThanOrEqualTo(NotificationPrefs.waterIntervalMinAllowed));
        expect(min, lessThanOrEqualTo(NotificationPrefs.waterIntervalMaxAllowed));
      }
      expect(counts[30], greaterThan(counts[120]!)); // 30m vs the 2h default
      expect(counts[120], greaterThan(counts[240]!));
      expect(counts.values.toSet().length, greaterThan(1));
    });
    test('spacing is the picked interval', () {
      final s = NotificationCenter.waterSlotMinutes(
          base.copyWith(waterIntervalMin: 90));
      expect(s.first, equals(8 * 60));
      expect(s[1] - s[0], equals(90));
    });
    test('off means no slots whatever the interval', () {
      expect(
          NotificationCenter.waterSlotMinutes(
              const NotificationPrefs(waterIntervalMin: 30)),
          isEmpty);
    });
  });
}
