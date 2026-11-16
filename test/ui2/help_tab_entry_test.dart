import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/guides/help_entry.dart';
import '../support/skeleton_fixture.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/guide_r2_scenes.dart' show r2OpenDb, r2Tab;
import '../support/live_guide_harness.dart';

const _ids = {
  GuideTopic.today: ['heart-rate-zones', 'remove-detected'],
  GuideTopic.sleep: ['alarm-schedule', 'add-nap', 'fix-sleep-times'],
  GuideTopic.activity: ['delete-workout', 'start-workout', 'log-past-workout'],
  GuideTopic.health: <String>[],
};
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    await r2OpenDb('help_tab_entry_test.db');
  });
  tearDownAll(LocalDb.close);
  for (final topic in GuideTopic.values) {
    // why: each production tab needs a reachable, stable footer that opens its own guides, with a way to all eight.
    testWidgets('${topic.name} bottom opens its guides and All guides', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      try {
        await pumpLiveGuideApp(t, brightness: Brightness.dark);
        await t.tap(r2Tab(topic.index));
        await settleLiveGuide(t);
        for (
          var i = 0;
          i < 30 && t.any(find.byType(CircularProgressIndicator));
          i++
        ) {
          await settleLiveGuide(t, frames: 4);
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final button = find.widgetWithText(
          TextButton,
          'Looking for something?',
        );
        // Scroll as a user does while the lazy sleep plan finishes its reads.
        for (var i = 0; i < 40; i++) {
          if (button.hitTestable().evaluate().isNotEmpty &&
              !t.any(find.byType(CircularProgressIndicator))) {
            break;
          }
          await t.drag(find.byType(Scrollable).first, const Offset(0, -400));
          await settleLiveGuide(t);
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(button.hitTestable(), findsOneWidget);
        final list = t.widget<ListView>(
          find.ancestor(of: button, matching: find.byType(ListView)).first,
        );
        final last =
            (list.childrenDelegate as SliverChildListDelegate).children.last;
        expect(
          find.descendant(of: find.byWidget(last), matching: button),
          findsOneWidget,
          reason: 'Help follows the last content item in the scroll view',
        );
        // A tappable centre can leave the last few pixels behind the tab bar.
        // Scroll the whole button into view before checking its full bounds.
        await t.ensureVisible(button);
        await settleLiveGuide(t);
        final rect = t.getRect(button);
        expect(rect.width, 358); // 390 px viewport, 16 px padding on each side.
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(
          rect.bottom,
          lessThan(780),
          reason: 'above the persistent bottom navigation',
        );
        final node = t.getSemantics(button).getSemanticsData();
        expect(node.label, 'Looking for something?');
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.hasAction(SemanticsAction.tap), isTrue);
        await settleLiveGuide(t);
        expect(
          t.getRect(button),
          rect,
          reason: 'settled content does not move the footer',
        );
        await t.tap(button);
        await settleLiveGuide(t);
        expect(find.byType(HelpScreen), findsOneWidget);
        for (final entry in _ids.entries) {
          for (final id in entry.value) {
            expect(
              find.byKey(HelpScreen.guideRowKey(id)),
              entry.key == topic ? findsOneWidget : findsNothing,
            );
          }
        }
        if (topic == GuideTopic.health) {
          expect(
            find.text('There are no guides for this tab yet.'),
            findsOneWidget,
          );
        }
        await t.tap(find.widgetWithText(TextButton, 'All guides'));
        await settleLiveGuide(t);
        t.view.physicalSize = const Size(390, 1800);
        await t.pump();
        // All guide rows are built in the detail scaffold, including those below the viewport.
        for (final id in _ids.values.expand((ids) => ids)) {
          expect(find.byKey(HelpScreen.guideRowKey(id)), findsOneWidget);
        }
        expect(t.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
  for (final locale in AppLocalizations.supportedLocales) {
    // why: long translations at the largest text size must wrap, with the full button still tappable.
    testWidgets('${locale.languageCode} footer wraps at large text size', (
      t,
    ) async {
      skTallView(t, w: 320, h: 844);
      await t.pumpWidget(
        skHost(
          Scaffold(
            body: Builder(
              builder: (c) => MediaQuery(
                data: MediaQuery.of(
                  c,
                ).copyWith(textScaler: TextScaler.linear(3.1)),
                child: const Align(
                  alignment: Alignment.bottomCenter,
                  child: HelpEntry(topic: GuideTopic.sleep),
                ),
              ),
            ),
          ),
          locale: locale,
        ),
      );
      await t.pump();
      final label = lookupAppLocalizations(locale).helpLookingForSomething;
      final button = find.widgetWithText(TextButton, label);
      expect(button.hitTestable(), findsOneWidget);
      expect(t.getRect(button).left, greaterThanOrEqualTo(0));
      expect(t.getRect(button).right, lessThanOrEqualTo(320));
      expect(t.getSize(button).height, greaterThanOrEqualTo(48));
      expect(t.takeException(), isNull);
    });
  }
  // why: every supported language needs translated discovery and escape labels, including Thai.
  test('Help entry labels are translated in every supported locale', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(l.helpLookingForSomething, isNotEmpty);
      expect(l.helpAllGuides, isNotEmpty);
      expect(l.helpTopicEmpty, isNotEmpty);
      if (locale.languageCode != 'en') {
        expect(l.helpLookingForSomething, isNot('Looking for something?'));
        expect(l.helpAllGuides, isNot('All guides'));
        expect(
          l.helpTopicEmpty,
          isNot('There are no guides for this tab yet.'),
        );
      }
    }
  });
}
