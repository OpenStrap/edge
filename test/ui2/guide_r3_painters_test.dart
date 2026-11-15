import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/skeleton/guide_plot.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../support/guide_r2_pixels.dart';

final _declaration = RegExp(r'class\s+(\w+)\s+extends\s+CustomPainter\b([^{]*)\{');
final _classes = RegExp(r'\b(GuidePlot|GuideRing|GuideDecoration|GuidePlotOverlay)\b');

/// The painters of [source] that declare no placeholder treatment.
List<String> _unclassified(String source) => [
  for (final m in _declaration.allMatches(source))
    if (!_classes.hasMatch(m.group(2)!)) m.group(1)!,
];

Map<String, String> _painters() {
  final found = <String, String>{};
  for (final f in Directory('lib/ui2').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    for (final m in _declaration.allMatches(f.readAsStringSync())) {
      found[m.group(1)!] = m.group(2)!;
    }
  }
  return found;
}

void main() {
  // WHY: owner review R3. A painter that draws data and was never classified leaks its
  // real values into a placeholder, and nothing noticed the next one. Every CustomPainter
  // in lib/ui2 declares one of GuidePlot / GuideRing / GuideDecoration / GuidePlotOverlay.
  // # catches: a new chart painter added without a placeholder treatment.
  test('R3: every CustomPainter in lib/ui2 declares its placeholder treatment', () {
    final all = _painters();
    expect(all.keys, containsAll(['LineChart', 'EcgWaveformPainter', 'Elevation', 'RouteMap', 'ExplorePlotPainter', '_GuidePainter']),
      reason: 'positive control: the scan sees painters in many files');
    expect(all.length, greaterThan(28));
    expect(_unclassified('class _New extends CustomPainter {\n}'), ['_New'], reason: 'the check rejects an undeclared painter');
    expect(_unclassified('class _Old extends CustomPainter implements GuideDecoration {}'), isEmpty);
    expect([for (final e in all.entries) if (!_classes.hasMatch(e.value)) e.key], isEmpty,
      reason: 'declare implements GuidePlot (data), GuideRing (dial), GuidePlotOverlay (marks over a plot) or GuideDecoration (no data)');
  });

  // WHY: the allow-list for decoration must not become the way out of the guard: these
  // painters draw the user's data (review R3) and must stay plots.
  // # catches: silencing the guard by calling a data painter a decoration.
  test('R3: the painters named in the review are plots, not decorations', () {
    const data = ['EcgWaveformPainter', 'EcgLivePainter', 'Elevation', 'RouteMap', 'ExplorePlotPainter', '_TypicalPainter',
      'IntervalLadder', '_SideStrip', 'PosterMap', 'HapticScorePainter', 'BreathRing', 'LineChart', 'Bars', 'Ring'];
    final all = _painters();
    for (final name in data) {
      expect(all[name], matches(RegExp(r'GuidePlot|GuideRing')), reason: name);
    }
  });

  // WHY: a painter nobody classified must not draw its values in a placeholder; one that
  // is declared decoration is left alone; a plot is replaced; a dial becomes an empty
  // ring and a chart a wave. The runtime default is the safety net behind the guard.
  // # catches: unclassified painters painting real data under the placeholder.
  testWidgets('R3/R9: placeholder paint hides unclassified painters, keeps decoration, ring is empty and chart is a wave', (t) async {
    final controller = GuideDimController();
    addTearDown(controller.dispose);
    final unknown = _Probe(), decoration = _Probe(), plot = _Probe(), dial = _Probe();
    const root = ValueKey('root'), boundary = ValueKey('boundary');
    final ringBox = GlobalKey(), waveBox = GlobalKey(), surface = GlobalKey();
    t.view.physicalSize = const Size(400, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Widget paint(CustomPainter p, {Key? key}) => Center(child: SizedBox(key: key, width: 80, height: 80, child: CustomPaint(painter: p)));
    await t.pumpWidget(GuideDimScope(
      controller: controller,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: RepaintBoundary(key: boundary, child: Column(key: root, children: [
          Surface(child: paint(_Unknown(unknown))),
          Surface(child: paint(_Decor(decoration))),
          Surface(child: paint(_Wave(plot), key: waveBox)),
          Surface(key: surface, child: paint(_Dial(dial), key: ringBox)),
        ]))),
      ),
    ));
    for (final probe in [unknown, decoration, plot, dial]) {
      expect(probe.paints, greaterThan(0), reason: 'positive control: paints with no guide');
      probe.paints = 0;
    }
    final page = t.element(find.byKey(root));
    controller.setLooks(GuidePlan.from(page, planSkeleton(page, keep: const [], chrome: const [],
      dim: const DimPolicy(skeletonAll: true)), skeletonAll: true));
    await t.pump();
    expect(unknown.paints, 0, reason: 'unclassified: no data under the placeholder');
    expect(plot.paints, 0, reason: 'a plot is replaced by its wave');
    expect(dial.paints, 0, reason: 'a dial is replaced by its ring track');
    expect(decoration.paints, greaterThan(0), reason: 'a decoration is left as it is');

    final raster = await r2Raster(t, find.byKey(boundary));
    List<int> pixel(GlobalKey box, Offset at) {
      final rect = t.getRect(find.byKey(box));
      return raster.at((rect.left + at.dx).round(), (rect.top + at.dy).round());
    }
    final card = r2Rgb(P(true).card);
    // Ring: empty in the middle, coloured on the circle. Wave: the line crosses the middle.
    expect(r2Distance(pixel(ringBox, const Offset(40, 40)), card), lessThan(4), reason: 'the ring track is empty (no arc, no value)');
    final onRing = [for (var x = 62; x <= 76; x++) pixel(ringBox, Offset(x.toDouble(), 40))]
      .any((px) => r2Distance(px, card) > 6);
    expect(onRing, isTrue, reason: 'the ring track is drawn');
    final waveMiddle = [for (var y = 38; y <= 42; y++) pixel(waveBox, Offset(40, y.toDouble()))]
      .any((px) => r2Distance(px, card) > 6);
    expect(waveMiddle, isTrue, reason: 'a chart becomes one wave through its middle');
    controller.clear();
    await t.pump();
    expect(unknown.paints, greaterThan(0), reason: 'ending the guide restores the painter');
  });
}

class _Probe {
  int paints = 0;
}

class _Unknown extends CustomPainter {
  _Unknown(this.probe);
  final _Probe probe;
  @override
  void paint(Canvas canvas, Size size) {
    probe.paints++;
    canvas.drawLine(Offset.zero, size.bottomRight(Offset.zero), Paint()..color = C.red..strokeWidth = 4);
  }

  @override
  bool shouldRepaint(_Unknown old) => true;
}

class _Decor extends _Unknown implements GuideDecoration {
  _Decor(super.probe);
}

class _Wave extends _Unknown implements GuidePlot {
  _Wave(super.probe);
  @override
  Color get guideLineColor => C.blue;
}

class _Dial extends _Unknown implements GuideRing {
  _Dial(super.probe);
  @override
  Color get guideLineColor => C.green;
}
