// The band alarm screen's one piece of real logic left in the screen itself:
// the mapping that decides what it is allowed to claim about confirmation.
// (The single next-occurrence picker — and its `nextAt` arithmetic — is gone;
// the weekly schedule in state/alarm_schedule.dart is now the only thing that
// arms the band, and its occurrence math is tested there, with no widget tree
// needed.)
//
// The screen is otherwise a rendering of AppState, and its layout is covered
// by the profile goldens.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/clock_format.dart';
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

  group('a fired alarm', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    Future<void> pump(WidgetTester t, DateTime now) => t.pumpWidget(
        MaterialApp(
            home: AlarmScreenView(
                firedAt: DateTime(2026, 8, 22, 6, 30), now: now)));

    testWidgets('says it fired for the rest of that day', (t) async {
      // the next alarm is armed the moment this one fires, so without this
      // the row just swaps times and a real fire reads like a fault
      await pump(t, DateTime(2026, 8, 22, 9));
      expect(find.text('Fired at 06:30'), findsOneWidget);
    });

    testWidgets('and not the day after', (t) async {
      await pump(t, DateTime(2026, 8, 23, 9));
      expect(find.textContaining('Fired at'), findsNothing);
    });
  });

  group('the alarm screen', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    testWidgets('an alarm that passed earlier today is not later today',
        (t) async {
      // band out of range, so the spent epoch is still armed at 09:00
      await t.pumpWidget(MaterialApp(
          home: AlarmScreenView(
              armedAt: DateTime(2026, 8, 22, 7, 30),
              state: AlarmArmState.confirmed,
              now: DateTime(2026, 8, 22, 9))));
      expect(find.textContaining('In the past'), findsOneWidget);
      expect(find.text('Later today'), findsNothing);
    });

    testWidgets('one still ahead today is', (t) async {
      await t.pumpWidget(MaterialApp(
          home: AlarmScreenView(
              armedAt: DateTime(2026, 8, 22, 21),
              state: AlarmArmState.confirmed,
              now: DateTime(2026, 8, 22, 9))));
      expect(find.text('Later today'), findsOneWidget);
    });
  });

  group('the home door', () {
    // The time follows the user's clock format; pin the 24-hour one.
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

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

  group('the at-a-glance tile', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    Future<void> pump(WidgetTester t, DateTime? at, AlarmArmState s,
            {DateTime? now}) =>
        t.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (c) => alarmGlanceCard(c, at, s,
                        now: now ?? DateTime(2026, 8, 21, 22))))));

    testWidgets('no alarm says it is not set', (t) async {
      await pump(t, null, AlarmArmState.none);
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text('Set an alarm'), findsOneWidget);
    });

    testWidgets('an armed alarm shows its time, day and real state',
        (t) async {
      await pump(t, DateTime(2026, 8, 22, 7, 30), AlarmArmState.unknown);
      expect(find.text('07:30'), findsOneWidget);
      expect(find.text('Tomorrow · Not confirmed'), findsOneWidget);
    });

    testWidgets('a spent alarm does not pass as the next one', (t) async {
      await pump(t, DateTime(2026, 8, 22, 7, 30), AlarmArmState.confirmed,
          now: DateTime(2026, 8, 22, 9));
      expect(find.textContaining('Confirmed'), findsNothing);
      expect(find.text('Fired or missed'), findsOneWidget);
    });

    // Home rebuilds only on new data or a changed alarm. With the band out of
    // range neither comes, so the tile has to notice the time passing itself.
    testWidgets('turns to fired or missed when the alarm passes on screen',
        (t) async {
      final at = clock.now().add(const Duration(minutes: 5));
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (c) =>
                      alarmGlanceCard(c, at, AlarmArmState.confirmed)))));
      expect(find.textContaining('Confirmed'), findsOneWidget);

      await t.pump(const Duration(minutes: 6));
      expect(find.textContaining('Confirmed'), findsNothing);
      expect(find.text('Fired or missed'), findsOneWidget);
    });
  });
  group('the test buzz', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    // The app gets no signal when the strap stops buzzing, so the confirmation
    // may only say the command was sent, and repeat taps must not queue one
    // 4-second snackbar each and keep "buzzing" on screen long after the band
    // has stopped.
    testWidgets('says the buzz was sent, once, however often it is tapped',
        (t) async {
      final now = DateTime(2026, 8, 22, 9);
      await t.pumpWidget(MaterialApp(
          home: AlarmScreenView(
              armedAt: DateTime(2026, 8, 23, 6, 30),
              state: AlarmArmState.confirmed,
              connected: true,
              now: now,
              onTest: () async {})));
      final button = find.text('Test the buzz');
      await t.ensureVisible(button);
      for (var i = 0; i < 3; i++) {
        await t.tap(button);
        await t.pump();
      }
      await t.pump(const Duration(milliseconds: 750));
      expect(find.text('Buzz sent to the band'), findsOneWidget);
      expect(find.textContaining('Buzzing'), findsNothing);
      // One snackbar's lifetime later nothing is left waiting in the queue.
      await t.pump(const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Buzz sent to the band'), findsNothing);
    });

    testWidgets('a result that lands while the last one is leaving replaces it',
        (t) async {
      // Tap, let the message show, tap again (its exit starts), and tap a
      // third time mid-exit: only the latest may follow, not a queue of two.
      await t.pumpWidget(MaterialApp(
          home: AlarmScreenView(
              armedAt: DateTime(2026, 8, 23, 6, 30),
              state: AlarmArmState.confirmed,
              connected: true,
              now: DateTime(2026, 8, 22, 9),
              onTest: () async {})));
      final button = find.text('Test the buzz');
      await t.ensureVisible(button);
      Future<void> step(int ms) async {
        for (var i = 0; i < ms ~/ 50; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
      }

      await t.tap(button);
      await step(1000);
      await t.tap(button);
      await step(50);
      await t.tap(button);
      await step(1000);
      // The latest message is up, alone.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Buzz sent to the band'), findsOneWidget);
      // One message's enter, 4 s on screen and exit, with a second of slack;
      // a second queued message would still be showing here.
      await step(6000);
      expect(find.text('Buzz sent to the band'), findsNothing);
    });
  });
}
