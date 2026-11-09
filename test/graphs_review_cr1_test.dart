// Review round 1 on the Graphs PR: one test per finding that held up.
//   2  a missing statistic is spoken as "No record", not skipped
//   3  a panel with no cells draws nothing and does not throw
//   5  a screen dates its history from the day the series was built
//   6  a missing day keeps the swatch width, so the label never rewraps
//   7  a gap in a device's epochs is a gap, not the stage before it
//   8  both sleep charts share one instant, not one fraction
//   9  a night with no staging does not say "not measured"
//  10  an empty series reads empty and does not throw
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/slot_scrub.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _app(Widget home, {double scale = 1}) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester t, double h) {
  t.view.physicalSize = Size(390 * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

List<String> _spoken(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    final d = n.getSemanticsData();
    for (final s in [d.label, d.value]) {
      if (s.isNotEmpty) out.add(s);
    }
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return out;
}

void main() {
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  group('ChartPanel', () {
    testWidgets('a statistic with no value is spoken as No record (finding 2)',
        (t) async {
      final h = t.ensureSemantics();
      _phone(t, 800);
      await t.pumpWidget(_app(Scaffold(
        body: ChartPanel(
          time: 'Mon 3',
          scrubbed: false,
          color: Colors.red,
          cells: const [ChartPanelCell('Resting heart rate', value: '55 bpm')],
          stats: const [
            ChartPanelCell('7-day avg', value: '54 bpm'),
            ChartPanelCell('vs avg'),
          ],
        ),
      )));
      final said = _spoken(t);
      expect(said, contains('7-day avg 54 bpm'));
      expect(said, contains('vs avg No record'));
      h.dispose();
    });

    testWidgets('no cells: nothing drawn, nothing thrown (finding 3)',
        (t) async {
      _phone(t, 800);
      await t.pumpWidget(_app(Scaffold(
        body: ChartPanel(
            time: null, scrubbed: false, color: Colors.red, cells: const []),
      )));
      expect(t.takeException(), isNull);
    });

    testWidgets('a cell with no colour can reserve the swatch (finding 6)',
        (t) async {
      _phone(t, 800);
      Future<double> labelWidth(ChartPanelCell cell) async {
        await t.pumpWidget(_app(Scaffold(
          body: ChartPanel(
              time: 'x', scrubbed: false, color: Colors.red, cells: [cell]),
        )));
        return t.getSize(find.text('Recovery')).width;
      }

      final painted = await labelWidth(
          const ChartPanelCell('Recovery', color: Colors.green, value: '70'));
      final missing = await labelWidth(
          const ChartPanelCell('Recovery', reserveSwatch: true));
      expect(missing, painted);
    });
  });

  group('SlotScrub', () {
    testWidgets('an empty series builds with an empty panel (finding 10)',
        (t) async {
      _phone(t, 800);
      var built = 0;
      await t.pumpWidget(_app(Scaffold(
        body: SlotScrub(
          series: const [],
          anchor: DateTime(2026, 5, 20),
          bars: true,
          label: 'Load',
          color: Colors.red,
          format: (v) => '$v',
          builder: (c, pick, scrub, panel) {
            built++;
            return panel;
          },
        ),
      )));
      expect(t.takeException(), isNull);
      expect(built, greaterThan(0));
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('Recovery history', () {
    final anchor = DateTime.now().subtract(const Duration(days: 3));
    ReadinessData data(List<double?> s) => ReadinessData(
          readiness: const Metric(
              value: 20, unit: '', confidence: .8, tier: MetricTier.estimate),
          series: s,
          anchor: anchor,
        );
    final series = <double?>[for (var i = 0; i < 20; i++) 50, 80, 20];

    Future<void> open(WidgetTester t, ReadinessData d) async {
      _phone(t, 2400);
      await t.pumpWidget(_app(ReadinessDetail(data: d)));
      await t.pumpAndSettle();
    }

    final strip = find.byWidgetPredicate(
        (w) => w is Scrubber && w.label == 'Recovery');

    testWidgets('dates are the series\' own, three days back (finding 5)',
        (t) async {
      await open(t, data(series));
      final l = AppLocalizations.of(t.element(find.byType(ReadinessDetail)))!;
      final then = dayNavLabel(dayLabelOf(anchor), l);
      final panel = find.byKey(const ValueKey('chart-panel'));
      expect(find.descendant(of: panel, matching: find.text('LATEST · $then')),
          findsOneWidget);
      final says = t.widget<Scrubber>(strip).describe(.999);
      expect(says, startsWith(prettyDay(dayLabelOf(anchor), l)));
      final frame = t.widget<ChartFrame>(find
          .byWidgetPredicate((w) => w is ChartFrame && w.title == 'Recovery'));
      expect(frame.xLabels.last, isNot('Today'));
      expect(frame.xLabels.first, '24 days ago',
          reason: '21 slots behind the anchor, which is 3 days behind today');
    });

    testWidgets('a missing day keeps the label width a scored day has '
        '(finding 6)', (t) async {
      final s = <double?>[for (var i = 0; i < 20; i++) 50, 80, null];
      await open(t, data(s));
      double width() => t
          .getSize(find.descendant(
              of: find.byKey(const ValueKey('chart-panel')),
              matching: find.text('Recovery')))
          .width;
      double height() =>
          t.getSize(find.byKey(const ValueKey('chart-panel'))).height;
      final scored = width();
      final scoredHeight = height();
      await t.tapAt(t.getBottomRight(strip) - const Offset(1, 1));
      await t.pumpAndSettle();
      expect(width(), scored);
      // The point of the reserved swatch: the panel, and everything below it,
      // stays put when scrubbing onto a missing day.
      expect(height(), scoredHeight);
    });
  });

  group('device staging', () {
    test('a gap between epochs is an unobserved boundary (finding 7)', () {
      final h = vendorHypnogram(const [
        VendorEpoch(0, 30, 'light'),
        VendorEpoch(30, 60, 'deep'),
        VendorEpoch(90, 120, 'rem'),
      ], 150);
      expect(h, [
        {'t': 0, 'stage': 'light'},
        {'t': 30, 'stage': 'deep'},
        {'t': 60, 'stage': 'unobserved'},
        {'t': 90, 'stage': 'rem'},
        {'t': 120, 'stage': 'unobserved'},
        {'t': 150, 'stage': 'unobserved'},
      ]);
      final night = {'hypnogram': h};
      expect(SleepData.stageAt(night, 45), (true, SleepStage.deep));
      expect(SleepData.stageAt(night, 75), (true, null));
      expect(SleepData.stageAt(night, 100), (true, SleepStage.rem));
    });

    test('back-to-back epochs add nothing', () {
      expect(
          vendorHypnogram(const [
            VendorEpoch(0, 30, 'light'),
            VendorEpoch(30, 60, 'deep'),
          ], 60),
          [
            {'t': 0, 'stage': 'light'},
            {'t': 30, 'stage': 'deep'},
            {'t': 60, 'stage': 'deep'},
          ]);
    });
  });

  group('sleep charts', () {
    final onset = DateTime(2026, 5, 19, 23).millisecondsSinceEpoch ~/ 1000;
    final wake = DateTime(2026, 5, 20, 7).millisecondsSinceEpoch ~/ 1000;
    final timeline = {
      'hr': [
        {'t': onset, 'v': 50},
        {'t': onset + 14400, 'v': 58},
        {'t': wake, 'v': 66},
      ],
      'resp': [
        {'t': onset + 14400, 'v': 17.5},
      ],
    };
    Map<String, Object?> night({bool staged = true}) => {
          'duration_min': 360,
          'in_bed_min': 480,
          'efficiency': .75,
          'onset_ts': onset,
          'wake_ts': wake,
          if (staged)
            'hypnogram': [
              {'t': onset, 'stage': 'light'},
              {'t': onset + 3600, 'stage': 'deep'},
              {'t': wake, 'stage': 'deep'},
            ],
        };

    Finder plot(String label) =>
        find.byWidgetPredicate((w) => w is Scrubber && w.label == label);

    Future<void> open(WidgetTester t, SleepData d) async {
      _phone(t, 6200);
      await t.pumpWidget(_app(SleepDetail(data: d)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    testWidgets('a night with no staging speaks the time and the signals, '
        'never "not measured" (finding 9)', (t) async {
      await open(
          t,
          SleepData(
              day: '2026-05-20', night: night(staged: false), timeline: timeline));
      final says = t.widget<Scrubber>(plot('Through the night')).describe(.5);
      expect(says, '03:00, Heart rate 58 bpm, Breathing 17.5 br/min');
    });

    testWidgets('a device with other bounds shares one instant with the '
        'signals chart (finding 8)', (t) async {
      final device = {
        'device_id': 'dev-1',
        'label': 'Ring',
        'family': 'colmi',
        // Two hours later than ours at the far end: its midpoint is 04:00.
        'onset_ts': onset,
        'wake_ts': wake + 7200,
        'duration_min': 560,
        'stage_min': {'light': 300, 'deep': 200},
        'hypnogram': [
          {'t': onset, 'stage': 'light'},
          {'t': onset + 3600, 'stage': 'deep'},
          {'t': wake + 7200, 'stage': 'deep'},
        ],
      };
      await open(
          t,
          SleepData(
              day: '2026-05-20',
              night: night(),
              timeline: timeline,
              deviceNights: [device]));
      await t.tap(find.text('Ring'));
      await t.pumpAndSettle();
      final rect = t.getRect(plot('Hypnogram'));
      await t.tapAt(Offset(rect.left + rect.width * .5, rect.center.dy));
      await t.pumpAndSettle();
      // 05 h into a 10 h device night is 04:00, which is 5/8 of ours.
      expect(t.widget<Scrubber>(plot('Hypnogram')).value, closeTo(.5, .01));
      expect(t.widget<Scrubber>(plot('Through the night')).value,
          closeTo(5 / 8, .01));
      final panels = find.byKey(const ValueKey('chart-panel'));
      for (var i = 0; i < 2; i++) {
        expect(
            find.descendant(
                of: panels.at(i), matching: find.text('SELECTED · 04:00')),
            findsOneWidget,
            reason: 'panel $i');
      }
    });
  });
}
