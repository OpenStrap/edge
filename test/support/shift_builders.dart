// Tiny builders so scorer tests read as scenarios, not constructors.
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

/// 100 x 100 viewport: area 10000, longest side 100.
const vp = ShiftRect(0, 0, 100, 100);

ElementSnapshot el(
  String id,
  ShiftRect r, {
  ElementRole role = ElementRole.other,
  int color = 0xFF000000,
  bool focusable = false,
  bool focused = false,
  bool enabled = true,
}) =>
    ElementSnapshot(
      id: id,
      rect: r,
      role: role,
      colorArgb: color,
      focusable: focusable,
      focused: focused,
      enabled: enabled,
    );

Frame fr(int at, List<ElementSnapshot> e) => Frame(at, e);

Scenario sc(
  List<Frame> frames, {
  ShiftRect viewport = vp,
  List<Interaction> interactions = const [],
  List<FocusEvent> focus = const [],
  List<AnimationSpan> animations = const [],
}) =>
    Scenario(
      viewport: viewport,
      frames: frames,
      interactions: interactions,
      focus: focus,
      animations: animations,
    );

double total(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) =>
    score(s, p).total;

/// Stable text form of a report for equality checks.
String sig(ShiftReport r) => r.findings
    .map((f) => '${f.rule}|${f.elementId}|${f.atMs}|${f.score}|${f.severity}')
    .join('\n');
