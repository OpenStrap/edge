// Tests for the pure AI notification schedule + the tap-route resolver.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/ai_prefs.dart';
import 'package:openstrap_edge/ai/reminder_plan.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/tap_router.dart';

void main() {
  group('aiReminderPlan', () {
    test('all three slots when configured, reminders on, sweep found one', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
        sweepHeadline: 'Resting heart rate 62 bpm — the highest in 41 days',
      );
      final ids = plan.map((s) => s.id).toSet();
      expect(ids, contains(NotificationService.idMorningBrief));
      expect(ids, contains(NotificationService.idEveningBrief));
      expect(ids, contains(NotificationService.idJournalLog));
    });

    test('briefing slots suppressed without a key; journal still scheduled', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: false,
        journalDoneToday: false,
        sweepHeadline: 'Steps 21,400 — the highest in 60 days',
      );
      final ids = plan.map((s) => s.id).toSet();
      expect(ids, isNot(contains(NotificationService.idMorningBrief)));
      expect(ids, isNot(contains(NotificationService.idEveningBrief)));
      expect(ids, contains(NotificationService.idJournalLog));
    });

    test('nothing scheduled when reminders are off entirely', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: false,
        aiConfigured: true,
        journalDoneToday: false,
      );
      expect(plan, isEmpty);
    });

    test('per-feature toggles honoured', () {
      final plan = aiReminderPlan(
        const AiPrefs(morningEnabled: false, journalEnabled: false),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
        sweepHeadline: 'HRV 28 ms — the lowest in 34 days',
      );
      final ids = plan.map((s) => s.id).toSet();
      expect(ids, {NotificationService.idEveningBrief});
    });

    test('journalDoneToday flags the journal slot to skip tonight', () {
      final done = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: true,
      ).firstWhere((s) => s.id == NotificationService.idJournalLog);
      expect(done.skipToday, isTrue);
    });

    test('journal fires ~30min before bedtime in AUTO mode', () {
      final slot = aiReminderPlan(
        const AiPrefs(), // journalMin defaults to AUTO
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 23 * 60, // 23:00
        journalDoneToday: false,
      ).firstWhere((s) => s.id == NotificationService.idJournalLog);
      expect(slot.hour, 22);
      expect(slot.minute, 30);
      expect(slot.route, kRouteJournalCompose);
    });

    test('explicit journal time overrides bedtime', () {
      final slot = aiReminderPlan(
        const AiPrefs(journalMin: 21 * 60 + 15),
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 23 * 60,
        journalDoneToday: false,
      ).firstWhere((s) => s.id == NotificationService.idJournalLog);
      expect(slot.hour, 21);
      expect(slot.minute, 15);
    });

    test('morning/evening carry their deep-link routes', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
        sweepHeadline: 'Readiness 31 — below your usual range',
      );
      expect(plan.firstWhere((s) => s.id == NotificationService.idMorningBrief).route,
          kRouteAiMorning);
      expect(plan.firstWhere((s) => s.id == NotificationService.idEveningBrief).route,
          kRouteAiEvening);
    });
  });

  group('the nightly sweep only interrupts when it has something', () {
    // The whole contract: a boring day is silent. A notification that fires to
    // announce that nothing happened is the loudest possible way to break it.
    test('no finding, no slot', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
      );
      expect(plan.map((s) => s.id),
          isNot(contains(NotificationService.idEveningBrief)));
    });

    test('the finding IS the body — the notification is not a promise', () {
      const headline = 'Resting heart rate 62 bpm — the highest in 41 days';
      final slot = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
        sweepHeadline: headline,
      ).firstWhere((s) => s.id == NotificationService.idEveningBrief);
      expect(slot.body, headline);
    });

    test('fires an hour before HIS bedtime, not at a fixed hour', () {
      final slot = aiReminderPlan(
        const AiPrefs(), // eveningMin default 20:00 — the fallback, not the time
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 21 * 60 + 15, // 21:15 — well clear of quiet hours
        journalDoneToday: false,
        sweepHeadline: 'x',
      ).firstWhere((s) => s.id == NotificationService.idEveningBrief);
      expect(slot.hour, 20);
      expect(slot.minute, 15);
    });

    test('evening slot is capped ahead of quiet hours, never inside them', () {
      // Learned bedtime 23:30 -> resolvedEveningMin = 22:30, which is inside
      // the default 22:00-07:00 quiet window. Regression for the bug where
      // scheduleAiReminders armed an OS notification inside quiet hours.
      final slot = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 23 * 60 + 30,
        journalDoneToday: false,
        sweepHeadline: 'x',
      ).firstWhere((s) => s.id == NotificationService.idEveningBrief);
      expect(slot.hour, 21);
      expect(slot.minute, 30);
      expect(
          const NotificationPrefs()
              .inQuietHours(slot.hour * 60 + slot.minute),
          isFalse);
    });

    test('evening slot is dropped entirely when quiet hours swallow it', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 23 * 60 + 30,
        journalDoneToday: false,
        sweepHeadline: 'x',
        quiet: const NotificationPrefs(
            quietEnabled: true, quietStartMin: 0, quietEndMin: 23 * 60 + 59),
      );
      expect(plan.map((s) => s.id),
          isNot(contains(NotificationService.idEveningBrief)));
    });

    test('a new install has no learned bedtime and gets the fallback', () {
      final slot = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
        sweepHeadline: 'x',
      ).firstWhere((s) => s.id == NotificationService.idEveningBrief);
      expect(slot.hour * 60 + slot.minute, const AiPrefs().eveningMin);
    });
  });

  group('resolveTapRoute', () {
    test('tab routes resolve to their index with no sub-screen', () {
      expect(resolveTapRoute('/today').tab, 0);
      expect(resolveTapRoute('/sleep').tab, 1);
      expect(resolveTapRoute('/today').screen, isNull);
    });

    test('AI + journal routes land on Today and request a sub-screen', () {
      final m = resolveTapRoute(kRouteAiMorning);
      expect(m.tab, 0);
      expect(m.screen, kRouteAiMorning);
      expect(resolveTapRoute(kRouteAiEvening).screen, kRouteAiEvening);
      expect(resolveTapRoute(kRouteJournalCompose).screen, kRouteJournalCompose);
    });

    test('unknown routes fall back to Today, no crash', () {
      // '/recap' used to be the example here. It is a known route now — see
      // tap_router_test — so this needs one that genuinely isn't.
      final r = resolveTapRoute('/nope/from/an/older/build');
      expect(r.tab, 0);
      expect(r.screen, isNull);
    });
  });

  group('AiPrefs', () {
    test('resolvedJournalMin: explicit > bedtime-lead > fallback', () {
      expect(const AiPrefs(journalMin: 1300).resolvedJournalMin(), 1300);
      expect(
          const AiPrefs()
              .resolvedJournalMin(bedtimeMinOfDay: 22 * 60), // 22:00
          21 * 60 + 30); // 30 min before
      expect(const AiPrefs().resolvedJournalMin(), AiPrefs.journalFallbackMin);
    });

    test('resolvedEveningMin: an hour before bedtime, else the fallback', () {
      expect(
          const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 22 * 60 + 30),
          21 * 60 + 30);
      expect(const AiPrefs().resolvedEveningMin(), 20 * 60);
      // A bedtime just after midnight must not wrap to a negative minute.
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 20), 1400);
    });

    test('resolvedEveningMin: a bedtime after 01:00 keeps the sweep tonight',
        () {
      // Bedtime 01:10 -> an hour before is 00:10 of the NEXT calendar day.
      // As a minute-of-day that is 10, and `minOfDay >= 10` is true all day,
      // so the sweep would beat the morning briefing from 00:10 onwards.
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 69.5),
          AiPrefs.eveningLatestMin);
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 3 * 60),
          AiPrefs.eveningLatestMin);
      // The latest slot is still late evening of the same calendar day.
      expect(AiPrefs.eveningLatestMin, greaterThanOrEqualTo(22 * 60));
      expect(AiPrefs.eveningLatestMin, lessThan(24 * 60));
      // An afternoon/evening bedtime is untouched.
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 23 * 60),
          22 * 60);
    });

    test('resolvedEveningMin: a day sleeper keeps a slot before bed', () {
      // Bedtime 11:00 -> 10:00. Past the morning floor, so the morning
      // briefing still gets 05:00-10:00; holding it at 23:30 would buzz
      // in the middle of that user's sleep.
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 11 * 60),
          10 * 60);
      // Bedtime 05:30 -> 04:30, before the floor: still held.
      expect(
          const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 5 * 60 + 30),
          AiPrefs.eveningLatestMin);
    });

    test('resolvedEveningMin: a bedtime just after 00:30 stops at 23:30', () {
      // Bedtime 00:50 -> 23:50, inside "evening" but ten minutes from the
      // day label rolling over; it is held at the latest slot instead.
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 50),
          AiPrefs.eveningLatestMin);
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 31),
          AiPrefs.eveningLatestMin);
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 59),
          AiPrefs.eveningLatestMin);
      // Exactly 00:30 lands on the limit itself.
      expect(const AiPrefs().resolvedEveningMin(bedtimeMinOfDay: 30),
          AiPrefs.eveningLatestMin);
    });
  });
}
