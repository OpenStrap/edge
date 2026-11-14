// Behavioral regressions for the pairing stack review. No real Bluetooth.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/band_identity.dart' show PairOutcome;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/pairing/add_device_flow.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/pairing/pair_text.dart';
import 'package:openstrap_edge/ui2/profile/pair_sensor.dart';

import 'support/app_state_derive_harness.dart'
    show deriveDbSetUp, deriveDbTearDown;
import 'support/pair_ui_support.dart';

class _App extends AppState {
  _App() : super.forTesting() {
    paired = PairedDevice('old', 'old');
  }
  Completer<bool>? supported;
  Completer<BluetoothDevice?>? scanned;
  String? scannedGeneration;
  String? scannedRemoteId;
  Object? pickerError;
  var replacements = 0;
  var pickers = 0;
  @override
  Future<bool> accessorySetupSupported() async =>
      supported == null ? false : await supported!.future;
  @override
  Future<BluetoothDevice?> scanForBand({
    String? remoteId,
    String? generation,
  }) async {
    scannedGeneration = generation;
    scannedRemoteId = remoteId;
    return scanned == null ? null : await scanned!.future;
  }

  @override
  Future<void> replaceWith(BluetoothDevice device) async => replacements++;
  @override
  Future<void> replaceViaAccessorySetup() async {
    pickers++;
    if (pickerError != null) throw pickerError!;
  }
  @override
  Future<void> pairViaAccessorySetup({String? serial}) async {
    pickers++;
    if (pickerError != null) throw pickerError!;
  }
  @override
  Future<void> refreshSensors() async {}
}

Future<void> _screen(WidgetTester t, _App app, Widget screen) => pumpPair(
  t,
  screen,
  wrap: (child) =>
      ChangeNotifierProvider<AppState>.value(value: app, child: child),
  size: const Size(412, 2400),
);

Future<void> _ioUntil(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
  }
  expect(ready(), isTrue, reason: 'screen did not finish its database read');
}

void main() {
  setUp(() async {
    await deriveDbSetUp('pairing_stack_review.db');
    await LocalDb.instance;
  });
  tearDown(() => deriveDbTearDown('pairing_stack_review.db'));

  for (final found in [false, true]) {
    // WHY: the default picker deliberately skips automatic scanning, and must
    // offer an explicit scan both before and after results arrive.
    // catches: exposing onScan only inside the held-back warning card.
    testWidgets('scan remains reachable (has results=$found)', (t) async {
      final query = TextEditingController();
      addTearDown(query.dispose);
      var scans = 0;
      await pumpPair(
        t,
        DevicePickerView(
          query: query,
          title: 'Devices',
          subtitle: 'Nearby',
          found: found
              ? [
                  (
                    device: BluetoothDevice.fromId('ring'),
                    label: 'Ring',
                    rssi: -50,
                    entryId: 'colmi',
                    alsoBand: null,
                  ),
                ]
              : [],
          onScan: () => scans++,
        ),
        size: const Size(412, 2400),
      );
      // Exercise the rendered scan control, not just the stored callback.
      expect(find.text('Search for devices'), findsOneWidget);
      await t.tap(find.text('Search for devices'));
      await t.pump();
      expect(scans, 1);
    });
  }

  // WHY: a hidden Rings selection must not hide an ungrouped scale.
  // catches: applying a selected filter when only one pill group remains.
  testWidgets('hidden filter pills leave rings and ungrouped devices visible', (
    t,
  ) async {
    final query = TextEditingController();
    final selection = ValueNotifier<PairFilter?>(PairFilter.rings);
    addTearDown(query.dispose);
    addTearDown(selection.dispose);
    await pumpPair(
      t,
      DevicePickerView(
        query: query,
        title: 'Devices',
        subtitle: 'Nearby',
        kindSelection: selection,
        categories: [
          (entry: kColmi, blurb: 'Ring', icon: LucideIcons.circleDot),
          (
            entry: kThermometer,
            blurb: 'Temperature',
            icon: LucideIcons.thermometer,
          ),
        ],
      ),
      size: const Size(412, 2400),
    );
    expect(find.text('Colmi ring'), findsOneWidget);
    expect(find.text('Bluetooth thermometer'), findsOneWidget);
  });

  // WHY: first-run callbacks may already be queued before navigation covers
  // the picker. Returning from the route must allow the next deliberate tap.
  testWidgets('first-run taps stay locked until navigation returns', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await _screen(t, app, const DevicePickerScreen());
    final dynamic host = t.state(find.byType(DevicePickerScreen));
    host.pickBand(kWhoopGen4);
    host.pickBand(kWhoopGen4);
    host.strapOnlyConfirmed();
    await t.pumpAndSettle();
    expect(find.byType(PairingScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    Navigator.of(t.element(find.byType(PairingScreen))).pop();
    await t.pumpAndSettle();
    host.pickBand(kWhoopGen4);
    await t.pumpAndSettle();
    expect(
      find.byType(PairingScreen),
      findsOneWidget,
      reason: 'next deliberate tap is accepted',
    );
  });

  // WHY: the host callbacks used by first-run must obey the same lock as
  // category and nearby taps, without losing the selected WHOOP model.
  // catches: pickBand forwarding straight to _openEntry without the guard.
  testWidgets('first-run host callbacks share the navigation lock', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await _screen(t, app, const DevicePickerScreen());
    final dynamic host = t.state(find.byType(DevicePickerScreen));
    host.pickBand(kWhoopGen5);
    host.pickBand(kWhoopGen4);
    host.strapOnlyConfirmed();
    await t.pumpAndSettle();
    expect(find.byType(PairingScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final pairing = t.widget<PairingScreen>(find.byType(PairingScreen));
    expect(pairing.entry, kWhoopGen5);
    await t.tap(find.text('Find my band'));
    await t.pumpAndSettle();
    expect(app.scannedGeneration, 'gen5');
  });

  // WHY: a name-only candidate establishes the remote id, but not a model.
  // The representative entry supplies safe help without filtering out gen5.
  testWidgets('name-only WHOOP handoff keeps help and the exact candidate', (
    t,
  ) async {
    final app = _App();
    addTearDown(app.dispose);
    await _screen(t, app, const DevicePickerScreen());
    final io = t.state(find.byType(DevicePickerScreen)) as AddDeviceIo;
    final opened = io.openBandFlow(
      kWhoopGen4,
      remoteId: 'picked',
      modelKnown: false,
    );
    await t.pumpAndSettle();
    expect(
      t.widget<PairingScreen>(find.byType(PairingScreen)).entry,
      kWhoopGen4,
    );
    await t.tap(find.text('Find my band'));
    await t.pumpAndSettle();
    expect(app.scannedGeneration, isNull);
    expect(app.scannedRemoteId, 'picked');
    Navigator.of(t.element(find.byType(PairingScreen))).pop();
    await t.pumpAndSettle();
    await opened;
  });

  for (final waitingOnSupport in [false, true]) {
    // WHY: leaving while the scan/support probe waits cancels the intent to
    // replace. Checking mounted after replacement is already too late.
    // catches: starting replaceWith/replaceViaAccessorySetup after disposal.
    testWidgets(
      'closing pairing cancels pending work (support=$waitingOnSupport)',
      (t) async {
        final app = _App();
        addTearDown(app.dispose);
        app.supported = Completer<bool>();
        app.scanned = Completer<BluetoothDevice?>();
        await _screen(t, app, const PairingScreen(replacing: true));
        await t.tap(find.text('Find my band'));
        await t.pump();
        if (!waitingOnSupport) {
          app.supported!.complete(false);
          await t.pump();
        }
        await t.pumpWidget(const MaterialApp(home: SizedBox()));
        if (waitingOnSupport) {
          app.supported!.complete(true);
        } else {
          app.scanned!.complete(BluetoothDevice.fromId('new'));
        }
        await t.pumpAndSettle();
        expect(app.replacements, 0);
        expect(app.pickers, 0);
        expect(t.takeException(), isNull);
      },
    );
  }

  // WHY: a category tap owns the radio even while the earlier iOS probe waits.
  // catches: _start checking the navigation lock only before its await.
  testWidgets('pending scan probe does not start a scan behind pairing', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    final probe = Completer<String?>();
    await _screen(t, app, DevicePickerScreen(includeBand: false, debugScanHeldBackReason: () => probe.future));
    final view = t.widget<DevicePickerView>(find.byType(DevicePickerView));
    view.onScan!();
    view.onOpenEntry!(kWhoopGen4);
    await t.pumpAndSettle();
    probe.complete(null);
    await t.pumpAndSettle();
    final parent = t.widget<DevicePickerView>(find.byType(DevicePickerView, skipOffstage: false));
    expect(parent.scanning, isFalse);
    expect(parent.problem, isNull, reason: 'no late parent scan may touch Bluetooth');
    // The navigation lock still belongs to the child route.
    expect(parent.locked, isTrue);
    Navigator.of(t.element(find.byType(PairingScreen))).pop();
    await t.pumpAndSettle();
    expect(t.widget<DevicePickerView>(find.byType(DevicePickerView)).locked, isFalse);
  });

  // WHY: a representative gen4 entry is not evidence of the band's model.
  // catches: forwarding widget.entry to failure help despite modelKnown=false.
  testWidgets('unknown WHOOP failure keeps recovery guidance model-neutral', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await _screen(t, app, const PairingScreen(entry: kWhoopGen4, modelKnown: false));
    await t.tap(find.text('Find my band'));
    await t.pumpAndSettle();
    expect(t.widget<PairingView>(find.byType(PairingView)).phase, PairPhase.notFound);
    expect(t.widget<PairingView>(find.byType(PairingView)).resetEntry, isNull);
    expect(find.text('WHOOP 4'), findsNothing);
  });

  for (final replacing in [true, false]) {
    // WHY: ASK can select a different generation from the row that opened it.
    // CLAIM(pairing-help-model); catches: using the tapped entry after ASK failure.
    testWidgets('ASK failure never assumes the tapped generation (replace=$replacing)', (t) async {
      final app = _App()
        ..supported = (Completer<bool>()..complete(true))
        ..pickerError = StateError('bootstrap failed');
      addTearDown(app.dispose);
      await _screen(t, app, PairingScreen(entry: kWhoopGen4, replacing: replacing));
      await t.tap(find.text('Find my band'));
      await t.pumpAndSettle();
      final view = t.widget<PairingView>(find.byType(PairingView));
      expect(view.phase, PairPhase.failed);
      expect(view.resetEntry, isNull);
      expect(find.text('WHOOP 4'), findsNothing);
    });
  }

  // WHY: iOS cannot scan an accessory before ASK grants access to it.
  // CLAIM(replacement-without-scan); catches: requiring a nearby WHOOP row.
  testWidgets('add device can replace the main band without a scan result', (t) async {
    final app = _App()..supported = (Completer<bool>()..complete(true));
    addTearDown(app.dispose);
    await _screen(t, app, DevicePickerScreen(includeBand: false,
        debugScanHeldBackReason: () async => 'No scan needed'));
    await t.pumpAndSettle();
    expect(find.text('Replace my band'), findsOneWidget);
    await t.tap(find.text('Replace my band'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('replace-confirm-yes')));
    await t.pumpAndSettle();
    final screen = t.widget<PairingScreen>(find.byType(PairingScreen));
    expect(screen.replacing, isTrue);
    expect(screen.remoteId, isNull);
    expect(screen.modelKnown, isFalse);
    await t.tap(find.text('Find my band'));
    await t.pumpAndSettle();
    expect(app.pickers, 1);
    expect(app.scannedGeneration, isNull);
    expect(app.paired?.remoteId, 'old');
  });

  // WHY: backing out of a ring's authenticated pairing saved nothing.
  // CLAIM(unframed-pairing-result); catches: treating all unframed handoffs as success.
  testWidgets('ring handoff cancellation keeps the original candidate', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    final candidate = (device: BluetoothDevice.fromId('ring'), label: 'Candidate ring',
        rssi: -50, entryId: 'ble_hrs', alsoBand: null);
    final entered = Completer<void>();
    await _screen(t, app, PairSensorScreen(entry: kBleHrs, debugFound: [candidate],
        debugPair: (_) async {
          entered.complete();
          return const PairOutcome.band(kOura);
        }));
    await t.pumpAndSettle();
    var done = false;
    final pick = t.widget<PairSensorView>(find.byType(PairSensorView)).onPick!
        as Future<void> Function(BandCandidate);
    final pairing = pick(candidate).whenComplete(() => done = true);
    await _ioUntil(t, () => entered.isCompleted);
    await t.pumpAndSettle();
    await t.tap(find.text('Pair Oura Ring'));
    await t.pumpAndSettle();
    expect(find.byType(PairSensorScreen, skipOffstage: false), findsNWidgets(2));
    Navigator.of(t.element(find.byType(PairSensorScreen).last)).pop();
    await t.pumpAndSettle();
    await _ioUntil(t, () => done);
    await pairing;
    expect(find.textContaining('Nothing was saved'), findsOneWidget);
    expect(find.text('Candidate ring'), findsOneWidget);
  });

  // WHY: requiring an explicit result must still accept a successful child pair.
  // CLAIM(unframed-pairing-result); catches: always returning cancellation after handoff.
  testWidgets('wearable child returns success only after its pairing succeeds', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    final candidate = (device: BluetoothDevice.fromId('ring'), label: 'Ring',
        rssi: -50, entryId: 'oura', alsoBand: null);
    BandFlowResult? result;
    final pairedIds = <String>[];
    await _screen(t, app, Builder(builder: (c) => TextButton(
      onPressed: () async {
        result = await Navigator.of(c).push(MaterialPageRoute<BandFlowResult>(
          builder: (_) => PairSensorScreen(entry: kOura, returnOnPair: true,
            debugFound: [candidate], onPicked: (device) async {
              pairedIds.add(device.remoteId.str);
              return null;
            }),
        ));
      }, child: const Text('Open wearable'))));
    await t.tap(find.text('Open wearable'));
    await t.pumpAndSettle();
    expect(result, isNull);
    var done = false;
    final pick = t.widget<PairSensorView>(find.byType(PairSensorView)).onPick!
        as Future<void> Function(BandCandidate);
    final pairing = pick(candidate).whenComplete(() => done = true);
    await _ioUntil(t, () => done);
    await pairing;
    await t.pumpAndSettle();
    expect(pairedIds, ['ring']);
    expect(result, BandFlowResult.pairedWearable);
    expect(find.byType(PairSensorScreen), findsNothing);
  });

  // WHY: an old primary still existing does not prove a replacement succeeded.
  // catches: using AppState.isPaired instead of comparing the selected identity.
  for (final systemPickerSaved in [false, true]) {
  testWidgets(
    'band flow reports actual replacement (system picker=$systemPickerSaved)',
    (t) async {
      final app = _App();
      addTearDown(app.dispose);
      final candidate = (
        device: BluetoothDevice.fromId('new'),
        label: 'Candidate',
        rssi: -50,
        entryId: 'ble_hrs',
        alsoBand: null,
      );
      final entered = Completer<void>();
      await _screen(
        t,
        app,
        PairSensorScreen(
          entry: kBleHrs,
          debugFound: [candidate],
          debugPair: (_) async {
            entered.complete();
            return PairOutcome.band(kWhoopGen5);
          },
        ),
      );
      await t.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pumpAndSettle();
      var done = false;
      final pick =
          t.widget<PairSensorView>(find.byType(PairSensorView)).onPick!
              as Future<void> Function(BandCandidate);
      final pairing = pick(candidate).whenComplete(() => done = true);
      await _ioUntil(t, () => entered.isCompleted);
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Pair this band, then disconnect'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('replace-confirm-yes')));
      await t.pumpAndSettle();
      expect(find.byType(PairingScreen), findsOneWidget);
      if (systemPickerSaved) app.paired = PairedDevice('system-picked', 'new');
      Navigator.of(t.element(find.byType(PairingScreen))).pop();
      await t.pumpAndSettle();
      await t.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pumpAndSettle();
      await _ioUntil(t, () => done);
      await pairing;
      await t.pumpAndSettle();
      expect(app.paired?.remoteId, systemPickerSaved ? 'system-picked' : 'old');
      expect(find.textContaining('Nothing was saved'), systemPickerSaved ? findsNothing : findsOneWidget);
      if (!systemPickerSaved) expect(find.text('Candidate'), findsOneWidget);
    },
  );

  }

  // WHY: AddDeviceFlow can finish stopping a scan after its owner is disposed.
  // catches: looking up either navigator on a disposed PairSensorScreen.
  testWidgets('disposed sensor screen ignores band handoff', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await _screen(t, app, PairSensorScreen(entry: kBleHrs));
    final io = t.state(find.byType(PairSensorScreen)) as AddDeviceIo;
    await t.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    for (final band in [kWhoopGen5, kOura]) {
      await io.openBandFlow(band, remoteId: 'new');
      expect(t.takeException(), isNull);
    }
  });
}
