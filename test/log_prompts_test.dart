// The two prompts that ASK you to log something — medication and the daily
// check-in — as pure policy. No plugins: nothing here schedules, it only
// decides what would be scheduled and when.
//
// Three properties are pinned, because each one is a bug this app has already
// shipped:
//
//   · every new id is on NotificationService.schedulableIds. A slot absent
//     from that list is dropped silently at the gate and never fires once —
//     which is what happened to the movement nudge for its whole life.
//   · a prompt does not fire for something already logged. A reminder to take
//     a pill already taken is how people turn every notification off.
//   · the tap route resolves to a real destination. The audit found one
//     notification saying "tap to log it" that landed on a screen which did
//     not exist, and another whose route mapped to null.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/app.dart';
import 'package:openstrap_edge/ui2/app_shell.dart' show ShellDomain;
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart'
    show WellnessScreen;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/tap_router.dart';

/// A definition that existed long before any day under test, so `slotsForDay`'s
/// created-at bound never trims a slot out from under a case.
MedDef _def(String key, List<MedSchedule> schedule) => MedDef(
      key: key,
      label: key,
      doseValue: 1000,
      doseUnit: 'IU',
      schedule: schedule,
      createdAt: DateTime(2020, 1, 1).millisecondsSinceEpoch,
    );

/// One `med_dose` row in the shape `MedDb.dosesForDay` returns.
Map<String, Map<int, Map<String, Object?>>> _doses(
  String medKey,
  int slotMin, {
  bool taken = false,
  bool skipped = false,
}) =>
    {
      medKey: {
        slotMin: {
          'taken_ts': taken ? 1 : null,
          'skipped': skipped ? 1 : 0,
        }
      }
    };

void main() {
  group('the scheduler allow-list', () {
    test('takes the check-in and the whole medication band', () {
      expect(NotificationService.maySchedule(NotificationService.idCheckIn),
          isTrue);
      for (var i = 0; i < NotificationService.maxMedSlots; i++) {
        expect(
            NotificationService.maySchedule(NotificationService.idMedsBase + i),
            isTrue,
            reason: 'med slot $i');
      }
    });

    test('and still refuses the ids either side of the band', () {
      expect(NotificationService.maySchedule(NotificationService.idMedsBase - 1),
          isFalse);
      expect(
          NotificationService.maySchedule(
              NotificationService.idMedsBase + NotificationService.maxMedSlots),
          isFalse);
    });

    test('the bands are disjoint from the hydration one', () {
      for (var i = 0; i < NotificationService.maxMedSlots; i++) {
        expect(NotificationService.isWaterSlot(NotificationService.idMedsBase + i),
            isFalse);
      }
      expect(NotificationService.isMedSlot(NotificationService.idCheckIn), isFalse);
      expect(NotificationService.isMedSlot(NotificationService.idStillness), isFalse);
    });
  });

  group('the check-in knows when it has already been answered', () {
    test('any rating counts, and one is enough', () {
      for (final f in kJournalFields.where((f) => f.isRating)) {
        expect(
            NotificationCenter.checkInDone({f.key: const JournalMetricValue(3)}),
            isTrue,
            reason: f.key);
      }
    });

    test('a dose logged as it happened is not a self-report', () {
      // Water at lunchtime says nothing about whether the day has been
      // reflected on — this is the case that would otherwise silence the
      // prompt for anyone who uses the water reminder.
      expect(
          NotificationCenter.checkInDone(
              const {'water_ml': JournalMetricValue(500)}),
          isFalse);
      expect(
          NotificationCenter.checkInDone(
              const {'caffeine_mg': JournalMetricValue(200)}),
          isFalse);
      expect(NotificationCenter.checkInDone(const {}), isFalse);
    });
  });

  group('the check-in follows the person', () {
    const off = NotificationPrefs();
    const on = NotificationPrefs(checkInEnabled: true);

    test('off by default — nothing is armed for anyone who did not ask', () {
      expect(NotificationCenter.checkInMinute(off, 23 * 60), isNull);
    });

    test('an hour before the bedtime the coach learned', () {
      expect(NotificationCenter.checkInMinute(on, 21 * 60), 20 * 60);
      // A late chronotype is asked later, not at everyone else's 20:30.
      expect(NotificationCenter.checkInMinute(on, 22 * 60 + 30), 21 * 60 + 30);
    });

    test('no bedtime yet → the stated fixed fallback', () {
      expect(NotificationCenter.checkInMinute(on, null),
          NotificationCenter.checkInFallbackMin);
    });

    test('never inside the quiet window, whatever the bedtime says', () {
      // 01:00 bedtime. Minus an hour is midnight, which is the middle of the
      // window the user asked not to be interrupted in.
      final t = NotificationCenter.checkInMinute(on, 25 * 60)!;
      expect(t, 21 * 60 + 30); // quietStart 22:00, minus the half-hour margin
      expect(on.inQuietHours(t), isFalse);
    });

    test('never before the day has happened', () {
      // A 17:00 bedtime would put the prompt at 16:00.
      expect(NotificationCenter.checkInMinute(on, 17 * 60),
          NotificationCenter.checkInEarliestMin);
    });

    test('a quiet window that swallows the evening arms nothing', () {
      const all = NotificationPrefs(
          checkInEnabled: true, quietStartMin: 12 * 60, quietEndMin: 11 * 60);
      expect(NotificationCenter.checkInMinute(all, null), isNull);
    });
  });

  group('the check-in does not ask twice', () {
    const on = NotificationPrefs(checkInEnabled: true);
    final fb = NotificationCenter.checkInFallbackMin;
    final noon = DateTime(2026, 8, 20, 12, 0);
    final tonight = DateTime(2026, 8, 20, fb ~/ 60, fb % 60);
    final tomorrow = DateTime(2026, 8, 21, fb ~/ 60, fb % 60);

    test('a day already written skips tonight but still arms tomorrow', () {
      // Rated at noon, slot later today. Nothing re-arms while the app is
      // closed, so returning null here meant tomorrow was never asked either.
      expect(
          NotificationCenter.checkInSlot(on, null, doneToday: true, now: noon),
          tomorrow);
    });

    test('and tomorrow once tonight has passed', () {
      expect(
          NotificationCenter.checkInSlot(on, null,
              doneToday: true, now: DateTime(2026, 8, 20, 21, 0)),
          tomorrow);
    });

    test('an unwritten day arms tonight', () {
      expect(
          NotificationCenter.checkInSlot(on, null, doneToday: false, now: noon),
          tonight);
    });
  });

  group('the movement nudge respects quiet hours', () {
    const on = NotificationPrefs(movementEnabled: true);

    test('two hours after the last movement, in the day', () {
      expect(NotificationCenter.stillnessNudgeAt(on, DateTime(2026, 8, 20, 10)),
          DateTime(2026, 8, 20, 12));
    });

    test('not past 21:00', () {
      expect(
          NotificationCenter.stillnessNudgeAt(on, DateTime(2026, 8, 20, 19, 30)),
          isNull);
    });

    test('not inside a quiet window the user set', () {
      // 20:00-07:00: movement at 18:30 would buzz at 20:30, inside it.
      const quiet = NotificationPrefs(
          movementEnabled: true, quietStartMin: 20 * 60, quietEndMin: 7 * 60);
      expect(
          NotificationCenter.stillnessNudgeAt(
              quiet, DateTime(2026, 8, 20, 18, 30)),
          isNull);
      // A midday nap window too.
      const nap = NotificationPrefs(
          movementEnabled: true, quietStartMin: 13 * 60, quietEndMin: 15 * 60);
      expect(NotificationCenter.stillnessNudgeAt(nap, DateTime(2026, 8, 20, 12)),
          isNull);
    });
  });

  group('medication prompts come off the schedule the user typed', () {
    // A Thursday, mid-morning: the 08:00 dose is behind us, the 20:00 one is not.
    final now = DateTime(2026, 8, 20, 10, 0);
    final defs = [
      _def('d3', const [MedSchedule(8 * 60, []), MedSchedule(20 * 60, [])]),
    ];
    const on = NotificationPrefs(medsEnabled: true);

    test('off by default', () {
      expect(
          NotificationCenter.medPromptSlots(
              const NotificationPrefs(), defs, const {},
              now: now),
          isEmpty);
    });

    test('every dose still due across the horizon, soonest first', () {
      final s =
          NotificationCenter.medPromptSlots(on, defs, const {}, now: now);
      // today 20:00, then both slots on each of the next two days.
      expect(s.length, 5);
      expect(s.first.date, todayLabel(now));
      expect(s.first.slotMin, 20 * 60);
      for (var i = 1; i < s.length; i++) {
        expect(NotificationCenter.medSlotInstant(s[i])!
            .isAfter(NotificationCenter.medSlotInstant(s[i - 1])!), isTrue);
      }
    });

    test('a dose already taken is never asked for', () {
      final s = NotificationCenter.medPromptSlots(
          on, defs, _doses('d3', 20 * 60, taken: true),
          now: now);
      expect(s.length, 4);
      expect(s.where((x) => x.date == todayLabel(now)), isEmpty);
    });

    test('a dose deliberately skipped is not asked for either', () {
      final s = NotificationCenter.medPromptSlots(
          on, defs, _doses('d3', 20 * 60, skipped: true),
          now: now);
      expect(s.where((x) => x.date == todayLabel(now)), isEmpty);
    });

    test('a dose that already came due today is not chased', () {
      // The 08:00 slot is a miss, not an upcoming dose. Arming it would be a
      // notification about a thing that is over — the same "yesterday's news"
      // rule emitOncePerDay carries.
      final s =
          NotificationCenter.medPromptSlots(on, defs, const {}, now: now);
      expect(
          s.where((x) => x.date == todayLabel(now) && x.slotMin == 8 * 60),
          isEmpty);
    });

    test('a weekday-restricted course only fires on its days', () {
      final mondays = [
        _def('m', const [MedSchedule(9 * 60, [DateTime.monday])])
      ];
      // Thu 20 Aug + Fri + Sat — no Monday in the horizon.
      expect(NotificationCenter.medPromptSlots(on, mondays, const {}, now: now),
          isEmpty);
      // From the Sunday, Monday is in it.
      final s = NotificationCenter.medPromptSlots(on, mondays, const {},
          now: DateTime(2026, 8, 23, 10, 0));
      expect(s.length, 1);
      expect(
          DateTime.parse(s.first.date).weekday, DateTime.monday);
    });

    test('two pills at the same minute are one interruption', () {
      final pair = [
        _def('a', const [MedSchedule(20 * 60, [])]),
        _def('b', const [MedSchedule(20 * 60, [])]),
      ];
      final s = NotificationCenter.medPromptSlots(on, pair, const {}, now: now);
      // One per day across the horizon, not two.
      expect(s.length, 3);
      expect(s.map((x) => x.date).toSet().length, 3);
    });

    test('an inactive definition is not armed', () {
      final stopped = [
        MedDef(
          key: 'x',
          label: 'x',
          active: false,
          schedule: const [MedSchedule(20 * 60, [])],
          createdAt: DateTime(2020).millisecondsSinceEpoch,
        )
      ];
      expect(NotificationCenter.medPromptSlots(on, stopped, const {}, now: now),
          isEmpty);
    });

    test('never more slots than the id band has room for', () {
      final many = [
        for (var i = 0; i < 8; i++)
          _def('m$i', [MedSchedule(11 * 60 + i, const [])]),
      ];
      final s = NotificationCenter.medPromptSlots(on, many, const {}, now: now);
      expect(s.length, NotificationService.maxMedSlots);
      // And every one of them lands on an id inside the band.
      for (var i = 0; i < s.length; i++) {
        expect(
            NotificationService.maySchedule(NotificationService.idMedsBase + i),
            isTrue);
      }
    });

    test('the instant is the day plus the minute the user entered', () {
      final s =
          NotificationCenter.medPromptSlots(on, defs, const {}, now: now).first;
      final at = NotificationCenter.medSlotInstant(s)!;
      expect(at.hour, 20);
      expect(at.minute, 0);
      expect(todayLabel(at), todayLabel(now));
      expect(at.isAfter(now), isTrue);
    });
  });

  group('both prompts have somewhere to land', () {
    test('the check-in opens the journal it is asking you to write', () {
      final t = resolveTapRoute(kRouteJournalCompose);
      expect(t.screen, kRouteJournalCompose);
      expect(screenForRoute(kRouteJournalCompose), isNotNull);
    });

    test('the medication reminder lands on Wellness, which owns the checklist',
        () {
      final t = resolveTapRoute(kRouteMeds);
      // Not the Home fallback an unknown payload gets — the route is KNOWN,
      // which is the half `/profile` and `/recap` were missing.
      expect(t.screen, kRouteMeds);
      expect(domainForRoute(kRouteMeds), ShellDomain.wellness);
      // Still pushes nothing, and that is now the WORKING answer rather than
      // the ceiling it used to be: the checklist is a sub-tab of a shell tab,
      // so anything pushed would be a second copy of Wellness over Wellness.
      // The shell asks the screen for the tab instead.
      expect(screenForRoute(kRouteMeds), isNull);
      // The number that deep link hands over. It is an index into a private
      // list, so a reorder would silently land the tap on Habits.
      expect(WellnessScreen.tabs[WellnessScreen.medsTab], 'Medication');
    });

    test('an unknown route still falls back to Home rather than crashing', () {
      expect(resolveTapRoute('/nope').tab, 0);
      expect(resolveTapRoute('/nope').screen, isNull);
    });
  });
}
