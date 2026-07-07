// Widget tests for the UI-upgrade foundation: Skeleton, StateCard, Gauge /
// RingStat, and BaselineProgress. These pump (never pumpAndSettle — the shimmer
// and breathe controllers repeat forever) and assert structure + behaviour.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui/kit/skeleton.dart';
import 'package:openstrap_edge/ui/kit/state_card.dart';
import 'package:openstrap_edge/ui/kit/os_icons.dart';
import 'package:openstrap_edge/ui/kit/charts.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

void main() {
  testWidgets('Skeleton presets build and animate without error', (t) async {
    for (final w in [Skeleton.hero(), Skeleton.tileRow(rows: 2), Skeleton.chart()]) {
      await t.pumpWidget(_host(w));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(ShaderMask), findsWidgets);
    }
  });

  testWidgets('StateCard shows title + message; action fires', (t) async {
    var tapped = 0;
    await t.pumpWidget(_host(StateCard(
      icon: OsIcon.activity,
      title: 'Nothing yet',
      message: 'Wear and sync.',
      actionLabel: 'Try again',
      onAction: () => tapped++,
    )));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Nothing yet'), findsOneWidget);
    expect(find.text('Wear and sync.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await t.tap(find.text('Try again'));
    await t.pump();
    expect(tapped, 1);
  });

  testWidgets('StateCard hides action when not provided', (t) async {
    await t.pumpWidget(_host(StateCard(
      icon: OsIcon.activity,
      title: 'Empty',
      message: 'No data.',
    )));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('RingStat / Gauge render the center + reveal', (t) async {
    await t.pumpWidget(_host(const RingStat(
      t: 0.6,
      color: Colors.orange,
      size: 120,
      center: Text('60'),
    )));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('60'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('Gauge with low confidence + target does not throw', (t) async {
    await t.pumpWidget(_host(const Gauge(
      t: 0.3,
      color: Colors.orange,
      confidence: 0.2,
      target: 0.8,
      zoneTint: 3,
      center: Text('x'),
    )));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('BaselineProgress.fromMetric parses need_baseline note', (t) async {
    const m = Metric(note: 'need_baseline:have=2,need=5');
    final w = BaselineProgress.fromMetric(m, unlocks: 'to unlock Readiness');
    expect(w, isNotNull);
    await t.pumpWidget(_host(w!));
    await t.pump(const Duration(milliseconds: 500));
    // remaining = 5 - 2 = 3
    expect(find.text('3'), findsOneWidget);
    expect(find.text('nights to go'), findsOneWidget);
    expect(find.text('to unlock Readiness'), findsOneWidget);
    expect(find.text('2 of 5 nights'), findsOneWidget);
  });

  testWidgets('BaselineProgress.fromMetric returns null for non-baseline note', (t) async {
    const m = Metric(note: 'something_else');
    expect(BaselineProgress.fromMetric(m), isNull);
  });
}
