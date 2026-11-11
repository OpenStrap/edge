// GUIDE MODEL (phase 2) — RED-PHASE STUBS ONLY.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'guide_target.dart';

enum BandGeneration { whoop4, whoop5 }

enum GuideAction { tap, scrollThenTap }

class GuideStep {
  /// The screen, filled with demo data (never read from or written to the DB).
  final Widget Function(BuildContext context) screen;
  final GuideTarget target;
  final GuideAction action;
  final String Function(AppLocalizations l) caption;

  const GuideStep({
    required this.screen,
    required this.target,
    required this.action,
    required this.caption,
  });
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
  final List<GuideVariant> variants;
  final List<GuideFooter> footers;

  const Guide({
    required this.id,
    required this.title,
    required this.variants,
    this.footers = const [],
  });

  /// Bands any variant covers; an "any" variant covers both.
  Set<BandGeneration> get devices => throw UnimplementedError();

  /// An exact-band variant beats an "any" variant; no match -> [GuideNoVariant].
  GuideVariantResult variantFor(BandGeneration? band) =>
      throw UnimplementedError();
}
