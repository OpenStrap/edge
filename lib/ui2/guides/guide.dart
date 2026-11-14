// GUIDE MODEL (phase 2)
//
// A guide is data: where it starts, its steps (each a target on one of the
// user's REAL screens), and its footers. The live overlay walks the user's own
// screens along it. Nothing here builds a screen; review renders on demo data
// are test tooling (test/support/guide_view.dart) and keep their own map from
// step id to demo screen.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'guide_target.dart';

enum BandGeneration { whoop4, whoop5 }

enum GuideAction { tap, scrollThenTap }

/// Where a guide begins: a tab of the shell, or the Settings screen. A run
/// first brings the app here (pop to the shell root, select the destination)
/// so step 1's screen is on top.
enum GuideStart { today, sleep, activity, health, settings }

class GuideStep {
  /// Stable across releases and locales (progress, deep links and the phase-4
  /// "which step am I on" logic key on it). Unique within a guide variant.
  final String id;

  final GuideTarget target;

  /// Identifies the route this step belongs to: the step is ACTIVE when this
  /// resolves on the current screen (and not on the others' screens).
  final GuideTarget anchor;

  /// Extra units kept readable besides the target's (step 3 keeps "Your zones").
  final List<GuideTarget> alsoKeep;
  final GuideAction action;
  final String Function(AppLocalizations l) caption;

  const GuideStep({
    required this.id,
    required this.target,
    required this.anchor,
    this.alsoKeep = const [],
    required this.action,
    required this.caption,
  });

  /// True when [anchor] resolves (found) under [root].
  bool isActive(Element root, AppLocalizations l) => anchor.resolve(root, l) is TargetFound;
}

/// What a footer is for; the live card picks footers by it.
enum GuideFooterKind {
  /// "Another way in": a second route to the same place. Shown on the Done card.
  anotherWay,

  /// "Don't see X?": why the target may be missing and what to do. The step
  /// card's "Don't see it?" link expands it in place during a step.
  missingTarget,

  /// Anything else worth saying once the guide is done ("What deleting does").
  note,
}

class GuideFooter {
  final GuideFooterKind kind;
  final String Function(AppLocalizations l) title;
  final String Function(AppLocalizations l) body;
  const GuideFooter({required this.kind, required this.title, required this.body});
}

class GuideVariant {
  /// Empty = any band.
  final Set<BandGeneration> devices;
  final List<GuideStep> steps;
  const GuideVariant({this.devices = const {}, required this.steps});
}

sealed class GuideVariantResult {
  const GuideVariantResult();
}

final class GuideVariantFound extends GuideVariantResult {
  final GuideVariant variant;
  const GuideVariantFound(this.variant);
}

/// "This guide has nothing for your band" — said, never an empty guide.
final class GuideNoVariant extends GuideVariantResult {
  final String guideId;

  /// The band asked about (null = unknown band).
  final BandGeneration? band;

  /// The bands the guide does cover.
  final Set<BandGeneration> available;
  const GuideNoVariant(this.guideId, this.band, this.available);
}

class Guide {
  final String id;
  final String Function(AppLocalizations l) title;

  /// Where a run brings the app before step 1.
  final GuideStart start;

  /// One line under the title ("...it takes three taps").
  final String Function(AppLocalizations l)? intro;
  final List<GuideVariant> variants;
  final List<GuideFooter> footers;

  const Guide({
    required this.id,
    required this.title,
    required this.start,
    this.intro,
    required this.variants,
    this.footers = const [],
  });

  /// The footer behind the step card's "Don't see it?" link, or null when the
  /// guide has none (then the link is not offered).
  GuideFooter? get missingTargetHelp {
    for (final f in footers) {
      if (f.kind == GuideFooterKind.missingTarget) return f;
    }
    return null;
  }

  /// What the Done card shows: every footer except the missing-target help
  /// (moot once the guide is done), in definition order.
  List<GuideFooter> get doneFooters =>
      [for (final f in footers) if (f.kind != GuideFooterKind.missingTarget) f];

  /// Bands any variant covers; an "any" variant covers both.
  Set<BandGeneration> get devices => {
        for (final v in variants)
          ...(v.devices.isEmpty ? BandGeneration.values : v.devices),
      };

  /// An exact-band variant beats an "any" variant; no match -> [GuideNoVariant].
  /// An unknown band (null) gets only an "any" variant: guessing a generation
  /// would show the wrong steps.
  GuideVariantResult variantFor(BandGeneration? band) {
    GuideVariant? any;
    for (final v in variants) {
      if (band != null && v.devices.contains(band)) return GuideVariantFound(v);
      if (v.devices.isEmpty) any ??= v;
    }
    return any == null ? GuideNoVariant(id, band, devices) : GuideVariantFound(any);
  }
}
