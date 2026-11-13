// ignore_for_file: depend_on_referenced_packages
// The "Trouble connecting?" card and the reset-steps view, plus the
// pairing screen's failure states that show them. Rendered, with fake link
// openers: no browser, no BLE.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/band_identity.dart' show PairOutcome;
import 'package:openstrap_edge/ble/ble_state.dart' show ScanAcceptPolicy;
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/community_links.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/pairing/pair_help.dart';
import 'package:openstrap_edge/ui2/pairing/pair_outcome_text.dart';
import 'package:openstrap_edge/ui2/pairing/reset_steps_view.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/pair_ui_support.dart';

class _Links implements PairLinkOpener {
  final opened = <String>[];
  final bool ok;
  _Links([this.ok = true]);
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return ok;
  }
}

class _FakeLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final calls = <(String, PreferredLaunchMode)>[];
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls.add((url, options.mode));
    return true;
  }
}

Widget _scroll(Widget w) => Scaffold(
    body: SingleChildScrollView(
        padding: const EdgeInsets.all(16), child: w));

void main() {
  group('(CR r1) the main-band scan takes only the band the user chose', () {
    // WHY: PairingScreen paired whichever WHOOP the scan heard first, so a
    // nearby WHOOP of the other generation, or not the one tapped, was saved.
    const gen4 = '61080001-8d6d-82b8-614a-1c8cb0f8dcc6';
    const gen5 = 'fd4b0001-cce1-4033-93ce-002d5875f58a';
    test('the tapped remote id only', () {
      expect(ScanAcceptPolicy.fitsChoice('AA:01', [gen5], wantRemoteId: 'AA:01'), isTrue);
      expect(ScanAcceptPolicy.fitsChoice('AA:02', [gen5], wantRemoteId: 'AA:01'), isFalse);
    });
    test('the chosen generation, or a result that names none', () {
      expect(ScanAcceptPolicy.fitsChoice('AA:01', [gen4], wantGeneration: 'gen5'), isFalse);
      expect(ScanAcceptPolicy.fitsChoice('AA:01', [gen5], wantGeneration: 'gen5'), isTrue);
      // A name-only or 16-bit-only match names no generation: still a candidate.
      expect(ScanAcceptPolicy.fitsChoice('AA:01', ['fd4b'], wantGeneration: 'gen4'), isTrue);
      expect(ScanAcceptPolicy.fitsChoice('AA:01', const [], wantGeneration: 'gen4'), isTrue);
    });
    test('nothing chosen: anything the scan matched', () {
      expect(ScanAcceptPolicy.fitsChoice('AA:09', [gen4]), isTrue);
    });
  });

  test('(CR r1) the band-not-sensor sentence names the band in the user\'s language', () {
    // WHY: the raw registry label ("Colmi ring") went into a German sentence.
    final de = lookupAppLocalizations(const Locale('de'));
    final text = pairOutcomeText(de, const PairOutcome.band(kColmi))!;
    expect(text, contains(de.presentationColmiRing));
    expect(de.presentationColmiRing, isNot('Colmi ring'), reason: 'control');
  });

  // WHY: WHOOP 4 must not send users into the app that may update their band.
  // catches: restoring the generic app-opening fallback for gen4.
  testWidgets('WHOOP 4 reset help never asks to open the maker app in any locale', (t) async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final view in [
        ResetStepsView(entry: kWhoopGen4),
        PairingModeSection(entry: kWhoopGen4),
      ]) {
        await pumpPair(t, _scroll(view), locale: locale);
        expect(find.text(l.pairResetGenericStep1), findsNothing, reason: locale.toString());
        expect(find.text(l.pairResetWhoop5Step3), findsOneWidget);
        expect(find.text(l.pairResetGenericStep2), findsOneWidget);
        expect(find.text(l.pairResetWhoop5Step4), findsOneWidget);
      }
    }
    expect(kWhoopGen4.resetSteps!.kind, ResetKind.unverified);
    expect(kWhoopGen4.resetSteps!.officialUrl,
        'https://support.whoop.com/s/article/WHOOP-4-0-iOS-Connectivity-and-Pairing?language=en_US');
  });

  // WHY: compact help must disclose that these are unverified instructions.
  // catches: hiding the note when the heading or help link is disabled.
  testWidgets('unverified pairing sections always disclose general guidance', (t) async {
    final l = lookupAppLocalizations(const Locale('en'));
    for (final heading in [false, true]) {
      for (final link in [false, true]) {
        await pumpPair(t, _scroll(PairingModeSection(
            entry: kColmi, heading: heading, link: link)));
        expect(find.text(l.pairResetGenericNote), findsOneWidget);
      }
    }
    await pumpPair(t, _scroll(PairingModeSection(entry: kWhoopGen5)));
    expect(find.text(l.pairResetGenericNote), findsNothing);
  });

  group('Trouble connecting card', () {
    Widget card(List<BandEntry> entries, [PairLinkOpener? links]) => _scroll(
        TroubleConnectingCard(entries: entries, openLink: links ?? _Links()));

    testWidgets('always open: title, body, a link per model, and Discord, with no tap',
        (t) async {
      await pumpPair(t, card([kWhoopGen4, kWhoopGen5]));
      expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
      expect(find.text('Trouble connecting?'), findsOneWidget);
      expect(find.text('Put the band in pairing mode, then try again. Still stuck? Ask us.'),
          findsOneWidget);
      expect(find.byKey(ValueKey('trouble-link-${kWhoopGen4.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')), findsOneWidget);
      expect(find.byKey(const ValueKey('trouble-link-discord')), findsOneWidget);
      expect(find.text('Ask on Discord'), findsOneWidget);
      expect(find.text('The OpenStrap community'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('each link row names its model and shows the page’s host', (t) async {
      await pumpPair(t, card([kWhoopGen5]));
      expect(find.text('${kWhoopGen5.label} pairing mode'), findsOneWidget);
      expect(find.text(Uri.parse(kWhoopGen5.resetSteps!.officialUrl!).host), findsOneWidget);
    });

    testWidgets('model links come in entry order, Discord last', (t) async {
      await pumpPair(t, card([kWhoopGen5, kWhoopGen4]));
      double y(String id) => t.getTopLeft(find.byKey(ValueKey('trouble-link-$id'))).dy;
      expect(y(kWhoopGen5.id), lessThan(y(kWhoopGen4.id)));
      expect(y(kWhoopGen4.id), lessThan(y('discord')));
      await pumpPair(t, card([kWhoopGen4, kWhoopGen5]));
      expect(y(kWhoopGen4.id), lessThan(y(kWhoopGen5.id)));
    });

    testWidgets('each model link opens its own page', (t) async {
      final links = _Links();
      await pumpPair(t, card([kWhoopGen4, kWhoopGen5], links));
      await t.tap(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')));
      await t.tap(find.byKey(ValueKey('trouble-link-${kWhoopGen4.id}')));
      expect(links.opened,
          [kWhoopGen5.resetSteps!.officialUrl, kWhoopGen4.resetSteps!.officialUrl]);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('an unverified device’s link opens its maker page too', (t) async {
      final links = _Links();
      await pumpPair(t, card([kColmi], links));
      await t.tap(find.byKey(ValueKey('trouble-link-${kColmi.id}')));
      expect(links.opened, [kColmi.resetSteps!.officialUrl]);
    });

    testWidgets('the Discord link opens the community link', (t) async {
      final links = _Links();
      await pumpPair(t, card([kWhoopGen5], links));
      await t.tap(find.byKey(const ValueKey('trouble-link-discord')));
      expect(links.opened, [kDiscordUrl]);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('(CR r1) a link nothing could open says so, with the address', (t) async {
      // WHY: open3rdPartyLink returns false when no app takes the link; the
      // tap did nothing visible and the user had no way to the page.
      // Control first: an opened link says nothing.
      await pumpPair(t, card([kWhoopGen5], _Links()));
      await t.tap(find.byKey(const ValueKey('trouble-link-discord')));
      await t.pump();
      expect(find.textContaining('Could not open the link'), findsNothing);
      await pumpPair(t, card([kWhoopGen5], _Links(false)));
      await t.tap(find.byKey(const ValueKey('trouble-link-discord')));
      await t.pump();
      expect(find.text('Could not open the link. The address is $kDiscordUrl'),
          findsOneWidget);
    });

    testWidgets('a model link that fails says it the same way, with its own address', (t) async {
      await pumpPair(t, card([kWhoopGen5], _Links(false)));
      await t.tap(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')));
      await t.pump();
      expect(
          find.text('Could not open the link. The address is '
              '${kWhoopGen5.resetSteps!.officialUrl}'),
          findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a device with no official site is left out: Discord only', (t) async {
      await pumpPair(t, card([kBleHrs]));
      expect(find.byKey(ValueKey('trouble-link-${kBleHrs.id}')), findsNothing);
      expect(find.byKey(const ValueKey('trouble-link-discord')), findsOneWidget);
    });

    testWidgets('no entries: Discord only', (t) async {
      await pumpPair(t, card(const []));
      expect(find.text('Ask on Discord'), findsOneWidget);
      expect(find.textContaining('pairing mode'), findsOneWidget); // the body line
    });

    testWidgets('by default links leave the app: external application mode', (t) async {
      final fake = _FakeLauncher();
      final before = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fake;
      addTearDown(() => UrlLauncherPlatform.instance = before);
      await pumpPair(t, _scroll(TroubleConnectingCard(entries: [kWhoopGen5])));
      await t.tap(find.byKey(const ValueKey('trouble-link-discord')));
      await t.pump();
      await t.tap(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')));
      await t.pump();
      expect(fake.calls, [
        (kDiscordUrl, PreferredLaunchMode.externalApplication),
        (kWhoopGen5.resetSteps!.officialUrl!, PreferredLaunchMode.externalApplication),
      ]);
    });

    testWidgets('German copy fits at 2x text', (t) async {
      await pumpPair(t, card([kWhoopGen4, kWhoopGen5]),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      expect(t.takeException(), isNull);
      expect(find.text('Probleme beim Verbinden?'), findsOneWidget);
      expect(find.text('Auf Discord fragen'), findsOneWidget);
    });
  });

  group('pairing mode, up front (owner r5)', () {
    Future<void> section(WidgetTester t, BandEntry e, {_Links? links}) => pumpPair(
        t,
        Scaffold(
            body: SingleChildScrollView(
                child: PairingModeSection(entry: e, openLink: links ?? _Links()))),
        size: const Size(412, 1000));

    testWidgets('specific (WHOOP 5): its own numbered steps, no link', (t) async {
      await section(t, kWhoopGen5);
      expect(find.text('Put it in pairing mode'), findsOneWidget);
      for (var i = 1; i <= 4; i++) {
        expect(find.byKey(ValueKey('pairing-mode-step-gen5-$i')), findsOneWidget);
      }
      expect(find.textContaining('tap the top firmly'), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-mode-link-gen5')), findsNothing);
    });

    testWidgets('unverified (Oura): the general steps and the maker page, no badge', (t) async {
      final links = _Links();
      await section(t, kOura, links: links);
      expect(find.text('Not confirmed yet'), findsNothing);
      expect(find.byKey(const ValueKey('pairing-mode-step-oura-3')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pairing-mode-link-oura')));
      await t.pumpAndSettle();
      expect(links.opened, [kOura.resetSteps!.officialUrl]);
    });

    testWidgets('no official site (a generic strap): one line, no steps, no link', (t) async {
      await section(t, kBleHrs);
      expect(find.byKey(const ValueKey('pairing-mode-no-site-ble_hrs')), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-mode-step-ble_hrs-1')), findsNothing);
    });

    testWidgets('the first-run card shows WHOOP 4 and WHOOP 5 steps with no tap', (t) async {
      await pumpPair(
          t,
          Scaffold(
              body: SingleChildScrollView(
                  child: TroubleConnectingCard(entries: [kWhoopGen4, kWhoopGen5]))),
          size: const Size(412, 1600));
      expect(find.byKey(const ValueKey('pairing-mode-step-gen4-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-mode-step-gen5-4')), findsOneWidget);
      // Each model's steps sit under its own link.
      final link5 = t.getTopLeft(find.byKey(const ValueKey('trouble-link-gen5'))).dy;
      expect(t.getTopLeft(find.byKey(const ValueKey('pairing-mode-step-gen4-1'))).dy,
          lessThan(link5));
      expect(t.getTopLeft(find.byKey(const ValueKey('pairing-mode-step-gen5-1'))).dy,
          greaterThan(link5));
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('every entry’s section fits in German at 2x text', (t) async {
      for (final e in kBandRegistry) {
        await pumpPair(
            t,
            Scaffold(body: SingleChildScrollView(child: PairingModeSection(entry: e))),
            locale: const Locale('de'),
            textScale: 2,
            size: const Size(360, 2400));
        expect(t.takeException(), isNull, reason: e.id);
      }
    });
  });

  group('reset steps view', () {
    testWidgets('WHOOP 5 shows its own four steps, no “not checked” note, no maker row',
        (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen5, openLink: _Links())));
      expect(find.text('To reset it'), findsOneWidget);
      expect(find.textContaining('Take the band off your wrist'), findsOneWidget);
      expect(find.textContaining('tap the top firmly'), findsOneWidget);
      expect(find.textContaining('force-quit it'), findsOneWidget);
      expect(find.text('Come back here and try again.'), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-general-note')), findsNothing);
      expect(find.text('Open the maker’s help page'), findsNothing);
    });

    testWidgets('a WHOOP says pairing here disconnects it from the WHOOP app', (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen5)));
      expect(find.text('Pairing here disconnects it from the WHOOP app.'), findsOneWidget);
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen4)));
      expect(find.text('Pairing here disconnects it from the WHOOP app.'), findsOneWidget);
    });

    testWidgets('an unverified device: orange note, three general steps, maker link row',
        (t) async {
      final links = _Links();
      await pumpPair(t, _scroll(ResetStepsView(entry: kColmi, openLink: links)));
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
      expect(find.textContaining('We haven’t checked the exact steps'), findsOneWidget);
      expect(find.text('Open the maker’s app and remove this device from it.'), findsOneWidget);
      expect(find.textContaining('choose Forget'), findsOneWidget);
      expect(find.textContaining('Restart the device'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleAlert), findsOneWidget);
      final host = Uri.parse(kColmi.resetSteps!.officialUrl!).host;
      expect(find.text('$host · opens in your browser'), findsOneWidget);
      await t.tap(find.text('Open the maker’s help page'));
      expect(links.opened, [kColmi.resetSteps!.officialUrl]);
      await pumpPair(t, _scroll(ResetStepsView(entry: kColmi, openLink: _Links(false))));
      await t.tap(find.text('Open the maker’s help page'));
      await t.pump();
      expect(
          find.text('Could not open the link. The address is '
              '${kColmi.resetSteps!.officialUrl}'),
          findsOneWidget,
          reason: 'CR r1: a failed open shows the address');
      // Not a WHOOP: no takeover line.
      expect(find.byKey(const ValueKey('reset-whoop-takeover')), findsNothing);
    });

    testWidgets('WHOOP 4 is unverified: general steps, note, maker row, and the takeover line',
        (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen4)));
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
      expect(find.text('Open the maker’s help page'), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-whoop-takeover')), findsOneWidget);
    });

    testWidgets('a device with no official site: general steps, no maker row, no orange alert',
        (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kThermometer)));
      expect(find.text('Open the maker’s app and remove this device from it.'), findsOneWidget);
      expect(find.text('Open the maker’s help page'), findsNothing);
      expect(find.byIcon(LucideIcons.circleAlert), findsNothing);
      // Still says the steps are general.
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
    });

    testWidgets('every registry entry renders, at 2x German text, without overflow', (t) async {
      for (final e in kBandRegistry) {
        await pumpPair(t, _scroll(ResetStepsView(entry: e)),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
        expect(t.takeException(), isNull, reason: e.id);
        expect(find.text('So setzt du es zurück'), findsOneWidget, reason: e.id);
      }
    });
  });

  group('pairing screen: when pairing could not finish', () {
    Widget view(PairPhase phase,
            {BandEntry? entry, VoidCallback? onPair, VoidCallback? onPick, _Links? links}) =>
        PairingView(
          phase: phase,
          onPair: onPair ?? () {},
          resetEntry: entry,
          onPickDifferent: onPick,
          openLink: (links ?? _Links()),
        );

    for (final phase in [PairPhase.notFound, PairPhase.bondRefused, PairPhase.failed]) {
      testWidgets('${phase.name}: the entry’s reset steps and the ways forward', (t) async {
        var tried = 0, picked = 0;
        await pumpPair(
            t,
            view(phase,
                entry: kWhoopGen5, onPair: () => tried++, onPick: () => picked++),
            size: const Size(412, 1800));
        expect(find.text('Your band is paired somewhere else'), findsOneWidget);
        expect(find.textContaining('We couldn’t finish pairing WHOOP 5.'), findsOneWidget);
        expect(find.textContaining('tap the top firmly'), findsOneWidget);
        expect(find.text('Pairing here disconnects it from the WHOOP app.'), findsOneWidget);
        await t.tap(find.text('Try again'));
        expect(tried, 1);
        await t.tap(find.text('Pick a different band'));
        expect(picked, 1);
        expect(find.text('I can’t pair my band'), findsNothing);
        expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
      });
    }

    testWidgets('a refused bond lists the Bluetooth-settings Forget step first, even for WHOOP 5', (t) async {
      // WHY: WHOOP 5's own four steps never say to forget the old pairing
      // record, and Try again cannot clear a refused bond without it.
      const forget = 'In your phone’s Bluetooth settings, find the device and choose Forget.';
      await pumpPair(t, view(PairPhase.bondRefused, entry: kWhoopGen5),
          size: const Size(412, 1600));
      expect(find.text(forget), findsOneWidget);
      expect(find.textContaining('tap the top firmly'), findsOneWidget,
          reason: 'its own steps stay');
      await pumpPair(t, view(PairPhase.notFound, entry: kWhoopGen5),
          size: const Size(412, 1600));
      expect(find.text(forget), findsNothing,
          reason: 'not found is not a refused bond');
      // A device on the general steps already has it, once.
      expect(resetStepKeysFor(kWhoopGen4, bondRefused: true)
          .where((k) => k == 'pairResetGenericStep2'), hasLength(1));
      // WHOOP 5's last step is to retry, which fails while the refused
      // record is still there, so Forget comes before its own steps.
      expect(resetStepKeysFor(kWhoopGen5, bondRefused: true).first,
          'pairResetGenericStep2');
    });

    testWidgets('the Trouble connecting card is there, with this device’s page, no tap needed',
        (t) async {
      final links = _Links();
      await pumpPair(t, view(PairPhase.notFound, entry: kWhoopGen5, links: links),
          size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
      expect(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')), findsOneWidget);
      expect(find.byKey(const ValueKey('trouble-link-discord')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('trouble-link-${kWhoopGen5.id}')));
      expect(links.opened, [kWhoopGen5.resetSteps!.officialUrl]);
      await t.tap(find.byKey(const ValueKey('trouble-link-discord')));
      expect(links.opened.last, kDiscordUrl);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('unless the steps already show it: an unverified device’s card is Discord only',
        (t) async {
      await pumpPair(t, view(PairPhase.bondRefused, entry: kColmi), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('trouble-connecting')), findsOneWidget);
      expect(find.byKey(ValueKey('trouble-link-${kColmi.id}')), findsNothing);
      expect(find.byKey(const ValueKey('trouble-link-discord')), findsOneWidget);
      // The maker row in the steps is the one way to the page.
      expect(find.text('Open the maker’s help page'), findsOneWidget);
    });

    testWidgets('an unverified ring: ring wording, orange note, maker row', (t) async {
      await pumpPair(t, view(PairPhase.bondRefused, entry: kColmi), size: const Size(412, 1400));
      expect(find.text('Your ring is paired somewhere else'), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
      expect(find.text('Open the maker’s help page'), findsOneWidget);
    });

    testWidgets('without an entry the screen is unchanged: no reset steps, no Trouble card', (t) async {
      await pumpPair(t, view(PairPhase.notFound), size: const Size(412, 1400));
      expect(find.text('To reset it'), findsNothing);
      expect(find.byKey(const ValueKey('trouble-connecting')), findsNothing);
      expect(find.text('No band in range'), findsOneWidget);
    });

    for (final phase in [PairPhase.idle, PairPhase.cancelled, PairPhase.paired]) {
      testWidgets('${phase.name} never shows reset steps', (t) async {
        await pumpPair(t, view(phase, entry: kWhoopGen5), size: const Size(412, 1400));
        expect(find.text('To reset it'), findsNothing);
        expect(find.byKey(const ValueKey('trouble-connecting')), findsNothing);
      });
    }

    testWidgets('German at 2x text does not overflow', (t) async {
      for (final e in [kColmi, kWhoopGen5]) {
        await pumpPair(t, view(PairPhase.notFound, entry: e),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 2200));
        expect(t.takeException(), isNull, reason: e.id);
      }
    });
  });
}
