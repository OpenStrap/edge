// CalmBreathingView — the guided-breathing screen's pure presentation layer.
// Regression coverage for replacing the old Random()-fabricated "coherence
// score" with real data: before a real result exists, the screen must show
// an honest "Calibrating…" state, never a placeholder number.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
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
      onStart: () => started = true,
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
