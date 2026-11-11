// Shared pumping and geometry helpers for the skeleton / guide tests.
// Not a test file (no _test suffix). Geometry oracles here come from the
// engine (RenderParagraph line boxes, RenderBox transforms), never from the
// code under test.

import 'package:flutter/material.dart';
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

/// [f]'s rect relative to [root]'s top-left (the "paint coordinates of the
/// root" the plan promises).
Rect skLocalRect(WidgetTester t, Finder f, Finder root) =>
    t.getRect(f).shift(-t.getTopLeft(root));

/// One rect per laid-out LINE of the Text found by [f], relative to [root].
/// Boxes of one line (several spans) are merged. Empty text -> no lines.
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
  final origin = para.localToGlobal(Offset.zero) - t.getTopLeft(root);
  return [for (final r in byLine.values) r.shift(origin)]
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
