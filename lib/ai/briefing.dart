// briefing.dart — the daily AI briefing value type + its on-device cache.
//
// A Briefing is one generated summary for one local day + period (morning =
// last night's sleep/recovery; evening = today's strain/activity). It carries
// BOTH the notification-length one-liner and the short structured breakdown,
// plus the exact inputs snapshot it was generated from (so the breakdown screen
// can show "based on" metrics without re-querying, and regeneration is honest
// about what the model saw).
//
// Storage: SharedPreferences via the synchronous `Prefs` façade — one slot per
// period, newest-wins. Today's card reads it synchronously at build (no async
// flash); a stale (previous-day) slot simply reads back as null. This is a
// cache, not a record: losing it only means a regenerate.

import 'dart:convert';

import '../data/day_label.dart';
import '../state/prefs.dart';

enum BriefingPeriod { morning, evening }

extension BriefingPeriodLabel on BriefingPeriod {
  String get id => this == BriefingPeriod.morning ? 'morning' : 'evening';
  String get title =>
      this == BriefingPeriod.morning ? 'Morning briefing' : 'Evening recap';
}

/// Which period the Today card should surface right now. Mornings through the
/// afternoon show the morning briefing; from 17:00 the evening recap takes over
/// (falling back to the cached morning one until the recap exists).
BriefingPeriod currentBriefingPeriod(DateTime now) =>
    now.hour >= 17 ? BriefingPeriod.evening : BriefingPeriod.morning;

class Briefing {
  /// Local day label (YYYY-MM-DD) the briefing belongs to.
  final String day;
  final BriefingPeriod period;

  /// Notification-length single sentence (plain text, no markdown).
  final String oneLiner;

  /// Short structured markdown breakdown (a few bullets — not an essay).
  final String breakdownMd;

  final int generatedAtMs;

  /// The compact metric snapshot the prompt was built from (only fields that
  /// were actually present — absent metrics are never fabricated).
  final Map<String, dynamic> inputs;

  const Briefing({
    required this.day,
    required this.period,
    required this.oneLiner,
    required this.breakdownMd,
    required this.generatedAtMs,
    required this.inputs,
  });

  Map<String, dynamic> toJson() => {
        'day': day,
        'period': period.id,
        'one_liner': oneLiner,
        'breakdown_md': breakdownMd,
        'generated_at_ms': generatedAtMs,
        'inputs': inputs,
      };

  static Briefing? fromJson(dynamic j) {
    if (j is! Map) return null;
    final day = j['day'];
    final one = j['one_liner'];
    if (day is! String || one is! String) return null;
    return Briefing(
      day: day,
      period: j['period'] == 'evening'
          ? BriefingPeriod.evening
          : BriefingPeriod.morning,
      oneLiner: one,
      breakdownMd: (j['breakdown_md'] as String?) ?? '',
      generatedAtMs: (j['generated_at_ms'] as num?)?.toInt() ?? 0,
      inputs: j['inputs'] is Map
          ? (j['inputs'] as Map).cast<String, dynamic>()
          : const {},
    );
  }
}

/// Per-day+period briefing cache + the journal "done for today" flag.
class BriefingStore {
  BriefingStore._();

  static String _slotKey(BriefingPeriod p) => 'ai.briefing.${p.id}';
  static const String _kJournalDoneDay = 'ai.journal_done_day';

  /// Synchronous read of the cached briefing for [period]. Returns null when
  /// nothing is cached or the cached slot belongs to a different day than
  /// [day] (default: today, local).
  static Briefing? read(BriefingPeriod period, {String? day}) {
    final raw = Prefs.getString(_slotKey(period), '');
    if (raw.isEmpty) return null;
    try {
      final b = Briefing.fromJson(jsonDecode(raw));
      if (b == null) return null;
      if (b.day != (day ?? todayLabel())) return null;
      return b;
    } catch (_) {
      return null;
    }
  }

  static void write(Briefing b) =>
      Prefs.setString(_slotKey(b.period), jsonEncode(b.toJson()));

  // ── journal "done for today" (suppresses tonight's pre-sleep nudge) ─────────

  static void markJournalDone([String? day]) =>
      Prefs.setString(_kJournalDoneDay, day ?? todayLabel());

  static bool journalDoneToday([String? day]) =>
      Prefs.getString(_kJournalDoneDay, '') == (day ?? todayLabel());
}
