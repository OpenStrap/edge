// GUIDE TARGET (phase 1) — RED-PHASE STUBS ONLY.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

enum TargetFailure {
  /// Nothing in the tree matched (or the match was Offstage / not laid out).
  noMatch,

  /// More than one match: a guide that points at "the first one" is a guess.
  ambiguous,
}

/// What a target resolves to: always one of the two, never null / empty.
sealed class TargetResolution {
  const TargetResolution();
}

final class TargetFound extends TargetResolution {
  /// In the coordinate space of the root element passed to `resolve`.
  final Rect rect;
  const TargetFound(this.rect);
}

final class TargetNotFound extends TargetResolution {
  final GuideTarget target;
  final TargetFailure reason;

  /// Human-readable: what was looked for, and how many matched.
  final String detail;
  const TargetNotFound(this.target, this.reason, this.detail);
}

sealed class GuideTarget {
  const GuideTarget();

  /// By translated label, matched (exactly, trimmed) against `Text` data /
  /// plain text and explicit `Semantics` labels. The resolved rect grows to the
  /// nearest `Pressable` ancestor (grammar.dart:54) when there is one, so the
  /// outline wraps the whole tappable thing, not its caption.
  factory GuideTarget.label(String Function(AppLocalizations l) label) =>
      throw UnimplementedError();

  /// By Key: the keyed widget's own render box; no growing.
  factory GuideTarget.key(Key key) => throw UnimplementedError();

  /// Resolve in the laid-out tree under [root], in [root]'s coordinates.
  TargetResolution resolve(Element root, AppLocalizations l) =>
      throw UnimplementedError();
}
