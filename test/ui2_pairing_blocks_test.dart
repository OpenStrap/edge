// The two swappable pairing building blocks: the capability matrix and
// the category filter pills, plus the registry field the pills read.
// Rendered, not read: both are layout.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/ui2/pairing/category_filter_pills.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show S;
import 'package:openstrap_edge/ui2/pairing/pair_text.dart';
import 'package:openstrap_edge/ui2/pairing/slot_comparison_view.dart';

import 'support/pair_ui_support.dart';

Finder _mark(String side, DeviceCapability c) =>
    find.byKey(ValueKey('slot-$side-${c.name}'));

bool _hasIcon(WidgetTester t, Finder mark, IconData icon) => t
    .widgetList<Icon>(find.descendant(of: mark, matching: find.byType(Icon)))
    .any((i) => i.icon == icon);

bool _sel(SemanticsNode n) => n.getSemanticsData().flagsCollection.isSelected == Tristate.isTrue;

void main() {
  group('BandEntry.kind', () {
    test('only generic HRS leaves physical placement unknown', () {
      // WHY: HRS can be a watch, armband or strap; named devices retain their kinds.
      final other = [
        for (final e in kBandRegistry)
          if (e.kind == DeviceKind.other) e.id
      ];
      expect(other, ['ble_hrs']);
    });

    test('the kinds the owner named', () {
      expect(kWhoopGen4.kind, DeviceKind.strap);
      expect(kWhoopGen5.kind, DeviceKind.strap);
      expect(kOura.kind, DeviceKind.ring);
      expect(kColmi.kind, DeviceKind.ring);
      expect(kUltrahuman.kind, DeviceKind.ring);
      expect(kGarmin.kind, DeviceKind.watch);
      expect(kMiBand234.kind, DeviceKind.band);
      expect(kBleHrs.kind, DeviceKind.other);
      expect(kThermometer.kind, DeviceKind.thermometer);
      expect(kMiScale2.kind, DeviceKind.scale);
    });
  });

  group('CategoryFilterPills', () {
    Widget pills(List<DeviceKind> kinds,
            {PairFilter? selected, ValueNotifier<PairFilter?>? selection}) =>
        Scaffold(
          body: CategoryFilterPills(
              kinds: kinds,
              selection: selection ?? ValueNotifier<PairFilter?>(selected)),
        );

    testWidgets('all five filters keep reading order when the strap label wraps',
        (t) async {
      await pumpPair(
          t,
          pills([
            DeviceKind.chestStrap,
            DeviceKind.watch,
            DeviceKind.ring,
            DeviceKind.strap,
          ]),
          size: const Size(600, 800));
      // The fuller strap label can wrap to the next line. Pin reading order
      // in both dimensions, so wrapping does not masquerade as reordering.
      final positions = [
        for (final k in ['All', 'WHOOP', 'Rings', 'Watches', 'Chest straps & armbands'])
          t.getTopLeft(find.text(k)),
      ];
      final readingOrder = [...positions]..sort((a, b) {
        final row = a.dy.compareTo(b.dy);
        return row == 0 ? a.dx.compareTo(b.dx) : row;
      });
      expect(positions, readingOrder);
      expect(positions.toSet().length, 5);
    });

    testWidgets('only the groups that have entries get a pill', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.strap, DeviceKind.ring]));
      expect(find.text('All'), findsOneWidget);
      expect(find.text('WHOOP'), findsOneWidget);
      expect(find.text('Rings'), findsOneWidget);
      expect(find.text('Watches'), findsNothing);
      expect(find.text('Chest straps & armbands'), findsNothing);
    });

    testWidgets('a Mi Band (DeviceKind.band) is under Watches, not a pill of its own',
        (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.band]));
      expect(find.text('Watches'), findsOneWidget);
      expect(find.text('Bands'), findsNothing);
      expect(pairFilterOf(DeviceKind.band), PairFilter.watches);
      expect(pairFilterOf(DeviceKind.watch), PairFilter.watches);
    });

    testWidgets('a scale shows under All only: it earns no pill', (t) async {
      await pumpPair(t, pills([DeviceKind.scale, DeviceKind.thermometer]));
      expect(find.text('All'), findsNothing);
      expect(pairFilterOf(DeviceKind.scale), isNull);
      expect(pairFilterOf(DeviceKind.thermometer), isNull);
      // With a ring beside it the scale still adds no pill.
      await pumpPair(t, pills([DeviceKind.scale, DeviceKind.ring, DeviceKind.watch]));
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Rings'), findsOneWidget);
      expect(find.text('Watches'), findsOneWidget);
      expect(find.byType(CategoryFilterPills), findsOneWidget);
    });

    test('every kind maps to its group', () {
      expect(pairFilterOf(DeviceKind.strap), PairFilter.whoop);
      expect(pairFilterOf(DeviceKind.ring), PairFilter.rings);
      expect(pairFilterOf(DeviceKind.chestStrap), PairFilter.straps);
      expect(pairFilterOf(DeviceKind.armband), PairFilter.straps);
      expect(pairFilterOf(DeviceKind.other), isNull);
    });

    testWidgets('a list with a single group shows no pills at all', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.ring]));
      expect(find.text('All'), findsNothing);
      expect(find.text('Rings'), findsNothing);
    });

    testWidgets('tapping a pill reports its group; All reports null', (t) async {
      final got = <PairFilter?>[];
      final sel = ValueNotifier<PairFilter?>(PairFilter.rings);
      sel.addListener(() => got.add(sel.value));
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.watch], selection: sel));
      await t.tap(find.text('Watches'));
      await t.tap(find.text('All'));
      expect(got, [PairFilter.watches, null]);
    });

    testWidgets('the selected pill is marked selected for screen readers, the rest are not',
        (t) async {
      await pumpPair(
          t, pills([DeviceKind.ring, DeviceKind.watch], selected: PairFilter.rings));
      final s = t.getSemantics(find.byKey(const ValueKey('pill-rings')));
      expect(_sel(s), isTrue);
      final o = t.getSemantics(find.byKey(const ValueKey('pill-watches')));
      expect(_sel(o), isFalse);
    });

    testWidgets('nothing selected means All is the selected pill', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.watch]));
      expect(_sel(t.getSemantics(find.byKey(const ValueKey('pill-all')))), isTrue);
    });

    testWidgets('labels follow the locale', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.watch]),
          locale: const Locale('de'));
      expect(find.text('Alle'), findsOneWidget);
      expect(find.text('Ringe'), findsOneWidget);
      expect(find.text('Uhren'), findsOneWidget);
    });

    testWidgets('five groups wrap instead of overflowing at 2x text on a narrow phone',
        (t) async {
      await pumpPair(
          t,
          pills([
            DeviceKind.strap,
            DeviceKind.ring,
            DeviceKind.watch,
            DeviceKind.chestStrap
          ]),
          textScale: 2,
          size: const Size(320, 700));
      expect(t.takeException(), isNull);
    });

    test('filterByGroup keeps only that group, null keeps all', () {
      final all = [kWhoopGen5, kOura, kColmi, kMiBand234, kBleHrs, kPolarPmd, kMiScale2];
      expect(filterByGroup(all, null), all);
      expect(filterByGroup(all, PairFilter.rings), [kOura, kColmi]);
      expect(filterByGroup(all, PairFilter.whoop), [kWhoopGen5]);
      expect(filterByGroup(all, PairFilter.watches), [kMiBand234]);
      expect(filterByGroup(all, PairFilter.straps), [kPolarPmd]);
    });
  });

  group('slot rows (pure)', () {
    final whoop = slotComparisonFor(kWhoopGen5);
    final strap = slotComparisonFor(kBleHrs);

    test('every comparison lists the whole table, in order, and never blood oxygen', () {
      for (final c in [whoop, strap, slotComparisonFor(kOura), slotComparisonFor(kCoros)]) {
        expect([for (final r in slotRowsFor(c)) r.capability], [
          DeviceCapability.sleep,
          DeviceCapability.recovery,
          DeviceCapability.strain,
          DeviceCapability.heartRate,
          DeviceCapability.hrv,
          DeviceCapability.respiration,
          DeviceCapability.skinTemperature,
          DeviceCapability.steps,
          DeviceCapability.workoutHeartRate,
          DeviceCapability.workoutBeatToBeat,
        ]);
      }
    });

    test('a WHOOP sends every day and, read as a strap, during workouts', () {
      final rows = {for (final r in slotRowsFor(whoop)) r.capability: r};
      expect(rows[DeviceCapability.sleep]!.everyDay, isNotNull);
      expect(rows[DeviceCapability.sleep]!.workouts, isNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.everyDay, isNotNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.workouts, isNotNull);
    });

    test('skin temperature keeps its condition', () {
      final r = slotRowsFor(whoop)
          .firstWhere((r) => r.capability == DeviceCapability.skinTemperature);
      expect(r.everyDay!.kind, CapabilityKind.conditional);
      expect(r.everyDay!.reasonKey, kReasonSkinTempNights);
    });

    test('a strap alone sends nothing every day: its rows are its workout lines plus the gaps', () {
      final rows = {for (final r in slotRowsFor(strap)) r.capability: r};
      // WHOOP: "Doesn't send" must stay visible for what a workout sensor lacks.
      expect(rows[DeviceCapability.sleep]!.workouts, isNull);
      expect(rows[DeviceCapability.sleep]!.everyDay, isNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.workouts, isNotNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.everyDay, isNull);
    });
  });

  group('SlotTable', () {
    Widget table(SlotComparison c, {DeviceSlot? focus, DeviceSlot? dim}) =>
        Scaffold(
            body: SingleChildScrollView(
                child: SlotTable(comparison: c, focus: focus, dim: dim)));

    const rowNames = [
      'Sleep',
      'Recovery',
      'Strain',
      'Heart rate and resting heart rate',
      'Heart-rate variability',
      'Respiration',
      'Skin temperature',
      'Steps',
      'Heart rate during workouts',
      'Beat-to-beat timing during workouts',
    ];

    testWidgets('every row is drawn, under the two column heads', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      expect(find.text('Every day'), findsOneWidget);
      expect(find.text('Workouts only'), findsOneWidget);
      expect(find.byKey(const ValueKey('slot-head-everyDay')), findsOneWidget);
      expect(find.byKey(const ValueKey('slot-head-workoutsOnly')), findsOneWidget);
      for (final c in kTableRows) {
        expect(find.byKey(ValueKey('slot-row-${c.name}')), findsOneWidget, reason: c.name);
      }
      for (final n in rowNames) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      // The workout rows name themselves; there is no group row.
      expect(find.text('DURING WORKOUTS'), findsNothing);
      expect(find.text('During workouts'), findsNothing);
    });

    testWidgets('the header leaves room above the column icons', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      final top = t.getTopLeft(find.byType(SlotTable)).dy;
      final icon = t.getTopLeft(find.descendant(
              of: find.byKey(const ValueKey('slot-cell-everyDay')).first,
              matching: find.byType(Icon)))
          .dy;
      // Was 1 px (the table's border) before the owner asked for room.
      expect(icon - top, greaterThanOrEqualTo(S.x3));
    });

    testWidgets('blood oxygen is never a row', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      expect(find.byKey(const ValueKey('slot-row-bloodOxygen')), findsNothing);
      expect(find.text('Blood oxygen'), findsNothing);
    });

    testWidgets('the workout rows come last, after Steps', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      final steps = t.getTopLeft(find.text('Steps')).dy;
      expect(t.getTopLeft(find.text('Heart rate during workouts')).dy, greaterThan(steps));
      expect(t.getTopLeft(find.text('Beat-to-beat timing during workouts')).dy,
          greaterThan(t.getTopLeft(find.text('Heart rate during workouts')).dy));
    });

    testWidgets('a check in the column that sends, a cross in the one that does not', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      expect(_hasIcon(t, _mark('everyDay', DeviceCapability.sleep), LucideIcons.check), isTrue);
      expect(_hasIcon(t, _mark('workoutsOnly', DeviceCapability.sleep), LucideIcons.x), isTrue);
      expect(_hasIcon(t, _mark('workoutsOnly', DeviceCapability.sleep), LucideIcons.check), isFalse);
      expect(_hasIcon(t, _mark('everyDay', DeviceCapability.sleep), LucideIcons.x), isFalse);
      // A WHOOP kept for workouts sends heart rate in both columns.
      expect(_hasIcon(t, _mark('workoutsOnly', DeviceCapability.workoutHeartRate), LucideIcons.check), isTrue);
    });

    testWidgets('a heart-rate strap crosses the whole-day column out', (t) async {
      await pumpPair(t, table(slotComparisonFor(kBleHrs)));
      for (final c in kDayCapabilities) {
        expect(_hasIcon(t, _mark('everyDay', c), LucideIcons.x), isTrue, reason: c.name);
        expect(_hasIcon(t, _mark('workoutsOnly', c), LucideIcons.x), isTrue, reason: c.name);
      }
      expect(_hasIcon(t, _mark('workoutsOnly', DeviceCapability.workoutHeartRate), LucideIcons.check), isTrue);
      expect(_hasIcon(t, _mark('everyDay', DeviceCapability.workoutHeartRate), LucideIcons.x), isTrue);
    });

    testWidgets('no dash anywhere: a "no" is a cross', (t) async {
      for (final e in [kWhoopGen5, kBleHrs, kOura, kCoros]) {
        await pumpPair(t, table(slotComparisonFor(e)));
        expect(find.byIcon(LucideIcons.minus), findsNothing, reason: e.id);
      }
    });

    testWidgets('marks name the capability, column and sends status to a screen reader', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      expect(t.getSemantics(_mark('everyDay', DeviceCapability.sleep)).label, 'Sleep, Every day: Sends');
      expect(t.getSemantics(_mark('workoutsOnly', DeviceCapability.sleep)).label, 'Sleep, Workouts only: Doesn’t send');
    });

    testWidgets('a conditional capability shows its caption under the label', (t) async {
      await pumpPair(t, table(slotComparisonFor(kWhoopGen5)));
      expect(find.text('Every day: After a few nights'), findsOneWidget);
      // Read as a workout sensor, a WHOOP's beat timing is conditional too.
      expect(find.text('Workouts only: If this device sends it, not confirmed'), findsOneWidget);
      // WHOOP 5 counts steps natively: no live-session caption.
      expect(find.text('Every day: During live sessions'), findsNothing);
      // The caption sits under its label, in the same row.
      final row = find.byKey(const ValueKey('slot-row-skinTemperature'));
      expect(find.descendant(of: row, matching: find.text('Skin temperature')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Every day: After a few nights')), findsOneWidget);
      expect(t.getTopLeft(find.text('Every day: After a few nights')).dy,
          greaterThan(t.getTopLeft(find.text('Skin temperature')).dy));
    });

    testWidgets('a strap says its beat timing is only if it sends it', (t) async {
      await pumpPair(t, table(slotComparisonFor(kBleHrs)));
      expect(find.text('Workouts only: If this device sends it, not confirmed'), findsOneWidget);
    });

    testWidgets('a ring’s captions: its own sleep stages and the first 14 nights', (t) async {
      await pumpPair(t, table(slotComparisonFor(kOura)));
      expect(find.text('Every day: From the ring’s own sleep stages'), findsOneWidget);
      expect(find.text('Every day: Estimated for the first 14 nights'), findsOneWidget);
    });

    testWidgets('a vendor-reported value says so instead of looking native', (t) async {
      await pumpPair(
          t,
          const Scaffold(
              body: SingleChildScrollView(
                  child: SlotTable(
                      comparison: SlotComparison(
                          everyDay: SlotSide(sends: {
                            DeviceCapability.sleep:
                                CapabilityStatus(CapabilityKind.vendorReported)
                          }, doesNotSend: {}),
                          workoutsOnly: SlotSide(sends: {}, doesNotSend: {DeviceCapability.sleep}))))));
      expect(find.text('Every day: The device’s own reading'), findsOneWidget);
    });

    testWidgets('focus washes only that column', (t) async {
      Color? colorOf(String s) => t
          .widget<Container>(find.byKey(ValueKey('slot-cell-$s')).first)
          .color;
      await pumpPair(t, table(slotComparisonFor(kBleHrs), focus: DeviceSlot.workoutsOnly));
      expect(colorOf('workoutsOnly'), isNotNull);
      expect(colorOf('everyDay'), isNull);
      await pumpPair(t, table(slotComparisonFor(kOura), focus: DeviceSlot.everyDay));
      expect(colorOf('everyDay'), isNotNull);
      expect(colorOf('workoutsOnly'), isNull);
      await pumpPair(t, table(slotComparisonFor(kOura)));
      expect(colorOf('everyDay'), isNull);
      expect(colorOf('workoutsOnly'), isNull);
    });

    testWidgets('dim fades only the other column (Opacity 0.28)', (t) async {
      double opacityIn(String s) => t
          .widget<Opacity>(find.descendant(
                  of: find.byKey(ValueKey('slot-cell-$s')).first,
                  matching: find.byType(Opacity))
              .first)
          .opacity;
      await pumpPair(t, table(slotComparisonFor(kBleHrs), dim: DeviceSlot.everyDay));
      expect(opacityIn('everyDay'), 0.28);
      expect(opacityIn('workoutsOnly'), 1);
      await pumpPair(t, table(slotComparisonFor(kOura), dim: DeviceSlot.workoutsOnly));
      expect(opacityIn('workoutsOnly'), 0.28);
      expect(opacityIn('everyDay'), 1);
    });

    test('the WHOOP-only strings exist, non-blank, in every locale', () {
      for (final f in Directory('lib/l10n').listSync().whereType<File>().where((f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path))) {
        final arb = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        for (final k in ['pairMainBandWhoopOnly']) {
          expect(arb[k], isA<String>(), reason: '${f.path} $k');
          expect((arb[k] as String).trim(), isNotEmpty, reason: '${f.path} $k');
        }
      }
    });

    testWidgets('German heads and rows render without overflow at 2x text', (t) async {
      for (final e in [kWhoopGen5, kBleHrs, kOura]) {
        await pumpPair(t, table(slotComparisonFor(e), focus: DeviceSlot.everyDay, dim: DeviceSlot.workoutsOnly),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
        expect(t.takeException(), isNull, reason: e.id);
        expect(find.text('Schlaf'), findsOneWidget);
      }
    });
  });
}
