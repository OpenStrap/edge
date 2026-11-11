// GUIDE TARGET (phase 1) — RED-PHASE STUBS ONLY.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// What a target resolves to: always exactly one of the four, never null.
sealed class TargetResolution {
  const TargetResolution();
}

final class TargetFound extends TargetResolution {
  /// In the coordinate space of the root element passed to `resolve`.
  final Rect rect;
  const TargetFound(this.rect);
}

/// No match in the built tree, but a scrollable under the root could still
/// build one lazily (a list with extent left to discover).
final class TargetNotBuilt extends TargetResolution {
  final GuideTarget target;
  final String detail;
  const TargetNotBuilt(this.target, this.detail);
}

/// No match, and nothing left to build: the target is not on this screen
/// (also: matches that are Offstage; a `within` scope that is itself absent).
final class TargetAbsent extends TargetResolution {
  final GuideTarget target;
  final String detail;
  const TargetAbsent(this.target, this.detail);
}

/// More than one distinct control matched.
final class TargetAmbiguous extends TargetResolution {
  final GuideTarget target;

  /// Distinct controls (Text + Semantics of one control count once).
  final int count;
  final String detail;
  const TargetAmbiguous(this.target, this.count, this.detail);
}

sealed class GuideTarget {
  const GuideTarget();

  /// By translated label, matched (exactly, trimmed) against `Text` plain text
  /// and `Semantics` labels. The resolved rect grows to the nearest `Pressable`
  /// ancestor (grammar.dart:54) when there is one. Matches that belong to one
  /// control (same nearest Pressable, or one semantics node) count ONCE.
  /// [within] scopes the match to the resolved rect's subtree of another
  /// target (a Key, a Section...).
  factory GuideTarget.label(
    String Function(AppLocalizations l) label, {
    GuideTarget? within,
  }) =>
      throw UnimplementedError();

  /// As [label], accepting any of several labels (a control whose text depends
  /// on state, e.g. "Set your own zones" / "Edit your own zones").
  factory GuideTarget.anyLabel(
    List<String Function(AppLocalizations l)> alternatives, {
    GuideTarget? within,
  }) =>
      throw UnimplementedError();

  /// By Key: the keyed widget's own render box; no growing.
  factory GuideTarget.key(Key key) => throw UnimplementedError();

  /// Resolve in the laid-out tree under [root], in [root]'s coordinates.
  TargetResolution resolve(Element root, AppLocalizations l) =>
      throw UnimplementedError();
}

/// Bounded scroll discovery: resolves [target]; while it is [TargetNotBuilt],
/// jumps the scrollables under [root] one viewport at a time (no animation,
/// at most [maxViewports] steps per scrollable, outer then inner) until it is
/// found; then scrolls so the target is inside the visible viewport.
///
/// - found: returns [TargetFound] with the rect after scrolling;
/// - the end of every scrollable reached without a match: [TargetAbsent], and
///   the scroll positions are restored to where they started;
/// - [maxViewports] spent before the end: [TargetNotBuilt] (budget exhausted),
///   positions restored.
Future<TargetResolution> revealTarget(
  Element root,
  GuideTarget target,
  AppLocalizations l, {
  int maxViewports = 20,
}) =>
    throw UnimplementedError();
