// The "this is a band" / "sensor without a band" sheets, and the tap flow that
// decides which one a scanned device gets. Rendered, with a fake pairing
// operation: no BLE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/band_identity.dart';
import 'package:openstrap_edge/ble/hrs_link.dart' show BandCandidate;
import 'package:openstrap_edge/ui2/pairing/add_device_flow.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show kPairableSensors;
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart' show DevicePickerView;
import 'package:openstrap_edge/ui2/pairing/pair_text.dart' show PairFilter;
import 'package:openstrap_edge/ui2/profile/pair_sensor.dart' show afterBandFoundText;
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/ui2/pairing/pair_choice_sheet.dart';
import 'package:openstrap_edge/ui2/pairing/pair_sheets.dart';

import 'support/pair_ui_support.dart';
import 'package:openstrap_edge/ui2/pairing/slot_comparison_view.dart';

BandCandidate _cand(String entryId,
        {String id = 'AA:BB:CC:DD:EE:01', String? label, BandEntry? alsoBand}) =>
    (
      device: BluetoothDevice.fromId(id),
      label: label,
      rssi: -60,
      entryId: entryId,
      alsoBand: alsoBand == null ? null : (entry: alsoBand, modelCertain: true),
    );

/// A screen with one button that runs [flow] on [cand] and prints the result.
class _Harness extends StatefulWidget {
  final AddDeviceFlow flow;
  final BandCandidate cand;
  const _Harness(this.flow, this.cand);
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String result = 'none';
  String second = 'none';
  @override
  Widget build(BuildContext c) => Scaffold(
        body: Column(children: [
          TextButton(
              onPressed: () async {
                final r = await widget.flow.onTap(c, widget.cand);
                setState(() => result = '${r.outcome.name}|${r.message ?? ''}');
              },
              child: const Text('tap')),
          // A competing tap on the same flow, as a second row would make.
          TextButton(
              onPressed: () async {
                final r = await widget.flow.onTap(c, widget.cand);
                setState(() => second = '${r.outcome.name}|${r.message ?? ''}');
              },
              child: const Text('tap again')),
          Text(result, key: const ValueKey('result')),
          Text(second, key: const ValueKey('second')),
        ]),
      );
}

class _Calls implements AddDeviceIo {
  final pairs = <(String entryId, PairConfirmation? confirmation)>[];
  final opened = <String>[];
  final events = <String>[];
  String? heldBack;
  final List<PairOutcome> outcomes;
  Object? pairError;
  _Calls([this.outcomes = const [PairOutcome.saved()]]);
  int _i = 0;
  bool _hasMain = false;
  @override
  bool get hasMainBand => _hasMain;

  String primaryId = 'primary';
  @override
  String? get mainBandRemoteId => _hasMain ? primaryId : null;

  String? bandName = 'Jordan’s WHOOP';
  @override
  String? get mainBandName => _hasMain ? bandName : null;

  BandFlowResult bandFlowResult = BandFlowResult.closed;
  Completer<void>? openGate;
  final replacementFlags = <bool>[];
  @override
  Future<PairOutcome> pair(BandCandidate cand, BandEntry entry,
      PairConfirmation? confirmation) async {
    if (pairError != null) throw pairError!;
    events.add('pair:${entry.id}');
    pairs.add((entry.id, confirmation));
    return outcomes[_i < outcomes.length ? _i++ : outcomes.length - 1];
  }

  final openedWith = <(String remoteId, bool modelKnown)>[];
  @override
  Future<BandFlowResult> openBandFlow(BandEntry band,
      {required String? remoteId, bool modelKnown = true, bool replacing = false}) async {
    events.add('open:${band.id}');
    replacementFlags.add(replacing);
    await openGate?.future;
    opened.add(band.id);
    openedWith.add((remoteId!, modelKnown));
    return bandFlowResult;
  }

  @override
  Future<void> stopScan() async => events.add('stop');

  @override
  Future<String?> mainBandBlockedReason() async => heldBack;

  late AddDeviceFlow flowFor;
  AddDeviceFlow flow({bool hasMain = false}) {
    _hasMain = hasMain;
    return flowFor = AddDeviceFlow(this);
  }
}

String _result(WidgetTester t) =>
    (t.widget(find.byKey(const ValueKey('result'))) as Text).data!;

Future<void> _tap(WidgetTester t, _Calls calls, BandCandidate cand,
    {bool hasMain = false}) async {
  await pumpPair(t, _Harness(calls.flow(hasMain: hasMain), cand),
      size: const Size(412, 2000));
  await t.tap(find.text('tap'));
  await t.pumpAndSettle();
}

void main() {
  group('the band-found sheet', () {
    Future<BandSheetChoice?> open(WidgetTester t, BandEntry band,
        {required bool hasMain, bool afterConnect = false}) async {
      BandSheetChoice? got;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async => got = await showBandFoundSheet(c,
                          band: band,
                          hasMainBand: hasMain,
                          afterConnect: afterConnect),
                      child: const Text('open')))),
          size: const Size(412, 2000));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return got;
    }

    testWidgets('pairing mode is up front: WHOOP 5’s steps, above the main button', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      expect(find.text('Put it in pairing mode'), findsOneWidget);
      final step = t.getTopLeft(find.byKey(const ValueKey('pairing-mode-step-gen5-1'))).dy;
      expect(step, lessThan(t.getTopLeft(find.text('Pair it as my band')).dy));
      expect(step, greaterThan(t.getTopLeft(find.byType(SlotTable)).dy));
    });

    testWidgets('the table: every day sends sleep, workouts only does not; no dashes', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-sleep'))).label, 'Sleep, Every day: Sends');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-workoutsOnly-sleep'))).label, 'Sleep, Workouts only: Doesn’t send');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-workoutsOnly-workoutHeartRate'))).label, 'Heart rate during workouts, Workouts only: Sends');
      expect(find.byIcon(LucideIcons.minus), findsNothing);
      expect(find.text('Workouts only: If this device sends it, not confirmed'), findsOneWidget);
      expect(find.text('Blood oxygen'), findsNothing);
    });

    testWidgets('the sheet washes the Every day column, not Workouts only', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      Color? colour(String slot) => (t
              .widget<Container>(find
                  .descendant(
                      of: find.byKey(const ValueKey('slot-row-sleep')),
                      matching: find.byKey(ValueKey('slot-cell-$slot')))
                  .first)
              .color);
      expect(colour('everyDay'), isNotNull);
      expect(colour('workoutsOnly'), isNull);
    });

    testWidgets('a ring fills every day: the ring’s rows with their captions, and the experimental note', (t) async {
      await open(t, kOura, hasMain: false);
      expect(find.text('This is a ring'), findsOneWidget);
      expect(find.text('It can fill your days with sleep, recovery and heart rate.'), findsOneWidget);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-sleep'))).label, 'Sleep, Every day: Sends. From the ring’s own sleep stages');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-workoutsOnly-sleep'))).label, 'Sleep, Workouts only: Doesn’t send');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-strain'))).label, 'Strain, Every day: Doesn’t send');
      expect(find.text('Every day: From the ring’s own sleep stages'), findsOneWidget);
      expect(find.text('Every day: Estimated for the first 14 nights'), findsOneWidget);
      expect(find.text('Every day: Provisional estimate; needs a few nights'), findsOneWidget);
      expect(find.text('Fills days without your WHOOP. Experimental, so switch it on in Devices.'), findsOneWidget);
      expect(find.text('Pair Oura Ring'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsNothing);
    });

    testWidgets('a heart-rate strap: workouts only, the switch note, and Pair', (t) async {
      await pumpPair(t, Builder(builder: (c) => Scaffold(body: TextButton(
          onPressed: () => showStrapSheet(c, sensor: kBleHrs),
          child: const Text('open')))), size: const Size(412, 2000));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('This is a heart-rate sensor'), findsOneWidget);
      expect(find.text('It adds heart rate while you work out. It does not record sleep, recovery or daily strain.'), findsOneWidget);
      expect(find.text('Turn on “Use during workouts” to record heart rate while you work out.'), findsOneWidget);
      expect(find.text('Workouts only: If this device sends it, not confirmed'), findsOneWidget);
      expect(find.text('Pair Bluetooth heart rate sensor'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-sleep'))).label, 'Sleep, Every day: Doesn’t send');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-workoutHeartRate'))).label, 'Heart rate during workouts, Every day: Doesn’t send');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-workoutsOnly-workoutHeartRate'))).label, 'Heart rate during workouts, Workouts only: Sends');
    });

    testWidgets('the confirm fits in German at 2x text', (t) async {
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () => showReplaceBandConfirm(c,
                          mainBandName: 'Jordans WHOOP'),
                      child: const Text('open')))),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 800));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(SlotTable), findsNothing);
    });
    testWidgets('no main band yet: pair it as my band, or use it for workouts only', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      expect(find.text('This is a WHOOP band'), findsOneWidget);
      expect(find.text('WHOOP 5'), findsOneWidget, reason: 'the device line');
      expect(find.text('It does much more every day than during workouts only. Which do you want?'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsOneWidget);
      expect(find.text('Use it for workouts only'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
    });



    testWidgets('a ring and a strap get their own pairing-mode section', (t) async {
      await open(t, kOura, hasMain: false);
      expect(find.byKey(const ValueKey('pairing-mode-oura')), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-mode-step-oura-1')), findsOneWidget);
    });





    testWidgets('the choices come back to the caller', (t) async {
      BandSheetChoice? got;
      Future<void> run(String label) async {
        await pumpPair(
            t,
            Builder(
                builder: (c) => Scaffold(
                    body: TextButton(
                        onPressed: () async => got = await showBandFoundSheet(c,
                            band: kWhoopGen5, hasMainBand: false),
                        child: const Text('open')))),
            size: const Size(412, 2000));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        await t.tap(find.text(label));
        await t.pumpAndSettle();
      }

      await run('Pair it as my band');
      expect(got, BandSheetChoice.asBand);
      got = null;
      await run('Use it for workouts only');
      expect(got, BandSheetChoice.asSensor);
      got = BandSheetChoice.asBand;
      await run('Go back');
      expect(got, isNull);
    });

    testWidgets('a main band already exists: unpair it and pair this one, or workouts only', (t) async {
      BandSheetChoice? got;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async => got = await showBandFoundSheet(c,
                          band: kWhoopGen5,
                          hasMainBand: true,
                          mainBandName: 'Jordan’s WHOOP'),
                      child: const Text('open')))),
          size: const Size(412, 2000));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('You already have a band. Only one can be your band at a time.'), findsOneWidget);
      expect(find.text('Your band now: Jordan’s WHOOP. Your data stays when you switch.'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsNothing);
      expect(find.text('Use it for workouts only'), findsOneWidget);
      await t.tap(find.text('Pair this band, then disconnect Jordan’s WHOOP'));
      await t.pumpAndSettle();
      expect(got, BandSheetChoice.replaceBand);
    });

    testWidgets('a paired band with no name is “your band”', (t) async {
      await open(t, kWhoopGen5, hasMain: true);
      expect(find.text('Pair this band, then disconnect your band'), findsOneWidget);
    });

    testWidgets('Coros fits neither column: a watch, all crosses, one Pair button', (t) async {
      await open(t, kCoros, hasMain: false);
      expect(find.text('This is a watch'), findsOneWidget);
      expect(find.text('Pair Coros watch'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsNothing);
      expect(find.byIcon(LucideIcons.check), findsNothing);
      expect(find.textContaining('its readings never feed a score'), findsOneWidget);
    });



    testWidgets('after connecting: says it identified itself, and that nothing was saved', (t) async {
      await open(t, kWhoopGen5, hasMain: false, afterConnect: true);
      expect(
          find.text('It looked like a heart-rate strap, but when we connected it identified itself as WHOOP 5. Nothing was saved.'),
          findsOneWidget);
      expect(find.text('Pair it as my band'), findsOneWidget);
    });

    testWidgets('German at 2x text does not overflow', (t) async {
      BandSheetChoice? ignore;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async => ignore = await showBandFoundSheet(c,
                          band: kWhoopGen5, hasMainBand: false),
                      child: const Text('open')))),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(ignore, isNull);
    });
  });

  group('the strap sheet', () {
    Future<void> open(WidgetTester t, BandEntry sensor, void Function(bool?) got) async {
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async =>
                          got(await showStrapSheet(c, sensor: sensor)),
                      child: const Text('open')))),
          size: const Size(412, 2000));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }



    testWidgets('a generic strap says there are no maker’s steps', (t) async {
      await open(t, kBleHrs, (_) {});
      expect(find.byKey(const ValueKey('pairing-mode-no-site-ble_hrs')), findsOneWidget);
    });

    testWidgets('another kind of sensor is a heart-rate sensor', (t) async {
      await open(t, kPolarPmd, (_) {});
      expect(find.text('This is a heart-rate sensor'), findsOneWidget);
      expect(find.text('This is a heart-rate strap'), findsNothing);
    });

    testWidgets('Pair returns true, Go back false', (t) async {
      bool? got;
      await open(t, kBleHrs, (v) => got = v);
      await t.tap(find.text('Pair Bluetooth heart rate sensor'));
      await t.pumpAndSettle();
      expect(got, isTrue);
      await open(t, kBleHrs, (v) => got = v);
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(got, isFalse);
    });

    testWidgets('German at 2x text does not overflow', (t) async {
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () => showStrapSheet(c, sensor: kBleHrs),
                      child: const Text('open')))),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('replacing the band', () {
    final whoop = _cand('gen5', id: 'AA:00:00:00:00:77', label: 'WHOOP 5A1B');

    testWidgets('confirm opens replacement pairing without forgetting the current band', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoop, hasMain: true);
      await t.tap(find.text('Pair this band, then disconnect Jordan’s WHOOP'));
      await t.pumpAndSettle();
      expect(find.text('Replace Jordan’s WHOOP after this band connects?'), findsOneWidget);
      expect(find.text('Your current band stays paired if setup fails or you cancel. Data already saved on this phone stays. Anything still unsynced on the old band is not synced to this phone after the switch.'), findsOneWidget);
      expect(calls.events, isEmpty, reason: 'nothing happens before the one confirm');
      await t.tap(find.text('Pair replacement'));
      await t.pumpAndSettle();
      expect(calls.events, ['stop', 'open:gen5']);
      expect(calls.openedWith, [('AA:00:00:00:00:77', true)]);
      expect(calls.replacementFlags, [true]);
      expect(calls.pairs, isEmpty);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('cancel does nothing: no unpair, no pairing, no band flow', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoop, hasMain: true);
      await t.tap(find.text('Pair this band, then disconnect Jordan’s WHOOP'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(calls.events, isEmpty);
      expect(calls.pairs, isEmpty);
      expect(calls.opened, isEmpty);
      expect(_result(t), 'cancelled|');
    });



    testWidgets('a second tap while replacement pairing is running starts nothing', (t) async {
      final calls = _Calls()..openGate = Completer<void>();
      await _tap(t, calls, whoop, hasMain: true);
      await t.tap(find.text('Pair this band, then disconnect Jordan’s WHOOP'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair replacement'));
      await t.pump();
      expect(calls.events, ['stop', 'open:gen5']);
      // Replacement pairing is still awaiting; a competing tap is refused at once.
      await t.tap(find.text('tap again'));
      await t.pumpAndSettle();
      expect(find.text('This is a WHOOP band'), findsNothing,
          reason: 'no second sheet opened');
      expect((t.widget(find.byKey(const ValueKey('second'))) as Text).data,
          'cancelled|');
      calls.openGate!.complete();
      await t.pumpAndSettle();
      expect(calls.events, ['stop', 'open:gen5']);
      expect(calls.opened, ['gen5']);
      expect(_result(t), 'openedBandFlow|');
      // Once it ended, the flow takes a tap again.
      expect(calls.flowFor.running, isFalse);
    });

    testWidgets('while a flow runs the Add a device list takes no taps', (t) async {
      var taps = 0;
      await pumpPair(
          t,
          DevicePickerView(
            query: TextEditingController(),
            title: 'Add a device',
            subtitle: '',
            found: [whoop],
            locked: true,
            onPickNearby: (_) => taps++,
          ),
          size: const Size(412, 2000));
      await t.tap(find.text('WHOOP 5A1B'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(taps, 0);
      await pumpPair(
          t,
          DevicePickerView(
            query: TextEditingController(),
            title: 'Add a device',
            subtitle: '',
            found: [whoop],
            onPickNearby: (_) => taps++,
          ),
          size: const Size(412, 2000));
      await t.tap(find.text('WHOOP 5A1B'));
      await t.pumpAndSettle();
      expect(taps, 1, reason: 'positive control: unlocked, the row takes a tap');
    });

    testWidgets('a WHOOP heard as a strap is replaced the same way, bound to that device', (t) async {
      final calls = _Calls();
      await _tap(t, calls,
          _cand('ble_hrs', id: 'AA:00:00:00:00:78', label: 'Jordan’s other WHOOP', alsoBand: kWhoopGen4),
          hasMain: true);
      await t.tap(find.text('Pair this band, then disconnect Jordan’s WHOOP'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair replacement'));
      await t.pumpAndSettle();
      expect(calls.events, ['stop', 'open:gen4']);
      expect(calls.openedWith, [('AA:00:00:00:00:78', true)]);
    });

    testWidgets('after a connect found a band: the same replace, one confirm', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5)]);
      await _tap(t, calls, _cand('ble_hrs', label: 'Polar H10'), hasMain: true);
      await t.tap(find.text('Pair this band, then disconnect Jordan’s WHOOP'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair replacement'));
      await t.pumpAndSettle();
      expect(calls.events, ['pair:ble_hrs', 'stop', 'open:gen5']);
    });


  });

  // WHY: the workout cleanup must never own the main peripheral's link.
  // catches: letting the primary's remote id reach the secondary pair call.
  for (final discoveredAfterConnect in [false, true]) {
    testWidgets('current main band cannot become a sensor (after connect=$discoveredAfterConnect)', (t) async {
      final calls = _Calls(discoveredAfterConnect
          ? [PairOutcome.band(kWhoopGen5), const PairOutcome.saved()]
          : [const PairOutcome.saved()]);
      await _tap(t, calls, _cand('ble_hrs', id: 'primary',
          alsoBand: discoveredAfterConnect ? null : kWhoopGen5), hasMain: true);
      final choice = find.text('Use it for workouts only');
      if (choice.evaluate().isNotEmpty) {
        await t.tap(choice);
        await t.pumpAndSettle();
      }
      expect(calls.pairs, isEmpty,
          reason: 'reject before connecting to the saved primary');
      expect(_result(t), startsWith('failed|'));
    });
  }

  // WHY: another flow can commit a primary while this confirmation is open.
  // catches: checking primary identity only at the original tap.
  testWidgets('workouts choice rechecks the primary identity before connecting', (t) async {
    final calls = _Calls();
    await _tap(t, calls, _cand('gen5', id: 'new-main'), hasMain: true);
    calls.primaryId = 'new-main';
    await t.tap(find.text('Use it for workouts only'));
    await t.pumpAndSettle();
    expect(calls.pairs, isEmpty);
    expect(_result(t), startsWith('failed|'));
  });

  // WHY: post-connect WHOOP identification supersedes a Polar-looking advert.
  // catches: retrying WHOOP under Polar PMD's required characteristics.
  testWidgets('WHOOP discovered during Polar pairing retries as BLE HRS', (t) async {
    final calls = _Calls([PairOutcome.band(kWhoopGen5), const PairOutcome.saved()]);
    await _tap(t, calls, _cand('polar_pmd'), hasMain: true);
    await t.tap(find.text('Use it for workouts only'));
    await t.pumpAndSettle();
    expect(calls.pairs.map((p) => p.$1), ['polar_pmd', 'ble_hrs']);
    expect(calls.pairs.last.$2?.bandEntryId, 'gen5');
    expect(_result(t), 'pairedSecondary|');
  });

  group('tap flow', () {
    final whoopAsStrap = _cand('ble_hrs', label: 'Jordan’s WHOOP', alsoBand: kWhoopGen5);

    testWidgets('a WHOOP heard as a strap, no band yet: sheet, then “secondary anyway” pairs with a confirmation bound to that device and entry', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap);
      expect(find.text('This is a WHOOP band'), findsOneWidget);
      await t.tap(find.text('Use it for workouts only'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1);
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(calls.pairs.single.$2!.remoteId, 'AA:BB:CC:DD:EE:01');
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('“Pair it as my band” goes to the main band flow and pairs nothing here', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(calls.opened, ['gen5']);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('(CR r1) the band flow is bound to the tapped device, not the first WHOOP in range', (t) async {
      // WHY: handing over only the entry let the main-band scan pair any
      // nearby WHOOP of that kind.
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs', id: 'AA:00:00:00:00:42', alsoBand: kWhoopGen5));
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.openedWith, [('AA:00:00:00:00:42', true)]);
    });

    testWidgets('(CR r1) a WHOOP known only by its name is not named a model', (t) async {
      // WHY: the name cannot tell WHOOP 4 from 5; the name-matched entry is
      // gen4, which must not become "This is WHOOP 4" or a WHOOP 4 pairing.
      final calls = _Calls();
      final byName = (
        device: BluetoothDevice.fromId('AA:00:00:00:00:43'),
        label: 'WHOOP 4C0FFEE',
        rssi: -60,
        entryId: 'gen4',
        alsoBand: (entry: kWhoopGen4, modelCertain: false),
      );
      await _tap(t, calls, byName);
      expect(find.text('This is a WHOOP band'), findsOneWidget);
      expect(find.text('WHOOP 4'), findsNothing, reason: 'no model named');
      expect(find.text('WHOOP 4C0FFEE'), findsOneWidget, reason: 'its own name');
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.openedWith, [('AA:00:00:00:00:43', false)]);
    });

    testWidgets('Go back pairs nothing and opens nothing', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap);
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(calls.opened, isEmpty);
      expect(_result(t), 'cancelled|');
    });

    testWidgets('a band already paired: workouts only pairs with the confirmation', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap, hasMain: true);
      expect(find.text('Pair it as my band'), findsNothing);
      await t.tap(find.text('Use it for workouts only'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a plain strap and no band: the strap sheet, then pairs without a confirmation', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs', label: 'Polar H10'));
      expect(find.text('This is a heart-rate sensor'), findsOneWidget);
      expect(find.text('Polar H10'), findsOneWidget, reason: 'its own name');
      await t.tap(find.text('Pair Bluetooth heart rate sensor'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(calls.pairs.single.$2, isNull);
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a plain strap, declined: nothing pairs', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs'));
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(_result(t), 'cancelled|');
    });

    testWidgets('a plain strap with a band already paired pairs at once, no sheet', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      expect(find.text('This is a heart-rate strap'), findsNothing);
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a thermometer is not a secondary sensor: no sheet, and no secondary message', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('thermometer'));
      expect(find.text('This is a heart-rate strap'), findsNothing);
      expect(calls.pairs.single.$1, 'thermometer');
      expect(_result(t), 'pairedOther|');
    });

    testWidgets('a connect that finds a band: the identified-itself sheet; confirming re-runs pairing with the confirmation', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5), const PairOutcome.saved()]);
      await _tap(t, calls, _cand('ble_hrs', label: 'Polar H10'), hasMain: true);
      expect(find.textContaining('identified itself as WHOOP 5. Nothing was saved.'), findsOneWidget);
      await t.tap(find.text('Use it for workouts only'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 2);
      expect(calls.pairs[0].$2, isNull);
      expect(calls.pairs[1].$2!.remoteId, 'AA:BB:CC:DD:EE:01');
      expect(calls.pairs[1].$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a connect that finds a band, no main band: “Pair it as my band” opens that flow', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5)]);
      await _tap(t, calls, _cand('ble_hrs'), hasMain: false);
      // The strap sheet first (nothing known yet), then the band sheet after connect.
      await t.tap(find.text('Pair Bluetooth heart rate sensor'));
      await t.pumpAndSettle();
      expect(find.textContaining('identified itself as WHOOP 5'), findsOneWidget);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1);
      expect(calls.opened, ['gen5']);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('a connect that finds a band, then Go back: pairing ran once and nothing was saved', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5)]);
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      await t.ensureVisible(find.text('Go back'));
      await t.pumpAndSettle();
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1);
      expect(_result(t), 'cancelled|');
    });

    // WHY: database/device errors must reach the screen and leave taps retryable.
    // catches: an exception escaping onTap before its caller can show a result.
    testWidgets('a thrown pairing error becomes a visible failure and allows retry', (t) async {
      final calls = _Calls()..pairError = StateError('device rows unavailable');
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      expect(_result(t), contains('Could not pair that device: Bad state: device rows unavailable'));
      expect(calls.flowFor.running, isFalse);
      calls.pairError = null;
      await t.tap(find.text('tap'));
      await t.pumpAndSettle();
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a failure comes back as its sentence', (t) async {
      final calls = _Calls([const PairOutcome.failed('The sensor did not answer.')]);
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      expect(_result(t), 'failed|The sensor did not answer.');
    });

    testWidgets('a ring (a band in its own right) gets the band sheet, and its own screen does the pairing', (t) async {
      final calls = _Calls()..bandFlowResult = BandFlowResult.pairedWearable;
      await _tap(t, calls, _cand('oura', label: 'Oura Ring'));
      expect(find.text('This is a ring'), findsOneWidget);
      // Not a WHOOP, so there is no main-band choice: one button.
      expect(find.text('Pair it as my band'), findsNothing);
      // The comparison table and unverified guidance can put this below the fold.
      await t.ensureVisible(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      // The ring needs its own key screen, so it never pairs from here.
      expect(calls.pairs, isEmpty);
      expect(calls.opened, ['oura']);
      expect(_result(t), 'pairedOther|');
    });
  });

  group('(CR r2) a ring heard as a heart-rate strap', () {
    final ouraAsStrap =
        _cand('ble_hrs', id: 'AA:00:00:00:00:91', label: 'Oura', alsoBand: kOura);

    testWidgets('the tap opens the ring’s own screen, never a plain strap pairing', (t) async {
      final calls = _Calls();
      await _tap(t, calls, ouraAsStrap);
      expect(find.text('This is a ring'), findsOneWidget);
      // The comparison table and unverified guidance can put this below the fold.
      await t.ensureVisible(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(calls.opened, ['oura']);
      expect(_result(t), 'cancelled|');
    });

    testWidgets('a connect that finds the ring does the same', (t) async {
      final calls = _Calls([PairOutcome.band(kOura)]);
      await _tap(t, calls, _cand('ble_hrs', label: 'HRM'), hasMain: true);
      await t.ensureVisible(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      // The comparison table and unverified guidance can put this below the fold.
      await t.ensureVisible(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair Oura Ring'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1, reason: 'only the first connect');
      expect(calls.opened, ['oura']);
      expect(_result(t), 'cancelled|');
    });
  });

  group('(CR r2) a WHOOP heard as a strap is filtered as a WHOOP', () {
    testWidgets('the WHOOP pill shows it, the Straps pill does not', (t) async {
      final group = ValueNotifier<PairFilter?>(null);
      await pumpPair(
          t,
          // The screen that owns the selection rebuilds on it, as the picker
          // does.
          ValueListenableBuilder<PairFilter?>(
            valueListenable: group,
            builder: (_, _, _) => DevicePickerView(
              query: TextEditingController(),
              title: 'Add a device',
              subtitle: '',
              found: [
                _cand('ble_hrs', id: 'AA:00:00:00:00:A1', label: 'Jordan’s WHOOP', alsoBand: kWhoopGen5),
                _cand('ble_hrs', id: 'AA:00:00:00:00:A2', label: 'Polar H10'),
                // This Polar fixture is an armband; HRS alone proves no placement.
                _cand('polar_pmd', id: 'AA:00:00:00:00:A3', label: 'Polar Verity Sense'),
              ],
              kindSelection: group,
            ),
          ),
          size: const Size(412, 2000));
      expect(find.byKey(const ValueKey('pill-whoop')), findsOneWidget);
      group.value = PairFilter.whoop;
      await t.pumpAndSettle();
      expect(find.text('Jordan’s WHOOP'), findsOneWidget);
      expect(find.text('Polar H10'), findsNothing);
      group.value = PairFilter.straps;
      await t.pumpAndSettle();
      expect(find.text('Jordan’s WHOOP'), findsNothing);
      expect(find.text('Polar H10'), findsNothing);
      expect(find.text('Polar Verity Sense'), findsOneWidget);
      group.value = null;
      await t.pumpAndSettle();
      expect(find.text('Polar H10'), findsOneWidget);
      expect(find.text('Jordan’s WHOOP'), findsOneWidget);
    });
  });

  group('(CR r2) after the band flow, the sensor screen tells the truth', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final found = PairOutcome.band(kWhoopGen5);
    const opened = (outcome: AddDeviceOutcome.openedBandFlow, message: null);
    test('the band got paired: no "Nothing was saved"', () {
      expect(afterBandFoundText(l, found, opened, bandPairedNow: true), isNull);
    });
    test('the band flow closed without pairing: nothing was saved, said so', () {
      expect(afterBandFoundText(l, found, opened, bandPairedNow: false),
          contains('Nothing was saved'));
    });
    test('a ring handoff needs an explicit successful pair result', () {
      expect(
          afterBandFoundText(l, PairOutcome.band(kOura), opened,
              bandPairedNow: false),
          contains('Nothing was saved'));
    });
    test('backed out, or failed, as before', () {
      expect(
          afterBandFoundText(
              l, found, (outcome: AddDeviceOutcome.cancelled, message: null),
              bandPairedNow: false),
          contains('Nothing was saved'));
      expect(
          afterBandFoundText(
              l, found, (outcome: AddDeviceOutcome.failed, message: 'x'),
              bandPairedNow: true),
          'x');
    });
  });

  group('browsing goes through the same confirmations', () {
    // A button that runs confirmBrowse and prints the answer.
    Future<bool?> browse(WidgetTester t, _Calls calls, BandEntry e,
        {required bool hasMain, String? tapLabel}) async {
      bool? got;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async =>
                          got = await calls.flow(hasMain: hasMain).confirmBrowse(c, e),
                      child: const Text('go')))),
          size: const Size(412, 2000));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      if (tapLabel != null) {
        await t.tap(find.text(tapLabel));
        await t.pumpAndSettle();
      }
      return got;
    }

    testWidgets('the generic heart-rate sensor with no main band asks first; Go back says no', (t) async {
      final calls = _Calls();
      final got = await browse(t, calls, kBleHrs, hasMain: false, tapLabel: 'Go back');
      expect(got, isFalse);
    });

    testWidgets('... and “Pair” says yes', (t) async {
      final calls = _Calls();
      expect(await browse(t, calls, kBleHrs, hasMain: false, tapLabel: 'Pair Bluetooth heart rate sensor'), isTrue);
    });

    testWidgets('Polar PMD is a workout sensor too: same sheet', (t) async {
      final calls = _Calls();
      await browse(t, calls, kPolarPmd, hasMain: false);
      expect(find.text('This is a heart-rate sensor'), findsOneWidget);
    });

    testWidgets('with a main band, or for a device that is its own entry, no sheet', (t) async {
      final calls = _Calls();
      expect(await browse(t, calls, kBleHrs, hasMain: true), isTrue);
      expect(find.text('This is a heart-rate strap'), findsNothing);
      expect(await browse(t, calls, kColmi, hasMain: false), isTrue);
      expect(find.text('This is a heart-rate strap'), findsNothing);
    });

    testWidgets('a connect that finds a band (category path): band-found sheet, then re-pair with the confirmation', (t) async {
      final calls = _Calls([const PairOutcome.saved()]);
      bool? ok;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        final r = await calls.flow(hasMain: true).afterConnect(
                            c, _cand('ble_hrs'), kBleHrs, PairOutcome.band(kWhoopGen5));
                        ok = r.outcome == AddDeviceOutcome.pairedSecondary;
                      },
                      child: const Text('go')))),
          size: const Size(412, 2000));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.textContaining('identified itself as WHOOP 5. Nothing was saved.'), findsOneWidget);
      await t.tap(find.text('Use it for workouts only'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(ok, isTrue);
    });
  });

  testWidgets('(CR 4500501772) a name-only WHOOP found on connect keeps its unknown model', (t) async {
    // WHY: the connect can only confirm what the name said (gen4 is the
    // name-matched entry); a WHOOP 5 heard by name must not enter the band
    // flow as a WHOOP 4.
    final calls = _Calls();
    final byName = (
      device: BluetoothDevice.fromId('AA:00:00:00:00:44'),
      label: 'WHOOP 4C0FFEE',
      rssi: -60,
      entryId: 'ble_hrs',
      alsoBand: (entry: kWhoopGen4, modelCertain: false),
    );
    await pumpPair(
        t,
        Builder(
            builder: (c) => Scaffold(
                body: TextButton(
                    onPressed: () => calls.flow(hasMain: false).afterConnect(
                        c, byName, kBleHrs,
                        const PairOutcome.band(kWhoopGen4, modelCertain: false)),
                    child: const Text('go')))),
        size: const Size(412, 2000));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.textContaining('WHOOP 4.'), findsNothing, reason: 'no model named');
    await t.tap(find.text('Pair it as my band'));
    await t.pumpAndSettle();
    expect(calls.openedWith, [('AA:00:00:00:00:44', false)]);
  });

  testWidgets('(CR 4500539072) a model GATT confirmed is named, even when the name guessed it', (t) async {
    final calls = _Calls();
    final byName = (
      device: BluetoothDevice.fromId('AA:00:00:00:00:45'),
      label: 'WHOOP 4C0FFEE',
      rssi: -60,
      entryId: 'ble_hrs',
      alsoBand: (entry: kWhoopGen4, modelCertain: false),
    );
    await pumpPair(
        t,
        Builder(
            builder: (c) => Scaffold(
                body: TextButton(
                    onPressed: () => calls.flow(hasMain: false).afterConnect(
                        c, byName, kBleHrs, const PairOutcome.band(kWhoopGen4)),
                    child: const Text('go')))),
        size: const Size(412, 2000));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Pair it as my band'));
    await t.pumpAndSettle();
    expect(calls.openedWith, [('AA:00:00:00:00:45', true)]);
  });

  testWidgets('(CR 4500539075) a ring found on connect pairs under its own entry', (t) async {
    // WHY: kept under ble_hrs, a Colmi would be a workout-only strap with no
    // ring history sync (and fail outright without 0x2A37).
    final calls = _Calls([const PairOutcome.saved()]);
    await pumpPair(
        t,
        Builder(
            builder: (c) => Scaffold(
                body: TextButton(
                    onPressed: () => calls.flow(hasMain: true).afterConnect(
                        c, _cand('ble_hrs', label: 'R02_1A2B'), kBleHrs,
                        const PairOutcome.band(kColmi)),
                    child: const Text('go')))),
        size: const Size(412, 2000));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Pair Colmi ring'));
    await t.tap(find.text('Pair Colmi ring'));
    await t.pumpAndSettle();
    expect(calls.pairs.map((p) => p.$1), ['colmi']);
  });

  testWidgets('(CR 4500539075) a ring heard as a heart-rate sensor pairs under its own entry from the list', (t) async {
    final calls = _Calls();
    await _tap(t, calls, _cand('ble_hrs', label: 'R02_1A2B', alsoBand: kColmi));
    await t.ensureVisible(find.text('Pair Colmi ring'));
    await t.tap(find.text('Pair Colmi ring'));
    await t.pumpAndSettle();
    expect(calls.pairs.map((p) => p.$1), ['colmi']);
    // WHY: a ring is not workout-only; CLAIM(wearable-pair-result).
    // catches: treating the presence of confirmation as a workout sensor.
    expect(_result(t), 'pairedOther|');
  });

  for (final sensor in kPairableSensors.where((s) => s.pick != null)) {
    testWidgets('(CR 4500569334) ${sensor.entry.id} found on connect goes to its own screen, never a plain save', (t) async {
      // WHY: its pairing installs a key (its `pick`). A plain notify pair
      // would save a row sync cannot use.
      final calls = _Calls([const PairOutcome.saved()]);
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () => calls.flow(hasMain: true).afterConnect(
                          c, _cand('ble_hrs'), kBleHrs,
                          PairOutcome.band(sensor.entry)),
                      child: const Text('go')))),
          size: const Size(412, 2000));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      final pair = find.textContaining('Pair ').last;
      await t.ensureVisible(pair);
      await t.tap(pair);
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(calls.opened, [sensor.entry.id]);
    });
  }

  group('the handoff to the main-band flow', () {
    final whoopOnly = _cand('gen5', label: 'WHOOP 5A1B');

    testWidgets('the scan is stopped BEFORE the main-band flow opens', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopOnly);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.events, ['stop', 'open:gen5']);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('where the system pairing sheet cannot open (iOS, no provisioned band) restart guidance replaces it', (t) async {
      final calls = _Calls()..heldBack = 'Restart the app before you pair it.';
      await _tap(t, calls, whoopOnly);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.opened, isEmpty);
      expect(calls.events, ['stop']);
      expect(_result(t), 'bandFlowHeldBack|Restart the app before you pair it.');
    });
  });

  group('a WHOOP-only advertisement', () {
    testWidgets('the band-choice flow runs for a scanned framed entry; a secondary choice pairs under ble_hrs with the confirmation', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('gen5', label: 'WHOOP 5A1B'), hasMain: true);
      expect(find.text('This is a WHOOP band'), findsOneWidget);
      await t.tap(find.text('Use it for workouts only'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });
  });

  group('the choice sheet respects the top safe area', () {
    testWidgets('a tall sheet stops below the status bar', (t) async {
      // 120 physical px at dpr 2 = a 60 px status bar / notch.
      t.view.padding = const FakeViewPadding(top: 120);
      await pumpPair(
        t,
        Builder(
          builder: (c) => TextButton(
            onPressed: () => showPairChoiceSheet(
              c,
              PairChoiceSheet(
                deviceIcon: LucideIcons.watch,
                deviceName: 'A band',
                title: 'Pair this band',
                comparison: const SlotComparison(
                    everyDay: SlotSide(sends: {}, doesNotSend: {}),
                    workoutsOnly: SlotSide(sends: {}, doesNotSend: {})),
                lead: List.filled(40, 'A long instruction line.').join(' '),
                primaryLabel: 'Pair',
                backLabel: 'Back',
              ),
            ),
            child: const Text('open'),
          ),
        ),
        size: const Size(412, 500),
        textScale: 2,
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.byType(PairChoiceSheet)).dy, greaterThanOrEqualTo(60),
          reason: 'the sheet must not slide under the system bar');
    });
  });
}
