// ai_prefs.dart — user control over the AI briefings + pre-sleep journaling.
//
// Same shape as NotificationPrefs: an immutable value type persisted in
// shared_preferences with load/save/copyWith. These prefs gate WHEN the
// morning/evening briefing and bedtime-journal notifications fire; whether a
// briefing can actually be generated is a separate question (the BYOK key in
// CoachConfig — checked at schedule/generate time, never duplicated here).

import 'package:shared_preferences/shared_preferences.dart';

class AiPrefs {
  final bool morningEnabled;
  final bool eveningEnabled;
  final bool journalEnabled;

  /// Fire times as minutes-from-midnight (local wall clock).
  final int morningMin;
  final int eveningMin;

  /// Pre-sleep journal prompt time. `< 0` means AUTO: ~30 min before the Sleep
  /// Coach's recommended bedtime when known, else [journalFallbackMin].
  final int journalMin;

  static const int journalAuto = -1;
  static const int journalFallbackMin = 22 * 60 + 30; // 22:30
  static const int journalBedtimeLeadMin = 30;

  const AiPrefs({
    this.morningEnabled = true,
    this.eveningEnabled = true,
    this.journalEnabled = true,
    this.morningMin = 8 * 60, // 08:00
    this.eveningMin = 20 * 60, // 20:00
    this.journalMin = journalAuto,
  });

  static const _kMorning = 'ai_morning_enabled';
  static const _kEvening = 'ai_evening_enabled';
  static const _kJournal = 'ai_journal_enabled';
  static const _kMorningMin = 'ai_morning_min';
  static const _kEveningMin = 'ai_evening_min';
  static const _kJournalMin = 'ai_journal_min';

  static Future<AiPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return AiPrefs(
      morningEnabled: p.getBool(_kMorning) ?? true,
      eveningEnabled: p.getBool(_kEvening) ?? true,
      journalEnabled: p.getBool(_kJournal) ?? true,
      morningMin: p.getInt(_kMorningMin) ?? 8 * 60,
      eveningMin: p.getInt(_kEveningMin) ?? 20 * 60,
      journalMin: p.getInt(_kJournalMin) ?? journalAuto,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kMorning, morningEnabled);
    await p.setBool(_kEvening, eveningEnabled);
    await p.setBool(_kJournal, journalEnabled);
    await p.setInt(_kMorningMin, morningMin);
    await p.setInt(_kEveningMin, eveningMin);
    await p.setInt(_kJournalMin, journalMin);
  }

  AiPrefs copyWith({
    bool? morningEnabled,
    bool? eveningEnabled,
    bool? journalEnabled,
    int? morningMin,
    int? eveningMin,
    int? journalMin,
  }) =>
      AiPrefs(
        morningEnabled: morningEnabled ?? this.morningEnabled,
        eveningEnabled: eveningEnabled ?? this.eveningEnabled,
        journalEnabled: journalEnabled ?? this.journalEnabled,
        morningMin: morningMin ?? this.morningMin,
        eveningMin: eveningMin ?? this.eveningMin,
        journalMin: journalMin ?? this.journalMin,
      );

  /// Resolved journal-prompt time (minutes-from-midnight): explicit user time,
  /// else ~30 min before the recommended bedtime, else the 22:30 fallback.
  int resolvedJournalMin({double? bedtimeMinOfDay}) {
    if (journalMin >= 0) return journalMin % 1440;
    if (bedtimeMinOfDay != null && bedtimeMinOfDay >= 0) {
      return (bedtimeMinOfDay.round() - journalBedtimeLeadMin) % 1440;
    }
    return journalFallbackMin;
  }
}
