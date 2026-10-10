// The two presentations of a non-WHOOP wearable's cells (one number, side by
// side), the estimate toggle, the not-available reasons, the device's own
// scores on its page, and "what this wearable unlocks" read off the table
// (lib/ui2/profile/wearable_numbers.dart, PLAN_multidevice_analytics §7).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/colmi_inputs.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart';
import 'package:openstrap_edge/compute/inputs/miband_inputs.dart';
import 'package:openstrap_edge/compute/inputs/pebble_inputs.dart';
import 'package:openstrap_edge/compute/inputs/ultrahuman_inputs.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/pair_sensor.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _device = 'Garmin watch';

Future<void> _pump(WidgetTester t, Widget w, {Locale? locale}) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: ListView(children: [w])),
  ));
  await t.pumpAndSettle();
}

const Map<String, Object?> _rhr = {
  'class': 'ours',
  'value': 52,
  'method': 'hr_1min',
  'device_value': 54,
};
const Map<String, Object?> _hrvDevice = {
  'class': 'device',
  'value': 48,
  'method': 'device',
};
const Map<String, Object?> _strainEst = {
  'class': 'estimated',
  'value': 9.4,
  'method': 'hr_5min',
};
const Map<String, Object?> _spo2None = {
  'class': 'unavailable',
  'value': null,
  'method': null,
  'reason': 'noDeviceSpo2',
};

void main() {
  group('one number', () {
    testWidgets('ours is the number, with a quiet source line', (t) async {
      await _pump(t, const WearableCell('resting_hr', _rhr, device: _device));
      expect(find.text('Resting heart rate'), findsOneWidget);
      expect(find.textContaining('52'), findsOneWidget);
      expect(find.text('From your Garmin watch · 1-min heart rate'),
          findsOneWidget);
      expect(find.textContaining('54'), findsNothing,
          reason: "the device's value waits behind the tap");
    });

    testWidgets("a tap opens the device's own value", (t) async {
      await _pump(t, const WearableCell('resting_hr', _rhr, device: _device));
      await t.tap(find.text('Resting heart rate'));
      await t.pumpAndSettle();
      expect(find.text('Your Garmin watch says'), findsOneWidget);
      expect(find.textContaining('54'), findsOneWidget);
    });

    testWidgets('the detail says so when the device gave nothing', (t) async {
      await _pump(
          t,
          const WearableCell('strain', _strainEst, device: _device));
      await t.tap(find.text('Strain'));
      await t.pumpAndSettle();
      expect(find.text('Your Garmin watch gives no value of its own for this'),
          findsOneWidget);
    });

    testWidgets("a value off a strap's beats names the strap", (t) async {
      await _pump(
          t,
          const WearableCell('hrv',
              {'class': 'ours', 'value': 41, 'method': 'rr_strap'},
              device: _device));
      expect(
          find.text("From a strap's beat-to-beat intervals"), findsOneWidget);
      expect(find.textContaining('Garmin watch'), findsNothing,
          reason: 'the strap measured it, not the watch');
    });

    testWidgets("a value off a strap's seconds names the strap", (t) async {
      await _pump(
          t,
          const WearableCell('hrr',
              {'class': 'ours', 'value': 30, 'method': 'hr_1hz'},
              device: _device));
      expect(find.text('From a strap, every second'), findsOneWidget);
    });

    testWidgets("a device value is labelled as the device's", (t) async {
      await _pump(t, const WearableCell('hrv', _hrvDevice, device: _device));
      expect(find.textContaining('48'), findsOneWidget);
      expect(find.text("Your Garmin watch's own value"), findsOneWidget);
    });
  });

  group('side by side', () {
    testWidgets('ours and the device value on one card', (t) async {
      await _pump(
          t,
          const WearableCell('resting_hr', _rhr,
              device: _device, sideBySide: true));
      expect(find.text('Ours'), findsOneWidget);
      expect(find.text(_device), findsOneWidget);
      expect(find.textContaining('52'), findsOneWidget);
      expect(find.textContaining('54'), findsOneWidget);
    });

    testWidgets('a tap opens how ours was made', (t) async {
      await _pump(
          t,
          const WearableCell('resting_hr', _rhr,
              device: _device, sideBySide: true));
      await t.tap(find.text('Resting heart rate'));
      await t.pumpAndSettle();
      expect(find.textContaining('From your Garmin watch'), findsOneWidget);
    });

    testWidgets('a device-only row leaves ours not available', (t) async {
      await _pump(
          t,
          const WearableCell('hrv', _hrvDevice,
              device: _device, sideBySide: true));
      expect(find.text('Not available'), findsOneWidget);
      expect(find.textContaining('48'), findsOneWidget);
    });
  });

  group('a ring\'s partial, provisional readiness', () {
    const cell = {
      'class': 'ours',
      'value': 61,
      'method': kPartialReadinessMethod,
      'provisional': true,
    };
    testWidgets('names its partial method and says it is provisional',
        (t) async {
      await _pump(t,
          const WearableCell('readiness', cell, device: 'Ultrahuman ring'));
      expect(find.text('Provisional'), findsOneWidget);
      expect(
          find.text('From your Ultrahuman ring · resting heart rate and skin '
              'temperature only (partial)'),
          findsOneWidget);
    });

    testWidgets('provisional in side by side too', (t) async {
      await _pump(
          t,
          const WearableCell('readiness', cell,
              device: 'Ultrahuman ring', sideBySide: true));
      expect(find.text('Provisional'), findsOneWidget);
    });
  });

  group('estimates', () {
    testWidgets('shown with the Estimated label by default', (t) async {
      await _pump(
          t,
          const WearableCell('strain', _strainEst, device: _device));
      expect(find.text('Estimated'), findsOneWidget);
      expect(find.text('9.4'), findsOneWidget);
      expect(
          find.text('Estimated from your Garmin watch · 5-min heart rate'),
          findsOneWidget);
    });

    testWidgets('labelled in side by side too', (t) async {
      await _pump(
          t,
          const WearableCell('strain', _strainEst,
              device: _device, sideBySide: true));
      expect(find.text('Estimated'), findsOneWidget);
    });

    testWidgets('hidden: no number, and a reason saying why', (t) async {
      await _pump(
          t,
          const WearableCell('strain', _strainEst,
              device: _device, showEstimates: false));
      expect(find.text('9.4'), findsNothing);
      expect(
          find.text(
              'Only an estimate exists, and estimates are hidden in Settings'),
          findsOneWidget);
    });

    test('the setting defaults to show and persists a hide', () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      final d = WearableDisplay.instance;
      expect((d.sideBySide, d.showEstimates), (false, true));
      var heard = 0;
      void listener() => heard++;
      d.addListener(listener);
      d.setShowEstimates(false);
      d.setSideBySide(true);
      d.removeListener(listener);
      expect((d.sideBySide, d.showEstimates), (true, false));
      expect(heard, 2);
      expect(Prefs.getBool(Prefs.wearableShowEstimates, true), isFalse);
      d.setShowEstimates(true);
      d.setSideBySide(false);
    });
  });

  group('not available', () {
    testWidgets('a one-line reason with the device named', (t) async {
      await _pump(t, const WearableCell('spo2', _spo2None, device: _device));
      expect(find.text('Blood oxygen'), findsOneWidget);
      expect(find.text('Your Garmin watch gave no blood oxygen'),
          findsOneWidget);
    });

    testWidgets('every reason code has words', (t) async {
      late AppLocalizations l;
      await _pump(t, Builder(builder: (c) {
        l = AppLocalizations.of(c)!;
        return const SizedBox.shrink();
      }));
      for (final w in Why.values) {
        final text = whyText(l, w.name, _device);
        expect(text, isNot(l.wearableNotAvailable), reason: w.name);
        expect(text, isNotEmpty, reason: w.name);
      }
      expect(whyText(l, 'no_such_code', _device), l.wearableNotAvailable);
    });

    testWidgets('another locale reads in its own words', (t) async {
      await _pump(t, const WearableCell('spo2', _spo2None, device: _device),
          locale: const Locale('de'));
      expect(find.text('Dein Garmin watch hat keinen Blutsauerstoff geliefert'),
          findsOneWidget);
    });
  });

  group("the device's own scores", () {
    testWidgets('drawn on its page, apart from our cells', (t) async {
      await _pump(
          t,
          const SizedBox(
            height: 1600,
            child: WearableDayView(
              device: _device,
              cells: {'resting_hr': _rhr},
              scores: {'body_battery': (value: 71, unit: null)},
            ),
          ));
      expect(find.text("Your Garmin watch's own scores"), findsOneWidget);
      expect(find.text('Body battery'), findsOneWidget,
          reason: 'worded, never the raw key');
      expect(find.text('body_battery'), findsNothing);
      expect(find.text('71'), findsOneWidget);
      expect(kDeviceValueSlot.containsKey('body_battery'), isFalse,
          reason: 'a proprietary score never fills one of our slots');
    });
  });

  group('what this wearable unlocks', () {
    testWidgets('grouped by class, read off the table', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      Prefs.setBool(Prefs.devMode, true);
      addTearDown(() => Prefs.setBool(Prefs.devMode, false));
      await _pump(t, const WearableUnlocks('garmin'));
      expect(find.text('What this wearable unlocks'), findsOneWidget);
      final caps = capabilities(kGarminColumn);
      final l = lookupAppLocalizations(const Locale('en'));
      bool strap(String r) => kGarminColumn[r]!.reason == Why.needsStrap;
      for (final (cls, title, isStrap) in [
        (MetricClass.ours, 'Measured by us', false),
        (MetricClass.unavailable, 'Measured by us with a strap session', true),
        (MetricClass.device, 'Its own values, labelled as its', false),
        (MetricClass.estimated, 'Estimated, labelled', false),
        (MetricClass.unavailable, 'Not available', false),
      ]) {
        final rows = [
          for (final e in caps.entries)
            if (e.value == cls &&
                (cls != MetricClass.unavailable || strap(e.key) == isStrap))
              rowLabel(l, e.key),
        ];
        expect(find.text(title), rows.isEmpty ? findsNothing : findsOneWidget,
            reason: cls.name);
        if (rows.isNotEmpty) {
          expect(find.text(rows.join(', ')), findsOneWidget, reason: cls.name);
        }
      }
      expect(caps['resting_hr'], MetricClass.ours,
          reason: 'ours where we compute one, even beside a device value');
      expect(caps['hrv'], MetricClass.device,
          reason: 'no beat intervals from this watch yet');
      expect(caps['readiness'], MetricClass.estimated,
          reason: 'resting HR only until beats or skin temp decode');
      expect(caps['spo2'], MetricClass.device);
      expect(caps['movement'], MetricClass.estimated);
      expect(caps['irregular_rhythm'], MetricClass.unavailable);
      final strapRows = find.text([
        for (final r in caps.keys)
          if (caps[r] == MetricClass.unavailable && strap(r)) rowLabel(l, r),
      ].join(', '));
      expect(strapRows, findsOneWidget,
          reason: 'workouts and HRR come with a strap, not "not available"');
      expect(find.textContaining(rowLabel(l, 'hrr')), findsOneWidget);
    });

    test('matches the table where an accessor alone would overclaim', () {
      for (final c in [kGarminColumn, kPebbleColumn, kColmiColumn,
          kUltrahumanColumn]) {
        expect(capabilities(c)['hrr'], MetricClass.unavailable,
            reason: 'strap only');
      }
      expect(capabilities(kPebbleColumn)['readiness'], MetricClass.estimated);
      expect(capabilities(kColmiColumn)['readiness'], MetricClass.ours);
    });

    testWidgets('nothing outside developer mode (R6)', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      Prefs.setBool(Prefs.devMode, false);
      await _pump(t, const WearableUnlocks('garmin'));
      expect(find.text('What this wearable unlocks'), findsNothing);
    });

    testWidgets('nothing for a device with no column', (t) async {
      await _pump(t, const WearableUnlocks('gen5'));
      expect(find.text('What this wearable unlocks'), findsNothing);
    });
  });
  test('the confidence line quotes the measured band in the row unit', () {
    final l = lookupAppLocalizations(const Locale('en'));
    // An average error, never worded as a per-day bound.
    expect(bandText(l, 'resting_hr', 1), contains('about 1 bpm on average'));
    expect(bandText(l, 'strain', 0.6), contains('about 0.6 on average'));
    expect(bandText(l, 'strain', 0.6), isNot(contains('within')));
    // Readiness says it is the partial score against the partial score.
    expect(bandText(l, 'readiness', 3),
        allOf(contains('partial score'), contains('not compared')));
    expect(bandText(l, 'resting_hr', null), isNull);
    // A sleep window's band is its length against the synthetic nights' own
    // time in bed (what the harness measures), not edge placement and not
    // the 1 Hz number.
    expect(bandText(l, 'sleep_window', 30),
        allOf(contains("window's length"), contains('time in bed'),
            isNot(contains('bed and wake times')),
            isNot(contains('second-by-second'))));
  });

  group("a ring's skin temperature baseline", () {
    testWidgets('reads in °C under its own name, never as a heart rate',
        (t) async {
      // An Oura day: the baselines row holds centi-°C off the ring's nights.
      await _pump(
          t,
          const WearableCell(
              'baselines_load_illness',
              {
                'class': 'ours',
                'value': 3530,
                'method': 'skin_temp_c_event',
              },
              device: 'Oura ring'));
      expect(find.text('Usual skin temperature'), findsOneWidget);
      expect(find.text('Usual resting HR'), findsNothing);
      expect(find.textContaining('35.3'), findsOneWidget);
      expect(find.textContaining('bpm'), findsNothing);
    });
  });

  group('device score names', () {
    test('known keys worded, an unknown key spaced out, never raw', () {
      final l = lookupAppLocalizations(const Locale('en'));
      expect(deviceScoreLabel(l, 'sleep_score'), 'Sleep score');
      expect(deviceScoreLabel(l, 'impedance'), 'Body impedance');
      expect(deviceScoreLabel(l, 'fitness_age'), 'Fitness age');
    });
  });

  group('on Home and Health', () {
    const cells = {
      'readiness': _strainEst,
      'resting_hr': _rhr,
      'spo2': _spo2None,
      'steps': {'class': 'device', 'value': 8412, 'method': 'device'},
    };

    testWidgets('the rows in order, each in its class, under the device',
        (t) async {
      await _pump(
          t,
          const WearableCellsCard(
              device: _device, rows: kHomeWearableRows, cells: cells));
      expect(find.text(_device), findsOneWidget);
      // Home's rows only, in Home's order; a row the day lacks is skipped.
      final labels = [
        for (final w in t.widgetList<WearableCell>(find.byType(WearableCell)))
          w.row,
      ];
      expect(labels, ['readiness', 'resting_hr', 'steps']);
      expect(find.text('Estimated'), findsOneWidget);
      expect(find.text('From your Garmin watch · 1-min heart rate'),
          findsOneWidget);
      expect(find.text("Your Garmin watch's own value"), findsOneWidget);
    });

    testWidgets('side by side and the hidden-estimate state carry through',
        (t) async {
      await _pump(
          t,
          const WearableCellsCard(
              device: _device,
              rows: kHomeWearableRows,
              cells: cells,
              sideBySide: true,
              showEstimates: false));
      expect(find.text('Ours'), findsWidgets);
      expect(find.text('Only an estimate exists, and estimates are hidden in '
          'Settings'), findsOneWidget);
    });

    testWidgets("Health's rows carry the not-available reason", (t) async {
      await _pump(
          t,
          const WearableCellsCard(
              device: _device, rows: kHealthWearableRows, cells: cells));
      expect(find.text('Resting heart rate'), findsOneWidget);
      expect(find.text('Blood oxygen'), findsOneWidget);
      expect(find.text('Steps'), findsNothing, reason: "not Health's row");
    });

    testWidgets('nothing when the day has none of the rows', (t) async {
      await _pump(
          t,
          const WearableCellsCard(
              device: _device, rows: kHealthWearableRows, cells: {}));
      expect(find.text(_device), findsNothing);
    });
  });

  group('Mi Band 2/3', () {
    const band = 'Mi Band 2/3';

    test('unlocks read off its column, matching the table', () {
      expect(wearableName(kMiBandFamily), band);
      final caps = capabilities(kMiBandColumn);
      expect(caps['resting_hr'], MetricClass.ours);
      expect(caps['sleep_stages'], MetricClass.device);
      expect(caps['steps'], MetricClass.device);
      expect(caps['readiness'], MetricClass.estimated, reason: 'C partial');
      expect(caps['movement'], MetricClass.estimated);
      expect(caps['hrv'], MetricClass.unavailable);
      expect(caps['hrr'], MetricClass.unavailable, reason: 'strap only');
    });

    testWidgets('its unlocks draw in developer mode', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      Prefs.setBool(Prefs.devMode, true);
      addTearDown(() => Prefs.setBool(Prefs.devMode, false));
      await _pump(t, const WearableUnlocks(kMiBandFamily));
      expect(find.text('What this wearable unlocks'), findsOneWidget);
      expect(find.text('Measured by us'), findsOneWidget);
      expect(find.text('Estimated, labelled'), findsOneWidget);
    });

    test('efficiency is ours off its stages only on a night it staged',
        () {
      String? how(String? source) => resolveCells(
            kMiBandColumn,
            day: {
              'scalars': {'efficiency': 91},
              'sleep_source': ?source,
            },
            crossDay: const {},
            deviceValues: const {},
            method: 'hr_1min',
            family: kMiBandFamily,
          )['efficiency_awakenings']!['method'] as String?;
      expect(how('vendor_staged'), 'device_stages');
      expect(how(null), 'hr_1min', reason: 'our HR-led window found it');
    });

    testWidgets('its served cells draw on the Home card in their class',
        (t) async {
      final cells = resolveCells(
        kMiBandColumn,
        day: {
          'scalars': {'rhr': 55, 'strain': 8.1, 'calories': 2210},
          'baselines': {
            'resting_hr': {'z': 0.4},
          },
        },
        crossDay: const {},
        deviceValues: const {'steps': 7012},
        method: 'hr_1min',
        family: kMiBandFamily,
      );
      await _pump(
          t,
          WearableCellsCard(
              device: band, rows: kHomeWearableRows, cells: cells));
      expect(find.text(band), findsOneWidget);
      expect(find.text('From your Mi Band 2/3 · 1-min heart rate'),
          findsWidgets);
      expect(find.text('Steps'), findsOneWidget);
      expect(find.text("Your Mi Band 2/3's own value"), findsOneWidget,
          reason: 'its own steps, labelled as its');
      // Readiness here is the resting-HR-only part, and says so.
      expect(cells['readiness']!['class'], isNot('ours'));
    });
  });

  group('the old sensor copy', () {
    testWidgets('a wearable is not told nothing is calculated from it',
        (t) async {
      await _pump(
          t,
          const SizedBox(
              height: 1600,
              child: PairSensorView(
                  entryLabel: 'Mi Band 2/3', adapterId: kMiBandFamily)));
      expect(find.textContaining('Working out our numbers from it'),
          findsOneWidget);
      expect(find.textContaining('feeds a score'), findsNothing);
      expect(find.textContaining('for workouts'), findsNothing);
    });

    testWidgets('a strap and a scale each get their own words', (t) async {
      await _pump(
          t,
          const SizedBox(
              height: 1600,
              child: PairSensorView(entryLabel: 'Strap', adapterId: 'ble_hrs')));
      expect(find.textContaining('for workouts'), findsOneWidget);
      // Flag off, it records nothing: the copy says so (rule R6).
      expect(find.textContaining('until then it records nothing'),
          findsOneWidget);
      // A workout arms the strap and nothing else does, so it never
      // records a night: the copy promises no overnight HRV.
      expect(find.textContaining('records while a workout runs'),
          findsOneWidget);
      expect(find.textContaining('overnight HRV'), findsNothing);
      expect(find.textContaining('never used overnight'), findsNothing);
      await _pump(
          t,
          const SizedBox(
              height: 1600,
              child: PairSensorView(
                  entryLabel: 'Scale', adapterId: 'miscale_bc')));
      expect(find.textContaining('Using them in your profile'),
          findsOneWidget);
    });

    testWidgets('a Coros watch is not told a workout records it', (t) async {
      await _pump(
          t,
          const SizedBox(
              height: 1600,
              child: PairSensorView(
                  entryLabel: 'Coros',
                  adapterId: 'coros',
                  paired: (id: 'coros-1', label: 'COROS PACE'))));
      expect(find.textContaining('No workout uses it'), findsOneWidget);
      expect(find.text('Synced in short windows'), findsOneWidget);
      expect(find.text('Used during workouts'), findsNothing);
      expect(find.textContaining('records while a workout runs'), findsNothing);
      expect(find.textContaining('Scoring a workout'), findsNothing);
    });

    testWidgets('a paired ring or scale is not told a workout uses it',
        (t) async {
      for (final (label, adapter, sub) in const [
        ('Oura', 'oura', 'Records stored when it syncs'),
        ('Scale', 'miscale_bc', 'Readings stored as it takes them'),
      ]) {
        await _pump(
            t,
            SizedBox(
                height: 1600,
                child: PairSensorView(
                    entryLabel: label,
                    adapterId: adapter,
                    paired: (id: '$adapter-1', label: label))));
        expect(find.text(sub), findsOneWidget, reason: adapter);
        expect(find.text('Used during workouts'), findsNothing, reason: adapter);
      }
    });

    test('no locale still says nothing is calculated from a device', () {
      for (final loc in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(loc);
        for (final s in [
          l.devicesWhatItDoesStored,
          l.devicesWhatItDoesBeats,
          l.pairSensorExplainerWearable,
        ]) {
          expect(s, isNot(contains('calculated from it yet')), reason: '$loc');
          if (loc.languageCode == 'en') {
            expect(s, contains('experimental'), reason: '$loc');
          }
        }
        // The wearable's explainer is in the reader's language.
        if (loc.languageCode != 'en') {
          expect(l.pairSensorExplainerWearable,
              isNot(lookupAppLocalizations(const Locale('en'))
                  .pairSensorExplainerWearable),
              reason: '$loc');
        }
      }
    });
  });

  group('developer settings', () {
    setUp(() {
      WearableDisplay.instance.devices = const [
        (id: 'g1', adapter: 'garmin', label: 'Garmin watch', on: true,
            active: true),
        (id: 's1', adapter: 'ble_hrs', label: 'Chest strap', on: false,
            active: false),
      ];
    });
    tearDown(() => WearableDisplay.instance.devices = const []);

    testWidgets('each flag is a row in the developer group', (t) async {
      await _pump(
          t,
          const SizedBox(
              height: 2200,
              child: MoreSettingsView(version: '1', devMode: true)));
      expect(find.text('Wearable numbers'), findsOneWidget);
      expect(find.text('Garmin watch'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Chest strap'), findsOneWidget);
      expect(find.text("Experimental. On uses this device's data for your "
          'numbers'), findsNWidgets(2));
    });

    testWidgets('hidden outside developer mode (R6)', (t) async {
      await _pump(
          t,
          const SizedBox(
              height: 2200,
              child: MoreSettingsView(version: '1', devMode: false)));
      expect(find.text('Wearable numbers'), findsNothing);
      expect(find.text('Chest strap'), findsNothing);
    });
  });
}

