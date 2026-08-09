// CalmBreathingView — the guided-breathing screen's pure presentation layer.
// Regression coverage for replacing the old Random()-fabricated "coherence
// score" with real data: before a real result exists, the screen must show
// an honest "Calibrating…" state, never a placeholder number.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/stress/breath_phases.dart';
import 'package:openstrap_edge/ui/stress/calm_breathing_screen.dart';

Widget _host(Widget child) {
  AppColors.active = kLightPalette;
  return MaterialApp(
    theme: buildOpenStrapTheme(kLightPalette),
    home: child,
  );
}

void main() {
  testWidgets('not connected: start button disabled, shows connect prompt',
      (tester) async {
    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: false,
      active: false,
    )));
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.text('Connect your band to start a session.'), findsOneWidget);
  });

  testWidgets('connected, not active: tapping start calls onStart',
      (tester) async {
    var started = false;
    await tester.pumpWidget(_host(CalmBreathingView(
      connected: true,
      active: false,
      onStart: ({pattern, target}) => started = true,
    )));
    await tester.tap(find.byType(FilledButton));
    expect(started, isTrue);
  });

  testWidgets(
      'active with no result yet shows an HONEST calibrating state, never a fabricated number',
      (tester) async {
    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: true,
      active: true,
      result: null,
    )));
    expect(find.text('Calibrating…'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('active with a not-ok result still shows calibrating, not a fake score',
      (tester) async {
    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: true,
      active: true,
      result: {'ok': false, 'n_beats': 5},
    )));
    expect(find.text('Calibrating…'), findsOneWidget);
  });

  testWidgets('active with a real ok result shows the real score',
      (tester) async {
    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: true,
      active: true,
      result: {'ok': true, 'score': 82, 'ratio': 4.5, 'peak_hz': 0.09},
    )));
    expect(find.text('82%'), findsOneWidget);
    expect(find.text('Calibrating…'), findsNothing);
  });

  testWidgets(
      'a view that mounts with a session ALREADY running still paces it',
      (tester) async {
    // Reachable by swiping back mid-session and re-entering: neither
    // swipe-back nor system back reaches onBack, so the session keeps running
    // and the next view mounts with active already true. Starting the clock
    // only on the false→true edge left that view frozen — no haptics, and a
    // timed session that never ended.
    final phases = <BreathPhaseKind>[];
    await tester.pumpWidget(_host(CalmBreathingView(
      connected: true,
      active: true,
      onPhaseChange: phases.add,
    )));
    // Far enough in to have crossed at least one phase boundary.
    await tester.pump(const Duration(seconds: 7));
    expect(
      phases,
      isNotEmpty,
      reason: 'the clock never started, so nothing paced',
    );
    // Settle the repeating ticker so the test can finish.
    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: true,
      active: false,
    )));
  });

  testWidgets('a remount keeps the session deadline, it does not restart it',
      (tester) async {
    // The view is rebuilt every time someone leaves the screen and comes back.
    // Timing from a local stopwatch restarted the pacing from zero and
    // reverted the length to the 2-minute default, so a five-minute session
    // re-entered at 4:00 showed 2:00 and stopped almost at once.
    var stopped = 0;
    await tester.pumpWidget(_host(CalmBreathingView(
      connected: true,
      active: true,
      startedAt: DateTime.now().subtract(const Duration(minutes: 4)),
      target: const Duration(minutes: 5),
      onStop: () => stopped++,
    )));
    await tester.pump(const Duration(seconds: 1));

    expect(stopped, 0, reason: 'a 5-minute session is not over at 4:00');
    // A minute of remaining time, not the default two.
    expect(find.text('0:59'), findsOneWidget);

    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: true,
      active: false,
    )));
  });

  testWidgets('an open-ended session stays open across a remount',
      (tester) async {
    // A null target on a RUNNING session means open-ended. Reading that as
    // "no answer" fell through to the picker's two minutes, so an open
    // session remounted past 2:00 stopped immediately.
    var stopped = 0;
    await tester.pumpWidget(_host(CalmBreathingView(
      connected: true,
      active: true,
      startedAt: DateTime.now().subtract(const Duration(minutes: 9)),
      onStop: () => stopped++,
    )));
    await tester.pump(const Duration(seconds: 1));

    expect(stopped, 0, reason: 'an open session never expires on its own');
    // Counting UP from the session start, not down from a target it never
    // had. Matched loosely because elapsed comes from the wall clock, which
    // the test's pump does not control.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('9:0'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(_host(const CalmBreathingView(
      connected: true,
      active: false,
    )));
  });

  testWidgets('tapping Stop Session calls onStop', (tester) async {
    var stopped = false;
    await tester.pumpWidget(_host(CalmBreathingView(
      connected: true,
      active: true,
      result: const {'ok': true, 'score': 70},
      onStop: () => stopped = true,
    )));
    await tester.tap(find.text('Stop Session'));
    expect(stopped, isTrue);
  });
}
