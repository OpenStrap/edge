// Settings > My sources > "Pair a device": the one "Your band" card (no band,
// a band paired), and what the "Add a device" screen adds (pills, slot chips,
// the paired notice).
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart' show BandCandidate;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/pairing/pair_text.dart' show PairFilter;
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/pair_ui_support.dart';

HealthSource _band([String name = 'Tyler’s WHOOP 5.0 / MG']) => HealthSource(
      name: name,
      kind: 'WHOOP',
      tier: SourceTier.wristOptical,
      icon: Icons.watch,
      connected: true,
      isBand: true,
    );

HealthSource _strap() => const HealthSource(
      name: 'Polar H10',
      kind: 'Bluetooth heart rate sensor',
      tier: SourceTier.beatToBeat,
      icon: Icons.favorite,
      isBand: false,
      deviceId: 'ble_hrs-0a1b2c3d',
      family: 'ble_hrs',
    );

BandCandidate _cand(String entryId,
        {String id = 'AA:BB:CC:DD:EE:01', String? label, BandEntry? alsoBand}) =>
    (
      device: BluetoothDevice.fromId(id),
      label: label,
      rssi: -60,
      entryId: entryId,
      alsoBand: alsoBand == null ? null : (entry: alsoBand, modelCertain: true),
    );

void main() {
  group('My sources: Pair a device', () {
    Widget view(List<HealthSource> sources,
            {VoidCallback? onPair, VoidCallback? onAdd, VoidCallback? onUnpair}) =>
        MyDevicesView(
            sources: sources,
            onPair: onPair,
            onAddSensor: onAdd,
            onUnpair: onUnpair);

    Finder inCard(String key, Finder f) =>
        find.descendant(of: find.byKey(ValueKey(key)), matching: f);

    testWidgets('no band: ONE Your band card says so, says WHOOP only, and Pair your band opens the band flow', (t) async {
      var pair = 0;
      await pumpPair(t, view(const [], onPair: () => pair++, onAdd: () {}),
          size: const Size(412, 1400));
      expect(find.text('Pair a device'), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-band-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('band-paired-card')), findsNothing);
      expect(inCard('pair-band-card', find.text('Your band')), findsOneWidget);
      expect(inCard('pair-band-card', find.text('Every day')), findsOneWidget);
      expect(inCard('pair-band-card', find.byKey(const ValueKey('your-band-status'))),
          findsOneWidget);
      expect(inCard('pair-band-card', find.text('No band is paired')), findsOneWidget);
      expect(
          inCard('pair-band-card',
              find.text('WHOOP 4.0 or WHOOP 5.0/MG only. Sleep, recovery and strain, around the clock.')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsOneWidget);
      final button = inCard('pair-band-card', find.byType(BigButton));
      expect(button, findsOneWidget);
      expect(find.descendant(of: button, matching: find.text('Pair your band')), findsOneWidget);
      await t.tap(button);
      expect(pair, 1);
      expect(find.text('Unpair band'), findsNothing);
    });

    testWidgets('no band: no separate “No band is paired” status card above the Your band card', (t) async {
      // WHY: the owner's rule is ONE card; a second one said the same thing twice.
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.text('No band is paired'), findsOneWidget);
      expect(find.text('Nothing is measuring yet'), findsNothing);
      expect(find.byType(StatusCard), findsNothing);
      expect(find.text('Pair a band'), findsNothing);
      // One button for the band; the Add a device row is not a BigButton.
      expect(find.byType(BigButton), findsOneWidget);
    });

    testWidgets('no band: the same card says what that costs, once', (t) async {
      // WHY: one card, but it must still say that every metric abstains; the
      // WHOOP-only line alone never told a person their data was empty.
      const phone = HealthSource(
        name: 'This phone',
        kind: 'Motion coprocessor',
        tier: SourceTier.phone,
        icon: Icons.smartphone,
        connected: false,
      );
      await pumpPair(t, view(const [phone], onPair: () {}, onAdd: () {}),
          size: const Size(412, 1400));
      expect(
          inCard('pair-band-card', find.byKey(const ValueKey('no-band-consequence'))),
          findsOneWidget);
      expect(find.textContaining('every metric in the app will abstain'), findsOneWidget);
      expect(find.textContaining('The phone counts steps and nothing else'), findsNothing);
    });

    testWidgets('no band, phone steps arriving: says only the phone counts steps', (t) async {
      const phone = HealthSource(
        name: 'This phone',
        kind: 'Motion coprocessor',
        tier: SourceTier.phone,
        icon: Icons.smartphone,
        connected: true,
      );
      await pumpPair(t, view(const [phone], onPair: () {}, onAdd: () {}),
          size: const Size(412, 1400));
      expect(find.textContaining('The phone counts steps and nothing else'), findsOneWidget);
      expect(find.textContaining('every metric in the app will abstain'), findsNothing);
    });

    testWidgets('no band, a connected ring: does not say every metric abstains', (t) async {
      // WHY: an active ring fills the everyday columns; telling the user that
      // heart rate, sleep and recovery abstain would contradict their own data.
      const ring = HealthSource(
        name: 'Oura Ring',
        kind: 'Ring',
        tier: SourceTier.wristOptical,
        icon: Icons.circle,
        connected: true,
        deviceId: 'oura-1',
        family: 'oura',
      );
      await pumpPair(t, view(const [ring], onPair: () {}, onAdd: () {}),
          size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('no-band-consequence')), findsNothing);
      expect(find.textContaining('every metric in the app will abstain'), findsNothing);
      expect(find.textContaining('The phone counts steps and nothing else'), findsNothing);
    });

    testWidgets('no band, a connected chest strap: is not mistaken for phone steps', (t) async {
      // WHY: phoneCounting used to be true for ANY connected non-band source.
      const strap = HealthSource(
        name: 'Chest strap',
        kind: 'Heart-rate strap',
        tier: SourceTier.beatToBeat,
        icon: Icons.favorite,
        connected: true,
        deviceId: 'hrs-1',
        family: 'ble_hrs',
      );
      await pumpPair(t, view(const [strap], onPair: () {}, onAdd: () {}),
          size: const Size(412, 1400));
      expect(find.textContaining('The phone counts steps and nothing else'), findsNothing);
      expect(find.textContaining('every metric in the app will abstain'), findsOneWidget);
    });

    testWidgets('a paired band: no consequence line', (t) async {
      await pumpPair(t, view([_band()], onUnpair: () {}), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('no-band-consequence')), findsNothing);
    });

    testWidgets('“Add a device” is its own row, below the band card', (t) async {
      var add = 0;
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () => add++), size: const Size(412, 1400));
      expect(find.descendant(of: find.byKey(const ValueKey('pair-band-card')), matching: find.text('Add a device')),
          findsNothing);
      expect(find.text('Rings, watches and heart-rate straps'), findsOneWidget);
      expect(t.getTopLeft(find.text('Add a device')).dy,
          greaterThan(t.getBottomLeft(find.byKey(const ValueKey('pair-band-card'))).dy));
      await t.tap(find.text('Add a device'));
      expect(add, 1);
    });

    testWidgets('the WHOOP-only line is in the card with no band; a paired band has no such line', (t) async {
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsOneWidget);
      await pumpPair(t, view([_band()], onUnpair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsNothing);
    });

    testWidgets('the old “Add a sensor” row is gone', (t) async {
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.text('Add a sensor'), findsNothing);
    });

    testWidgets('a paired strap is not a band: still the Your band card, no band', (t) async {
      await pumpPair(t, view([_strap()], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('pair-band-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('band-paired-card')), findsNothing);
    });

    testWidgets('a band paired: the same card names it, shows its state, offers Unpair band; Add a device stays', (t) async {
      var unpair = 0, add = 0;
      await pumpPair(t, view([_band()], onPair: () {}, onAdd: () => add++, onUnpair: () => unpair++),
          size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('pair-band-card')), findsNothing);
      final card = find.byKey(const ValueKey('band-paired-card'));
      expect(card, findsOneWidget);
      expect(inCard('band-paired-card', find.text('Your band')), findsOneWidget);
      expect(inCard('band-paired-card', find.text('Every day')), findsOneWidget);
      expect(
          t.widget<Text>(inCard('band-paired-card', find.byKey(const ValueKey('your-band-status')))).data,
          'Tyler’s WHOOP 5.0 / MG');
      expect(inCard('band-paired-card', find.text('Connected')), findsOneWidget);
      // None of the old copy.
      expect(find.text('Paired'), findsNothing);
      expect(find.textContaining('You already have a band paired'), findsNothing);
      expect(find.text('No band is paired'), findsNothing);
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsNothing);
      expect(find.text('Pair your band'), findsNothing);
      await t.tap(inCard('band-paired-card', find.text('Unpair band')));
      expect(unpair, 1);
      await t.tap(find.text('Add a device'));
      expect(add, 1);
    });

    testWidgets('Unpair band is tinted red, soft, not a filled button', (t) async {
      await pumpPair(t, view([_band()], onUnpair: () {}), size: const Size(412, 1400));
      final button = t.widget<BigButton>(find.byType(BigButton));
      expect(button.color, C.red);
      expect(button.soft, isTrue);
      expect(find.text('Unpair band'), findsOneWidget);
    });

    testWidgets('Pair your band is the filled one', (t) async {
      await pumpPair(t, view(const [], onPair: () {}), size: const Size(412, 1400));
      expect(t.widget<BigButton>(find.byType(BigButton)).soft, isFalse);
    });

    testWidgets('no callbacks, no band: no Pair a device section at all', (t) async {
      await pumpPair(t, const MyDevicesView(), size: const Size(412, 1400));
      expect(find.text('Pair a device'), findsNothing);
      expect(find.byKey(const ValueKey('pair-band-card')), findsNothing);
    });

    testWidgets('the forget flow asks first, and Keep it paired changes nothing', (t) async {
      final app = AppState();
      addTearDown(app.dispose);
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () => debugConfirmForgetBand(c, app, 'Tyler’s WHOOP'),
                      child: const Text('go')))),
          size: const Size(412, 900));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Forget Tyler’s WHOOP?'), findsOneWidget);
      await t.tap(find.text('Keep it paired'));
      await t.pumpAndSettle();
      expect(find.text('Forget Tyler’s WHOOP?'), findsNothing);
    });

    testWidgets('German at 2x text does not overflow, in either state', (t) async {
      for (final (sources, card) in [
        (const <HealthSource>[], 'pair-band-card'),
        ([_band()], 'band-paired-card'),
      ]) {
        await pumpPair(t, view(sources, onPair: () {}, onAdd: () {}, onUnpair: () {}),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 1800));
        final ex = t.takeException();
        expect(ex, isNull, reason: ex is FlutterError ? ex.toStringDeep() : '$ex');
        expect(find.byKey(ValueKey(card)), findsOneWidget);
      }
    });
  });

  group('Add a device (the unified scan screen)', () {
    DevicePickerView view({
      List<BandCandidate> found = const [],
      List<({BandEntry entry, String blurb, IconData icon})> categories = const [],
      ValueNotifier<PairFilter?>? kindSelection,
      String? notice,
      ValueChanged<BandCandidate>? onPick,
    }) =>
        DevicePickerView(
          query: TextEditingController(),
          title: 'Add a device',
          subtitle: 'Scan once.',
          found: found,
          categories: categories,
          kindSelection: kindSelection ?? ValueNotifier<PairFilter?>(null),
          notice: notice,
          onPickNearby: onPick,
        );

    testWidgets('a WHOOP heard as a strap gets the Every day chip, read off the band; a plain strap Workouts only', (t) async {
      await pumpPair(
          t,
          view(found: [
            _cand('ble_hrs', label: 'Jordan’s WHOOP', alsoBand: kWhoopGen5, id: 'AA:01'),
            _cand('ble_hrs', label: 'Polar H10', id: 'AA:02'),
          ]),
          size: const Size(412, 1400));
      expect(find.text('This is a band'), findsNothing);
      // Both candidates are ble_hrs rows; the chip under each is its own.
      final chips = find.byKey(const ValueKey('row-slot-ble_hrs'));
      expect(find.byKey(ValueKey('row-slot-${kWhoopGen5.id}')), findsOneWidget);
      expect(find.descendant(of: find.byKey(ValueKey('row-slot-${kWhoopGen5.id}')), matching: find.text('Every day')),
          findsOneWidget);
      expect(chips, findsOneWidget);
      expect(find.descendant(of: chips, matching: find.text('Workouts only')), findsOneWidget);
    });

    testWidgets('a ring that is nearby gets the Every day chip', (t) async {
      await pumpPair(t, view(found: [_cand('oura', label: 'Oura Ring')]), size: const Size(412, 1400));
      expect(find.descendant(of: find.byKey(const ValueKey('row-slot-oura')), matching: find.text('Every day')),
          findsOneWidget);
      expect(find.text('This is a band'), findsNothing);
    });

    testWidgets('a device that fits neither column (Coros) gets no chip', (t) async {
      await pumpPair(t, view(found: [_cand('coros', label: 'Coros')]), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('row-slot-coros')), findsNothing);
    });

    testWidgets('Browse rows carry the chip too', (t) async {
      await pumpPair(
          t,
          view(categories: [
            (entry: kOura, blurb: 'ring blurb', icon: Icons.circle),
            (entry: kBleHrs, blurb: 'strap blurb', icon: Icons.favorite),
          ]),
          size: const Size(412, 1400));
      expect(find.descendant(of: find.byKey(const ValueKey('row-slot-oura')), matching: find.text('Every day')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('row-slot-ble_hrs')), matching: find.text('Workouts only')),
          findsOneWidget);
    });

    testWidgets('pills cover the found devices and the browse list; Rings narrows both', (t) async {
      final kind = ValueNotifier<PairFilter?>(null);
      Widget harness() => ValueListenableBuilder<PairFilter?>(
          valueListenable: kind,
          builder: (_, _, _) => view(
              kindSelection: kind,
              found: [
                _cand('oura', label: 'Oura Ring', id: 'AA:01'),
                _cand('ble_hrs', label: 'Polar H10', id: 'AA:02'),
                _cand('polar_pmd', label: 'Polar Verity Sense', id: 'AA:03'),
              ],
              categories: [
                (entry: kOura, blurb: 'ring blurb', icon: Icons.circle),
                (entry: kBleHrs, blurb: 'strap blurb', icon: Icons.favorite),
                (entry: kPolarPmd, blurb: 'armband blurb', icon: Icons.favorite),
              ]));
      await pumpPair(t, harness(), size: const Size(412, 1400));
      expect(find.text('Rings'), findsOneWidget);
      expect(find.text('Chest straps & armbands'), findsOneWidget);
      await t.tap(find.text('Rings'));
      await t.pumpAndSettle();
      expect(kind.value, PairFilter.rings);
      expect(find.text('Polar H10'), findsNothing);
      expect(find.text('Polar Verity Sense'), findsNothing);
      expect(find.text('armband blurb'), findsNothing);
      expect(find.text('Oura Ring'), findsWidgets);
      expect(find.text('strap blurb'), findsNothing);
      expect(find.text('ring blurb'), findsOneWidget);
    });

    testWidgets('(CR r1) a kind the search emptied out filters nothing', (t) async {
      // WHY: with one kind left the pills hide, "All" with them; a stale
      // selection then hid every row with no control to clear it.
      final kind = ValueNotifier<PairFilter?>(PairFilter.rings);
      await pumpPair(
          t,
          view(kindSelection: kind, found: [
            _cand('ble_hrs', label: 'Polar H10', id: 'AA:02'),
          ]),
          size: const Size(412, 1400));
      expect(find.text('All'), findsNothing);
      expect(find.text('Polar H10'), findsWidgets);
    });

    testWidgets('no pills when onKind is not supplied (the old screen is unchanged)', (t) async {
      await pumpPair(
          t,
          DevicePickerView(
              query: TextEditingController(),
              title: 't',
              subtitle: 's',
              found: [_cand('oura', label: 'Oura Ring'), _cand('ble_hrs', label: 'Polar H10', id: 'AA:02')]),
          size: const Size(412, 1400));
      expect(find.text('All'), findsNothing);
    });

    testWidgets('after a workouts-only device pairs: “Paired for workouts only.”', (t) async {
      await pumpPair(t, view(notice: 'Paired for workouts only.'), size: const Size(412, 1400));
      expect(find.text('Paired for workouts only.'), findsOneWidget);
    });

    testWidgets('tapping a nearby row hands the candidate over', (t) async {
      final got = <String>[];
      await pumpPair(t, view(found: [_cand('ble_hrs', label: 'Polar H10')], onPick: (c) => got.add(c.entryId)),
          size: const Size(412, 1400));
      await t.tap(find.text('Polar H10'));
      expect(got, ['ble_hrs']);
    });
  });
}
