// First-run "Pair your band": the list, the filter pills, the strap-only
// sheet, the always-open Trouble connecting card and the way out. Rendered with fakes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ui2/community_links.dart';
import 'package:openstrap_edge/ui2/pairing/pair_band_view.dart';
import 'package:openstrap_edge/ui2/pairing/pair_help.dart' show PairLinkOpener;
import 'package:openstrap_edge/ui2/pairing/pair_text.dart' show PairFilter;

import 'support/pair_ui_support.dart';

class _Links implements PairLinkOpener {
  final opened = <String>[];
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

class _Host implements PairBandHost {
  final void Function(BandEntry) onPick;
  final VoidCallback onStrap;
  _Host(this.onPick, this.onStrap);
  @override
  void pickBand(BandEntry entry) => onPick(entry);
  @override
  void strapOnlyConfirmed() => onStrap();
}

Finder _row(BandEntry e) => find.byKey(ValueKey('band-row-${e.id}'));

void main() {
  group('which devices the first run offers', () {
    test('only the WHOOP bands', () {
      final ids = [for (final e in firstRunBandEntries()) e.id];
      expect(ids, ['gen4', 'gen5']);
      // Other bands pair as additional devices from "Add a device"; sensors,
      // scales and the thermometer are never a main device.
      for (final id in ['oura', 'colmi', 'miband234', 'ultrahuman', 'pebble', 'coros', 'garmin',
          'ble_hrs', 'polar_pmd', 'thermometer', 'miscale_bc', 'miscale2']) {
        expect(ids, isNot(contains(id)), reason: id);
      }
    });
  });

  group('PairBandView', () {
    Widget view({
      List<BandEntry>? entries,
      ValueChanged<BandEntry>? onPick,
      VoidCallback? onStrap,
      VoidCallback? onSkip,
      VoidCallback? onBack,
      String? problem,
      _Links? links,
    }) =>
        PairBandView(
          entries: entries ?? firstRunBandEntries(),
          host: _Host(onPick ?? (_) {}, onStrap ?? () {}),
          onSkip: onSkip,
          onBack: onBack,
          problem: problem,
          openLink: links ?? _Links(),
        );

    testWidgets('title, subtitle, and one row per device with what it sends', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      expect(find.text('Set up'), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-band-title')), findsOneWidget);
      expect(find.text('Pair your band'), findsOneWidget);
      expect(find.text('Pick the one you wear. We will look for it nearby.'), findsOneWidget);
      for (final e in firstRunBandEntries()) {
        expect(_row(e), findsOneWidget, reason: e.id);
        expect(
            find.descendant(
                of: _row(e),
                matching: find.text('Sleep, recovery, strain, heart rate and more')),
            findsOneWidget,
            reason: e.id);
      }
    });



    testWidgets('the WHOOP description is not shown under other devices', (t) async {
      await pumpPair(t, view(entries: [kWhoopGen5, kOura, kColmi]),
          size: const Size(412, 2400));
      const line = 'Sleep, recovery, strain, heart rate and more';
      expect(find.descendant(of: _row(kWhoopGen5), matching: find.text(line)),
          findsOneWidget);
      for (final e in [kOura, kColmi]) {
        expect(_row(e), findsOneWidget, reason: e.id);
        expect(find.descendant(of: _row(e), matching: find.text(line)),
            findsNothing,
            reason: e.id);
      }
    });

    testWidgets('says plainly that only WHOOP is the main band', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsOneWidget);
      expect(find.text('Main band: WHOOP 4.0 or WHOOP 5.0/MG only. Other devices can be added as additional devices.'), findsOneWidget);
    });

    testWidgets('each row carries the Every day chip', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      for (final e in firstRunBandEntries()) {
        expect(find.descendant(of: _row(e), matching: find.text('Every day')), findsOneWidget,
            reason: e.id);
        expect(find.descendant(of: _row(e), matching: find.text('Workouts only')), findsNothing,
            reason: e.id);
      }
    });

    testWidgets('never says what a band would NOT send, nor primary/secondary/tier', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      for (final w in ['Doesn’t send', 'primary', 'Primary', 'secondary', 'Secondary', 'Tier', 'Experimental']) {
        expect(find.textContaining(w), findsNothing, reason: w);
      }
    });

    testWidgets('pills show only the groups in the list; Rings narrows it', (t) async {
      // The view works for any list; the first run itself offers WHOOP only.
      final all = [kWhoopGen5, kOura, kColmi, kUltrahuman, kMiBand234, kPebble];
      await pumpPair(t, view(entries: all), size: const Size(412, 2400));
      for (final k in ['All', 'WHOOP', 'Rings', 'Watches']) {
        expect(find.text(k), findsOneWidget, reason: k);
      }
      expect(find.text('Chest straps & armbands'), findsNothing);
      expect(find.text('Bands'), findsNothing);
      expect(find.text('Scales'), findsNothing);
      await t.tap(find.text('Rings'));
      await t.pumpAndSettle();
      expect(_row(kOura), findsOneWidget);
      expect(_row(kColmi), findsOneWidget);
      expect(_row(kUltrahuman), findsOneWidget);
      expect(_row(kWhoopGen5), findsNothing);
      expect(_row(kMiBand234), findsNothing);
      // The Mi Band is a watch, with the other watches.
      await t.tap(find.text('Watches'));
      await t.pumpAndSettle();
      expect(_row(kMiBand234), findsOneWidget);
      expect(_row(kPebble), findsOneWidget);
      expect(_row(kOura), findsNothing);
      await t.tap(find.text('All'));
      await t.pumpAndSettle();
      expect(_row(kWhoopGen5), findsOneWidget);
    });

    test('the pills’ groups are PairFilter values (WHOOP, rings, watches, straps)', () {
      expect(PairFilter.values.map((f) => f.name), ['whoop', 'rings', 'watches', 'straps']);
    });

    testWidgets('tapping a row picks that device', (t) async {
      final picked = <String>[];
      await pumpPair(t, view(onPick: (e) => picked.add(e.id)), size: const Size(412, 2400));
      await t.tap(_row(kWhoopGen5));
      expect(picked, ['gen5']);
    });

    testWidgets('the strap-only link opens the strap sheet', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      await t.tap(find.text('I only have a heart-rate strap'));
      await t.pumpAndSettle();
      expect(find.text('This is a heart-rate sensor'), findsOneWidget);
      expect(find.text('Pair Bluetooth heart rate sensor'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
      expect(find.text('Sleep'), findsWidgets);
    });

    testWidgets('Go back closes the sheet and pairs nothing', (t) async {
      var confirmed = 0;
      await pumpPair(t, view(onStrap: () => confirmed++), size: const Size(412, 2400));
      await t.tap(find.text('I only have a heart-rate strap'));
      await t.pumpAndSettle();
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(find.text('This is a heart-rate sensor'), findsNothing);
      expect(confirmed, 0);
    });

    testWidgets('Pair closes the sheet and carries on (strapOnlyConfirmed)', (t) async {
      var confirmed = 0;
      await pumpPair(t, view(onStrap: () => confirmed++), size: const Size(412, 2400));
      await t.tap(find.text('I only have a heart-rate strap'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair Bluetooth heart rate sensor'));
      await t.pumpAndSettle();
      expect(find.text('This is a heart-rate sensor'), findsNothing);
      expect(confirmed, 1);
    });

    testWidgets('there is no “I can’t pair my band” button, and no dialog anywhere', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      expect(find.text('I can’t pair my band'), findsNothing);
      await t.tap(_row(kWhoopGen5));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Need a hand pairing?'), findsNothing);
    });

    testWidgets('the Trouble connecting card is always there, with a link per WHOOP and Discord', (t) async {
      final links = _Links();
      await pumpPair(t, view(links: links), size: const Size(412, 2400));
      expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
      expect(find.text('Trouble connecting?'), findsOneWidget);
      for (final e in firstRunBandEntries()) {
        expect(find.byKey(ValueKey('trouble-link-${e.id}')), findsOneWidget, reason: e.id);
      }
      await t.tap(find.byKey(const ValueKey('trouble-link-discord')));
      expect(links.opened, [kDiscordUrl]);
    });

    testWidgets('the card stays, unchanged, after trying a device; its links open each model’s page', (t) async {
      final links = _Links();
      await pumpPair(t, view(links: links), size: const Size(412, 2400));
      await t.tap(_row(kWhoopGen5));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')));
      expect(links.opened, [kWhoopGen5.resetSteps!.officialUrl]);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('Skip for now shows only when there is something to skip', (t) async {
      await pumpPair(t, view(), size: const Size(412, 2400));
      expect(find.text('Skip for now'), findsNothing);
      var skipped = 0;
      await pumpPair(t, view(onSkip: () => skipped++), size: const Size(412, 2400));
      // The first-run help and comparison chips can put Skip below the fold.
      await t.ensureVisible(find.text('Skip for now'));
      await t.pumpAndSettle();
      await t.tap(find.text('Skip for now'));
      expect(skipped, 1);
    });

    testWidgets('the back chevron goes where the first run says', (t) async {
      var back = 0;
      await pumpPair(t, view(onBack: () => back++), size: const Size(412, 2400));
      await t.tap(find.byIcon(LucideIcons.chevronLeft));
      expect(back, 1);
    });

    testWidgets('a problem is said in a card', (t) async {
      await pumpPair(t, view(problem: 'Bluetooth is off.'), size: const Size(412, 2400));
      expect(find.text('Bluetooth is off.'), findsOneWidget);
      // The card is under it, not instead of it.
      expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
    });

    testWidgets('German at 2x text on a small phone does not overflow', (t) async {
      await pumpPair(t, view(onSkip: () {}),
          locale: const Locale('de'), textScale: 2, size: const Size(320, 700));
      expect(t.takeException(), isNull);
      // The retained firmware warning adds substantial height at 2x text.
      await t.scrollUntilVisible(find.text('Ich habe nur einen Herzfrequenzgurt'), 200, maxScrolls: 100);
      await t.ensureVisible(find.text('Ich habe nur einen Herzfrequenzgurt'));
      await t.pumpAndSettle();
      await t.tap(find.text('Ich habe nur einen Herzfrequenzgurt'));
      await t.pumpAndSettle();
      expect(find.text('Das ist ein Herzfrequenzsensor'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
