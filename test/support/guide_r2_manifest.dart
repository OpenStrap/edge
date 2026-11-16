// Independent r2 oracle: component ownership is derived from public widget types and actual control callbacks, never from skeletonPlan's section ids.
import 'dart:convert'; import 'dart:io'; import 'dart:math' as math; import 'dart:ui' as ui; import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/guides/tree_geometry.dart'; import 'package:openstrap_edge/ui2/skeleton/skeleton.dart'; import 'guide_r2_scenes.dart';
double r2UnionArea(List<Rect> rectangles) { final xs = rectangles.expand((r) => [r.left, r.right]).toSet().toList()..sort(); var area = 0.0;
  for (var i = 1; i < xs.length; i++) { final intervals = rectangles.where((r) => r.left < xs[i] && r.right > xs[i-1])
      .map((r) => (r.top, r.bottom)).toList()..sort((a,b) => a.$1.compareTo(b.$1)); var covered = 0.0, end = double.negativeInfinity;
    for (final interval in intervals) { if (interval.$2 > end) { covered += interval.$2 - (interval.$1 > end ? interval.$1 : end);
        end = interval.$2; } } area += (xs[i] - xs[i-1]) * covered; } return area; } List<double> r2Rect(Rect r) => [r.left, r.top, r.width, r.height];
bool r2Contains(Rect outer, Rect inner) => inner.left >= outer.left - .5 && inner.top >= outer.top - .5 && inner.right <= outer.right + .5 && inner.bottom <= outer.bottom + .5;
Set<String> r2Words(String s) => RegExp(r'[\p{L}\p{N}]+', unicode: true) .allMatches(s.toLowerCase()).map((m) => m[0]!).where((word) =>
    word.length >= 3 && !const {'how', 'are', 'these', 'your', 'the', 'and', 'for', 'with', 'this', 'that', 'you', 'from', 'into', 'own', 'our',
      'can', 'not', 'but', 'has', 'have', 'was', 'were', 'its'}.contains(word)).toSet();
bool r2Control(Widget w) => w is Pressable && w.onTap != null || w is GestureDetector && (w.onTap != null || w.onLongPress != null) ||
  w is InkResponse && w.onTap != null || w is ButtonStyleButton && w.onPressed != null || w is Semantics && (w.properties.onTap != null || w.properties.button == true) ||
  w is TextField || w is Switch || w is Checkbox || w is Radio; String r2Text(Element root) => onstageElements(root).map((e) => switch (e.widget) {
  Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText() ?? '', Semantics(:final properties) => properties.label ?? '',
  _ => '', }).where((s) => s.isNotEmpty).join(' '); class R2Unit { final Element element; final Rect rect; final String text; final bool control;
  R2Unit(this.element, this.rect, this.text, this.control); }
List<R2Unit> r2Units(Element page) { final root = laidOutBox(page)!; final units = <R2Unit>[]; void walk(Element e) { final w = e.widget;
    if (w is ScreenTitle || w is NavBar || w.runtimeType.toString() == '_TabBar') return; final box = laidOutBox(e);
    if (w is Surface || w is Section || r2Control(w) || w is Text || w is RichText || w is CustomPaint || w is Image) { if (box != null) {
        final r = rectInRoot(box, root).intersect(visibleBoundsInRoot(box, root));
        if (!r.isEmpty) units.add(R2Unit(e, r, r2Text(e), onstageElements(e).any((x) => r2Control(x.widget)))); } return; }
    e.debugVisitOnstageChildren(walk); } walk(page); return units; }
List<Rect> r2Kept(Element page, GuideStep step) { final kept = <Rect>[]; for (final target in [step.target, ...step.alsoKeep]) {
    if (target.resolve(page, r2Locale) case TargetFound(:final rect)) kept.add(rect); }
  for (final content in [...step.alsoTap, ...step.alsoRead]) { kept.addAll(content.resolve(page, r2Locale).map((x) => x.rect)); } return kept; }
/// Item F: a skeleton card with a body (two or more text lines) keeps its HEADING
/// (the Section title, else the first text line) drawn dimmed at the top-left (one
/// `heading` shape on that line, no bar over it); every other line is a bar.
/// Single-line units (a tab, a button label) are plain bars.
List<String> r2HeadingViolations(R2Unit u, Element page, List<SkeletonShape> shapes) { final root = laidOutBox(page)!;
  final lines = <Rect>[]; // every visible text line of the unit, in root coordinates
  for (final e in onstageElements(u.element)) { final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is! RenderParagraph || !ro.hasSize) continue; final length = ro.text.toPlainText().length; if (length == 0) continue;
    final rows = <Rect>[]; for (final b in ro.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length))) { final r = rectInRoot(ro, root, b.toRect());
      final at = rows.indexWhere((x) => (math.min(x.bottom, r.bottom) - math.max(x.top, r.top)) > .5 * math.min(x.height, r.height));
      if (at < 0) { rows.add(r); } else { rows[at] = rows[at].expandToInclude(r); } } lines.addAll(rows); }
  if (lines.length < 2) return const []; lines.sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
  final first = lines.first; final inside = shapes.where((s) => u.rect.inflate(1).contains(s.rect.center)).toList();
  final headings = inside.where((s) => s.kind.name == 'heading').toList(); final out = <String>[]; if (headings.length != 1) {
    out.add('F: skeleton card needs exactly one dimmed heading, has ${headings.length}: ${u.text}'); } else {
    if (!headings.single.rect.inflate(1).contains(first.center)) out.add('F: heading is not on the first line: ${u.text}');
    if (headings.single.rect.center.dx > u.rect.center.dx) out.add('F: heading is not at the top-left: ${u.text}'); }
  if (inside.any((s) => (s.kind.name == 'bar' || s.kind.name == 'block') && s.rect.overlaps(first.deflate(1)))) {
    out.add('F: a bar covers the heading line: ${u.text}'); } for (final line in lines.skip(1)) {
    if (!inside.any((s) => s.kind.name == 'bar' && s.rect.overlaps(line.deflate(1)))) { out.add('F: body line is not a bar: ${u.text}'); } } return out; }
Map<String, Object?> r2Manifest(WidgetTester t, R2Mounted mounted, R2Scene scene) { final page = mounted.app.runner.routes.page!;
  final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
  final step = mounted.run.variant.steps.firstWhere((s) => s.id == scene.step); final target = overlay.targetRect;
  // Labels are an independent scene oracle: a Strain control also renders numbers, which are not words from its label; Finish is semantics-only.
  final label = switch (scene.id) { 'heart-rate-zones/open-strain' => r2Locale.homeRingStrain,
    'heart-rate-zones/open-zones' => r2Locale.dayStrainHowSet, 'heart-rate-zones/set-own-zones' => r2Locale.activityZonesSetYourOwnLink,
    'alarm-schedule/open-alarm' => r2Locale.settingsAlarmRowTitle,
    // The day on/off row prints "Alarm" in every language (guide_alarm_schedule.dart).
    'alarm-schedule/pick-day' => 'Alarm', 'alarm-schedule/set-wake-time' => r2Locale.alarmWakeTimeRowTitle,
    'add-nap/open-naps' => r2Locale.sleepDetailEditNaps, 'add-nap/log-nap' => r2Locale.napsLogANap,
    'remove-detected/open-detected' => r2Locale.activityReviewTitle, 'remove-detected/discard' => r2Locale.napsNotANapLabel,
    // The demo night is automatic, so the button reads "Set the times myself".
    'fix-sleep-times/change-times' => r2Locale.sleepDetailSetTimesMyself,
    'fix-sleep-times/back-to-automatic' => r2Locale.sleepDetailBackToAutomatic, 'delete-workout/open-history' => r2Locale.workoutTabHistory,
    'delete-workout/delete-session' => r2Locale.workoutDeleteSessionLabel, 'start-workout/start-card' => r2Locale.workoutStartSessionLabel,
    'start-workout/choose-activity' => r2Locale.activityPickerSearchLabel, 'start-workout/start' => r2Locale.activitySetupStart,
    'start-workout/finish' => r2Locale.activityLiveFinishSessionLabel, 'log-past-workout/open-history' => r2Locale.workoutTabHistory,
    'log-past-workout/log-past' => r2Locale.workoutLogPastFix, 'log-past-workout/log-it' => r2Locale.logWorkoutLogIt,
    _ => throw StateError('no label oracle for ${scene.id}'), }; final resolved = step.target.resolve(page, r2Locale);
  final targetWords = r2Words(label); Rect? targetGroup; if (resolved is TargetFound) { for (final e in onstageElements(page)) {
      if (!r2Control(e.widget) || !identical(laidOutBox(e), resolved.renderObject)) continue; var levels = 0;
      e.visitAncestorElements((parent) { if (parent is RenderObjectElement && ++levels > 2) return false; final w = parent.widget;
        if (w is Flex || w is ListView || w is SliverList) { final box = laidOutBox(parent);
          if (box != null) targetGroup = rectInRoot(box, laidOutBox(page)!); return false; } return !identical(parent, page); }); break; } }
  final kept = r2Kept(page, step); final shapes = overlay.paintedShapes; final violations = <String>[]; final units = r2Units(page);
  final records = <Map<String, Object?>>[]; final dayTabs = scene.id == 'alarm-schedule/pick-day' ? [for (var d = 0; d < 7; d++)
    if (GuideTarget.key(ValueKey('wake-day-$d')).resolve(page, r2Locale) case TargetFound(:final rect)) rect] : <Rect>[]; for (final u in units) {
    // Caption obligations are an independent oracle, not conditional on the new declarations being populated (an empty declaration must go red).
    final offeredListChoice = scene.step == 'choose-activity' && u.control;
    // The five newly covered guides: caption-offered choices, from the printed text and the screen's own keys, never from the declarations under test.
    final offeredHere = (scene.id == 'remove-detected/discard' && u.text.contains(r2Locale.napsNotANapLabel)) ||
      (scene.id == 'delete-workout/delete-session' && u.text.contains(r2Locale.workoutDeleteSessionLabel)) ||
      (dayTabs.any((r) => r.overlaps(u.rect))); final namedDetails = scene.guide == 'start-workout' && scene.step == 'start' &&
      [r2Locale.activitySetupRouteLabel, r2Locale.activitySetupHeartRateLabel, r2Locale.activitySetupPrivateLabel].any(u.text.contains);
    final keep = offeredListChoice || offeredHere || namedDetails || kept.any((r) => r.overlaps(u.rect));
    // Structural r2: a LARGE unit (taller than _kOldLargeUnit) is never skeleton for being near the target; look-alike words still apply.
    final large = u.rect.height > _kOldLargeUnit; final nearbySibling = !large && u.control && resolved is TargetFound && rectGap(u.rect, resolved.rect) <= _kOldReach;
    final competing = nearbySibling || r2Words(u.text).intersection(targetWords).isNotEmpty; final covering = shapes.where((s) => s.rect.overlaps(u.rect.deflate(.5))).toList();
    final expected = keep ? 'keep' : competing ? 'skeleton' : 'dim'; bool? tapPasses; if (r2Control(u.element.widget)) {
      final hit = HitTestResult(); WidgetsBinding.instance.hitTestInView(hit, u.rect.center, t.view.viewId);
      final control = laidOutBox(u.element); tapPasses = hit.path.any((entry) => identical(entry.target, control));
      final underCard = t.getRect(find.byKey(GuideStepCard.cardKey)).contains(u.rect.center); if (!tapPasses && !underCard && (keep || !competing)) {
        violations.add('owner: dimmed/target/caption control cannot receive pointer: ${u.text}'); }
      if (tapPasses && !underCard && !keep && competing) { violations.add('owner: skeleton look-alike receives a pointer: ${u.text}'); }
      if ((offeredListChoice || offeredHere) && !tapPasses) violations.add('P7: offered choice cannot receive pointer: ${u.text}'); }
    if (keep && covering.isNotEmpty) violations.add('P3/P7/P8: kept ${u.text} covered'); if (!keep && competing && !covering.any((s) => s.kind.name != 'dim')) {
      violations.add('P1: competing control/look-alike is not skeletonized: ${u.text}'); } if (!keep && !competing) {
      final dims = covering.where((s) => s.kind.name == 'dim').toList(); if (dims.length != 1 || !r2Contains(dims.single.rect, u.rect) || !r2Contains(u.rect, dims.single.rect)) {
        violations.add('P2: one whole dim required for ${u.element.widget.runtimeType}: ${u.text}'); }
      if (covering.any((s) => s.kind.name != 'dim')) violations.add('P1/P9: quiet content skeleton/erase: ${u.text}'); }
    if (expected == 'skeleton') violations.addAll(r2HeadingViolations(u, page, shapes)); records.add({'type': u.element.widget.runtimeType.toString(), 'text': u.text,
      'rect': r2Rect(u.rect), 'control': u.control, 'wordMatch': r2Words(u.text).intersection(targetWords).toList(),
      'expected': expected, 'tapPasses': tapPasses, 'shapeIndices': covering.map(shapes.indexOf).toList()}); }
  final rootBox = laidOutBox(page)!; final controlRects = <Rect>[]; final lookalikes = <Rect>[]; final coloured = <Rect>[];
  for (final e in onstageElements(page)) { final box = laidOutBox(e); if (box == null) continue;
    final r = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox)); if (r.isEmpty) continue; final w = e.widget;
    if (r2Control(w) && resolved is TargetFound && rectGap(r, resolved.rect) <= _kOldReach) controlRects.add(r);
    if (w is Text && r2Words(w.data ?? w.textSpan?.toPlainText() ?? '').intersection(targetWords).isNotEmpty) { lookalikes.add(r); }
    final decoration = w is DecoratedBox ? w.decoration : w is Container ? w.decoration : null;
    final color = w is ColoredBox ? w.color : w is Surface ? w.color : decoration is BoxDecoration ? decoration.color : null;
    final isColoured = color != null && color.a > 0 && (color.r - color.g).abs() + (color.g - color.b).abs() > .05;
    if (isColoured || decoration is BoxDecoration && decoration.gradient != null) coloured.add(r); } final chrome = defaultSkeletonChrome(page); for (final s in shapes) {
    if (!r2Contains(Offset.zero & r2Size, s.rect)) violations.add('P5: offscreen ${s.kind.name} ${s.rect}');
    if (!units.any((u) => r2Contains(u.rect.inflate(1), s.rect))) violations.add('P5: shape on blank scaffold ${s.rect}');
    if (chrome.any((r) => r.overlaps(s.rect))) violations.add('P4: chrome covered ${s.rect}'); if (s.kind.name == 'erase' && coloured.any((r) => r.overlaps(s.rect))) {
      violations.add('P9: erase patch on a coloured background ${s.rect}'); } if (s.kind.name != 'dim' && s.kind.name != 'erase' && s.kind.name != 'heading' &&
      ![...controlRects, ...lookalikes].any((r) => r2Contains(r.inflate(1), s.rect))) {
      violations.add('P1: skeleton is neither control nor target look-alike ${s.rect}'); } } final counts = <String, int>{'dim': 0};
  for (final shape in shapes) { counts.update(shape.kind.name, (n) => n + 1, ifAbsent: () => 1); } final area = r2UnionArea(shapes.where((s) => s.kind.name == 'dim')
    .map((s) => s.rect.intersect(Offset.zero & r2Size)).where((r) => !r.isEmpty).toList()); return {'shapeCounts': counts,
    'dimmedAreaFraction': area / (r2Size.width * r2Size.height), 'dimmedAreaDefinition': 'Union of viewport-clipped dim rectangles divided by viewport area',
    'guide': scene.guide, 'step': scene.step, 'targetLabel': label, 'caption': step.caption.of(r2Locale),
    'size': [r2Size.width, r2Size.height], 'coordinateSpace': 'logical pixels; root overlay origin', 'targetGroup': targetGroup == null ? null : r2Rect(targetGroup!),
    'target': target == null ? null : r2Rect(target), 'card': r2Rect(t.getRect(find.byKey(GuideStepCard.cardKey))),
    'chrome': chrome.map(r2Rect).toList(), 'kept': kept.map(r2Rect).toList(), 'units': records, 'shapes': [for (final s in shapes) {'kind': s.kind.name, 'rect': r2Rect(s.rect),
      'section': s.section, 'color': s.color?.toARGB32()}], 'violations': violations}; }
// The OLD placeholder policy's numbers (reach falloff, large unit), kept for this oracle only: it
// backs the P1-P9 manifest sweeps, which are skipped (hardening) until rewritten for the window rule. Production no longer has either constant.
const _kOldReach = 56.0, _kOldLargeUnit = 120.0; Future<void> r2WriteManifest(WidgetTester t, R2Scene scene, Map<String, Object?> data) async {
  // Always emitted, including failing runs; no opt-in that silently drops proof.
  final file = File('build/guides-r2/${scene.guide}/${scene.step}.json'); file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  // Capture the root overlay layer, not a newly painted imitation of the plan.
  RenderObject? object = t.element(find.byType(LiveGuideOverlay)).findRenderObject();
  while (object != null && (object is! RenderRepaintBoundary || object.size != r2Size)) { object = object.parent; }
  if (object is! RenderRepaintBoundary) throw StateError('missing root capture boundary'); final boundary = object;
  await t.runAsync(() async { final image = await boundary.toImage(); try { final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(file.path.replaceAll('.json', '.png')).writeAsBytesSync(bytes!.buffer.asUint8List()); } finally { image.dispose(); } }); }
