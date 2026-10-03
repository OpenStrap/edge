// The router and the onboarding decisions, as pure functions.
//
// Onboarding is the flow a user walks through exactly once, so a bug here is
// a bug nobody reports and everybody hits. Two of the cases below are the
// audit's findings written down as regressions:
//
//   · a profile form that promised optional fields and then refused to
//     continue without them,
//   · a pairing screen with no way out of a refused bond.
//
// The deep-link cases exist because a notification is scheduled days before
// it is tapped: a payload written by an older build must still land somewhere
// deterministic after the five tabs were renamed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/app.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/models.dart' show DeviceState;
import 'package:openstrap_edge/notify/tap_router.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart'
    show isEncryptedBackup;
import 'package:openstrap_edge/ui2/screens/log_workout.dart'
    show WorkoutSuggestionScreen;
import 'package:openstrap_edge/ui2/screens/nutrition_screen.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// A viewport tall enough that nothing under test is below the fold. The
/// default 800x600 harness window hides the very buttons these tests are
/// about, which is a property of the harness and not of the screen — the
/// goldens are where layout at a real phone size is checked.
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  group('the onboarding gate', () {
    test('walks welcome → pairing → profile → shell when nothing is skipped',
        () {
      for (final r in AppRoute.values) {
        expect(resolveRoute(r, pairingSkipped: false, profileSeen: false), r);
      }
    });

    test('a skipped pairing still asks for the profile, then opens the app',
        () {
      expect(
        resolveRoute(AppRoute.pairing,
            pairingSkipped: true, profileSeen: false),
        AppRoute.profile,
        reason: 'the four profile numbers are still worth asking for',
      );
      expect(
        resolveRoute(AppRoute.pairing, pairingSkipped: true, profileSeen: true),
        AppRoute.shell,
      );
    });

    test('a deliberately partial profile is not bounced back forever', () {
      // AppState.route keeps returning `profile` while any of age/height/
      // weight/sex is blank. Honouring that literally is the bug: the form
      // says the fields are optional.
      expect(
        resolveRoute(AppRoute.profile,
            pairingSkipped: false, profileSeen: true),
        AppRoute.shell,
      );
    });

    test('loading is never bypassed — there is nothing to show yet', () {
      expect(
        resolveRoute(AppRoute.loading, pairingSkipped: true, profileSeen: true),
        AppRoute.loading,
      );
      // Not even for someone who finished onboarding months ago.
      expect(
        resolveRoute(AppRoute.loading,
            pairingSkipped: false, profileSeen: false, onboarded: true),
        AppRoute.loading,
      );
    });

    test('forgetting a band does not restart onboarding', () {
      // The NAV-03 case: paired for months (so `pairingSkipped` is false),
      // then "Forget this band" → AppState.route goes to `pairing`. That used
      // to drop the user into the first-run pairing screen with every night
      // of their data behind it.
      expect(
        resolveRoute(AppRoute.pairing,
            pairingSkipped: false, profileSeen: true, onboarded: true),
        AppRoute.shell,
      );
      // Same for an install that upgraded into this build and never marked
      // the profile step.
      expect(
        resolveRoute(AppRoute.profile,
            pairingSkipped: false, profileSeen: false, onboarded: true),
        AppRoute.shell,
      );
      // A first run is still a first run.
      expect(
        resolveRoute(AppRoute.pairing,
            pairingSkipped: false, profileSeen: false, onboarded: false),
        AppRoute.pairing,
      );
      expect(
        resolveRoute(AppRoute.welcome,
            pairingSkipped: false, profileSeen: false, onboarded: true),
        AppRoute.welcome,
        reason: 'welcome is reached only with no band AND no choice made',
      );
    });
  });

  group('deep links survive the five-tab rename', () {
    test('every notification tab index resolves', () {
      expect(domainForTab(0), ShellDomain.home);
      // Sleep, Heart and Body all folded into Health.
      expect(domainForTab(1), ShellDomain.health);
      expect(domainForTab(2), ShellDomain.health);
      expect(domainForTab(3), ShellDomain.health);
      expect(domainForTab(4), ShellDomain.workout);
      // A payload from a build that had more tabs than we do.
      expect(domainForTab(9), ShellDomain.home);
      expect(domainForTab(-1), ShellDomain.home);
    });

    test('every kRoute constant lands somewhere deliberate', () {
      const routes = {
        kRouteAiMorning: ShellDomain.home,
        kRouteAiEvening: ShellDomain.home,
        kRouteJournalCompose: ShellDomain.wellness,
        kRouteBreathing: ShellDomain.wellness,
        kRouteWorkoutSuggestion: ShellDomain.home,
        kRouteDetectedActivities: ShellDomain.home,
        kRouteWater: ShellDomain.nutrition,
      };
      routes.forEach((route, domain) {
        expect(domainForRoute(route), domain, reason: route);
      });
      // The hydration reminder says "tap to log a glass": it has to open the
      // control, not the tab the control is buried on.
      // The water reminder lands on Nutrition now — the water tile there
      // steps and clears in place, and the single-field screen it used to
      // open was reachable from nowhere else.
      expect(screenForRoute(kRouteWater), isA<NutritionScreen>());
      // Payload routes that predate the five-tab shell, and that
      // `resolveTapRoute` does not carry yet — the destinations exist here so
      // they stop landing on Home the moment it does.
      expect(domainForRoute('/profile'), ShellDomain.home);
      expect(screenForRoute('/profile'), isA<ProfileHome>(),
          reason: 'the battery notification promises the band, not Home');
      // A week of sleep, strain and recovery is Health. There is no recap
      // screen; landing on Home was not even close.
      expect(domainForRoute('/recap'), ShellDomain.health);
      // Unknown / retired routes must not crash a cold launch.
      expect(domainForRoute(''), ShellDomain.home);
      expect(screenForRoute('/nope'), isNull);
    });

    test('the detected-workout deep link opens on THAT bout', () {
      // "We spotted ~42 min. Tap to log it." has to land on those 42 minutes.
      // Landing on the Workouts tab was issue #113; landing on a list of every
      // unreviewed bout is the same broken promise one screen further in.
      const id = '2026-08-19:1755625800';
      final route = workoutSuggestionRoute(id);
      expect(domainForRoute(route), ShellDomain.home);
      final screen = screenForRoute(route);
      expect(screen, isA<WorkoutSuggestionScreen>());
      expect((screen! as WorkoutSuggestionScreen).focusId, id);
      // A payload from a build that carried no id still reviews everything.
      expect(
          (screenForRoute(kRouteWorkoutSuggestion)! as WorkoutSuggestionScreen)
              .focusId,
          isNull);
    });

    test('the tab index the shell persists round-trips through the enum', () {
      for (final d in ShellDomain.values) {
        expect(ShellDomain.values[d.index], d);
      }
    });
  });

  group('pairing failures are distinguishable', () {
    test('a dismissed picker is not an error', () {
      expect(classifyPairError(Exception('Pairing cancelled.')),
          PairPhase.cancelled);
    });

    test('a refused bond is its own state, because its fix is elsewhere', () {
      expect(classifyPairError(Exception('createBond refused'),),
          PairPhase.bondRefused);
      // The engine's own counter is enough on its own — the message from a
      // platform channel is not guaranteed to name the bond.
      expect(classifyPairError(Exception('link lost'), bondRefusals: 2),
          PairPhase.bondRefused);
    });

    test('anything else keeps its real message and stays generic', () {
      expect(classifyPairError(Exception('gatt 133')), PairPhase.failed);
    });

    testWidgets('every failure state offers a way into the app anyway',
        (tester) async {
      _tallView(tester);
      for (final phase in PairPhase.values) {
        var skipped = false;
        await tester.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: PairingView(
              phase: phase, onPair: () {}, onSkip: () => skipped = true),
        ));
        if (phase == PairPhase.paired) continue;
        await tester.tap(find.text('Skip for now'));
        expect(skipped, isTrue, reason: '$phase has no escape');
      }
    });
  });

  // The first screen a new user sees is the worst place to be vague, and the
  // vaguest thing it could say is a hardware instruction for a phone setting.
  group('a phone-side block is named as a phone-side block', () {
    test('a permission refusal is not "no band in range"', () {
      expect(classifyPairError(Exception('scan failed: permission denied')),
          PairPhase.bluetoothBlocked);
      expect(classifyPairError(Exception('bluetooth unauthorized')),
          PairPhase.bluetoothBlocked);
    });

    test('a typed transport failure carries its own verdict', () {
      // `adapterOff` matches NONE of the string matcher's phrases, so reading
      // this exception as text would demote a switched-off radio to a band
      // fault and send the user walking around the house.
      const e = BleUnavailableException(BleBlocker.adapterOff);
      expect(pairBlocker(e), BleBlocker.adapterOff);
      expect(classifyPairError(e), PairPhase.bluetoothBlocked);
    });

    test('a band-side failure is still a band-side failure', () {
      expect(classifyPairError(Exception('gatt 133')), PairPhase.failed);
      expect(classifyPairError(Exception('createBond refused')),
          PairPhase.bondRefused);
      expect(classifyPairError(Exception('Pairing cancelled.')),
          PairPhase.cancelled);
    });

    testWidgets('the screen says what the BLE layer says, in its words',
        (tester) async {
      _tallView(tester);
      final s = bandStatusFor(
          connection: 'disconnected', blocker: BleBlocker.permissionDenied);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PairingView(
            phase: PairPhase.bluetoothBlocked,
            blocker: BleBlocker.permissionDenied,
            onPair: () {}),
      ));
      expect(find.text(s.title), findsOneWidget);
      expect(find.text(s.reason), findsOneWidget);
      expect(find.text(s.fix!), findsOneWidget);
      // The state this used to land in.
      expect(find.text('No band in range'), findsNothing);
    });
  });

  group('profile setup keeps its promise', () {
    testWidgets('continue is gated on sex alone, and blanks stay blank',
        (tester) async {
      _tallView(tester);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ProfileSetupView(onSave: (f) async => saved = f),
      ));

      // Nothing chosen: the one required field is missing.
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(saved, isNull);

      await tester.tap(find.text('Female'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!['sex'], 'f');
      // The three optional fields were left blank, so they are ABSENT — not
      // zero, and not a default body.
      expect(saved!.containsKey('age'), isFalse);
      expect(saved!.containsKey('height_cm'), isFalse);
      expect(saved!.containsKey('weight_kg'), isFalse);
    });

    testWidgets('what is typed is what is written', (tester) async {
      _tallView(tester);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ProfileSetupView(onSave: (f) async => saved = f),
      ));
      await tester.tap(find.text('Male'));
      await tester.enterText(find.byType(TextField).at(0), '34');
      await tester.enterText(find.byType(TextField).at(2), '78.4');
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(saved!['sex'], 'm');
      expect(saved!['age'], 34);
      expect(saved!['weight_kg'], 78.4);
      expect(saved!.containsKey('height_cm'), isFalse);
    });

    testWidgets('a number it cannot read stops the save instead of dropping it',
        (tester) async {
      _tallView(tester);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ProfileSetupView(onSave: (f) async => saved = f),
      ));
      await tester.tap(find.text('Male'));
      await tester.enterText(find.byType(TextField).at(2), '78 kg');
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pump();

      // Blank is unknown; "78 kg" is not blank, and writing the profile
      // without it would have read as a save that worked.
      expect(saved, isNull);
    });
  });

  group('a typed number is blank, a number, or unreadable', () {
    test('the three cases stay apart', () {
      expect(Typed.of('  ').blank, isTrue);
      expect(Typed.of('  ').bad, isFalse);
      expect(Typed.of('78.4').value, 78.4);
      // A comma decimal is 1.5 to half of Europe and 15 to the other half, and
      // a unit suffix is not a number at all. Neither is guessed at.
      for (final s in ['78 kg', '1,5', '1,200', 'twelve']) {
        expect(Typed.of(s).bad, isTrue, reason: s);
        expect(Typed.of(s).value, isNull, reason: s);
      }
    });
  });

  group('dates', () {
    test('the date reads as a date a person can hold', () {
      expect(formatDay(DateTime(2026, 9, 3)), 'Thu 3 Sep');
      expect(formatDay(DateTime(2026, 1, 1)), 'Thu 1 Jan');
    });
  });

  group('sources rank by quality, not by who wrote last', () {
    HealthSource src(String name, SourceTier tier, {DateTime? at}) =>
        HealthSource(
            name: name, kind: '', tier: tier, icon: LucideIcons.watch,
            lastData: at);

    test('a fresher worse sensor never outranks a better one', () {
      final ranked = rankSources([
        src('Phone', SourceTier.phone, at: DateTime(2026, 8, 22, 12)),
        src('Band', SourceTier.wristOptical, at: DateTime(2026, 8, 20)),
        src('Chest strap', SourceTier.beatToBeat, at: DateTime(2026, 8, 1)),
      ]);
      expect(ranked.map((s) => s.name).toList(),
          ['Chest strap', 'Band', 'Phone']);
    });

    test('recency only breaks a tie inside a tier', () {
      final ranked = rankSources([
        src('Old band', SourceTier.wristOptical, at: DateTime(2026, 8, 1)),
        src('New band', SourceTier.wristOptical, at: DateTime(2026, 8, 22)),
      ]);
      expect(ranked.first.name, 'New band');
    });

    // There is no user preference: the parameter had no caller and no control
    // anywhere in the app, so the last tiebreak is the name.
    test('a tie inside a tier falls back to the name', () {
      final ranked = rankSources([
        src('B', SourceTier.wristOptical),
        src('A', SourceTier.wristOptical),
      ]);
      expect(ranked.first.name, 'A');
    });
  });

  group('a source row states what is measuring, not what is switched on', () {
    HealthSource phone({bool connected = false}) => HealthSource(
        name: 'This phone',
        kind: '',
        tier: SourceTier.phone,
        icon: LucideIcons.smartphone,
        connected: connected);

    HealthSource band({bool connected = true, bool syncing = false}) =>
        HealthSource(
            name: 'WHOOP 4.0',
            kind: '',
            tier: SourceTier.wristOptical,
            icon: LucideIcons.watch,
            connected: connected,
            syncing: syncing,
            isBand: true);

    test('the phone is a source only once steps have actually arrived', () {
      // It used to say "Connected", unconditionally, while HealthKit was
      // returning nothing — a confident claim of a source measuring nothing.
      expect(sourceState(phone()), 'No steps arriving');
      expect(sourceState(phone(connected: true)), 'Reporting steps');
      // And it never says "connected" about a thing with no radio link.
      expect(sourceState(phone(connected: true)), isNot(contains('onnected')));
    });

    test('an offload in progress is not an idle link', () {
      expect(sourceState(band(syncing: true)), 'Syncing');
      expect(sourceState(band()), 'Connected');
      expect(sourceState(band(connected: false)), 'Not connected');
    });

    testWidgets('a fault is named on the row, with its own fix',
        (tester) async {
      _tallView(tester);
      final s = bandStatusFor(
          connection: 'disconnected', autoReconnectPaused: true,
          bondRefusals: 5);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MyDevicesView(sources: [band(connected: false)], status: s),
      ));
      expect(find.text(s.title), findsOneWidget);
      expect(find.text(s.fix!), findsOneWidget);
    });

    testWidgets('an ordinary disconnect does not get a failure card',
        (tester) async {
      _tallView(tester);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MyDevicesView(
            sources: [band(connected: false)],
            status: bandStatusFor(connection: 'disconnected')),
      ));
      // Exactly one "Not connected": the row. No card repeating it.
      expect(find.text('Not connected'), findsOneWidget);
    });
  });

  // The dead end this group exists for: forget the band and the only route
  // back to pairing disappeared. The pair affordance lived inside
  // `sources.isEmpty`, and a phone reporting steps is a source — so one
  // steps-only row was enough to hide it, and the app became unusable as a
  // band app with no way to say so.
  //
  // Driven through the real screen over a real AppState, because reading the
  // widget tree is exactly what missed it: both halves look right on their
  // own.
  group('the way back to pairing survives a forget', () {
    testWidgets('the band goes, the phone stays, the pair affordance appears',
        (tester) async {
      _tallView(tester);
      final app = AppState()
        ..paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1')
        ..phoneStepsEnabled = true
        ..phoneStepsLastSyncedDays = 1
        ..phoneStepsLastTotal = 4200;
      addTearDown(app.dispose);

      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
            theme: buildTheme(Brightness.light), home: const MyDevices()),
      ));
      expect(find.text('Your band'), findsOneWidget);
      expect(find.text('Pair a band'), findsNothing);

      // Forget. `unpair()` itself is platform-bound (ASK, the engine, the
      // foreground service); what it leaves behind for this screen is this.
      app.paired = null;
      app.notifyListeners();
      await tester.pump();

      expect(find.text('Your band'), findsNothing);
      expect(find.text('This phone'), findsOneWidget,
          reason: 'the phone row is what used to swallow the empty state');
      expect(find.text('Pair a band'), findsOneWidget);
    });

    testWidgets('and for someone who only ever had the phone', (tester) async {
      _tallView(tester);
      var pairs = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MyDevicesView(
          sources: [
            const HealthSource(
                name: 'This phone',
                kind: 'Motion coprocessor',
                tier: SourceTier.phone,
                icon: LucideIcons.smartphone,
                connected: true),
          ],
          onPair: () => pairs++,
        ),
      ));
      await tester.tap(find.text('Pair a band'));
      expect(pairs, 1);
    });

    // The other half of the same dead end: getting back to pairing is no good
    // if the band you pair next inherits the forgotten one's identity. The
    // engine holds one DeviceState for the life of the process.
    test('forgetting drops what the old band said about itself', () {
      final d = DeviceState(connection: 'connected')
        ..serial = 'SER1'
        ..strapName = 'Old band'
        ..generation = 'gen4'
        ..batteryPct = 71
        ..autoReconnectPaused = true
        ..bondRefusals = 5;
      d.reset();
      expect(d.serial, isNull);
      expect(d.strapName, isNull);
      expect(d.generation, isNull,
          reason: 'a gen5 band must not be calibrated as the gen4 it replaced');
      expect(d.batteryPct, isNull);
      expect(d.connection, 'disconnected');
      expect(d.autoReconnectPaused, isFalse,
          reason: 'the next band starts with a clean reconnect loop');
      expect(d.bondRefusals, 0);
    });

    testWidgets('a paired band is not asked to pair again', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MyDevicesView(sources: [
          const HealthSource(
              name: 'WHOOP 4.0',
              kind: '',
              tier: SourceTier.wristOptical,
              icon: LucideIcons.watch,
              connected: true,
              isBand: true),
        ], onPair: () {}),
      ));
      expect(find.text('Pair a band'), findsNothing);
    });
  });

  test('byte sizes read like sizes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
  });

  // MT-12 / CV-04a. Per-family calibration means two straps can tier
  // differently on the same physiology; if that is nowhere on screen the tier
  // stops meaning anything. The case that matters most is the THIRD one —
  // every pre-stamp row, every import and every raw replay carries no family,
  // and the disclosure has to say "abstains", never quietly imply gen4.
  group('the device disclosure', () {
    HealthSource band(String? family) => HealthSource(
          name: 'Band',
          kind: 'wrist optical',
          tier: SourceTier.wristOptical,
          icon: LucideIcons.watch,
          isBand: true,
          family: family,
        );

    test('names the family it is calibrated for', () {
      expect(calibrationDisclosure(band('gen4'))!.$1, 'WHOOP 4');
      expect(calibrationDisclosure(band('gen5'))!.$1, 'WHOOP 5');
    });

    test('an unknown family is a refusal, not gen4 by default', () {
      final d = calibrationDisclosure(band(null))!;
      expect(d.$1, isNot(contains('WHOOP 4')));
      expect(d.$2, contains('abstain'));
      // Same answer for a family this build does not know.
      expect(calibrationDisclosure(band('gen9'))!.$1, d.$1);
    });

    test('the phone has no per-sensor calibration to disclose', () {
      expect(
        calibrationDisclosure(const HealthSource(
          name: 'This phone',
          kind: 'Motion coprocessor',
          tier: SourceTier.phone,
          icon: LucideIcons.smartphone,
        )),
        isNull,
      );
    });

    testWidgets('reaches the band page', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DeviceDetailView(band('gen5')),
      ));
      expect(find.text('Calibration'), findsOneWidget);
      expect(find.text('WHOOP 5'), findsOneWidget);
    });
  });

  // An encrypted backup comes back off iCloud Drive or a mail attachment with
  // whatever name that round trip gave it, so routing on the extension would
  // hand the user's entire history to the vendor-CSV importer and report
  // "nothing in it this app could use".
  group('an encrypted backup is recognised by its magic', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('osbk-test');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('whatever it was renamed to', () async {
      final plain = File('${dir.path}/x.db')
        ..writeAsBytesSync(List<int>.generate(5000, (i) => i % 251));
      final sealed = File('${dir.path}/Backup (1).bin');
      await encryptBackupFile(plain, sealed, 'correct horse battery',
          iterations: 1000);
      expect(await isEncryptedBackup(sealed.path), isTrue);
    });

    test('and a plaintext database is not one', () async {
      final plain = File('${dir.path}/y.db')
        ..writeAsStringSync('SQLite format 3\u0000 and then some');
      expect(await isEncryptedBackup(plain.path), isFalse);
      expect(await isEncryptedBackup('${dir.path}/does-not-exist'), isFalse);
    });
  });
}
