import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  group('DayGraph.window', () {
    final g = DayGraph(
      dayStart: 1000,
      hr: [for (var i = 0; i < 10; i++) i.toDouble()],
      movement: [for (var i = 0; i < 10; i++) null],
      rest: const [(0, 4, C.blue)],
      work: const [(6, 9, C.orange), (9, 10, C.orange)],
    );

    test('slices every lane and re-bases the clock', () {
      final w = g.window(3, 8);
      expect(w.hr, [3, 4, 5, 6, 7]);
      expect(w.slots, 5);
      expect(w.dayStart, 1000 + 3 * 60);
    });

    test('clips spans to the window instead of dropping them', () {
      final w = g.window(3, 8);
      expect(w.rest, [(0, 1, C.blue)]);
      expect(w.work, [(3, 5, C.orange)]);
    });
  });

  group('perSecondHr', () {
    test('one slot per second, null where unrecorded, 0 is no lock', () {
      final s = perSecondHr([
        {'rec_ts': 100, 'hr': 60},
        {'rec_ts': 102, 'hr': 0},
        {'rec_ts': 103, 'hr': 62},
        {'rec_ts': 99, 'hr': 70}, // before the window
        {'rec_ts': 104, 'hr': 70}, // at the exclusive end
      ], 100, 104);
      expect(s, [60, null, null, 62]);
    });
  });

  group('heartRateMinuteRows', () {
    test('one row per stored minute, source carried, no lock skipped', () {
      final t = DateTime(2026, 8, 14, 7, 5).millisecondsSinceEpoch ~/ 1000;
      final rows = heartRateMinuteRows([
        {'t': t, 'v': 58},
        {'t': t + 60, 'v': 0},
        {'t': t + 120},
        'junk',
      ], 'band');
      expect(rows, [
        {
          'timestamp': t,
          'local_time': '2026-08-14 07:05',
          'bpm': 58,
          'source': 'band',
        },
      ]);
    });

    test('unknown provenance stays an empty cell', () {
      final rows = heartRateMinuteRows([
        {'t': 0, 'v': 60},
      ], null);
      expect(renderCsv(kHeartRateCsvColumns, rows).split('\n')[1],
          endsWith(',60,'));
    });
  });

  testWidgets('the day chart carries a zoom control and a resolution note',
      (t) async {
    final start = DateTime(2026, 8, 14).millisecondsSinceEpoch ~/ 1000;
    final g = DayGraph(
      dayStart: start,
      hr: [for (var i = 0; i < 1440; i++) 60 + (i % 20).toDouble()],
      movement: List.filled(1440, null),
    );
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
          builder: (c) => Scaffold(
              body: ListView(
                  children: timelineBody(c, TimelineData(day: '2026-08-14', graph: g))))),
    ));
    expect(find.byType(RangeSlider), findsOneWidget);
    expect(find.textContaining('1-minute averages'), findsOneWidget);
  });
}
