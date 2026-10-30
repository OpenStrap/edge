// A model on this device or the local network (Ollama, LM Studio) needs no API
// key, and the briefings generate for it. The reminder schedule used to gate on
// a stored key instead, so those users never got the morning briefing or the
// nightly sweep notification.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/ai_prefs.dart';
import 'package:openstrap_edge/ai/reminder_plan.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/notify/notification_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  List<int> planIds(CoachConfig? cfg) => [
        for (final s in aiReminderPlan(
          const AiPrefs(morningEnabled: true, eveningEnabled: true),
          remindersEnabled: true,
          aiConfigured: aiRemindersConfigured(cfg),
          journalDoneToday: false,
          sweepHeadline: 'HRV well below your usual',
        ))
          s.id,
      ];

  test('a keyless local endpoint arms both briefing slots', () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://192.168.1.20:11434/v1', model: 'llama3');
    expect(cfg.hasKey, isFalse);
    expect(cfg.configured, isTrue);
    expect(planIds(cfg), containsAll([
      NotificationService.idMorningBrief,
      NotificationService.idEveningBrief,
    ]));
  });

  test('a keyless cloud endpoint still arms neither', () async {
    final cfg = CoachConfig();
    await cfg.save(model: 'gpt-4o-mini');
    expect(cfg.configured, isFalse);
    final ids = planIds(cfg);
    expect(ids, isNot(contains(NotificationService.idMorningBrief)));
    expect(ids, isNot(contains(NotificationService.idEveningBrief)));
  });

  test('no coach config arms neither', () {
    final ids = planIds(null);
    expect(ids, isNot(contains(NotificationService.idMorningBrief)));
    expect(ids, isNot(contains(NotificationService.idEveningBrief)));
  });
}
