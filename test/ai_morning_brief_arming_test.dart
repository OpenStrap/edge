// The morning briefing arms for TODAY only — ahead of its slot, or inside the
// late-fire grace window just past it — so a later pass never arms tomorrow's
// occurrence off today's data readiness; the nightly sweep is today-only too.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/ai_prefs.dart';
import 'package:openstrap_edge/ai/reminder_plan.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';

void main() {
  List<int> armedAt(int nowMin) {
    final plan = aiReminderPlan(
      const AiPrefs(),
      remindersEnabled: const NotificationPrefs().remindersEnabled,
      aiConfigured: true,
      lastNightDataReady: true,
      journalDoneToday: false,
    ).where((s) => NotificationService.maySchedule(s.id));
    return [
      for (final s in plan)
        if (NotificationCenter.aiSlotArmable(
            s.id, s.hour * 60 + s.minute, nowMin))
          s.id,
    ];
  }

  test('morning briefing arms for today only: ahead of the slot or in grace', () {
    // Slot is 08:00; the grace window reaches 11:00.
    for (final now in [6 * 60, 7 * 60 + 59, 8 * 60, 9 * 60, 10 * 60 + 59]) {
      expect(armedAt(now), contains(NotificationService.idMorningBrief),
          reason: 'pass at minute $now');
    }
  });

  test('past the grace window the morning slot is NOT armed for tomorrow', () {
    // A pass at 14:00 must not arm tomorrow 08:00: tomorrow's readiness is
    // established by tomorrow's own pass, not reused from today.
    for (final now in [11 * 60, 12 * 60, 21 * 60, 23 * 60 + 59]) {
      expect(armedAt(now), isNot(contains(NotificationService.idMorningBrief)),
          reason: 'pass at minute $now');
    }
  });

  test('evening sweep is still today-only', () {
    const id = NotificationService.idEveningBrief;
    expect(NotificationCenter.aiSlotArmable(id, 21 * 60, 20 * 60), isTrue);
    expect(NotificationCenter.aiSlotArmable(id, 21 * 60, 21 * 60), isFalse);
    expect(NotificationCenter.aiSlotArmable(id, 21 * 60, 22 * 60), isFalse);
  });

  test('a slot just past fires late within the grace window, not tomorrow', () {
    // Sync landed at 08:30 for an 08:00 slot: fire ~now instead of next 08:00.
    final late =
        NotificationCenter.morningBriefLateFire(8 * 60, DateTime(2025, 1, 6, 8, 30));
    expect(late, isNotNull);
    expect(late!.hour, 8);
    expect(late.minute, 32);
  });

  test('a slot long past rolls to tomorrow — no 14:00 "morning" briefing', () {
    expect(
        NotificationCenter.morningBriefLateFire(8 * 60, DateTime(2025, 1, 6, 11, 0)),
        isNull);
    expect(
        NotificationCenter.morningBriefLateFire(8 * 60, DateTime(2025, 1, 6, 23, 0)),
        isNull);
  });

  test('a slot still ahead is not "late"', () {
    expect(
        NotificationCenter.morningBriefLateFire(8 * 60, DateTime(2025, 1, 6, 7, 59)),
        isNull);
  });
}
