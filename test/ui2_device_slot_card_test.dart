// The device slot card and how a paired device reads on the sources list
// and its detail page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/ui2/pairing/device_slot_card.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart' show DeviceUseSwitch;

import 'support/pair_ui_support.dart';

HealthSource _src(String family, {String name = 'Polar H10', bool isBand = false}) =>
    HealthSource(
      name: name,
      kind: 'Bluetooth heart rate sensor',
      tier: SourceTier.beatToBeat,
      icon: LucideIcons.heartPulse,
      isBand: isBand,
      deviceId: '$family-0a1b2c3d',
      family: family,
    );

Widget _card(BandEntry e, DeviceSlot slot) => Scaffold(
    body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: DeviceSlotCard(entry: e, slot: slot)));

bool _icon(WidgetTester t, Finder within, IconData icon) => t
    .widgetList<Icon>(find.descendant(of: within, matching: find.byType(Icon)))
    .any((i) => i.icon == icon);

Finder _mark(String side, DeviceCapability c) =>
    find.byKey(ValueKey('slot-$side-${c.name}'));

double _opacityOf(WidgetTester t, String side) => t
    .widget<Opacity>(find.descendant(
            of: find.byKey(ValueKey('slot-cell-$side')).first,
            matching: find.byType(Opacity))
        .first)
    .opacity;

void main() {
  test('a ring reads as a band does, not as a sensor waiting for a workout', () {
    expect(sourceState(_src('oura', name: 'Oura Ring')), 'Not connected');
    expect(sourceState(_src('ble_hrs')), 'Waiting for a workout');
  });

  group('which sources get the card', () {
    test('a strap, a Polar sensor and a ring, not a band, a scale or a Coros watch', () {
      expect(slotDeviceOf(_src('ble_hrs'))?.entry.id, 'ble_hrs');
      expect(slotDeviceOf(_src('ble_hrs'))?.slot, DeviceSlot.workoutsOnly);
      expect(slotDeviceOf(_src('polar_pmd'))?.entry.id, 'polar_pmd');
      expect(slotDeviceOf(_src('polar_pmd'))?.slot, DeviceSlot.workoutsOnly);
      // A columned wearable fills every day.
      expect(slotDeviceOf(_src('oura'))?.slot, DeviceSlot.everyDay);
      expect(slotDeviceOf(_src('colmi'))?.slot, DeviceSlot.everyDay);
      expect(slotDeviceOf(_src('thermometer')), isNull);
      expect(slotDeviceOf(_src('miscale2')), isNull);
      expect(slotDeviceOf(_src('coros')), isNull);
      // The primary band is never a slot device (it is every day by itself).
      expect(slotDeviceOf(_src('gen5', isBand: true)), isNull);
      expect(sourceSlot(_src('gen5', isBand: true)), DeviceSlot.everyDay);
      // The phone has no device row.
      const phone = HealthSource(
          name: 'This phone',
          kind: 'Motion coprocessor',
          tier: SourceTier.phone,
          icon: Icons.phone_android);
      expect(slotDeviceOf(phone), isNull);
      expect(sourceSlot(phone), isNull);
    });
  });

  group('DeviceSlotCard', () {
    testWidgets('a strap: Workouts only chip, the Every day column faded, the other not', (t) async {
      await pumpPair(t, _card(kBleHrs, DeviceSlot.workoutsOnly), size: const Size(412, 1100));
      expect(find.text('What it sends'), findsOneWidget);
      final pill = find.byKey(const ValueKey('device-slot-pill'));
      expect(find.descendant(of: pill, matching: find.text('Workouts only')), findsOneWidget);
      expect(find.descendant(of: pill, matching: find.text('Every day')), findsNothing);
      expect(_opacityOf(t, 'everyDay'), 0.28);
      expect(_opacityOf(t, 'workoutsOnly'), 1);
    });

    testWidgets('a strap: heart rate and beat timing are ✓ under Workouts only, sleep ✗ in both', (t) async {
      await pumpPair(t, _card(kBleHrs, DeviceSlot.workoutsOnly), size: const Size(412, 1100));
      final cmp = slotComparisonFor(kBleHrs);
      expect(cmp.workoutsOnly.sends, isNotEmpty);
      for (final k in cmp.workoutsOnly.sends.keys) {
        expect(_icon(t, _mark('workoutsOnly', k), LucideIcons.check), isTrue, reason: k.name);
      }
      expect(_icon(t, _mark('workoutsOnly', DeviceCapability.workoutHeartRate), LucideIcons.check), isTrue);
      expect(_icon(t, _mark('workoutsOnly', DeviceCapability.workoutBeatToBeat), LucideIcons.check), isTrue);
      for (final side in ['everyDay', 'workoutsOnly']) {
        expect(_icon(t, _mark(side, DeviceCapability.sleep), LucideIcons.x), isTrue, reason: side);
        expect(_icon(t, _mark(side, DeviceCapability.sleep), LucideIcons.check), isFalse, reason: side);
      }
      expect(find.byIcon(LucideIcons.minus), findsNothing);
    });

    testWidgets('a strap’s note: it names the switch and stands alone; no Experimental word', (t) async {
      // WHY: a workout sensor records nothing until the switch is on (default off).
      await pumpPair(t, _card(kBleHrs, DeviceSlot.workoutsOnly), size: const Size(412, 1100));
      expect(find.text('Turn on “Use during workouts” to record heart rate while you work out.'), findsOneWidget);
      expect(find.textContaining('Experimental'), findsNothing);
      expect(find.textContaining('Tier'), findsNothing);
    });

    testWidgets('a strap’s beat timing is conditional on the strap', (t) async {
      await pumpPair(t, _card(kBleHrs, DeviceSlot.workoutsOnly), size: const Size(412, 1100));
      expect(find.text('Workouts only: If this device sends it, not confirmed'), findsOneWidget);
    });

    testWidgets('a ring: Every day chip, Workouts only faded, the orange experimental note', (t) async {
      await pumpPair(t, _card(kOura, DeviceSlot.everyDay), size: const Size(412, 1400));
      final pill = find.byKey(const ValueKey('device-slot-pill'));
      expect(find.descendant(of: pill, matching: find.text('Every day')), findsOneWidget);
      expect(_opacityOf(t, 'workoutsOnly'), 0.28);
      expect(_opacityOf(t, 'everyDay'), 1);
      const note = 'Fills days without your WHOOP. Experimental, so switch it on below.';
      expect(find.text(note), findsOneWidget);
      expect(find.text('Turn on “Use during workouts” to record heart rate while you work out.'), findsNothing);
      // Orange, not the grey of the strap's note.
      final grey = t.widget<Text>(find.text(note)).style!.color;
      await pumpPair(t, _card(kBleHrs, DeviceSlot.workoutsOnly), size: const Size(412, 1100));
      final strapNote = t.widget<Text>(find.text('Turn on “Use during workouts” to record heart rate while you work out.')).style!.color;
      expect(grey, isNot(strapNote));
    });

    testWidgets('a ring sends in the Every day column, nothing in Workouts only', (t) async {
      await pumpPair(t, _card(kOura, DeviceSlot.everyDay), size: const Size(412, 1400));
      expect(_icon(t, _mark('everyDay', DeviceCapability.sleep), LucideIcons.check), isTrue);
      expect(_icon(t, _mark('workoutsOnly', DeviceCapability.sleep), LucideIcons.x), isTrue);
      expect(_icon(t, _mark('workoutsOnly', DeviceCapability.workoutHeartRate), LucideIcons.x), isTrue);
    });

    for (final (e, s) in [
      (kOura, DeviceSlot.everyDay),
      (kPolarPmd, DeviceSlot.workoutsOnly),
    ]) {
      testWidgets('German at 2x text does not overflow (${e.id})', (t) async {
        await pumpPair(t, _card(e, s),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 2000));
        expect(t.takeException(), isNull);
        expect(find.text('Was es sendet'), findsOneWidget);
      });
    }
  });

  group('on the sources list', () {
    testWidgets('a strap’s row shows its Workouts only chip, no Tier pill, no Experimental word', (t) async {
      await pumpPair(t, Scaffold(body: SourceRow(_src('ble_hrs'))), size: const Size(412, 600));
      expect(find.byKey(const ValueKey('source-slot-workoutsOnly')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-slot-everyDay')), findsNothing);
      expect(find.textContaining('Tier'), findsNothing);
      expect(find.text('Experimental'), findsNothing);
      expect(find.text('Waiting for a workout'), findsOneWidget);
    });

    testWidgets('a ring’s row shows an Every day chip and no Tier pill', (t) async {
      await pumpPair(
          t,
          Scaffold(
              body: SourceRow(HealthSource(
                  name: 'Oura Ring',
                  kind: 'Ring',
                  tier: SourceTier.wristOptical,
                  icon: Icons.circle,
                  deviceId: 'oura-1',
                  family: 'oura'))),
          size: const Size(412, 600));
      expect(find.byKey(const ValueKey('source-slot-everyDay')), findsOneWidget);
      expect(find.textContaining('Tier'), findsNothing);
      expect(find.text('Experimental'), findsNothing);
    });

    testWidgets('the band’s row says Every day', (t) async {
      await pumpPair(
          t,
          const Scaffold(
              body: SourceRow(HealthSource(
                  name: 'WHOOP 5',
                  kind: 'WHOOP',
                  tier: SourceTier.wristOptical,
                  icon: Icons.watch,
                  isBand: true))),
          size: const Size(412, 600));
      expect(find.byKey(const ValueKey('source-slot-everyDay')), findsOneWidget);
    });

    testWidgets('a device with no column (Coros) keeps its Tier pill and has no slot chip', (t) async {
      await pumpPair(
          t,
          const Scaffold(
              body: SourceRow(HealthSource(
                  name: 'Coros',
                  kind: 'Watch',
                  tier: SourceTier.wristOptical,
                  icon: Icons.watch,
                  deviceId: 'coros-1',
                  family: 'coros'))),
          size: const Size(412, 600));
      expect(find.textContaining('Tier'), findsOneWidget);
      expect(find.byKey(const ValueKey('source-slot-everyDay')), findsNothing);
      expect(find.byKey(const ValueKey('source-slot-workoutsOnly')), findsNothing);
    });
  });

  group('on its detail page', () {
    testWidgets('the card replaces the tier row and the Support row, and the use switch follows it', (t) async {
      await pumpPair(t, DeviceDetailView(_src('ble_hrs')), size: const Size(412, 2000));
      expect(find.byKey(const ValueKey('device-slot-card')), findsOneWidget);
      expect(find.textContaining('Tier'), findsNothing);
      // No Support: Experimental row either.
      expect(find.text('Support'), findsNothing);
      expect(find.text('Experimental'), findsNothing);
      // The switch widget sits right after the card in the page (it draws
      // nothing here: no device is registered with WearableDisplay).
      final items = t
          .widgetList(find.descendant(
              of: find.byType(DeviceDetailView), matching: find.byWidgetPredicate((w) => w is DeviceSlotCard || w is DeviceUseSwitch)))
          .toList();
      expect(items.map((w) => w.runtimeType), [DeviceSlotCard, DeviceUseSwitch]);
    });

    testWidgets('a ring’s page gets the card and the switch too', (t) async {
      await pumpPair(t, DeviceDetailView(_src('oura', name: 'Oura Ring')), size: const Size(412, 2400));
      expect(find.byKey(const ValueKey('device-slot-card')), findsOneWidget);
      expect(find.byType(DeviceUseSwitch), findsOneWidget);
      expect(find.textContaining('Tier'), findsNothing);
    });

    testWidgets('a band’s page does not get the card', (t) async {
      await pumpPair(
          t,
          DeviceDetailView(const HealthSource(
              name: 'WHOOP 5',
              kind: 'WHOOP',
              tier: SourceTier.wristOptical,
              icon: Icons.watch,
              isBand: true)),
          size: const Size(412, 2000));
      expect(find.byKey(const ValueKey('device-slot-card')), findsNothing);
      expect(find.byType(DeviceUseSwitch), findsNothing);
    });
  });
}
