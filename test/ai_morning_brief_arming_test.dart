// The morning briefing must be armed for tomorrow by a pass that runs after
// its time today; the nightly sweep must not roll over.

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

  test('morning briefing is armed whatever time the last pass ran', () {
    for (final now in [6 * 60, 8 * 60, 9 * 60, 12 * 60, 21 * 60, 23 * 60 + 59]) {
      expect(armedAt(now), contains(NotificationService.idMorningBrief),
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
