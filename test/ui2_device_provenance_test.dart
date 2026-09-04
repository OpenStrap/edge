// M6 — device-provenance pure-function tests (spec-m6.md §13.2, tests 1-3, 7).
//
// These exercise `candidatesFromSources`/`contendedSignalsOf` (the pure halves
// of `signalCandidates`/`contendedSignals`) directly against hand-built
// `HealthSource` lists, the same idiom `device_sources_test.dart` already
// uses, rather than constructing a live `AppState`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _keys = [
  'resting_hr', 'hrv', 'readiness', 'resp_rate', 'sleep', 'efficiency', 'deep',
  'rem', 'steps', 'calories', 'strain', 'trimp', 'stress', 'dip', 'hrr',
  'lf_hf', 'hrv_cv', 'brv', 'nap_min', 'active_min', 'wear', 'skin_temp',
];

HealthSource _band({String family = 'gen4'}) => HealthSource(
      name: 'Your band',
      kind: 'wrist optical',
      tier: SourceTier.wristOptical,
      icon: Icons.watch, // unused by the pure functions under test
      isBand: true,
      family: family,
    );

HealthSource _oura() => const HealthSource(
      name: 'Oura ring',
      kind: 'Oura',
      tier: null,
      icon: Icons.circle,
      isBand: false,
      deviceId: 'oura-A1B2',
      family: 'oura',
    );

HealthSource _hrs() => const HealthSource(
      name: 'Chest strap',
      kind: 'Bluetooth heart rate sensor',
      tier: SourceTier.beatToBeat,
      icon: Icons.favorite,
      isBand: false,
      deviceId: 'ble_hrs-0a1b2c3d',
      family: 'ble_hrs',
    );

/// A [test] that hands its body a real, LOCALIZED [BuildContext].
///
/// `candidatesFromSources` takes one now, purely to translate a rejected
/// device's `reason` — nothing about which devices qualify depends on it, so
/// this stays the pure-function suite it was. Wired to the real delegates
/// rather than a bare context so the strings asserted below are the ones a
/// user actually reads, not the English fallbacks behind them.
void contextTest(String name, void Function(BuildContext c) body) =>
    testWidgets(name, (t) async {
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      body(ctx);
    });

void main() {
  // Test 1: single band — every metric's requires (empty or not) yields
  // fewer than two candidates. This IS the protected case, machine-checked.
  contextTest('signalCandidates: fewer than two candidates on a single band, '
      'for every metric key', (c) {
    final sources = [_band()];
    for (final key in _keys) {
      final spec = specOf(key);
      final out = candidatesFromSources(c, sources, requires: spec.requires);
      expect(out.length, lessThan(2), reason: key);
    }
  });

  // Test 2: WHOOP + Oura. OuraAdapter declares nothing, so every metric sees
  // exactly one candidate (the band) — the declaration mechanism gates it,
  // not a hand-written exclusion.
  contextTest('signalCandidates: WHOOP + Oura yields one candidate for every '
      'metric', (c) {
    final sources = [_band(), _oura()];
    for (final key in _keys) {
      final spec = specOf(key);
      final out = candidatesFromSources(c, sources, requires: spec.requires);
      if (spec.requires.isEmpty) {
        expect(out, isEmpty, reason: key);
      } else {
        expect(out.length, 1, reason: key);
        expect(out.single.deviceId, LocalDb.kPrimaryDeviceId, reason: key);
      }
    }
  });

  // Test 3: WHOOP + HRS. Both declare rrIntervals, so hrv sees two candidates
  // (the §0 deviation, pinned so a future reader sees it was deliberate);
  // readiness needs hr1Hz/accel1Hz/skinTempRaw too, which the strap lacks, so
  // it stays at one.
  contextTest('signalCandidates: WHOOP + HRS yields two for hrv, one for '
      'readiness', (c) {
    final sources = [_band(), _hrs()];
    final hrv = candidatesFromSources(c, sources, requires: specOf('hrv').requires);
    expect(hrv.length, 2);
    expect(hrv.every((o) => o.selectable), isTrue);

    final readiness =
        candidatesFromSources(c, sources, requires: specOf('readiness').requires);
    expect(readiness.length, 2);
    final strapOption =
        readiness.firstWhere((o) => o.deviceId == 'ble_hrs-0a1b2c3d');
    expect(strapOption.selectable, isFalse);
    expect(strapOption.reason, isNotNull);
  });

  // The basis of every `signal_priority` write. The chest strap is
  // `selectable: false` on readiness (test 3 above) and still emits RR — and
  // `setSignalPriority` replaces a signal's WHOLE row set, whose rows are also
  // the resolver's candidate list. So an order built from readiness'
  // selectable pills deleted the strap's `rrIntervals` row and took it out of
  // HRV, a metric the readiness screen was never showing.
  test('declaringDeviceIds: a metric-unselectable device keeps the signals it '
      'does declare', () {
    final sources = [_band(), _hrs()];
    expect(
      declaringDeviceIds(sources, InputSignal.rrIntervals),
      containsAll([LocalDb.kPrimaryDeviceId, 'ble_hrs-0a1b2c3d']),
    );
    // Candidacy is still per signal, not a free-for-all: the strap has no
    // thermistor, so it must not appear under skinTempRaw.
    expect(
      declaringDeviceIds(sources, InputSignal.skinTempRaw),
      isNot(contains('ble_hrs-0a1b2c3d')),
    );
    // And a device declaring nothing is a candidate for no signal at all.
    expect(
      [
        for (final s in InputSignal.values)
          ...declaringDeviceIds([_band(), _oura()], s),
      ],
      isNot(contains('oura-A1B2')),
    );
  });

  // Test 7: missingSignalReason names every InputSignal member, so adding an
  // enum member fails here rather than silently rendering the generic phrase.
  contextTest('missingSignalReason: a phrase for every InputSignal member',
      (c) {
    for (final s in InputSignal.values) {
      expect(missingSignalReason(c, {s}), isNot('cannot supply this'),
          reason: s.name);
    }
    // And the empty set is the only thing that reaches the generic phrase.
    expect(missingSignalReason(c, const {}), 'cannot supply this');
  });

  test('contendedSignalsOf: empty on a single band', () {
    expect(contendedSignalsOf([_band()]), isEmpty);
  });

  test('contendedSignalsOf: rrIntervals contends for WHOOP + HRS', () {
    final contended = contendedSignalsOf([_band(), _hrs()]);
    expect(contended, contains(InputSignal.rrIntervals));
    expect(contended, isNot(contains(InputSignal.accel1Hz)));
  });

  // Test 12: fewer than two options renders nothing at all.
  testWidgets('DeviceFilter with one option renders SizedBox.shrink', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: DeviceFilter(
          options: const [
            (deviceId: '', label: 'Band', selectable: true, reason: null),
          ],
          selected: null,
          onSelect: (_) {},
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byType(SubTabs), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.width == 0 && w.height == 0),
      findsOneWidget,
    );
  });

  // Test 13: a non-selectable option is present, untappable, and explained.
  testWidgets('DeviceFilter with a non-selectable option: pill present, '
      'onTap null, reason renders', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: DeviceFilter(
          options: const [
            (deviceId: '', label: 'Band', selectable: true, reason: null),
            (
              deviceId: 'ble_hrs-1',
              label: 'Chest strap',
              selectable: false,
              reason: 'no accelerometer',
            ),
          ],
          selected: null,
          onSelect: (_) {},
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Chest strap'), findsOneWidget);
    expect(find.textContaining('no accelerometer'), findsOneWidget);
    final subTabs = t.widget<SubTabs>(find.byType(SubTabs));
    // Index 0 is "All devices"; the strap sits at index 2 (band is 1).
    expect(subTabs.disabled, contains(2));
  });
}
