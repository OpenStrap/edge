// THE ALWAYS-PRESENT SCRUB PANEL (Graphs PR, red tests).
//
// WHY: when you stop on a time, an inset panel under the chart reads every
// series at that instant. Idle it says LATEST (the newest reading, or the
// stage at wake on a night); touched it says SELECTED. Upstream shows a
// pop-in row only WHILE a finger is down (`MetricDetail._picked`,
// `SleepDetail._scrubCard`), so the chart jumps in height under the thumb and
// nothing is readable at rest. The panel contract (owner decision 2026-10-22,
// ported from the fork's support/scrub_panel_laws.dart) uses ValueKeys:
//   chart-panel          the inset box: card2 fill, rMd radius, no shadow,
//                        no visible border at rest, a border in the series
//                        colour while scrubbing. Fixed rect.
//   chart-panel-caption  Text 'LATEST · <day|time>' / 'SELECTED · <day|time>',
//                        in the series colour while scrubbing.
//   chart-panel-value    the big value + unit; '—' where nothing was recorded.
//   chart-panel-stat:<id> a secondary stat of the one series.
// Spoken form: the slider says the selected instant ONCE; the panel adds only
// what the slider does not (the stats, 'label value'), and a day with a value
// offers an 'Open <day>' action of at least 48 dp.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _panelKey = ValueKey('chart-panel');
const _captionKey = ValueKey('chart-panel-caption');
const _valueKey = ValueKey('chart-panel-value');

String _plain(Text x) => x.data ?? x.textSpan?.toPlainText() ?? '';

Widget _scaled(double scale, Widget home, {Brightness b = Brightness.light}) =>
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(b),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

/// Every string a screen reader could be given, from the whole tree.
List<String> _spoken(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    final d = n.getSemanticsData();
    for (final s in [d.label, d.value, d.increasedValue, d.decreasedValue]) {
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

int _times(WidgetTester t, String what) =>
    _spoken(t).where((s) => s.contains(what)).length;

/// Whether [caption] names [back] days ago: the weekday and the day of the
/// month, or 'today' / 'yesterday' where the chart words it so.
bool _namesDay(String caption, int back) {
  final c = caption.toLowerCase();
  final n = DateTime.now();
  final d = DateTime(n.year, n.month, n.day - back);
  const wd = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  if (back == 0 && c.contains('today')) return true;
  if (back == 1 && c.contains('yesterday')) return true;
  return c.contains(wd[d.weekday - 1]) && RegExp('\\b${d.day}\\b').hasMatch(c);
}

BoxDecoration _decoration(WidgetTester t, Finder panel) {
  final w = t.widget(panel);
  if (w is Container) return w.decoration! as BoxDecoration;
  if (w is DecoratedBox) return w.decoration as BoxDecoration;
  fail('chart-panel must be a Container or DecoratedBox, got ${w.runtimeType}');
}

int _rgb(Color c) => c.toARGB32() & 0xFFFFFF;

// ═══════════════ metric detail: resting heart rate, 7 days ═══════════════
//
// A value of 50 + back (back = days ago, 0 = today) on every day of the
// window except a GAP at 2 days ago.
const _gapBack = 2, _scrubbedBack = 3;

MetricData _rhr() {
  final n = DateTime.now();
  return MetricData(daysAvailable: 10, series: [
    for (var back = 9; back >= 0; back--)
      if (back != _gapBack)
        (
          t: DateTime(n.year, n.month, n.day - back, 12)
                  .millisecondsSinceEpoch ~/
              1000,
          v: 50.0 + back,
        ),
  ]);
}

Future<void> _openRhr(WidgetTester t,
    {double width = 390, double scale = 1}) async {
  _phone(t, width, 1800);
  await t.pumpWidget(_scaled(
      scale, Scaffold(body: MetricDetail('resting_hr', data: _rhr()))));
  await t.pumpAndSettle();
  await t.tap(find.text('7 days'));
  await t.pumpAndSettle();
}

Finder get _plot => find.descendant(
    of: find.byType(ChartFrame).first, matching: find.byType(Scrubber));

/// Taps the plot on the day [back] days ago (7 slots, the last is today).
Future<void> _scrubBack(WidgetTester t, int back) async {
  final r = t.getRect(_plot);
  await t.tapAt(Offset(r.left + r.width * (6 - back) / 6, r.center.dy));
  await t.pumpAndSettle();
}

String _valueOf(WidgetTester t, Finder panel) {
  final f = find.descendant(of: panel, matching: find.byKey(_valueKey));
  expect(f, findsOneWidget, reason: 'the panel has no value');
  return [
    for (final x in t.widgetList<Text>(
        find.descendant(of: f, matching: find.byType(Text))))
      _plain(x)
  ].join().replaceAll(RegExp(r'\s+'), '');
}

String _captionOf(WidgetTester t, Finder panel) {
  final f = find.descendant(of: panel, matching: find.byKey(_captionKey));
  expect(f, findsOneWidget, reason: 'the panel has no caption');
  return _plain(t.widget<Text>(f));
}

void main() {
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  group('metric detail panel', () {
    testWidgets('at rest: one panel, LATEST, today, the value and unit, the '
        'stats', (t) async {
      await _openRhr(t);
      final panel = find.byKey(_panelKey);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final cap = _captionOf(t, panel);
      expect(cap.toLowerCase(), startsWith('latest'));
      expect(_namesDay(cap, 0), isTrue, reason: 'caption "$cap" names no day');
      expect(_valueOf(t, panel), '50bpm');
      final stats = find.descendant(
          of: panel,
          matching: find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('chart-panel-stat:')));
      expect(stats, findsAtLeastNWidgets(2), reason: '7-day avg and vs avg');
      final texts = [
        for (final x in t.widgetList<Text>(
            find.descendant(of: stats, matching: find.byType(Text))))
          _plain(x).replaceAll(RegExp(r'\s+'), ' ')
      ];
      // Days 6,5,4,3,1,0 ago read 56,55,54,53,51,50: mean 53.17.
      expect(texts, contains('53 bpm'));
      expect(texts.where((s) => RegExp(r'^[+\-−]3 bpm$').hasMatch(s)),
          isNotEmpty,
          reason: 'vs avg for the latest day (50 against 53.17)');
    });

    testWidgets('scrubbing: SELECTED, the scrubbed day, its value, a border in '
        'the series colour', (t) async {
      await _openRhr(t);
      final panel = find.byKey(_panelKey);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final rest = _decoration(t, panel).border;
      expect(rest == null || rest.top.width == 0 || rest.top.color.a == 0,
          isTrue,
          reason: 'no visible border at rest');
      await _scrubBack(t, _scrubbedBack);
      expect(panel, findsOneWidget);
      final cap = _captionOf(t, panel);
      expect(cap.toLowerCase(), startsWith('selected'));
      expect(_namesDay(cap, _scrubbedBack), isTrue,
          reason: 'caption "$cap" is not $_scrubbedBack days back');
      expect(_valueOf(t, panel), '53bpm');
      final colour = _rgb(
          P.of(t.element(panel)).on(specOf('resting_hr').color));
      final b = _decoration(t, panel).border;
      expect(b, isNotNull, reason: 'scrubbing draws a border');
      expect(b!.top.width, greaterThan(0));
      expect(_rgb(b.top.color), colour);
      final capText = t.widget<Text>(
          find.descendant(of: panel, matching: find.byKey(_captionKey)));
      expect(_rgb(capText.style!.color!), colour,
          reason: 'SELECTED is in the series colour');
    });

    testWidgets('a day with no reading says so: SELECTED and a dash, never a '
        'neighbour\'s number', (t) async {
      await _openRhr(t);
      final panel = find.byKey(_panelKey);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      await _scrubBack(t, _gapBack);
      expect(_captionOf(t, panel).toLowerCase(), startsWith('selected'));
      expect(_namesDay(_captionOf(t, panel), _gapBack), isTrue);
      expect(_valueOf(t, panel), startsWith('—'));
    });

    testWidgets('the panel and the frame keep their size and place at rest, '
        'scrubbing, on a gap day and back on today; no pop-in row appears',
        (t) async {
      await _openRhr(t);
      final panel = find.byKey(_panelKey);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final rect = t.getRect(panel);
      final frame = t.getRect(find.byType(ChartFrame).first);
      final surfaces = find.byType(Surface).evaluate().length;
      for (final back in [_scrubbedBack, _gapBack, 4, 0]) {
        await _scrubBack(t, back);
        expect(panel, findsOneWidget);
        expect(t.getRect(panel), rect, reason: 'panel moved on day -$back');
        expect(t.getRect(find.byType(ChartFrame).first), frame,
            reason: 'frame moved on day -$back');
        expect(find.byType(Surface).evaluate().length, surfaces,
            reason: 'the old pop-in Surface must not come back (day -$back)');
      }
    });

    testWidgets('inset style: card2 fill, rMd radius, no shadow, under the '
        'plot and inside the card', (t) async {
      await _openRhr(t);
      final panel = find.byKey(_panelKey);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final p = P.of(t.element(panel));
      final d = _decoration(t, panel);
      expect(d.color, p.card2);
      expect(d.borderRadius, R.rMd);
      expect(d.boxShadow, anyOf(isNull, isEmpty));
      expect(t.getRect(panel).top, greaterThanOrEqualTo(t.getRect(_plot).bottom));
    });

    for (final w in [360.0, 390.0]) {
      for (final s in [1.0, 1.3]) {
        testWidgets('no overflow and no shift at width $w, text scale $s',
            (t) async {
          await _openRhr(t, width: w, scale: s);
          final panel = find.byKey(_panelKey);
          expect(panel, findsOneWidget, reason: 'no panel at rest');
          expect(t.takeException(), isNull);
          final rect = t.getRect(panel);
          final box = t.getRect(find.byType(ChartFrame).first);
          expect(rect.left, greaterThanOrEqualTo(box.left - .01));
          expect(rect.right, lessThanOrEqualTo(box.right + .01));
          for (final back in [_scrubbedBack, _gapBack]) {
            await _scrubBack(t, back);
            expect(t.takeException(), isNull);
            expect(t.getRect(panel), rect);
          }
        });
      }
    }

    testWidgets('spoken once: the slider says the selected day and value; the '
        'panel does not repeat it and speaks the stats as "label value"',
        (t) async {
      final h = t.ensureSemantics();
      await _openRhr(t);
      await _scrubBack(t, _scrubbedBack);
      final scrubber = t.widget<Scrubber>(_plot);
      final said = scrubber.describe(scrubber.value!);
      expect(said, contains('53 bpm'));
      expect(_times(t, said), 1,
          reason: 'the selection is voiced once across slider and panel');
      expect(find.bySemanticsLabel(RegExp(r'^(LATEST|SELECTED)', caseSensitive: false)),
          findsNothing,
          reason: 'the visual caption is not a second announcement');
      expect(_spoken(t).where((s) => RegExp(r'7-day avg.*53 bpm').hasMatch(s)),
          hasLength(1),
          reason: 'a stat is spoken as one "label value" node');
      h.dispose();
    });

    testWidgets('at rest the panel speaks the LATEST day and value once; '
        'selecting hands the reading to the slider', (t) async {
      final h = t.ensureSemantics();
      await _openRhr(t);
      final latest = find.semantics.byLabel(RegExp(r'^LATEST'));
      final said = latest.evaluate().single.label;
      expect(said, startsWith('LATEST · Today, '));
      expect(said, contains('50 bpm'));
      expect(
          t.getSemantics(find.byWidgetPredicate(
              (w) => w is Scrubber && w.label == 'Resting heart rate')).value,
          'Nothing selected');
      await _scrubBack(t, _scrubbedBack);
      expect(latest, findsNothing);
      expect(find.semantics.byLabel(RegExp(r'^SELECTED')), findsNothing);
      expect(
          t.getSemantics(find.byWidgetPredicate(
              (w) => w is Scrubber && w.label == 'Resting heart rate')).value,
          contains('53 bpm'),
          reason: 'the slider says the selected day and value');
      h.dispose();
    });

    testWidgets('a day with a value offers "Open <day>" of at least 48 dp; a '
        'day without one offers nothing to open', (t) async {
      final h = t.ensureSemantics();
      await _openRhr(t);
      await _scrubBack(t, _scrubbedBack);
      final open = find.bySemanticsLabel(RegExp(r'^Open '));
      expect(open, findsOneWidget);
      expect(t.getSemantics(open).rect.height, greaterThanOrEqualTo(48));
      await _scrubBack(t, _gapBack);
      expect(find.bySemanticsLabel(RegExp(r'^Open ')), findsNothing,
          reason: 'an action button is a promise; an empty day has no screen');
      h.dispose();
    });

    // A day that can be opened shows the same chevron the old pop-in row had.
    final chevron = find.descendant(
        of: find.byKey(_panelKey), matching: find.byIcon(LucideIcons.chevronRight));

    testWidgets('a chevron shows when the day opens and not on a gap day, '
        'and the panel keeps its size', (t) async {
      await _openRhr(t);
      final panel = find.byKey(_panelKey);
      expect(chevron, findsOneWidget, reason: 'today opens, so a chevron');
      final icon = t.widget<Icon>(chevron);
      expect(icon.size, 18);
      expect(icon.color, P.of(t.element(panel)).ink3);
      final size = t.getSize(panel);
      final cap = t.getRect(find.byKey(_captionKey));
      await _scrubBack(t, _gapBack);
      expect(chevron, findsNothing, reason: 'a gap day opens nothing');
      expect(t.getSize(panel), size, reason: 'the chevron changed the height');
      expect(t.getRect(find.byKey(_captionKey)), cap,
          reason: 'the caption jumped');
      await _scrubBack(t, _scrubbedBack);
      expect(chevron, findsOneWidget);
      expect(t.getSize(panel), size);
    });

    testWidgets('the chevron sits at the trailing edge, centred on the value '
        'line, and is not spoken', (t) async {
      final h = t.ensureSemantics();
      await _openRhr(t);
      final panel = t.getRect(find.byKey(_panelKey));
      final c = t.getRect(chevron);
      final value = t.getRect(find.byKey(_valueKey));
      expect(c.right, lessThanOrEqualTo(panel.right));
      expect(panel.right - c.right, lessThan(24),
          reason: 'trailing edge of the panel');
      expect((c.center.dy - value.center.dy).abs(), lessThan(1.5),
          reason: 'centred on the value line');
      expect(c.left, greaterThanOrEqualTo(value.right - 0.01),
          reason: 'the chevron never sits on the value');
      expect(_spoken(t).where((s) => s.toLowerCase().contains('chevron')),
          isEmpty);
      h.dispose();
    });

    testWidgets('the chevron fits on metric detail at text scale 1.3 without '
        'overflow or a height change', (t) async {
      await _openRhr(t, scale: 1.3);
      final panel = find.byKey(_panelKey);
      expect(chevron, findsOneWidget);
      final size = t.getSize(panel);
      expect(t.takeException(), isNull);
      await _scrubBack(t, _gapBack);
      expect(t.takeException(), isNull);
      expect(chevron, findsNothing);
      expect(t.getSize(panel), size);
    });

    // The metric-detail screen has its own overflow at 3.1x (the range chips),
    // so the large-text case runs on the panel alone, narrow and wide.
    for (final w in [320.0, 390.0]) {
      testWidgets('the panel alone at text scale 3.1, width $w: the chevron '
          'fits and opening or not leaves the size alone', (t) async {
        _phone(t, w, 1800);
        Widget panel({required bool open}) => _scaled(
            3.1,
            Scaffold(
                body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topCenter,
                child: ChartPanel(
                  time: 'Wednesday, 28 September',
                  timeSpan: const ['Today', 'Wednesday, 28 September'],
                  scrubbed: true,
                  color: Colors.red,
                  cells: [
                    ChartPanelCell('Resting heart rate',
                        color: Colors.red, value: open ? '52 bpm' : null),
                  ],
                  stats: const [
                    ChartPanelCell('7-day avg', value: '54 bpm'),
                    ChartPanelCell('vs avg', value: '−2 bpm'),
                  ],
                  onOpen: open ? () {} : null,
                  openLabel: 'Open Wednesday',
                ),
              ),
            )));
        await t.pumpWidget(panel(open: true));
        expect(t.takeException(), isNull);
        expect(chevron, findsOneWidget);
        final size = t.getSize(find.byKey(_panelKey));
        final cap = t.getRect(find.byKey(_captionKey));
        await t.pumpWidget(panel(open: false));
        expect(t.takeException(), isNull);
        expect(chevron, findsNothing);
        expect(t.getSize(find.byKey(_panelKey)), size);
        expect(t.getRect(find.byKey(_captionKey)), cap);
      });
    }
  });

  // ═══════════════ sleep: the hypnogram and the night's signals ═══════════════
  group('sleep panels', () {
    final onset = DateTime(2026, 5, 19, 23).millisecondsSinceEpoch ~/ 1000;
    final wake = DateTime(2026, 5, 20, 7).millisecondsSinceEpoch ~/ 1000;

    SleepData data({bool signals = true}) => SleepData(
          day: '2026-05-20',
          night: {
            'duration_min': 360,
            'in_bed_min': 480,
            'awake_min': 15,
            'efficiency': .75,
            'onset_ts': onset,
            'wake_ts': wake,
            'light_min': 120,
            'deep_min': 120,
            'rem_min': 105,
            'hypnogram': [
              {'t': onset, 'stage': 'light'},
              {'t': onset + 3600, 'stage': 'deep'},
              {'t': onset + 10800, 'stage': 'unobserved'},
              {'t': onset + 18000, 'stage': 'rem'},
              // The display samples miss this: two minutes before wake.
              {'t': wake - 60, 'stage': 'awake'},
              {'t': wake, 'stage': 'awake'},
            ],
          },
          timeline: signals
              ? {
                  'hr': [
                    {'t': onset, 'v': 50},
                    {'t': onset + 7200, 'v': 54},
                    {'t': onset + 14400, 'v': 58},
                    {'t': wake, 'v': 66},
                  ],
                  'hrv': [
                    {'t': onset + 7200, 'v': 42}
                  ],
                  'resp': [
                    {'t': onset + 14400, 'v': 17.5}
                  ],
                }
              : {},
        );

    Future<void> pump(WidgetTester t,
        {double scale = 1,
        bool signals = true,
        Brightness b = Brightness.light}) async {
      _phone(t, 390, 6200 * scale);
      await t.pumpWidget(_scaled(
          scale, SleepDetail(data: data(signals: signals)),
          b: b));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    Finder plot(String label) =>
        find.byWidgetPredicate((w) => w is Scrubber && w.label == label);
    Finder inPanel(Finder panel, String text) =>
        find.descendant(of: panel, matching: find.text(text));

    Future<void> scrub(WidgetTester t, String label, double at) async {
      final rect = t.getRect(plot(label));
      await t.tapAt(Offset(rect.left + rect.width * at, rect.center.dy));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    for (final scale in [1.0, 1.3, 3.1]) {
      testWidgets('both night panels are there at rest (LATEST at wake) and '
          'keep their size and place at ${scale}x text', (t) async {
        await pump(t, scale: scale);
        final panels = find.byKey(_panelKey);
        expect(panels, findsNWidgets(2),
            reason: 'one under the hypnogram, one under the night signals');
        final rects = [for (var i = 0; i < 2; i++) t.getRect(panels.at(i))];
        for (var i = 0; i < 2; i++) {
          expect(inPanel(panels.at(i), 'LATEST · 07:00'), findsOneWidget);
          expect(inPanel(panels.at(i), 'Awake'), findsOneWidget);
          expect(inPanel(panels.at(i), '66 bpm'), findsOneWidget);
          expect(find.descendant(of: panels.at(i), matching: find.text('—')),
              findsAtLeastNWidgets(2),
              reason: 'HRV and breathing were not recorded at wake: a dash, '
                  'never a neighbour\'s reading');
          final box = t.widget<Container>(panels.at(i)).decoration as BoxDecoration;
          expect(box.border, isNull, reason: 'no border at rest');
        }
        final surfaces = find.byType(Surface).evaluate().length;
        for (final (label, at, time) in [
          ('Hypnogram', .25, '01:00'),
          ('Through the night', .5, '03:00'),
          ('Hypnogram', .75, '05:00'),
        ]) {
          await scrub(t, label, at);
          expect(panels, findsNWidgets(2));
          expect(find.byType(Surface).evaluate().length, surfaces,
              reason: 'the old readout added a Surface on every scrub');
          for (var i = 0; i < 2; i++) {
            expect(inPanel(panels.at(i), 'SELECTED · $time'), findsOneWidget);
            expect(t.getRect(panels.at(i)), rects[i], reason: 'no shift at $time');
            final box =
                t.widget<Container>(panels.at(i)).decoration as BoxDecoration;
            expect(box.border, isNotNull);
          }
        }
      });
    }

    testWidgets('SELECTED shows the stage and EVERY signal at that instant, '
        'and a dash where one was not recorded', (t) async {
      await pump(t);
      final panels = find.byKey(_panelKey);
      expect(panels, findsNWidgets(2), reason: 'no panels under the charts');
      // 01:00: deep sleep; heart rate and HRV were both recorded here.
      await scrub(t, 'Hypnogram', .25);
      for (var i = 0; i < 2; i++) {
        expect(inPanel(panels.at(i), 'Deep sleep'), findsOneWidget);
        expect(inPanel(panels.at(i), '54 bpm'), findsOneWidget);
        expect(inPanel(panels.at(i), '42 ms'), findsOneWidget);
      }
      // 03:00: an unobserved stretch; heart rate and breathing, no HRV.
      await scrub(t, 'Through the night', .5);
      for (var i = 0; i < 2; i++) {
        expect(inPanel(panels.at(i), 'Not measured'), findsOneWidget,
            reason: 'a hole in the record is not a stage');
        expect(inPanel(panels.at(i), '58 bpm'), findsOneWidget);
        expect(find.descendant(of: panels.at(i), matching: find.textContaining('17.5')),
            findsOneWidget);
        expect(find.descendant(of: panels.at(i), matching: find.textContaining(' ms')),
            findsNothing,
            reason: 'no HRV was recorded near 03:00');
      }
      // 05:00: REM, but no signal within reach: nothing is invented.
      await scrub(t, 'Hypnogram', .75);
      for (var i = 0; i < 2; i++) {
        expect(inPanel(panels.at(i), 'REM'), findsOneWidget);
        for (final unit in [' bpm', ' ms', 'br/min']) {
          expect(find.descendant(of: panels.at(i), matching: find.textContaining(unit)),
              findsNothing,
              reason: 'no signal near 05:00, so no $unit value');
        }
      }
    });

    testWidgets('the stage comes from the timestamped boundaries, even '
        'between display samples; the slider agrees', (t) async {
      await pump(t);
      final panels = find.byKey(_panelKey);
      expect(panels, findsNWidgets(2), reason: 'no panels under the charts');
      for (final (seconds, time, stage) in [
        (3599, '23:59', 'Light sleep'),
        (3600, '00:00', 'Deep sleep'),
        (10799, '01:59', 'Deep sleep'),
        (10800, '02:00', 'Not measured'),
        (17999, '03:59', 'Not measured'),
        (18000, '04:00', 'REM'),
        (28739, '06:58', 'REM'),
        (28740, '06:59', 'Awake'),
      ]) {
        await scrub(t, 'Hypnogram', seconds / 28800);
        for (var i = 0; i < 2; i++) {
          expect(inPanel(panels.at(i), 'SELECTED · $time'), findsOneWidget,
              reason: 'panel $i at $seconds s');
          expect(inPanel(panels.at(i), stage), findsOneWidget,
              reason: 'panel $i at $seconds s');
        }
        final s = t.widget<Scrubber>(plot('Hypnogram'));
        final spoken = stage == 'Not measured' ? 'not measured' : stage;
        // The slider speaks the whole reading the panel is showing: the stage
        // and every signal at that second, a missing one as 'No record'.
        final hr = seconds >= 28000 ? '66 bpm' : 'No record';
        expect(s.describe(seconds / 28800),
            '$time, $spoken, Heart rate $hr, HRV No record, Breathing No record');
      }
    });

    for (final b in Brightness.values) {
      testWidgets('the stage caption and value clear 4.5:1 on the panel in $b',
          (t) async {
        await pump(t, b: b);
        expect(find.byKey(_panelKey), findsNWidgets(2));
        final panel = find.byKey(_panelKey).first;
        final p = P.of(t.element(panel));
        for (final (at, stage, pigment) in [
          (0.0, 'Light sleep', C.sky),
          (.25, 'Deep sleep', C.blue),
          (.75, 'REM', C.teal),
          (1.0, 'Awake', C.orange),
        ]) {
          await scrub(t, 'Hypnogram', at == 1 ? .9999 : at);
          final caption = find.descendant(
              of: panel, matching: find.byKey(_captionKey));
          for (final text in [inPanel(panel, stage), caption]) {
            final color = t.widget<Text>(text).style!.color!;
            expect(color, p.on(pigment));
            expect(P.contrast(color, p.card2), greaterThanOrEqualTo(4.5));
          }
        }
      });
    }

    testWidgets('a night with no recorded signals keeps one panel for the '
        'hypnogram and fabricates no values', (t) async {
      await pump(t, signals: false);
      final panels = find.byKey(_panelKey);
      expect(panels, findsOneWidget);
      expect(inPanel(panels, 'LATEST · 07:00'), findsOneWidget);
      expect(inPanel(panels, 'Awake'), findsOneWidget);
      for (final unit in [' bpm', ' ms', 'br/min']) {
        expect(find.descendant(of: panels, matching: find.textContaining(unit)),
            findsNothing);
      }
    });

    /// Labels and values a screen reader reads as the node itself (not the
    /// neighbouring-step values a slider also carries).
    List<String> said(WidgetTester t) {
      final out = <String>[];
      void walk(SemanticsNode n) {
        final d = n.getSemanticsData();
        for (final x in [d.label, d.value]) {
          if (x.isNotEmpty) out.add(x);
        }
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      walk(t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
      return out;
    }

    int times(WidgetTester t, String what) => said(t)
        .map((s) => what.allMatches(s).length)
        .fold(0, (a, b) => a + b);

    // Two charts, two panels, each showing the same instant: each chart's
    // reading is spoken by exactly one owner, so every displayed value is
    // spoken twice on the page and never twice for one chart.
    testWidgets('at rest the panel speaks LATEST once per chart: the stage '
        'and every signal, a missing one as No record', (t) async {
      final h = t.ensureSemantics();
      await pump(t);
      final readings = find.semantics.byLabel(RegExp(r'^LATEST'));
      expect(readings.evaluate(), hasLength(2), reason: 'one per panel');
      for (final n in readings.evaluate()) {
        expect(n.label,
            'LATEST · 07:00, Stage Awake, Heart rate 66 bpm, '
            'HRV No record, Breathing No record');
      }
      for (final value in ['Stage Awake', '66 bpm', 'HRV No record', 'Breathing No record']) {
        expect(times(t, value), 2, reason: '$value: once per panel');
      }
      h.dispose();
    });

    testWidgets('selected, the slider speaks the whole reading once per chart '
        'and the panel is silent', (t) async {
      final h = t.ensureSemantics();
      await pump(t);
      await scrub(t, 'Hypnogram', .25);
      const full = '01:00, Deep sleep, Heart rate 54 bpm, HRV 42 ms, '
          'Breathing No record';
      for (final label in ['Hypnogram', 'Through the night']) {
        final node = find.semantics.byLabel(label).evaluate().single;
        expect(node.value, full, reason: '$label slider');
      }
      for (final value in ['Deep sleep', '54 bpm', '42 ms', 'Breathing No record']) {
        expect(times(t, value), 2, reason: '$value: once per slider');
      }
      expect(find.bySemanticsLabel(RegExp(r'^(LATEST|SELECTED)', caseSensitive: false)),
          findsNothing,
          reason: 'the panel caption and cells are not a second announcement');
      // Letting go is not possible here (a tap selects), but a second
      // selection moves the one reading rather than adding another.
      await scrub(t, 'Through the night', .5);
      expect(find.semantics.byLabel('Hypnogram').evaluate().single.value,
          '03:00, not measured, Heart rate 58 bpm, HRV No record, '
          'Breathing 17.5 br/min');
      h.dispose();
    });
  });
}
