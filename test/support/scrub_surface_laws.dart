// THE SCRUB + PANEL CONTRACT, AS LAWS A SURFACE CAN BE HELD TO (Graphs PR,
// phase 5). One rig per screen; the same laws for every rig, so Health, Workout
// and the month grid cannot drift apart. The contract is the one phases 2-3
// pinned on metric detail and sleep (graphs_scrub_panel_test.dart,
// graphs_scroll_first_scrub_test.dart):
//   * a `chart-panel` is present at rest, LATEST, on the newest reading;
//   * a tap or a horizontal-dominant drag selects: SELECTED, that day's value;
//   * a day with no reading reads a dash, never a neighbour;
//   * the panel keeps its rect across rest / selected / gap;
//   * the slider speaks the selection ONCE; the caption is not announced;
//   * a vertical drag that starts on the chart scrolls the page and selects
//     nothing; a horizontal-dominant drag scrubs and the page stays;
//   * no "Open <day>" button where there is no day screen to open.
//
// FIXTURES are dated backwards from the wall clock in LOCAL calendar days
// (never a fixed date, never UTC), so they hold in any host timezone.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const panelKey = ValueKey('chart-panel');
const captionKey = ValueKey('chart-panel-caption');
const valueKey = ValueKey('chart-panel-value');

String plainOf(Text x) => x.data ?? x.textSpan?.toPlainText() ?? '';

Widget scaledApp(double scale, Widget home) => MaterialApp(
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

void phone(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

/// Every string a screen reader could be given, from the whole tree.
List<String> spoken(WidgetTester t) {
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

/// Whether [caption] names [back] days ago, as the chart words it: 'today',
/// 'yesterday', or the weekday and the day of the month.
bool namesDay(String caption, int back, {String? lastWord}) {
  final c = caption.toLowerCase();
  if (back == 0 && lastWord != null && c.contains(lastWord.toLowerCase())) {
    return true;
  }
  final n = DateTime.now();
  final d = DateTime(n.year, n.month, n.day - back);
  const wd = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  if (back == 0 && c.contains('today')) return true;
  if (back == 1 && c.contains('yesterday')) return true;
  return c.contains(wd[d.weekday - 1]) && RegExp('\\b${d.day}\\b').hasMatch(c);
}

/// One screen's chart, described for the laws. Slot 0 is the OLDEST; the last
/// slot is today.
class SurfaceRig {
  const SurfaceRig({
    required this.name,
    required this.mount,
    required this.plot,
    required this.slots,
    required this.bars,
    required this.scrubbed,
    required this.gap,
    required this.valueAt,
    this.lastWord,
  });

  final String name;

  /// Pumps the screen at [scale] text scale with the fixture and brings the
  /// chart's page into view. Must assert its own controls (the chart's frame is
  /// on screen) so a failure afterwards is about the contract.
  final Future<void> Function(WidgetTester t, double scale) mount;

  /// The chart's `Scrubber`.
  final Finder Function() plot;

  /// How many slots the chart has, and whether they are bars (a slot is an
  /// interval, so its centre is `(i + .5) / n`) or points on a line (`i / (n -
  /// 1)`).
  final int slots;
  final bool bars;

  /// A slot with a reading that is not the newest, and a slot with none.
  final int scrubbed, gap;

  /// The panel's value for [slot] with all whitespace removed, as a pattern.
  /// Slot `slots - 1` is the one the panel shows at rest.
  final String Function(int slot) valueAt;

  /// A chart that words its newest slot its own way (HRV: "Last night").
  final String? lastWord;

  int dayBack(int slot) => slots - 1 - slot;

  double fraction(int slot) =>
      bars ? (slot + .5) / slots : slot / (slots - 1);
}

Finder get _vertical => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axis == Axis.vertical);

String _caption(WidgetTester t) {
  final f = find.descendant(
      of: find.byKey(panelKey), matching: find.byKey(captionKey));
  expect(f, findsOneWidget, reason: 'the panel has no caption');
  return plainOf(t.widget<Text>(f));
}

String _value(WidgetTester t) {
  final f = find.descendant(
      of: find.byKey(panelKey), matching: find.byKey(valueKey));
  expect(f, findsOneWidget, reason: 'the panel has no value');
  return [
    for (final x in t.widgetList<Text>(
        find.descendant(of: f, matching: find.byType(Text))))
      plainOf(x)
  ].join().replaceAll(RegExp(r'\s+'), '');
}

/// The chart on screen and the panel under it. The first assertions say what is
/// missing, so a red run names the surface and not a cascade.
Future<void> _ready(WidgetTester t, SurfaceRig r, double scale) async {
  await r.mount(t, scale);
  expect(r.plot(), findsOneWidget,
      reason: '${r.name}: the chart has no scroll-first Scrubber');
  expect(find.byKey(panelKey), findsOneWidget,
      reason: '${r.name}: no chart-panel under the chart at rest');
  expect(t.takeException(), isNull, reason: '${r.name} lays out at $scale');
}

Future<void> _tapSlot(WidgetTester t, SurfaceRig r, int slot) async {
  await t.ensureVisible(r.plot());
  await t.pumpAndSettle();
  final box = t.getRect(r.plot());
  await t.tapAt(
      Offset(box.left + box.width * r.fraction(slot), box.center.dy));
  await t.pumpAndSettle();
}

void defineSurfaceLaws(SurfaceRig r) {
  group('${r.name}: scrub and panel', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    for (final scale in [1.0, 1.3]) {
      testWidgets('at rest the panel is there: LATEST, today, the newest '
          'reading (x$scale)', (t) async {
        await _ready(t, r, scale);
        final cap = _caption(t);
        expect(cap.toLowerCase(), startsWith('latest'));
        expect(namesDay(cap, 0, lastWord: r.lastWord), isTrue, reason: 'caption "$cap" names no day');
        expect(_value(t), matches(r.valueAt(r.slots - 1)));
        expect(t.widget<Scrubber>(r.plot()).value, isNull,
            reason: 'nothing is selected before a touch');
      });

      testWidgets('a tap selects: SELECTED, that day, its value; the panel '
          'keeps its rect (x$scale)', (t) async {
        await _ready(t, r, scale);
        await t.ensureVisible(r.plot());
        await t.pumpAndSettle();
        final rect = t.getRect(find.byKey(panelKey));
        await _tapSlot(t, r, r.scrubbed);
        expect(find.byKey(panelKey), findsOneWidget);
        final cap = _caption(t);
        expect(cap.toLowerCase(), startsWith('selected'));
        expect(namesDay(cap, r.dayBack(r.scrubbed)), isTrue,
            reason: 'caption "$cap" is not ${r.dayBack(r.scrubbed)} days back');
        expect(_value(t), matches(r.valueAt(r.scrubbed)));
        expect(t.getRect(find.byKey(panelKey)), rect,
            reason: 'a scrub moves nothing');
        expect(t.takeException(), isNull);
      });

      testWidgets('a day with no reading is a dash, and the panel still '
          'does not move (x$scale)', (t) async {
        await _ready(t, r, scale);
        await t.ensureVisible(r.plot());
        await t.pumpAndSettle();
        final rect = t.getRect(find.byKey(panelKey));
        await _tapSlot(t, r, r.gap);
        final cap = _caption(t);
        expect(cap.toLowerCase(), startsWith('selected'));
        expect(namesDay(cap, r.dayBack(r.gap)), isTrue);
        expect(_value(t), startsWith('—'),
            reason: 'never a neighbour, never an interpolation');
        expect(t.getRect(find.byKey(panelKey)), rect);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('a vertical drag that starts on the chart scrolls the page '
        'and selects nothing', (t) async {
      await _ready(t, r, 1);
      await t.ensureVisible(r.plot());
      await t.pumpAndSettle();
      final scroll = t
          .state<ScrollableState>(
              find.ancestor(of: r.plot(), matching: _vertical).first)
          .position;
      expect(scroll.maxScrollExtent, greaterThan(100),
          reason: 'a real scrollable page');
      final before = scroll.pixels;
      final dy = scroll.extentAfter > 150 ? -130.0 : 130.0;
      await t.timedDrag(
          r.plot(), Offset(12, dy), const Duration(milliseconds: 350));
      await t.pumpAndSettle();
      expect((scroll.pixels - before).abs(), greaterThan(40),
          reason: 'the page moved under the thumb');
      await t.ensureVisible(r.plot());
      await t.pumpAndSettle();
      expect(t.widget<Scrubber>(r.plot()).value, isNull);
      expect(_caption(t).toLowerCase(), startsWith('latest'),
          reason: 'a page scroll is not a selection');
      expect(t.takeException(), isNull);
    });

    testWidgets('a horizontal-dominant drag scrubs and the page stays put',
        (t) async {
      await _ready(t, r, 1);
      await t.ensureVisible(r.plot());
      await t.pumpAndSettle();
      final scroll = t
          .state<ScrollableState>(
              find.ancestor(of: r.plot(), matching: _vertical).first)
          .position;
      final before = scroll.pixels;
      await t.drag(r.plot(), const Offset(60, 5));
      await t.pumpAndSettle();
      expect(scroll.pixels, closeTo(before, 1));
      expect(t.widget<Scrubber>(r.plot()).value, isNotNull);
      expect(_caption(t).toLowerCase(), startsWith('selected'));
      expect(t.takeException(), isNull);
    });

    testWidgets('spoken once at rest: with nothing selected the panel speaks '
        'the LATEST day and value, and the slider repeats neither', (t) async {
      final h = t.ensureSemantics();
      await _ready(t, r, 1);
      await t.ensureVisible(r.plot());
      await t.pumpAndSettle();
      final latest = find.semantics.byLabel(RegExp(r'^LATEST'));
      expect(latest.evaluate(), hasLength(1),
          reason: '${r.name}: the resting reading has no owner (or two)');
      final said = latest.evaluate().single.label;
      expect(namesDay(said, 0, lastWord: r.lastWord), isTrue, reason: '"$said" names no day');
      expect(said.replaceAll(RegExp(r'\s+'), ''),
          contains(RegExp(r.valueAt(r.slots - 1)
              .replaceAll(RegExp(r'^\^|\$$'), ''))),
          reason: 'the value shown at rest is spoken');
      expect(t.widget<Scrubber>(r.plot()).value, isNull);
      expect(t.getSemantics(r.plot()).value, 'Nothing selected',
          reason: 'the slider owns nothing at rest; the panel owns the reading');
      h.dispose();
    });

    testWidgets('spoken once: the slider says the selected day and value; '
        'the panel does not repeat it', (t) async {
      final h = t.ensureSemantics();
      await _ready(t, r, 1);
      await _tapSlot(t, r, r.scrubbed);
      final s = t.widget<Scrubber>(r.plot());
      final said = s.describe(s.value!);
      expect(said, isNotEmpty);
      expect(spoken(t).where((x) => x.contains(said)), hasLength(1),
          reason: 'the selection is voiced once across slider and panel');
      expect(
          find.bySemanticsLabel(
              RegExp(r'^(LATEST|SELECTED)', caseSensitive: false)),
          findsNothing,
          reason: 'the visual caption is not a second announcement');
      h.dispose();
    });

    testWidgets('offers no "Open <day>" button: there is no day screen behind '
        'this chart', (t) async {
      final h = t.ensureSemantics();
      await _ready(t, r, 1);
      await _tapSlot(t, r, r.scrubbed);
      expect(find.bySemanticsLabel(RegExp(r'^Open ')), findsNothing,
          reason: 'an action button is a promise of a screen');
      h.dispose();
    });
  });
}
