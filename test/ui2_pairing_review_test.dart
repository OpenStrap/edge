// PR #669 review regressions: exercise the rendered sheets, recovery screens,
// table and device details, rather than just their copy helpers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/pairing/pair_help.dart';
import 'package:openstrap_edge/ui2/pairing/pair_sheets.dart';
import 'package:openstrap_edge/ui2/pairing/pair_text.dart';
import 'package:openstrap_edge/ui2/pairing/slot_comparison_view.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';

import 'support/pair_ui_support.dart';

const _ouraKey = 'Already use the Oura app? Keep the ring in that app and pair with its existing key. Skip the reset steps below. Only reset it if you want a new key.';
const _pebbleLead = 'Pebble 2 can fill your days with sleep, recovery and heart rate. Pebble 2 SE records sleep and steps, but has no heart-rate sensor and cannot estimate recovery from resting heart rate.';
const _strapLead = 'It adds heart rate while you work out. It does not record sleep, recovery or daily strain.';

Future<void> _openBand(WidgetTester t, BandEntry entry) async {
  await pumpPair(t, Builder(builder: (c) => Scaffold(body: TextButton(
      onPressed: () => showBandFoundSheet(c, band: entry, hasMainBand: false),
      child: const Text('open')))), size: const Size(412, 2400));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void _expectKeyBeforeReset(WidgetTester t) {
  final guidance = find.text(_ouraKey);
  expect(guidance, findsOneWidget);
  final reset = find.text('Open the maker’s app and remove this device from it.');
  expect(reset, findsOneWidget, reason: 'new-key reset path stays available');
  expect(t.getTopLeft(guidance).dy, lessThan(t.getTopLeft(reset).dy));
}

void main() {
  testWidgets('Oura sheet preserves the existing key before reset steps', (t) async {
    await _openBand(t, kOura);
    _expectKeyBeforeReset(t);
  });

  testWidgets('Oura trouble card preserves the existing key before reset steps', (t) async {
    await pumpPair(t, Scaffold(body: SingleChildScrollView(
        child: TroubleConnectingCard(entries: [kOura]))),
        size: const Size(412, 2400));
    _expectKeyBeforeReset(t);
  });

  testWidgets('Oura bond-refused screen preserves the existing key before reset steps', (t) async {
    await pumpPair(t, PairingView(phase: PairPhase.bondRefused,
        onPair: () {}, resetEntry: kOura), size: const Size(412, 2400));
    _expectKeyBeforeReset(t);
    expect(find.text('In your phone’s Bluetooth settings, find the device and choose Forget.'),
        findsOneWidget);
  });

  testWidgets('Pebble lead keeps HR for Pebble 2 and excludes it for SE', (t) async {
    await _openBand(t, kPebble);
    expect(find.text(_pebbleLead), findsOneWidget);
    expect(find.text('It can fill your days with sleep, recovery and heart rate.'), findsNothing);
  });

  testWidgets('strap lead excludes daily strain precisely', (t) async {
    await pumpPair(t, Builder(builder: (c) => Scaffold(body: TextButton(
        onPressed: () => showStrapSheet(c, sensor: kBleHrs),
        child: const Text('open')))), size: const Size(412, 2400));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text(_strapLead), findsOneWidget);
  });

  test('Russian replacement and unpair actions remove the pairing', () {
    final l = lookupAppLocalizations(const Locale('ru'));
    final actions = [l.pairReplaceConfirmTitle('WHOOP'), l.pairReplaceBand('WHOOP'),
      l.pairReplaceConfirmYes, l.pairReplaceUnpairFailed, l.pairUnpairBand];
    for (final text in actions) {
      expect(text.toLowerCase(), contains('сопряжени'), reason: text);
      expect(text.toLowerCase(), isNot(contains('отключ')), reason: text);
    }
  });

  test('Thai strap filter names chest straps and armbands', () {
    final l = lookupAppLocalizations(const Locale('th'));
    expect(l.pairKindStrap, contains('คาดอก'));
    expect(l.pairKindStrap, contains('ต้นแขน'));
  });

  testWidgets('WHOOP unconfirmed beat timing caption names only Workouts only', (t) async {
    await pumpPair(t, Scaffold(body: SingleChildScrollView(
        child: SlotTable(comparison: slotComparisonFor(kWhoopGen5)))),
        size: const Size(412, 2000));
    final row = find.byKey(const ValueKey('slot-row-workoutBeatToBeat'));
    expect(find.descendant(of: row, matching: find.text(
        'Workouts only: If this device sends it, not confirmed')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(
        'Every day: If this device sends it, not confirmed')), findsNothing);
  });

  testWidgets('different reasons in both columns remain associated with each column', (t) async {
    await pumpPair(t, const Scaffold(body: SingleChildScrollView(
        child: SlotTable(comparison: SlotComparison(
          everyDay: SlotSide(sends: {DeviceCapability.sleep:
              CapabilityStatus(CapabilityKind.vendorReported)}, doesNotSend: {}),
          workoutsOnly: SlotSide(sends: {DeviceCapability.sleep:
              CapabilityStatus(CapabilityKind.conditional, reasonKey: kReasonUnconfirmed)},
              doesNotSend: {}),
        )))), size: const Size(412, 2000));
    final row = find.byKey(const ValueKey('slot-row-sleep'));
    expect(find.descendant(of: row, matching: find.text(
        'Every day: The device’s own reading')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(
        'Workouts only: If this device sends it, not confirmed')), findsOneWidget);
  });

  testWidgets('each table mark announces its capability, column and status', (t) async {
    await pumpPair(t, Scaffold(body: SingleChildScrollView(
        child: SlotTable(comparison: slotComparisonFor(kWhoopGen5)))),
        size: const Size(412, 2000));
    for (final (key, label) in [
      ('slot-everyDay-sleep', 'Sleep, Every day: Sends'),
      ('slot-workoutsOnly-sleep', 'Sleep, Workouts only: Doesn’t send'),
      ('slot-everyDay-workoutBeatToBeat', 'Beat-to-beat timing during workouts, Every day: Sends'),
      ('slot-workoutsOnly-workoutBeatToBeat', 'Beat-to-beat timing during workouts, Workouts only: Sends'),
    ]) {
      expect(t.getSemantics(find.byKey(ValueKey(key))).label, label, reason: key);
    }
  });

  for (final family in ['colmi', 'oura']) {
    testWidgets('$family detail uses its every-day description without workout-only copy', (t) async {
      final l = lookupAppLocalizations(const Locale('en'));
      await pumpPair(t, DeviceDetailView(HealthSource(name: family, kind: 'Ring',
          tier: SourceTier.beatToBeat, icon: Icons.circle, isBand: false,
          deviceId: '$family-test', family: family)), size: const Size(412, 2400));
      expect(find.text(l.pairWearableCardNote), findsOneWidget,
          reason: 'the every-day card explains its role');
      expect(find.text(l.devicesWhatItDoesBeats), findsNothing);
    });
  }

  testWidgets('workout strap detail retains the workout description', (t) async {
    final l = lookupAppLocalizations(const Locale('en'));
    await pumpPair(t, const DeviceDetailView(HealthSource(name: 'Strap', kind: 'Strap',
        tier: SourceTier.beatToBeat, icon: Icons.favorite, isBand: false,
        deviceId: 'ble_hrs-test', family: 'ble_hrs')), size: const Size(412, 2400));
    expect(find.text(l.devicesWhatItDoesBeats), findsOneWidget);
  });

  test('every conditional mark in every locale has its caption', () {
    // A check whose condition has no caption would claim more than the device
    // gives. Every registry entry, both columns, every shipped locale.
    var seen = 0;
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final e in kBandRegistry) {
        final cmp = slotComparisonFor(e);
        for (final side in [cmp.everyDay, cmp.workoutsOnly]) {
          for (final MapEntry(key: cap, value: st) in side.sends.entries) {
            if (st.kind != CapabilityKind.conditional) continue;
            seen++;
            final caption = capabilityReason(l, st);
            expect(caption, isNotNull,
                reason: '${e.id} $cap ${st.reasonKey} in $locale has no caption');
            expect(caption!.trim(), isNotEmpty);
          }
        }
      }
    }
    expect(seen, greaterThan(0), reason: 'the registry has conditional marks');
  });
}
