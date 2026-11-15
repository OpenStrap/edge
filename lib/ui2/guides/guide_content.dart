// GUIDE CONTENT: caption-named content a step keeps in full colour (P7 offered
// controls via [GuideStep.alsoTap], P8 readable details via [GuideStep.alsoRead]).
// Resolved afresh from the live tree on every plan; nothing is stored.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

import '../activity/picker.dart' show ActivityRow;
import '../grammar.dart' show Pressable;
import 'guide.dart';
import 'guide_labels.dart';
import 'guide_target.dart';
import 'tree_geometry.dart';

/// Every pressable ROW built on the page (smaller than half the page, so a
/// page-wide tap area never counts): the list a caption offers ("tap one in the
/// list"), however many rows the page has built right now.
class PressableRows implements UnscopedGuideContent {
  const PressableRows();

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) return const [];
    final found = <TargetFound>[];
    for (final e in onstageElements(root)) {
      final w = e.widget;
      final box = laidOutBox(e);
      if (w is! Pressable || w.onTap == null || box == null) continue;
      final rect = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox));
      if (rect.isEmpty || box.size.height > rootBox.size.height / 2) continue;
      found.add(TargetFound(rect, renderObject: box));
    }
    return found;
  }
}

/// The controls or texts the screen prints under these [labels] (those that
/// resolve to exactly one place).
class LabelledContent implements GuideContent {
  final List<GuideText> labels;
  const LabelledContent(this.labels);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    for (final label in labels)
      if (GuideTarget.label(label).resolve(root, l) case final TargetFound found) found,
  ];
}

/// EVERY control the screen prints under these [labels], not just one: "Every item
/// has its own Discard", "the bin at the end of the session's row". Each is a
/// control the caption offers, so each stays legible and keeps its real tap.
class EveryLabelled implements GuideContent {
  final List<GuideText> labels;
  const EveryLabelled(this.labels);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    for (final label in labels) ...everyControlLabelled(root, label, l),
  ];
}

/// The widgets the screen keys with these [keys] (each that resolves to exactly one
/// place): the seven day tabs of the alarm screen.
class KeyedContent implements GuideContent {
  final List<Key> keys;
  const KeyedContent(this.keys);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    for (final key in keys)
      if (GuideTarget.key(key).resolve(root, l) case final TargetFound found) found,
  ];
}


/// One target as content (so a multi-target step can list a target next to other content).
class TargetContent implements GuideContent {
  final GuideTarget target;
  const TargetContent(this.target);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    if (target.resolve(root, l) case final TargetFound found) found,
  ];
}

/// Several contents, in order.
class ContentList implements GuideContent {
  final List<GuideContent> parts;
  const ContentList(this.parts);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [for (final p in parts) ...p.resolve(root, l)];
}

TargetFound? _visibleFound(Element e, RenderBox rootBox) {
  final box = laidOutBox(e);
  if (box == null) return null;
  final rect = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox));
  return rect.isEmpty ? null : TargetFound(rect, renderObject: box);
}

/// The Keep, Discard and Edit buttons of the FIRST item that waits for review, in that order (the
/// review screen keys them per item). The remove-detected step 2 points at all three.
class ReviewRowButtons implements GuideContent {
  const ReviewRowButtons();

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    ...everyControlLabelled(root, ScreenLabel.napsNotANapLabel, l),
    ...everyControlLabelled(root, ScreenLabel.activityNotAWorkout, l),
  ];
}

/// The recent / quick-start chips of the activity picker (left to right).
class PickerChips implements GuideContent {
  const PickerChips();

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) return const [];
    return [
      for (final e in onstageElements(root))
        if (e.widget.runtimeType.toString() == '_Quick')
          if (_visibleFound(e, rootBox) case final TargetFound found) found,
    ];
  }
}

/// The group headers of the activity picker (top to bottom): the pressable rows that carry the
/// turning chevron.
class PickerGroupHeaders implements GuideContent {
  const PickerGroupHeaders();

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) return const [];
    return [
      for (final e in onstageElements(root))
        if (e.widget is Pressable && onstageElements(e).any((c) => c.widget is AnimatedRotation))
          if (_visibleFound(e, rootBox) case final TargetFound found) found,
    ];
  }
}

/// The headers of the picker's open groups (the chevron has turned): resolves to something exactly while
/// a group is open, whether or not the header is in view. Read from the widgets' state, not from geometry,
/// so a group that is still opening counts.
class PickerOpenGroup implements GuideContent {
  const PickerOpenGroup();

  static bool _turned(Element e) {
    final w = e.widget;
    return w is AnimatedRotation && w.turns != 0;
  }

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) return const [];
    return [
      for (final e in onstageElements(root))
        if (e.widget is Pressable && onstageElements(e).any(_turned))
          if (laidOutBox(e) case final RenderBox box) TargetFound(rectInRoot(box, rootBox), renderObject: box),
    ];
  }
}

/// The first [count] activity rows the picker shows (those of the open group).
class PickerRows implements GuideContent {
  final int count;
  const PickerRows(this.count);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) return const [];
    final out = <TargetFound>[];
    for (final e in onstageElements(root)) {
      if (e.widget is! ActivityRow) continue;
      final found = _visibleFound(e, rootBox);
      if (found != null) out.add(found);
      if (out.length >= count) break;
    }
    return out;
  }
}

/// The first of [inner]'s results (the control a guide opens).
class FirstOf implements GuideContent {
  final GuideContent inner;
  const FirstOf(this.inner);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => inner.resolve(root, l).take(1).toList();
}
