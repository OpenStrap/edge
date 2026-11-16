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
import 'guide_navigation.dart';
import 'guide_text.dart';

export 'guide_text.dart' show GuideText;

enum BandGeneration { whoop4, whoop5 }

enum GuideAction { tap, scrollThenTap }

/// Where a guide begins: a tab of the shell, or the Settings screen. A run
/// first brings the app here (pop to the shell root, select the destination)
/// so step 1's screen is on top.
enum GuideStart { today, sleep, activity, health, settings }

/// Caption-named content resolved afresh from the live tree. Implementations
/// may select a collection (for example every currently built activity row).
/// The live overlay resolves a step's [GuideStep.alsoTap] and [GuideStep.alsoRead]
/// afresh on every plan and keeps what they return in full colour.
abstract interface class GuideContent {
  List<TargetFound> resolve(Element root, AppLocalizations l);
}

/// Page-wide content does not identify a particular neighbouring control.
/// The overlay must not keep an unrelated page's entire control list real.
abstract interface class UnscopedGuideContent implements GuideContent {}

/// The order a multi-target step's hand visits its targets in.
enum GuideVisit {
  /// One continuous wave through the targets in order and back.
  row,

  /// A vertical list: bottom up, then an upright drift back down.
  list,
}

/// A step with several targets, any of which does the step. [targets] resolves, in visiting order,
/// to every control the hover highlight marks. The step's own [GuideStep.target] stays the primary
/// (it anchors the run and is what the screen is scrolled to).
class GuideMultiTarget {
  final GuideContent targets;

  /// The short label above the targets; null: "tap one of".
  final GuideText? label;
  final GuideVisit visit;

  /// A control the guide opens ONCE per arrival at the screen (the first result is tapped when the
  /// hand reaches it; the screen takes no taps while it opens). The most a guide may do to the app:
  /// it never selects, saves or starts anything.
  final GuideContent? opens;

  /// The visiting set once [opens] has opened (null: [targets]).
  final GuideContent? afterOpen;

  /// Resolves to something while [opens]'s control is already open (the user opened it): the guide
  /// then skips its own press, which would toggle it shut.
  final GuideContent? alreadyOpen;

  /// What the label sits above once [opens] has opened (null: the visiting set), so it does not
  /// cover the rows of an open list.
  final GuideContent? labelAfterOpen;
  const GuideMultiTarget({required this.targets, this.label, this.visit = GuideVisit.row, this.opens, this.afterOpen, this.alreadyOpen, this.labelAfterOpen});
}

class GuideStep {
  /// Stable across releases and locales (progress, deep links and the phase-4
  /// "which step am I on" logic key on it). Unique within a guide variant.
  final String id;

  final GuideTarget target;

  /// Declared destination; optional only for custom/legacy guide fixtures.
  final GuideNode? node;

  /// Selects between actions on the same declared node once content arrives.
  /// In custom guides without a node, it also identifies the page.
  final GuideTarget anchor;

  /// The previous step's target must have been tapped in this run before this
  /// step can match. Used when its anchor can predate the guide, as with undo.
  final bool requiresPreviousTap;

  /// Extra units kept readable besides the target's (step 3 keeps "Your zones").
  final List<GuideTarget> alsoKeep;
  /// P7: caption-offered controls kept full colour; tapping one also completes
  /// the step, like the primary target. All page input passes
  /// through independently of this visual declaration (owner amendment A/C).
  final List<GuideContent> alsoTap;

  /// P8: caption-named information kept full colour.
  final List<GuideContent> alsoRead;
  final GuideAction action;
  final GuideText caption;

  /// The caption under reduced motion, when the step's aid differs from the animated one
  /// (a step whose caption mentions the moving highlight); null: [caption] serves both.
  final GuideText? stillCaption;

  /// The caption to show: [stillCaption] when [still] and there is one.
  GuideText captionFor({required bool still}) => still ? stillCaption ?? caption : caption;

  /// Several choices visited by the moving hand; any can perform the step.
  final GuideMultiTarget? multi;

  const GuideStep({
    required this.id,
    required this.target,
    this.node,
    required this.anchor,
    this.requiresPreviousTap = false,
    this.alsoKeep = const [],
    this.alsoTap = const [],
    this.alsoRead = const [],
    required this.action,
    required this.caption,
    this.stillCaption,
    this.multi,
  });

  /// Anchor presence for compatibility/review fixtures. The live run uses its
  /// declared navigation node, including loading states.
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
  final GuideText title;
  final GuideText body;
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
  final GuideText title;

  /// Where a run brings the app before step 1.
  final GuideStart start;

  /// One line under the title ("...it takes three taps").
  final GuideText? intro;
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

  /// Bands any variant covers; an "any" variant covers both. A variant with no
  /// steps covers nothing: a run on it would have no step to show.
  Set<BandGeneration> get devices => {
        for (final v in variants)
          if (v.steps.isNotEmpty) ...(v.devices.isEmpty ? BandGeneration.values : v.devices),
      };

  /// An exact-band variant beats an "any" variant; no match -> [GuideNoVariant].
  /// An unknown band (null) gets only an "any" variant: guessing a generation
  /// would show the wrong steps.
  GuideVariantResult variantFor(BandGeneration? band) {
    GuideVariant? any;
    for (final v in variants) {
      if (v.steps.isEmpty) continue; // nothing to run: never an empty guide
      if (band != null && v.devices.contains(band)) return GuideVariantFound(v);
      if (v.devices.isEmpty) any ??= v;
    }
    return any == null ? GuideNoVariant(id, band, devices) : GuideVariantFound(any);
  }
}
