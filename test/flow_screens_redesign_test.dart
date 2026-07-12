// Widget tests for the LAST design-system batch: the flow/form screens.
// Pure presentation widgets render in BOTH palettes:
//   • onboarding (WelcomeHero + WelcomeOptionCard)
//   • pairing (instruction content + every PairPhase of PairingStateView)
//   • profile setup (ProfileSetupForm: fields, sex chips, consents, submit)
//   • profile (DeviceTile ink card incl. Sync-now action)
// Explicit pump durations (never blind pumpAndSettle — several widgets repeat).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui/design/design.dart';
import 'package:openstrap_edge/ui/onboarding/welcome_screen.dart'
    show WelcomeHero, WelcomeOptionCard;
import 'package:openstrap_edge/ui/pairing_screen.dart'
    show PairPhase, PairingInstructionContent, PairingStateView;
import 'package:openstrap_edge/ui/profile/profile_screen.dart' show DeviceTile;
import 'package:openstrap_edge/ui/profile_setup_screen.dart'
    show ConsentTile, ProfileSetupForm;

Widget _host(Widget child, {Palette palette = kLightPalette, bool scroll = true}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(
      body: scroll ? SingleChildScrollView(child: child) : child,
    ),
  );
}

Future<void> _pumpTwice(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(seconds: 1));
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  // ── Onboarding ─────────────────────────────────────────────────────────────

  for (final (label, palette) in [('light', kLightPalette), ('dark', kDarkPalette)]) {
    testWidgets('welcome hero + option cards render ($label)', (t) async {
      var tapped = 0;
      await t.pumpWidget(_host(
        Column(children: [
          const WelcomeHero(),
          WelcomeOptionCard(
            icon: Ic.cloud,
            title: 'I used OpenStrap before',
            body: 'Sign in and pull your history onto this phone.',
            onTap: () => tapped++,
          ),
          WelcomeOptionCard(
            icon: Ic.profile,
            title: 'I’m new',
            body: 'A few basics and you’re in.',
            accent: true,
            onTap: () => tapped++,
          ),
        ]),
        palette: palette,
      ));
      await _pumpTwice(t);

      expect(find.textContaining('Welcome to'), findsOneWidget);
      expect(find.text('I used OpenStrap before'), findsOneWidget);
      expect(find.text('I’m new'), findsOneWidget);

      await t.tap(find.text('I’m new'));
      await t.pump(const Duration(milliseconds: 300));
      expect(tapped, 1);
    });
  }

  // ── Pairing ────────────────────────────────────────────────────────────────

  for (final (label, palette) in [('light', kLightPalette), ('dark', kDarkPalette)]) {
    testWidgets('pairing instruction step renders ($label)', (t) async {
      t.view.physicalSize = const Size(800, 2200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      var ready = false;
      await t.pumpWidget(_host(
        PairingInstructionContent(onReady: () => ready = true),
        palette: palette,
        scroll: false,
      ));
      await _pumpTwice(t);

      expect(find.textContaining('pairing mode'), findsWidgets);
      expect(find.text('Wake the strap'), findsOneWidget);
      expect(find.text('Enter pairing mode'), findsOneWidget);

      await t.ensureVisible(find.text('My strap is in pairing mode'));
      await t.tap(find.text('My strap is in pairing mode'));
      expect(ready, isTrue);
    });
  }

  testWidgets('pairing state view renders every phase in both palettes',
      (t) async {
    for (final palette in [kLightPalette, kDarkPalette]) {
      for (final phase in PairPhase.values) {
        await t.pumpWidget(_host(
          PairingStateView(
            phase: phase,
            deviceName: phase == PairPhase.found ? 'WHOOP 4A0XXXX' : null,
            error: phase == PairPhase.notFound ? 'Bluetooth timed out.' : null,
            onBack: () {},
            onPair: () {},
            onRetry: () {},
          ),
          palette: palette,
          scroll: false,
        ));
        // Rings repeat — explicit pumps only.
        await t.pump();
        await t.pump(const Duration(milliseconds: 600));

        switch (phase) {
          case PairPhase.scanning:
            expect(find.textContaining('Scanning'), findsOneWidget);
          case PairPhase.found:
            expect(find.text('WHOOP 4A0XXXX'), findsOneWidget);
            expect(find.text('Ready to pair'), findsOneWidget);
            expect(find.text('Pair'), findsOneWidget);
          case PairPhase.notFound:
            expect(find.text('Scan again'), findsOneWidget);
            expect(find.text('Bluetooth timed out.'), findsOneWidget);
          case PairPhase.pairing:
            expect(find.byType(CircularProgressIndicator), findsWidgets);
          case PairPhase.askReady:
            expect(find.text('Pair'), findsOneWidget);
          case PairPhase.bluetoothOff:
            expect(find.text('Bluetooth is off.'), findsOneWidget);
            expect(find.text('Check again'), findsOneWidget);
        }
      }
    }
  });

  // ── Profile setup ──────────────────────────────────────────────────────────

  for (final (label, palette) in [('light', kLightPalette), ('dark', kDarkPalette)]) {
    testWidgets('profile setup form renders + submits ($label)', (t) async {
      t.view.physicalSize = const Size(800, 2200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      Map<String, dynamic>? submitted;
      bool? telemetry;
      bool? healthShare;
      await t.pumpWidget(_host(
        ProfileSetupForm(
          initial: const {'age': 30, 'weight_kg': 72.0, 'height_cm': 180.0},
          onSubmit: (p, tel, hs) async {
            submitted = p;
            telemetry = tel;
            healthShare = hs;
          },
        ),
        palette: palette,
        scroll: false,
      ));
      await _pumpTwice(t);

      expect(find.text('About you'), findsOneWidget);
      expect(find.text('Male'), findsOneWidget);
      expect(find.text('Female'), findsOneWidget);
      expect(find.byType(ConsentTile), findsNWidgets(2));

      // No sex chosen yet → Continue disabled (onSubmit not called on tap).
      await t.ensureVisible(find.text('Continue'));
      await t.tap(find.text('Continue'), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 300));
      expect(submitted, isNull);

      // Choose a sex → the form becomes valid → submit reports the profile.
      await t.ensureVisible(find.text('Female'));
      await t.tap(find.text('Female'));
      await t.pump(const Duration(milliseconds: 300));
      await t.ensureVisible(find.text('Continue'));
      await t.tap(find.text('Continue'));
      await t.pump(const Duration(milliseconds: 300));

      expect(submitted, isNotNull);
      expect(submitted!['age'], 30);
      expect(submitted!['sex'], 'f');
      expect(telemetry, isTrue);
      expect(healthShare, isTrue);
    });
  }

  testWidgets('consent tile toggles', (t) async {
    var value = true;
    await t.pumpWidget(_host(
      StatefulBuilder(
        builder: (context, setState) => ConsentTile(
          title: 'Send anonymous diagnostics',
          subtitle: 'No health data.',
          value: value,
          onChanged: (v) => setState(() => value = v),
        ),
      ),
    ));
    await _pumpTwice(t);
    await t.tap(find.byType(Switch));
    await t.pump(const Duration(milliseconds: 300));
    expect(value, isFalse);
  });

  // ── Profile: device tile ───────────────────────────────────────────────────

  for (final (label, palette) in [('light', kLightPalette), ('dark', kDarkPalette)]) {
    testWidgets('device tile renders + sync action runs ($label)', (t) async {
      var synced = 0;
      await t.pumpWidget(_host(
        DeviceTile(
          name: 'My Strap',
          statusText: 'Connected',
          statusTone: ChipTone.positive,
          battery: '82%',
          wrist: 'On wrist',
          serial: '4A0XXXX',
          onTap: () {},
          onSyncNow: () async => synced++,
        ),
        palette: palette,
      ));
      await _pumpTwice(t);

      expect(find.text('My Strap'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('82%'), findsOneWidget);
      expect(find.text('On wrist'), findsOneWidget);
      expect(find.text('4A0XXXX'), findsOneWidget);
      // No sync-anxiety copy on the tile.
      expect(find.textContaining('stored to'), findsNothing);
      expect(find.textContaining('every ~15'), findsNothing);

      await t.tap(find.text('Sync now'));
      await t.pump(const Duration(milliseconds: 300));
      expect(synced, 1);
    });
  }

  testWidgets('device tile hides sync action when disconnected', (t) async {
    await t.pumpWidget(_host(
      const DeviceTile(
        name: 'My Strap',
        statusText: 'Disconnected',
        statusTone: ChipTone.neutral,
        battery: '—',
        wrist: '—',
        serial: '4A0XXXX',
      ),
    ));
    await _pumpTwice(t);
    expect(find.text('Sync now'), findsNothing);
    expect(find.text('Disconnected'), findsOneWidget);
  });

}
