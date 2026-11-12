// The Help list's data: which guides exist, how they are grouped and which
// ones a band sees.
//
// Pure tests (no widgets): grouping and filtering are functions of
// (entries, band). Synthetic guides cover the band-specific cases, because
// none of the shipped guides has a WHOOP 4 / WHOOP 5 split (see the per-guide
// tests); the shipped catalogue is pinned separately.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';

Guide _guide(String id, List<Set<BandGeneration>> variants) => Guide(
      id: id,
      title: (_) => 'Title $id',
      start: GuideStart.today,
      variants: [for (final d in variants) GuideVariant(devices: d, steps: const [])],
    );

final _any = _guide('any', [<BandGeneration>{}]);
final _only4 = _guide('only4', [{BandGeneration.whoop4}]);
final _only5 = _guide('only5', [{BandGeneration.whoop5}]);
final _split = _guide('split', [{BandGeneration.whoop4}, {BandGeneration.whoop5}]);

List<String> _ids(List<GuideTopicGroup> groups) => [for (final g in groups) for (final e in g.entries) e.guide.id];

void main() {
  group('helpGroups', () {
    final entries = [
      GuideEntry(GuideTopic.activity, _only5),
      GuideEntry(GuideTopic.sleep, _any),
      GuideEntry(GuideTopic.activity, _only4),
      GuideEntry(GuideTopic.today, _split),
      GuideEntry(GuideTopic.sleep, _only4),
    ];

    test('groups by topic in GuideTopic order, entries in list order, no empty topics', () {
      // why: the list reads like the tab bar (Today, Sleep, Activity, Health);
      // an empty "Health" heading over nothing is clutter.
      final groups = helpGroups(entries, null);
      expect([for (final g in groups) g.topic], [GuideTopic.today, GuideTopic.sleep, GuideTopic.activity]);
      expect([for (final g in groups) [for (final e in g.entries) e.guide.id]], [
        ['split'],
        ['any', 'only4'],
        ['only5', 'only4'],
      ]);
      expect(groups.every((g) => g.entries.every((e) => e.topic == g.topic)), isTrue);
    });

    test('variant filtering: WHOOP 4 keeps any, split and WHOOP 4-only; drops WHOOP 5-only', () {
      // why: a WHOOP 4 owner must not be offered a path that exists only on a
      // WHOOP 5. proves: CLAIM(help-filter)
      expect(_ids(helpGroups(entries, BandGeneration.whoop4)), ['split', 'any', 'only4', 'only4']);
    });

    test('variant filtering: WHOOP 5 keeps any, split and WHOOP 5-only; drops WHOOP 4-only', () {
      expect(_ids(helpGroups(entries, BandGeneration.whoop5)), ['split', 'any', 'only5']);
    });

    test('no band known: every guide is listed (D3)', () {
      // why: someone who has not paired yet is who asks "how do I pair"; a
      // band-specific guide opened then says which bands it covers.
      expect(_ids(helpGroups(entries, null)), ['split', 'any', 'only4', 'only5', 'only4']);
    });

    test('a topic whose guides are all filtered out disappears', () {
      // why: positive control that emptiness is judged AFTER filtering.
      final groups = helpGroups([GuideEntry(GuideTopic.health, _only5), GuideEntry(GuideTopic.sleep, _any)], BandGeneration.whoop4);
      expect([for (final g in groups) g.topic], [GuideTopic.sleep]);
    });

    test('nothing to list gives no groups', () {
      expect(helpGroups(const [], null), isEmpty);
      expect(helpGroups([GuideEntry(GuideTopic.today, _only5)], BandGeneration.whoop4), isEmpty);
    });
  });

  group('the shipped catalogue', () {
    test('guides #1-#8, once each, filed under the tab they start on', () {
      // why: #1 starts on the Today ring, #2/#3/#5 on the Sleep tab, #4 on the
      // Today "Detected activities" card, #6-#8 on the Activity tab.
      final byId = {for (final e in kGuideCatalogue) e.guide.id: e.topic};
      expect(kGuideCatalogue.map((e) => e.guide.id).toList(), [
        'heart-rate-zones',
        'alarm-schedule',
        'add-nap',
        'remove-detected',
        'fix-sleep-times',
        'delete-workout',
        'start-workout',
        'log-past-workout',
      ]);
      expect(byId, {
        'heart-rate-zones': GuideTopic.today,
        'alarm-schedule': GuideTopic.sleep,
        'add-nap': GuideTopic.sleep,
        'remove-detected': GuideTopic.today,
        'fix-sleep-times': GuideTopic.sleep,
        'delete-workout': GuideTopic.activity,
        'start-workout': GuideTopic.activity,
        'log-past-workout': GuideTopic.activity,
      });
    });

    test('grouped for an unknown band: Today, Sleep, Activity in catalogue order', () {
      final groups = helpGroups(kGuideCatalogue, null);
      expect([for (final g in groups) g.topic], [GuideTopic.today, GuideTopic.sleep, GuideTopic.activity]);
      expect([for (final g in groups) [for (final e in g.entries) e.guide.id]], [
        ['heart-rate-zones', 'remove-detected'],
        ['alarm-schedule', 'add-nap', 'fix-sleep-times'],
        ['delete-workout', 'start-workout', 'log-past-workout'],
      ]);
    });
  });

  group('live-run model: start destination and footer roles', () {
    test('a guide starts on the shell tab it is filed under', () {
      // why: GuideTopic is "the tab its first step is on"; the run brings the app
      // to Guide.start. A guide filed under Sleep that starts on Today would put
      // step 1 on a screen that cannot show it.
      for (final e in kGuideCatalogue) {
        expect(e.guide.start.name, e.topic.name, reason: e.guide.id);
      }
    });

    test('the missing-target help is the guide\'s "Don\'t see X?" footer; guides without one offer no link', () {
      // why: the step card\'s "Don\'t see it?" link expands THIS footer. Expected
      // sets are written by hand from the footers\' titles (guideXxxMissingTitle /
      // guideFixTimesBackTitle / guideDeleteNoneTitle): guides #3 and #7 have only notes.
      final l = lookupAppLocalizations(const Locale('en'));
      final withHelp = {for (final e in kGuideCatalogue) if (e.guide.missingTargetHelp != null) e.guide.id};
      expect(withHelp, {'heart-rate-zones', 'alarm-schedule', 'remove-detected', 'fix-sleep-times', 'delete-workout', 'log-past-workout'});
      for (final id in withHelp) {
        final title = kGuideCatalogue.firstWhere((e) => e.guide.id == id).guide.missingTargetHelp!.title(l);
        expect(title, endsWith('?'), reason: '$id: the missing-target footer is a question ($title)');
      }
    });

    test('the Done card shows every footer except the missing-target help, in the guide\'s order', () {
      // why: moot once done; "Another way in" first where the guide has one.
      for (final e in kGuideCatalogue) {
        final done = e.guide.doneFooters;
        expect(done.any((f) => f.kind == GuideFooterKind.missingTarget), isFalse, reason: e.guide.id);
        expect(done.length, e.guide.footers.length - (e.guide.missingTargetHelp == null ? 0 : 1), reason: e.guide.id);
      }
      final hr = kGuideCatalogue.first.guide;
      expect(hr.id, 'heart-rate-zones');
      expect(hr.doneFooters.single.kind, GuideFooterKind.anotherWay);
    });

    test('every guide has at most one missing-target footer', () {
      // why: "the" footer behind the link must be unambiguous.
      for (final e in kGuideCatalogue) {
        expect(e.guide.footers.where((f) => f.kind == GuideFooterKind.missingTarget).length, lessThanOrEqualTo(1), reason: e.guide.id);
      }
    });
  });

  group('bandGenerationOf', () {
    test('gen4 and gen5 map; anything else is unknown, never guessed', () {
      // why: PairedDevice.generation is null until a link has identified the
      // band, and holds only 'gen4' / 'gen5' (paired_device.dart:60). Guessing
      // WHOOP 4 would show a WHOOP 5 owner the wrong steps.
      expect(bandGenerationOf(PairedDevice('r', 's', generation: 'gen4')), BandGeneration.whoop4);
      expect(bandGenerationOf(PairedDevice('r', 's', generation: 'gen5')), BandGeneration.whoop5);
      expect(bandGenerationOf(PairedDevice('r', 's')), isNull);
      expect(bandGenerationOf(null), isNull);
      expect(bandGenerationOf(PairedDevice('r', 's', generation: 'ble_hrs')), isNull);
      expect(bandGenerationOf(PairedDevice('r', 's', generation: '')), isNull);
    });
  });
}
