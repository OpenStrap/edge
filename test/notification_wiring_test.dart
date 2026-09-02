// Tests for the notification wiring pass: recovery-ready, step goal,
// wind-down, and the weekly lookback finding.
//
// History this pins: three of these emitted correctly for months and never
// reached anyone (recovery-ready on the dropped recovery channel; step-goal
// on the dropped reminders/low pair), one had a slot no caller ever armed
// (wind-down), and one had a schedule whose `weeklyFinding` parameter no
// caller ever passed. Each test names the contract it now holds.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/tap_router.dart';

NotificationEvent _ev(NotifCategory c, NotifPriority p, String route) =>
    NotificationEvent(
      dedupeKey: '2026-08-22:test',
      category: c,
      priority: p,
      title: 't',
      body: 'b',
      date: '2026-8-22',
      route: route,
    );

Map<String, dynamic> _day({
  required String date,
  double? rhr,
  bool unsettled = false,
  bool illness = false,
  bool anomaly = false,
  bool temp = false,
}) =>
    {
      'date': date,
      'rhr': rhr,
      'unsettled': unsettled,
      'illness': illness,
      'anomaly': anomaly,
      'temp': temp,
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('recovery-ready classification', () {
    test('the real payload is a prompt', () {
      expect(
          classOf(_ev(NotifCategory.recovery, NotifPriority.normal,
              kRouteRecovery)),
          NotifClass.prompt);
    });

    test('the channel alone stays closed — route is what opens it', () {
      // A bare /today recovery event is exactly the dead emit this wiring
      // replaces; it must stay null so nothing else rides the channel back.
      expect(classOf(_ev(NotifCategory.recovery, NotifPriority.normal, '/today')),
          isNull);
      expect(
          classOf(_ev(NotifCategory.recovery, NotifPriority.low, kRouteRecovery)),
          isNull);
    });

    test("muted by the retained recoveryEnabled switch", () {
      const off = NotificationPrefs(recoveryEnabled: false);
      expect(
          off.shouldFireOs(
              _ev(NotifCategory.recovery, NotifPriority.normal,
                  kRouteRecovery),
              12 * 60),
          isFalse);
      const on = NotificationPrefs();
      expect(
          on.shouldFireOs(
              _ev(NotifCategory.recovery, NotifPriority.normal,
                  kRouteRecovery),
              12 * 60),
          isTrue);
    });
  });

  group('step-goal classification', () {
    test('the achievement is a prompt on its own route', () {
      expect(
          classOf(_ev(NotifCategory.reminders, NotifPriority.normal,
              kRouteSteps)),
          NotifClass.prompt);
      // Low priority on the same route stays out — same narrowing the workout
      // prompt got after its low-priority walk-through.
      expect(
          classOf(
              _ev(NotifCategory.reminders, NotifPriority.low, kRouteSteps)),
          isNull);
    });

    test('silenced by stepGoalEnabled, and by quiet hours like any prompt',
        () {
      const off = NotificationPrefs(stepGoalEnabled: false);
      final e =
          _ev(NotifCategory.reminders, NotifPriority.normal, kRouteSteps);
      expect(off.shouldFireOs(e, 12 * 60), isFalse);
      expect(const NotificationPrefs().shouldFireOs(e, 2 * 60), isFalse);
    });
  });

  group('windDownSlot', () {
    test('off switch wins', () {
      expect(
          NotificationCenter.windDownSlot(
              const NotificationPrefs(windDownEnabled: false), 23 * 60),
          isNull);
    });

    test('no LEARNED bedtime means silence — never a population fallback', () {
      expect(
          NotificationCenter.windDownSlot(
              const NotificationPrefs(windDownEnabled: true), null),
          isNull);
    });

    test('fires 45 minutes before the learned bedtime, when quiet allows',
        () {
      // Learned bedtime 23:00 → raw slot 22:15 lands INSIDE the default
      // 22:00–07:00 quiet window, so it caps to half an hour before quiet
      // opens (the check-in's own rule).
      final t = NotificationCenter.windDownSlot(
          const NotificationPrefs(windDownEnabled: true), 23 * 60 + 0.0);
      expect(t, 21 * 60 + 30);
    });

    test('no quiet window means the true pre-bedtime slot', () {
      final t = NotificationCenter.windDownSlot(
          const NotificationPrefs(windDownEnabled: true, quietEnabled: false),
          23 * 60 + 0.0);
      expect(t, 22 * 60 + 15);
    });

    test('a post-midnight bedtime wraps to the SAME evening', () {
      // Bedtime 00:20 → raw −25 min → wrapped 23:35 → inside quiet → capped
      // like any other late slot rather than disabling the feature.
      final t = NotificationCenter.windDownSlot(
          const NotificationPrefs(windDownEnabled: true), 20.0);
      expect(t, 21 * 60 + 30);
    });
  });

  group('alarmNightCheckSlot', () {
    test('off switch wins even with nothing armed for tonight', () {
      expect(
          NotificationCenter.alarmNightCheckSlot(
              const NotificationPrefs(alarmNightCheckEnabled: false),
              armedTonight: false,
              nowMin: 12 * 60),
          isNull);
    });

    test('an alarm armed for tonight silences it — the whole point is the gap',
        () {
      expect(
          NotificationCenter.alarmNightCheckSlot(
              const NotificationPrefs(alarmNightCheckEnabled: true),
              armedTonight: true,
              nowMin: 12 * 60),
          isNull);
    });

    test('nothing armed for tonight, before 19:00 → the 19:00 slot', () {
      expect(
          NotificationCenter.alarmNightCheckSlot(
              const NotificationPrefs(alarmNightCheckEnabled: true),
              armedTonight: false,
              nowMin: 12 * 60),
          NotificationCenter.alarmNightCheckHour * 60);
    });

    test('after 19:00 today, nothing is armed — a one-shot would land a day '
        'late', () {
      expect(
          NotificationCenter.alarmNightCheckSlot(
              const NotificationPrefs(alarmNightCheckEnabled: true),
              armedTonight: false,
              nowMin: 20 * 60),
          isNull);
    });
  });

  group('weeklyLookbackFinding', () {
    test('an empty week says nothing', () {
      expect(NotificationCenter.weeklyLookbackFinding(const []), isNull);
    });

    test('unsettled nights are excluded from every count', () {
      final f = NotificationCenter.weeklyLookbackFinding([
        _day(date: 'a', illness: true, unsettled: true),
        _day(date: 'b'),
        _day(date: 'c'),
      ]);
      expect(f, isNull, reason: 'the only flagged night was unsettled');
    });

    test('medical flags are named, per kind', () {
      final f = NotificationCenter.weeklyLookbackFinding([
        _day(date: 'a', illness: true),
        _day(date: 'b', illness: true),
        _day(date: 'c', temp: true),
        _day(date: 'd'),
      ]);
      expect(f, contains('possible illness onset ×2'));
      expect(f, contains('elevated skin temperature ×1'));
    });

    test('a quiet week with stable RHR says nothing', () {
      final f = NotificationCenter.weeklyLookbackFinding([
        for (var i = 0; i < 7; i++) _day(date: '$i', rhr: 52.0),
      ]);
      expect(f, isNull);
    });

    test('a ≥3 bpm RHR drift is stated plainly, both directions', () {
      final up = NotificationCenter.weeklyLookbackFinding([
        _day(date: '1', rhr: 50), _day(date: '2', rhr: 51),
        _day(date: '3', rhr: 52), _day(date: '4', rhr: 53),
        _day(date: '5', rhr: 56), _day(date: '6', rhr: 57),
        _day(date: '7', rhr: 58),
      ]);
      expect(up, contains('higher'));
      final down = NotificationCenter.weeklyLookbackFinding([
        _day(date: '1', rhr: 58), _day(date: '2', rhr: 57),
        _day(date: '3', rhr: 56), _day(date: '4', rhr: 53),
        _day(date: '5', rhr: 50), _day(date: '6', rhr: 49),
        _day(date: '7', rhr: 48),
      ]);
      expect(down, contains('lower'));
    });

    test('too few RHR nights stays silent even if the drift looks big', () {
      final f = NotificationCenter.weeklyLookbackFinding([
        _day(date: '1', rhr: 50),
        _day(date: '2', rhr: 58),
        _day(date: '3', rhr: 50),
      ]);
      expect(f, isNull);
    });
  });
}
