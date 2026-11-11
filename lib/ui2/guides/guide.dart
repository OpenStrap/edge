// GUIDE MODEL (phase 2)
//
// One guide definition drives two renderers: the demo frame (GuideStepView /
// GuideView, filled with demo data) and, in phase 4, a live overlay on the
// user's own screen. Steps are data; nothing here builds a frame.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'guide_target.dart';

enum BandGeneration { whoop4, whoop5 }

enum GuideAction { tap, scrollThenTap }

class GuideStep {
  /// Stable across releases and locales (progress, deep links and the phase-4
  /// "which step am I on" logic key on it). Unique within a guide variant.
  final String id;

  /// The screen, filled with demo data (never read from or written to the DB).
  final Widget Function(BuildContext context) screen;
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
    required this.screen,
    required this.target,
    required this.anchor,
    this.alsoKeep = const [],
    required this.action,
    required this.caption,
  });

  /// True when [anchor] resolves (found) under [root].
  bool isActive(Element root, AppLocalizations l) => anchor.resolve(root, l) is TargetFound;
}

class GuideFooter {
  final String Function(AppLocalizations l) title;
  final String Function(AppLocalizations l) body;
  const GuideFooter({required this.title, required this.body});
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

  /// One line under the title ("...it takes three taps").
  final String Function(AppLocalizations l)? intro;
  final List<GuideVariant> variants;
  final List<GuideFooter> footers;

  const Guide({
    required this.id,
    required this.title,
    this.intro,
    required this.variants,
    this.footers = const [],
  });

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
