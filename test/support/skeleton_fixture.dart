// Shared pumping and geometry helpers for the skeleton / guide tests.
// Not a test file (no _test suffix). Geometry oracles here come from the
// engine (RenderParagraph line boxes, RenderBox transforms), never from the
// code under test.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// A MaterialApp with the app's localization delegates, one locale, and ui2's
/// theme, so P.of(context) and AppLocalizations.of(context) both work.
Widget skHost(
  Widget home, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// A tall 1:1 surface so lazily built lists build everything.
void skTallView(WidgetTester t, {double w = 800, double h = 3000}) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

/// Matrix taking [box]'s local space to [root]'s local space (through the
/// global space, so transforms and scaling above either are honoured).
Matrix4 _toRoot(RenderObject box, RenderObject root) {
  final inv = Matrix4.copy(root.getTransformTo(null))..invert();
  return inv..multiply(box.getTransformTo(null));
}

/// [f]'s rect relative to [root]'s local space (the "paint coordinates of the
/// root" the plan promises), honouring transforms.
Rect skLocalRect(WidgetTester t, Finder f, Finder root) {
  final box = t.renderObject<RenderBox>(f);
  return MatrixUtils.transformRect(
      _toRoot(box, t.renderObject(root)), Offset.zero & box.size);
}

/// One rect per laid-out LINE of the Text found by [f], in [root]'s local
/// space. Boxes of one line (several spans) are merged. Empty text -> none.
List<Rect> skLineRects(WidgetTester t, Finder f, Finder root) {
  final para = t.renderObject<RenderParagraph>(f);
  final len = para.text.toPlainText().length;
  if (len == 0) return const [];
  final boxes = para.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: len));
  final byLine = <int, Rect>{};
  for (final b in boxes) {
    final r = Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
    if (r.width <= 0 || r.height <= 0) continue;
    final key = (r.top * 2).round();
    byLine[key] = byLine[key]?.expandToInclude(r) ?? r;
  }
  final m = _toRoot(para, t.renderObject(root));
  return [for (final r in byLine.values) MatrixUtils.transformRect(m, r)]
    ..sort((a, b) => a.top.compareTo(b.top));
}

/// True when [outer] contains [inner] up to [eps] of rounding slack.
bool skContains(Rect outer, Rect inner, [double eps = 0.51]) =>
    outer.inflate(eps).contains(inner.topLeft) &&
    outer.inflate(eps).contains(inner.bottomRight);

/// Strict overlap (touching edges do not count).
bool skOverlaps(Rect a, Rect b) => a.overlaps(b);

class SkPainter extends CustomPainter {
  const SkPainter();
  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF336699));
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// Loads the app's real fonts (Manrope, as ui2_activity_test does) so frame
/// tests measure real glyph widths, not Ahem. Call from setUpAll.
Future<void> skLoadAppFonts() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}

/// Labels of every semantics node in screen-reader traversal order.
List<String> skTraversalLabels(WidgetTester t) => [
      for (final n in t.semantics.simulatedAccessibilityTraversal())
        if (n.label.isNotEmpty) n.label,
    ];

/// True when some semantics node under the root has exactly [label].
bool skHasSemanticsLabel(WidgetTester t, String label) =>
    skTraversalLabels(t).any((l) => l == label || l.contains(label));
