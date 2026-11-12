// The Help entry: one "Help" row in Profile, and the HelpScreen it opens.
//
// The only existing-screen edit of this PR is that row (profile.dart). The
// screen under it lists guides grouped by topic, filtered by the paired band.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';

Guide _guide(String id, Set<BandGeneration> devices) => Guide(
      id: id,
      title: (_) => 'Title $id',
      start: GuideStart.today,
      variants: [
        GuideVariant(devices: devices, steps: [
          GuideStep(
            id: 'only',
            target: GuideTarget.label((_) => 'nowhere'),
            anchor: GuideTarget.label((_) => 'nowhere'),
            action: GuideAction.tap,
            caption: (_) => 'Caption',
          ),
        ]),
      ],
    );

List<GuideEntry> _entries() => [
      GuideEntry(GuideTopic.activity, _guide('five', {BandGeneration.whoop5})),
      GuideEntry(GuideTopic.sleep, _guide('anyone', {})),
      GuideEntry(GuideTopic.activity, _guide('four', {BandGeneration.whoop4})),
      GuideEntry(GuideTopic.today, _guide('anyone2', {})),
    ];

/// Records what Help asked of the runner; answers like a runner that started.
class _RecordingRunner extends GuideRunner {
  final calls = <(String, BandGeneration?)>[];
  GuideStartResult Function(Guide guide)? answer;
  _RecordingRunner() : super(navigatorKey: GlobalKey<NavigatorState>());

  @override
  Future<GuideStartResult> start(Guide guide, {required BandGeneration? band}) async {
    calls.add((guide.id, band));
    return answer?.call(guide) ?? GuideStarted(GuideRun(guide: guide, variant: (guide.variantFor(band) as GuideVariantFound).variant));
  }
}

Future<_RecordingRunner> _pumpHelp(WidgetTester t, {BandGeneration? band, List<GuideEntry>? guides, Locale locale = const Locale('en')}) async {
  skTallView(t, w: 390, h: 3000);
  final runner = _RecordingRunner();
  addTearDown(runner.dispose);
  await t.pumpWidget(ChangeNotifierProvider<GuideRunner>.value(
    value: runner,
    child: skHost(HelpScreen(band: band, guides: guides), locale: locale),
  ));
  await t.pumpAndSettle();
  return runner;
}

Widget _profileHost(Widget home, {AppState? app}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<LocaleController>.value(value: LocaleController.seed(null)),
        if (app != null) ChangeNotifierProvider<AppState>.value(value: app),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the Profile row', () {
    testWidgets('"Help" is a row of its own, directly under "Settings"', (t) async {
      // why: the owner's entry point; "near Settings" - the same group, right
      // after it, so people who look for settings find it.
      skTallView(t, w: 390, h: 3000);
      await t.pumpWidget(_profileHost(const ProfileHomeView(stats: ProfileStats(name: 'Tester'))));
      await t.pumpAndSettle();
      final l = lookupAppLocalizations(const Locale('en'));
      final rows = t.widgetList<SetRow>(find.byType(SetRow)).toList();
      final settings = rows.indexWhere((r) => r.title == l.profileSettingsRow);
      final help = rows.indexWhere((r) => r.title == l.profileHelpRow);
      expect(settings, isNonNegative, reason: 'fixture sanity: the Settings row exists');
      expect(help, settings + 1, reason: 'Help is the row right after Settings');
      expect(rows.where((r) => r.title == l.profileHelpRow), hasLength(1));
    });

    for (final (gen, expected) in [
      ('gen5', BandGeneration.whoop5),
      ('gen4', BandGeneration.whoop4),
      (null, null),
    ]) {
      testWidgets('tapping it opens the HelpScreen for the paired band (${gen ?? 'no band'})', (t) async {
        // why: "opening a HelpScreen that lists guides filtered by the paired
        // band generation" - the row must hand the screen the band.
        final app = AppState.forTesting();
        addTearDown(app.dispose);
        if (gen != null) app.paired = PairedDevice('remote', 'SN', generation: gen);
        skTallView(t, w: 390, h: 3000);
        await t.pumpWidget(_profileHost(const ProfileHome(), app: app));
        await t.pumpAndSettle();
        final l = lookupAppLocalizations(const Locale('en'));
        expect(find.text(l.profileHelpRow), findsOneWidget, reason: 'the Help row is on Profile');
        await t.tap(find.text(l.profileHelpRow));
        await t.pumpAndSettle();
        expect(find.byType(HelpScreen), findsOneWidget);
        expect(t.widget<HelpScreen>(find.byType(HelpScreen)).band, expected);
      });
    }

    for (final locale in AppLocalizations.supportedLocales) {
      test('${locale.languageCode}: the row label exists and is translated', () {
        // why: every shipped locale, per the PR checklist.
        final l = lookupAppLocalizations(locale);
        expect(l.profileHelpRow, isNotEmpty);
        if (locale.languageCode != 'en') expect(l.profileHelpRow, isNot(lookupAppLocalizations(const Locale('en')).profileHelpRow));
      });
    }
  });

  group('the Help list', () {
    testWidgets('groups guides under topic headings in tab order and shows each guide\'s title', (t) async {
      // why: the owner asked for guides "grouped by topic".
      await _pumpHelp(t, guides: _entries());
      final today = t.getRect(find.byKey(HelpScreen.topicKey(GuideTopic.today)));
      final sleep = t.getRect(find.byKey(HelpScreen.topicKey(GuideTopic.sleep)));
      final activity = t.getRect(find.byKey(HelpScreen.topicKey(GuideTopic.activity)));
      expect(find.byKey(HelpScreen.topicKey(GuideTopic.health)), findsNothing, reason: 'no empty topic');
      expect(today.top, lessThan(sleep.top));
      expect(sleep.top, lessThan(activity.top));
      double row(String id) => t.getRect(find.byKey(HelpScreen.guideRowKey(id))).top;
      expect(row('anyone2'), allOf(greaterThan(today.top), lessThan(sleep.top)));
      expect(row('anyone'), allOf(greaterThan(sleep.top), lessThan(activity.top)));
      expect(row('five'), lessThan(row('four')), reason: 'catalogue order inside a topic');
      expect(row('five'), greaterThan(activity.top));
      for (final id in ['five', 'anyone', 'four', 'anyone2']) {
        expect(find.descendant(of: find.byKey(HelpScreen.guideRowKey(id)), matching: find.text('Title $id')), findsOneWidget);
      }
    });

    testWidgets('filters by band: WHOOP 4, WHOOP 5 and no band', (t) async {
      // why: proves CLAIM(help-filter) through the widget: the rows on screen
      // are exactly the guides the band can use.
      Set<String> shown() => {
            for (final e in _entries())
              if (t.any(find.byKey(HelpScreen.guideRowKey(e.guide.id)))) e.guide.id,
          };
      await _pumpHelp(t, band: BandGeneration.whoop4, guides: _entries());
      expect(shown(), {'anyone', 'four', 'anyone2'});
      await _pumpHelp(t, band: BandGeneration.whoop5, guides: _entries());
      expect(shown(), {'anyone', 'five', 'anyone2'});
      await _pumpHelp(t, band: null, guides: _entries());
      expect(shown(), {'anyone', 'four', 'five', 'anyone2'});
    });

    testWidgets('when nothing fits the band the screen says so', (t) async {
      // why: a blank list reads as a broken app.
      await _pumpHelp(t, band: BandGeneration.whoop4, guides: [GuideEntry(GuideTopic.today, _guide('five', {BandGeneration.whoop5}))]);
      expect(find.byKey(HelpScreen.emptyKey), findsOneWidget);
      expect(find.byKey(HelpScreen.guideRowKey('five')), findsNothing);
      await _pumpHelp(t, band: null, guides: _entries());
      expect(find.byKey(HelpScreen.emptyKey), findsNothing, reason: 'positive control');
    });

    testWidgets('a row starts a LIVE run of that guide for the same band (no walkthrough route)', (t) async {
      // why: CLAIM(help-starts-live). The list is useless unless a row leads to
      // the guide, and the owner chose the real screens over a demo walkthrough:
      // the row asks the runner, and pushes nothing itself.
      final runner = await _pumpHelp(t, band: BandGeneration.whoop4, guides: _entries());
      expect(find.byKey(HelpScreen.guideRowKey('four')), findsOneWidget);
      await t.tap(find.byKey(HelpScreen.guideRowKey('four')));
      await t.pumpAndSettle();
      expect(runner.calls, [('four', BandGeneration.whoop4)]);
      expect(find.byType(HelpScreen), findsOneWidget, reason: 'popping to the shell root is the runner\'s job');
      expect(find.byType(Scaffold), findsOneWidget, reason: 'no walkthrough page was pushed');
    });

    testWidgets('an unknown band and a guide with only band-specific variants: asks which band, then starts with the answer', (t) async {
      // why: "picker when none" (spec, band variants unchanged): guessing a
      // generation would show the wrong steps. The picker offers the bands the
      // guide covers, by their brand names.
      final both = _guide('both', {BandGeneration.whoop4, BandGeneration.whoop5});
      final runner = await _pumpHelp(t, band: null, guides: [GuideEntry(GuideTopic.today, both)]);
      await t.tap(find.byKey(HelpScreen.guideRowKey('both')));
      await t.pumpAndSettle();
      expect(runner.calls, isEmpty, reason: 'nothing starts before the user answers');
      expect(find.byKey(HelpScreen.bandPickerKey), findsOneWidget);
      expect(find.text(lookupAppLocalizations(const Locale('en')).guidePickBand), findsOneWidget);
      expect(find.text('WHOOP 4'), findsOneWidget);
      expect(find.text('WHOOP 5'), findsOneWidget);
      await t.tap(find.text('WHOOP 5'));
      await t.pumpAndSettle();
      expect(runner.calls, [('both', BandGeneration.whoop5)]);
    });

    testWidgets('an "any" guide starts at once for an unknown band: no picker', (t) async {
      // why: positive control for the test above - the picker is only for guides that need it.
      final runner = await _pumpHelp(t, band: null, guides: _entries());
      await t.tap(find.byKey(HelpScreen.guideRowKey('anyone')));
      await t.pumpAndSettle();
      expect(find.byKey(HelpScreen.bandPickerKey), findsNothing);
      expect(runner.calls, [('anyone', null)]);
    });

    testWidgets('a runner that finds no variant for the band: the screen says so and lists the bands covered', (t) async {
      // why: "a guide with no variant for the user\'s band says so".
      final runner = await _pumpHelp(t, band: BandGeneration.whoop4, guides: _entries());
      runner.answer = (g) => GuideStartNoVariant(GuideNoVariant(g.id, BandGeneration.whoop4, {BandGeneration.whoop5}));
      await t.tap(find.byKey(HelpScreen.guideRowKey('four')));
      await t.pumpAndSettle();
      expect(find.byKey(HelpScreen.noVariantKey), findsOneWidget);
      expect(find.textContaining('WHOOP 5'), findsOneWidget);
    });

    testWidgets('the shipped catalogue: all eight guides for an unknown band, titles in the app language', (t) async {
      // why: the default list is the catalogue; rows show the translated title.
      await _pumpHelp(t, locale: const Locale('ru'));
      final l = lookupAppLocalizations(const Locale('ru'));
      expect(kGuideCatalogue, hasLength(8));
      for (final e in kGuideCatalogue) {
        final row = find.byKey(HelpScreen.guideRowKey(e.guide.id));
        expect(row, findsOneWidget, reason: e.guide.id);
        expect(find.descendant(of: row, matching: find.text(e.guide.title(l))), findsOneWidget);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('semantics: headings are headings, rows are tappable and named by the guide, read in order', (t) async {
      // why: Sol finding 9. A screen-reader user must hear each topic heading
      // and then the guides under it, in the visual order, and be able to jump
      // by heading.
      final handle = t.ensureSemantics();
      await _pumpHelp(t, guides: _entries());
      final headingKeys = [for (final tp in [GuideTopic.today, GuideTopic.sleep, GuideTopic.activity]) HelpScreen.topicKey(tp)];
      final rowIds = ['anyone2', 'anyone', 'five', 'four']; // today, sleep, activity x2
      for (final k in headingKeys) {
        expect(find.byKey(k), findsOneWidget);
        expect(t.getSemantics(find.byKey(k)), isSemantics(isHeader: true), reason: '$k is a heading');
        expect(t.getSemantics(find.byKey(k)).label, isNotEmpty);
      }
      for (final id in rowIds) {
        final row = find.byKey(HelpScreen.guideRowKey(id));
        expect(row, findsOneWidget);
        final data = t.getSemantics(row).getSemanticsData();
        expect(data.label, contains('Title $id'));
        expect(data.hasAction(SemanticsAction.tap), isTrue);
      }
      final labels = skTraversalLabels(t);
      int at(Finder f) {
        final label = t.getSemantics(f).label;
        // Exact first: 'Title anyone' is a prefix of 'Title anyone2', and a
        // substring match alone would find the wrong row.
        var i = labels.indexWhere((l) => l == label);
        if (i < 0) i = labels.indexWhere((l) => l.contains(label));
        expect(i, isNonNegative, reason: '"$label" announced; got $labels');
        return i;
      }

      final order = [
        at(find.byKey(headingKeys[0])), at(find.byKey(HelpScreen.guideRowKey('anyone2'))),
        at(find.byKey(headingKeys[1])), at(find.byKey(HelpScreen.guideRowKey('anyone'))),
        at(find.byKey(headingKeys[2])), at(find.byKey(HelpScreen.guideRowKey('five'))), at(find.byKey(HelpScreen.guideRowKey('four'))),
      ];
      expect(order, [...order]..sort(), reason: 'heading, its rows, next heading...; got $order in $labels');
      expect(order.toSet(), hasLength(order.length));
      handle.dispose();
    });

    testWidgets('semantics: a topic that is filtered away, and the empty message, are announced correctly', (t) async {
      // why: hidden rows must not linger in the semantics tree.
      final handle = t.ensureSemantics();
      await _pumpHelp(t, band: BandGeneration.whoop4, guides: _entries());
      final labels = skTraversalLabels(t);
      expect(labels.any((l) => l.contains('Title five')), isFalse, reason: 'the WHOOP 5-only guide is filtered out and not announced');
      expect(labels.any((l) => l.contains('Title four')), isTrue);
      handle.dispose();
    });
  });
}
