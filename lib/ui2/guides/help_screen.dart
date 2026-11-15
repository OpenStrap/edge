// HELP SCREEN: the list of guides, grouped by topic. A row starts a LIVE run
// (guide_runner.dart) on the user's own screens.
//
//  * title = the Profile row's label ("Help");
//  * one heading per non-empty topic ([topicKey]) and one row per guide
//    ([guideRowKey], showing the guide's title), grouped via [helpGroups];
//  * a tap on a row starts a live run of that guide for [band] ([GuideRunner]);
//  * when no guide can be shown for the band, [emptyKey] says so (a visible
//    message, never a blank screen).
//
// Topic headings are `isHeader` semantics nodes and each row is one tappable
// node named by its guide, so a screen reader reads heading, its rows, next
// heading in the visual order and can jump by heading.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../screens/metric_detail.dart' show detailScaffold;
import '../ui2.dart';
import 'guide.dart';
import 'guide_catalogue.dart';
import 'guide_runner.dart';

class HelpScreen extends StatelessWidget {
  /// The paired band's generation; null = no band known (list everything).
  final BandGeneration? band;

  /// What the list offers. Defaults to the shipped catalogue; injectable so
  /// the grouping and filtering are testable with band-specific guides.
  final List<GuideEntry>? guides;

  const HelpScreen({super.key, this.band, this.guides});

  static ValueKey<String> topicKey(GuideTopic topic) => ValueKey('help-topic-${topic.name}');
  static ValueKey<String> guideRowKey(String guideId) => ValueKey('help-guide-$guideId');
  static const emptyKey = ValueKey('help-empty');

  /// Shown when a band-specific guide is opened with no known band.
  static const bandPickerKey = ValueKey('help-band-picker');

  /// Shown instead of starting when the guide does not cover [band].
  static const noVariantKey = ValueKey('help-no-variant');

  static String _topicName(AppLocalizations l, GuideTopic topic) => switch (topic) {
        GuideTopic.today => l.tabToday,
        GuideTopic.sleep => l.tabSleep,
        GuideTopic.activity => l.tabActivity,
        GuideTopic.health => l.tabHealth,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    final p = P.of(context);
    final groups = helpGroups(guides ?? kGuideCatalogue, band);
    return detailScaffold(context, l.profileHelpRow, [
      const SizedBox(height: S.x2),
      if (groups.isEmpty)
        Surface(
          key: emptyKey,
          child: Text(l.helpEmpty, style: F.body.copyWith(color: p.ink2)),
        )
      else
        for (final group in groups) ...[
          Semantics(
            key: topicKey(group.topic),
            container: true,
            header: true,
            child: Padding(
              padding: const EdgeInsets.only(top: S.x4, bottom: S.x2),
              child: Text(_topicName(l, group.topic), style: F.over.copyWith(color: p.ink3)),
            ),
          ),
          for (final entry in group.entries)
            Semantics(
              key: guideRowKey(entry.guide.id),
              container: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: S.x2),
                child: Surface(
                  onTap: () => _open(context, entry.guide),
                  child: Row(children: [
                    Expanded(child: Text(entry.guide.title.of(l), style: F.body.copyWith(color: p.ink))),
                    const SizedBox(width: S.x2),
                    Icon(LucideIcons.chevronRight, size: 18, color: p.ink3),
                  ]),
                ),
              ),
            ),
        ],
    ]);
  }

  /// Starts a live run of [guide]. The Help screen is a route above the shell:
  /// the runner pops to the shell root first, so this screen is gone when the
  /// run begins.
  ///
  /// A guide with only band-specific variants and no known band asks which band
  /// first ([bandPickerKey]); a band the guide does not cover says so
  /// ([noVariantKey]) and starts nothing.
  /// CLAIM(help-starts-live): a row starts a LIVE run (no walkthrough route)
  /// [help_screen_test 'a row starts a live run'].
  void _open(BuildContext context, Guide guide) async {
    final runner = context.read<GuideRunner>();
    final l = AppLocalizations.of(context)!;
    var selected = band;
    if (selected == null && guide.variantFor(null) is GuideNoVariant) {
      selected = await showDialog<BandGeneration>(context: context, builder: (c) => SimpleDialog(
        key: bandPickerKey, title: Text(l.guidePickBand), children: [
          for (final generation in BandGeneration.values)
            if (guide.devices.contains(generation)) SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(generation),
              child: Text(generation == BandGeneration.whoop4 ? 'WHOOP 4' : 'WHOOP 5'),
            ),
        ],
      ));
      if (!context.mounted || selected == null) return;
    }
    final result = await runner.start(guide, band: selected);
    if (result is GuideStartNoVariant && context.mounted) {
      final bands = result.reason.available.map((g) => g == BandGeneration.whoop4 ? 'WHOOP 4' : 'WHOOP 5').join(', ');
      showDialog<void>(context: context, builder: (_) => AlertDialog(
        key: noVariantKey, content: Text(l.guideNoVariantBody(bands)),
      ));
    }
  }
}
