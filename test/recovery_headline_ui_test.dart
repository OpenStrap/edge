// The recovery ring's three states and the "Updated" note, plus the contract
// that the Coach's `get_today` tool and Home read the same recovery.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/clock_format.dart' show formatClockOf;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _env(num v) =>
    {'value': v, 'confidence': .8, 'tier': 'HIGH'};

class _Repo extends LocalRepository {
  final Map<String, dynamic> today;
  _Repo(this.today);
  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
}

Future<void> _pump(WidgetTester t, HomeData d) => t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: RingTrio(d: d))),
    ));

void main() {
  testWidgets('night in progress: no number, says it scores after wake',
      (t) async {
    await _pump(
        t,
        const HomeData(
            recoveryState: 'night_in_progress',
            readiness: Metric(value: 2, confidence: .8)));
    expect(find.text('Sleeping…'), findsOneWidget);
    expect(find.textContaining('after you wake'), findsOneWidget);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('provisional: the number, marked finishing up', (t) async {
    await _pump(
        t,
        const HomeData(
            recoveryState: 'provisional',
            readiness: Metric(value: 27.6, confidence: .8)));
    expect(find.text('28'), findsOneWidget);
    expect(find.text('Finishing up'), findsOneWidget);
  });

  testWidgets('final: the number, no provisional caption, update note',
      (t) async {
    final at = DateTime(2026, 10, 8, 8, 12).millisecondsSinceEpoch;
    await _pump(
        t,
        HomeData(
            recoveryState: 'final',
            readiness: const Metric(value: 28, confidence: .8),
            readinessUpdate: {'from': 2, 'to': 28, 'at': at}));
    expect(find.text('28'), findsOneWidget);
    expect(find.text('Finishing up'), findsNothing);
    final clock = formatClockOf(DateTime.fromMillisecondsSinceEpoch(at));
    expect(find.text('Updated $clock · 2 → 28'), findsOneWidget);
  });

  group('Coach get_today and Home read the same recovery', () {
    Future<void> check(Map<String, dynamic> today, num? want) async {
      final repo = _Repo(today);
      final home = await HomeData.load(repo);
      final engine = CoachEngine(config: CoachConfig(), api: repo);
      final coach = jsonDecode(await engine.debugRunTool('get_today', {}));
      expect(home.readiness.value, want);
      expect(coach['recovery'], want);
      expect(coach['recovery_state'], home.recoveryState);
    }

    test('final (pinned) night', () async {
      await check({
        'daily': {'readiness': _env(28), 'strain': _env(4.2)},
        'status': {'today_day': '2026-10-08', 'overnight_state': 'ready'},
      }, 28);
    });

    test('provisional night', () async {
      await check({
        'daily': {
          // The held-over prior night must not leak into either reader.
          'readiness': _env(61),
          'readiness_provisional': _env(27.6),
        },
        'status': {
          'today_day': '2026-10-08',
          'overnight_state': 'building',
          'recovery_state': 'provisional',
          'showing_prior_overnight': true,
          'overnight_day': '2026-10-07',
        },
      }, 27.6);
    });
  });
}
