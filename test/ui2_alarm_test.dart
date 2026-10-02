// The band alarm screen's one piece of real logic left in the screen itself:
// the mapping that decides what it is allowed to claim about confirmation.
// (The single next-occurrence picker — and its `nextAt` arithmetic — is gone;
// the weekly schedule in state/alarm_schedule.dart is now the only thing that
// arms the band, and its occurrence math is tested there, with no widget tree
// needed.)
//
// The screen is otherwise a rendering of AppState, and its layout is covered
// by the profile goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/profile/alarm.dart';

void main() {
  group('what the screen may claim', () {
    test('an unconfirmed alarm never says it will fire', () {
      // The band confirms separately (event 56) and might never do so; after a
      // relaunch there is no live confirmation at all, only the epoch on disk.
      for (final s in [AlarmArmState.unknown, AlarmArmState.pending]) {
        final view = AlarmScreenView(state: s, armedAt: DateTime(2026, 8, 22));
        expect(AlarmScreenView.stateLabel(s), isNot(contains('Confirmed')));
        expect(view.state, s);
      }
      expect(AlarmScreenView.stateLabel(AlarmArmState.confirmed),
          contains('Confirmed'));
    });
  });

  group('the home door', () {
    // A fixed clock: whether the alarm is still ahead is relative to now.
    Future<void> pump(WidgetTester t, DateTime? at, AlarmArmState s,
            {DateTime? now}) =>
        t.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (c) => alarmDoor(c, at, s,
                        now: now ?? DateTime(2026, 8, 21, 22))))));

    testWidgets('no alarm offers to set one', (t) async {
      await pump(t, null, AlarmArmState.none);
      expect(find.text('Set an alarm'), findsOneWidget);
    });

    testWidgets('an armed alarm shows its day, time and real state',
        (t) async {
      // 2026-08-22 is a Saturday.
      await pump(t, DateTime(2026, 8, 22, 7, 30), AlarmArmState.unknown);
      expect(find.text('Sat 07:30 · Not confirmed'), findsOneWidget);
    });

    testWidgets('a spent alarm says so instead of passing as the next one',
        (t) async {
      // Fired (or missed) while the link was down: the epoch is still saved.
      await pump(t, DateTime(2026, 8, 22, 7, 30), AlarmArmState.confirmed,
          now: DateTime(2026, 8, 22, 9));
      expect(find.textContaining('Confirmed'), findsNothing);
      expect(find.textContaining('Sat 07:30 · In the past'), findsOneWidget);
    });
  });
}
