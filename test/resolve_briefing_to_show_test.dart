// resolveBriefingToShow backs the Home "Briefing" link row (see EDGE-14 /
// PR #447). currentBriefingPeriod documents that past 17:00 it returns
// `evening` even before the evening recap exists, "falling back to the
// cached morning one until [it] exists" — a contract the row's first version
// did not honor: it just opened whatever currentBriefingPeriod said, so
// after 5pm with no evening sweep written yet it showed the generic "tap to
// write" prompt and opened an empty evening screen instead of the morning
// briefing already sitting in cache (Sourcery finding on PR #447).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ai/briefing.dart';

Briefing _briefing(BriefingPeriod period, String oneLiner) => Briefing(
      day: '2026-09-20',
      period: period,
      oneLiner: oneLiner,
      breakdownMd: '',
      generatedAtMs: 0,
      inputs: const {},
    );

void main() {
  test('morning, before 17:00: the morning briefing is used as-is', () {
    final morning = _briefing(BriefingPeriod.morning, 'slept well');
    final result =
        resolveBriefingToShow(BriefingPeriod.morning, morning, morning);
    expect(result.period, BriefingPeriod.morning);
    expect(result.briefing, morning);
  });

  test('evening, recap already written: the evening briefing is used', () {
    final morning = _briefing(BriefingPeriod.morning, 'slept well');
    final evening = _briefing(BriefingPeriod.evening, 'good day overall');
    final result =
        resolveBriefingToShow(BriefingPeriod.evening, evening, morning);
    expect(result.period, BriefingPeriod.evening);
    expect(result.briefing, evening);
  });

  test(
      'evening, recap not written yet, morning cached: falls back to the '
      'morning briefing', () {
    final morning = _briefing(BriefingPeriod.morning, 'slept well');
    final result =
        resolveBriefingToShow(BriefingPeriod.evening, null, morning);
    expect(result.period, BriefingPeriod.morning,
        reason: 'currentBriefingPeriod documents this exact fallback');
    expect(result.briefing, morning);
  });

  test('evening, neither written yet: stays on evening with nothing cached',
      () {
    final result = resolveBriefingToShow(BriefingPeriod.evening, null, null);
    expect(result.period, BriefingPeriod.evening,
        reason: 'the destination screen\'s own "write one now" state should '
            'open for the period the user actually asked about');
    expect(result.briefing, isNull);
  });
}
