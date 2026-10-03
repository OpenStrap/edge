// What goes on a clock, and what does not. `dayMoments`, `dayNotes` and
// `dayGraph` are pure, so the placement rules are testable without a database
// or a frame — and they are the rules the page is only honest because of. A
// mis-slotted sample puts a workout under the wrong hour; a missed hole draws
// a line through the time the band spent on the charger.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final int _day = DateTime(2026, 8, 14).millisecondsSinceEpoch ~/ 1000;
int _at(int h, [int m = 0]) => _day + h * 3600 + m * 60;

void main() {
  group('the day timeline places only what carries a clock', () {
    test('everything is ordered by time and nothing else', () {
      final m = dayMoments(
        timeline: {
          'day_start': _day,
          // Deliberately out of order in the input.
          'sessions': [
            {'start_ts': _at(18), 'end_ts': _at(19), 'type': 'football'},
          ],
          'sleep': [
            {'onset_ts': _day - 3600, 'wake_ts': _at(6, 30)},
          ],
          'naps': [
            {'start': _at(14), 'end': _at(14, 40), 'duration_min': 40},
          ],
        },
      );
      expect([for (final x in m) x.at], [_day - 3600, _at(14), _at(18)]);
      // The night that ended this morning started yesterday, and the page says
      // so by putting it first rather than by clipping it to midnight.
      expect(m.first.at, lessThan(_day));
    });

    test('an off-wrist gap under the floor is a dropout, not an event', () {
      final m = dayMoments(
        timeline: {'day_start': _day},
        wear: {
          'segments': [
            {'on': true, 'start': _at(0), 'end': _at(20), 'len_min': 1200},
            {'on': false, 'start': _at(20), 'end': _at(21), 'len_min': 60},
            {'on': false, 'start': _at(22), 'end': _at(22, 3), 'len_min': 3},
          ],
        },
      );
      expect(m, hasLength(1));
      expect(m.single.at, _at(20));
      // A fact about the band, not about the person: no domain colour.
      expect(m.single.color, isNull);
    });

    test('a repeated band event produces one line', () {
      final m = dayMoments(timeline: {
        'day_start': _day,
        'events': [
          {'event_id': 7, 'ts': _at(20)},
          {'event_id': 7, 'ts': _at(20)},
          {'event_id': 7, 'ts': _at(20)},
          // A different id at the same instant is a different fact.
          {'event_id': 8, 'ts': _at(20)},
          // Not in the allow-list: a bond is about the strap, not the day.
          {'event_id': 31, 'ts': _at(20)},
        ],
      });
      expect(m, hasLength(2));
    });

    test('a meal with no time is never placed, and is not lost either', () {
      const timed = FoodEntry(
          id: 'a', date: '2026-08-14', meal: 'Lunch', label: 'Soup', kcal: 300);
      final withTime = FoodEntry(
          id: 'b',
          date: '2026-08-14',
          meal: 'Lunch',
          label: 'Soup',
          atTs: _at(13),
          kcal: 300);
      expect(
        dayMoments(
            timeline: {'day_start': _day}, meals: const [timed]),
        isEmpty,
      );
      expect(
        dayMoments(timeline: {'day_start': _day}, meals: [withTime]),
        hasLength(1),
      );
      expect(dayNotes(meals: const [timed]), hasLength(1));
      expect(dayNotes(meals: [withTime]), isEmpty);
    });

    test('a bare eating occasion carries no energy figure', () {
      final m = dayMoments(timeline: {
        'day_start': _day
      }, meals: [
        FoodEntry(
            id: 'a',
            date: '2026-08-14',
            meal: 'Snack',
            label: 'Apple',
            atTs: _at(16)),
      ]);
      expect(m.single.detail, isNot(contains('kcal')));
    });

    test('a timed journal field lands at its own minute, an untimed one below',
        () {
      final m = dayMoments(
        timeline: {'day_start': _day},
        journal: const {
          'caffeine': JournalMetricValue(3, atMinuteOfDay: 16 * 60 + 40),
          'alcohol': JournalMetricValue(2),
        },
        fields: kJournalFields,
      );
      expect(m, hasLength(1));
      expect(m.single.at, _at(16, 40));
      expect(
        dayNotes(
          journal: const {
            'caffeine': JournalMetricValue(3, atMinuteOfDay: 100),
            'alcohol': JournalMetricValue(2),
          },
          fields: kJournalFields,
        ),
        hasLength(1),
      );
    });

    test('a timed journal field keeps its wall-clock minute on a DST day', () {
      // The first 23- or 25-hour day of the year in this zone, if it has one.
      DateTime? dst;
      for (var d = DateTime(2026, 1, 1); d.year == 2026;) {
        final next = DateTime(d.year, d.month, d.day + 1);
        if (next.difference(d) != const Duration(hours: 24)) {
          dst = d;
          break;
        }
        d = next;
      }
      if (dst == null) {
        markTestSkipped('no DST in this time zone');
        return;
      }
      final m = dayMoments(
        timeline: {'day_start': dst.millisecondsSinceEpoch ~/ 1000},
        journal: const {
          'caffeine': JournalMetricValue(3, atMinuteOfDay: 15 * 60),
        },
        fields: kJournalFields,
      );
      final at = DateTime.fromMillisecondsSinceEpoch(m.single.at * 1000);
      expect((at.hour, at.minute), (15, 0));
    });

    test('a journal row is read off tags_json, not tags', () {
      final n = dayNotes(journalRows: const [
        {'date': '2026-08-14', 'tags_json': '["travel","late meal"]', 'note': ''},
      ]);
      expect(n.single.detail, 'travel · late meal');
    });
  });

  _graphTests();
}

// ── the same day, drawn ───────────────────────────────────────────────────

const _gDay = '2026-08-12';
final int _gStart = localDayStartSec(_gDay)!;

int _gAt(int h, [int m = 0]) => _gStart + h * 3600 + m * 60;

Map<String, dynamic> _gTimeline({
  List<Map<String, dynamic>> hr = const [],
  List<Map<String, dynamic>> activity = const [],
  List<Map<String, dynamic>> sleep = const [],
  List<Map<String, dynamic>> naps = const [],
  List<Map<String, dynamic>> sessions = const [],
}) =>
    {
      'date': _gDay,
      'day_start': _gStart,
      'hr': hr,
      'activity': activity,
      'sleep': sleep,
      'naps': naps,
      'sessions': sessions,
    };

void _graphTests() {
  test('a day with no start is not a graph', () {
    expect(dayGraph(const {}).isEmpty, isTrue);
    expect(dayGraph(const {'day_start': 0}).isEmpty, isTrue);
  });

  test('an empty day has every lane empty and no curve', () {
    final g = dayGraph(_gTimeline());
    expect(g.hasCurve, isFalse);
    expect(g.isEmpty, isTrue);
    expect(g.slots, 1440);
  });

  group('the graph puts a sample on its own minute', () {
    test('midnight, half past one, and the last minute of the day', () {
      final g = dayGraph(_gTimeline(hr: [
        {'t': _gAt(0), 'v': 55},
        {'t': _gAt(1, 30), 'v': 62},
        {'t': _gAt(23, 59), 'v': 71},
      ]));
      expect(g.hr[0], 55);
      expect(g.hr[90], 62);
      expect(g.hr[1439], 71);
      expect(g.hr[1], isNull);
    });

    test('a sample outside the day is dropped, not clamped onto its edge', () {
      final g = dayGraph(_gTimeline(hr: [
        {'t': _gStart - 60, 'v': 50},
        {'t': _gStart + 1440 * 60, 'v': 50},
        {'t': _gAt(12), 'v': 88},
      ]));
      expect(g.hr.where((v) => v != null), hasLength(1));
      expect(g.hr[720], 88);
    });

    test('heart rate 0 is the pipeline saying no lock, not a resting heart',
        () {
      final g = dayGraph(_gTimeline(hr: [
        {'t': _gAt(3), 'v': 0},
        {'t': _gAt(4), 'v': 61},
      ]));
      expect(g.hr[180], isNull);
      expect(g.hr[240], 61);
    });

    test('a five-minute movement bucket fills five minutes and no more', () {
      final g = dayGraph(_gTimeline(activity: [
        {'t': _gAt(6), 'v': 0.4},
      ]));
      expect(g.movement.sublist(360, 365), everyElement(0.4));
      expect(g.movement[359], isNull);
      expect(g.movement[365], isNull);
    });
  });

  group('a gap is a gap', () {
    test('a hole in both lanes is one; a hole in one of them is not', () {
      final g = dayGraph(_gTimeline(
        hr: [
          {'t': _gAt(0), 'v': 60},
          {'t': _gAt(0, 2), 'v': 60},
        ],
        // Minute 1 has movement and no heart rate — a minute we were there
        // for, so it must not read as absent.
        activity: [
          {'t': _gAt(0, 1), 'v': 0.0},
        ],
      ));
      expect(g.unmeasured, [(6, 1440)]);
    });

    test('the leading and trailing holes are gaps too', () {
      final g = dayGraph(_gTimeline(hr: [
        {'t': _gAt(20, 0), 'v': 70},
        {'t': _gAt(20, 1), 'v': 70},
      ]));
      expect(g.unmeasured, [(0, 1200), (1202, 1440)]);
    });

    test('a measured zero is not a gap', () {
      final g = dayGraph(_gTimeline(activity: [
        {'t': _gAt(0), 'v': 0.0},
      ]));
      expect(g.movement[0], 0.0);
      expect(g.unmeasured, [(5, 1440)]);
    });

    test('a night we know about is not a hole, even with no curve over it', () {
      final g = dayGraph(_gTimeline(
        hr: [
          {'t': _gAt(12), 'v': 70},
        ],
        sleep: [
          {'onset_ts': _gStart - 3600, 'wake_ts': _gAt(6)},
        ],
      ));
      expect(g.unmeasured, [(360, 720), (721, 1440)]);
    });

    test('a fully covered day has no gaps at all', () {
      final g = dayGraph(_gTimeline(activity: [
        for (var m = 0; m < 1440; m += 5) {'t': _gStart + m * 60, 'v': 0.1},
      ]));
      expect(g.unmeasured, isEmpty);
    });
  });

  group('which lanes exist', () {
    test('a night that began yesterday clips to midnight, it is not dropped',
        () {
      final g = dayGraph(_gTimeline(sleep: [
        {'onset_ts': _gStart - 3600, 'wake_ts': _gAt(7, 30)},
      ]));
      expect(g.rest, hasLength(1));
      expect(g.rest.first.$1, 0);
      expect(g.rest.first.$2, 450);
    });

    test('naps join sleep in one lane and one colour', () {
      final g = dayGraph(_gTimeline(
        sleep: [
          {'onset_ts': _gAt(0), 'wake_ts': _gAt(6)},
        ],
        naps: [
          {'start': _gAt(14), 'end': _gAt(14, 40)},
        ],
      ));
      expect(g.rest, hasLength(2));
      expect(g.rest.map((r) => r.$3).toSet(), {C.blue});
      expect(g.work, isEmpty);
    });

    test('a span wholly outside the day contributes nothing', () {
      final g = dayGraph(_gTimeline(sessions: [
        {'start_ts': _gStart - 7200, 'end_ts': _gStart - 3600},
      ]));
      expect(g.work, isEmpty);
    });

    test('a workout is its own lane, in one colour whatever it was', () {
      final g = dayGraph(_gTimeline(sessions: [
        {'start_ts': _gAt(18), 'end_ts': _gAt(18, 45), 'type': 'running'},
        {'start_ts': _gAt(20), 'end_ts': _gAt(20, 30), 'type': 'yoga'},
      ]));
      expect(g.work, [(1080, 1125, C.orange), (1200, 1230, C.orange)]);
    });

    test('a zero-length or backwards span is not a lane', () {
      final g = dayGraph(_gTimeline(sessions: [
        {'start_ts': _gAt(9), 'end_ts': _gAt(9)},
        {'start_ts': _gAt(11), 'end_ts': _gAt(10)},
      ]));
      expect(g.work, isEmpty);
    });
  });

  group('the card it draws', () {
    Widget frame(TimelineData d, {double scale = 1}) => MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (c) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(body: ListView(children: timelineBody(c, d))),
            ),
          ),
        );

    TimelineData full() => TimelineData(
          day: _gDay,
          graph: dayGraph(_gTimeline(
            hr: [
              for (var m = 300; m < 1200; m++)
                {'t': _gStart + m * 60, 'v': 55 + (m % 40)},
            ],
            activity: [
              for (var m = 300; m < 1200; m += 5)
                {'t': _gStart + m * 60, 'v': (m % 10) / 10},
            ],
            sleep: [
              {'onset_ts': _gStart - 3600, 'wake_ts': _gAt(6)},
            ],
            sessions: [
              {'start_ts': _gAt(17), 'end_ts': _gAt(18)},
            ],
          )),
        );

    testWidgets('a day with no curve draws no axis', (t) async {
      await t.pumpWidget(frame(const TimelineData(day: _gDay)));
      expect(find.text('Heart rate'), findsNothing);
      expect(find.text('Nothing was recorded on this day'), findsOneWidget);
    });

    testWidgets('a day with a curve draws one axis, labelled once', (t) async {
      await t.pumpWidget(frame(full()));
      expect(find.text('Heart rate'), findsOneWidget);
      expect(find.text('bpm'), findsOneWidget);
      expect(find.text('Midnight'), findsNWidgets(2));
      expect(find.text('Noon'), findsOneWidget);
      // Every lane with something in it is named, and none that is empty.
      expect(find.text('Asleep'), findsOneWidget);
      expect(find.text('Workout'), findsOneWidget);
      expect(find.text('Moving'), findsOneWidget);
      expect(find.text('Not recorded'), findsOneWidget);
    });

    testWidgets('nothing overflows at 3.1x', (t) async {
      t.view.physicalSize = const Size(390 * 3, 4000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString());
      await t.pumpWidget(frame(full(), scale: 3.1));
      await t.pump();
      FlutterError.onError = previous;
      expect(errors.where((e) => e.contains('overflowed')), isEmpty);
    });
  });
}
