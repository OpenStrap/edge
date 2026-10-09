// Workout sensors and health measurements on a wearable's day, end to end.
// A Pebble 2 is the ACTIVE WEARABLE (four synthetic days through the real
// Pebble link, no primary band). A Bluetooth heart-rate strap, flagged on,
// is worn for a 20-minute session and again overnight at rest: inside the
// session its 1 Hz HR wins (strain, heart-rate recovery), and its night
// beats give the watch's day an HRV of ours the watch alone cannot. A Mi
// composition scale's weighing then becomes the app's profile weight once
// its flag is on (never before), and the day's calories move with it.

import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/pebble_link.dart';
import 'package:openstrap_edge/ble/session_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/measurement_inputs.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/strap_day.dart';
import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
final SyntheticDay _truth = _days.last;
const String _watch = 'pebble-accessories';
const String _strap = 'hrs-accessories';
const String _scale = 'scale-accessories';
const String _dayId = '2026-10-04';
const Map<String, dynamic> _profileMap = {
  'age': 32,
  'weight_kg': 72.0,
  'height_cm': 176.0,
  'sex': 'm',
};

Future<Map<String, dynamic>> _scalars() async =>
    ((jsonDecode((await LocalDb.dayResult(_dayId))!['payload_json'] as String)
            as Map)['scalars'] as Map)
        .cast<String, dynamic>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_accessories_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _watch, adapterId: 'pebble', remoteId: 'AA:BB:CC:00:00:13');
    final now = DateTime(2026, 10, 4, 22, 30);
    await PebbleLink.instance.ingestForTest(
        _watch, SyntheticDay.pebbleDays(_days),
        nowSeconds: () => SyntheticDay.sec(now));
    await LocalDb.setCursor(kActiveWearableCursor, _watch);
    await LocalDb.setCursor(wearableEnabledCursor('pebble'), '1');
    final profile = Profile.fromMap(_profileMap);
    for (var i = 0; i < 2; i++) {
      await DerivationEngine()
          .runDays(profile, {for (final d in _days) dayLabelOf(d.day)},
              force: true);
    }
  });

  tearDownAll(() async => LocalDb.close());

  test("a strap's workout and its night at rest on the watch's day",
      () async {
    final profile = Profile.fromMap(_profileMap);
    final before = (await dayCells(_dayId))!;
    expect(before['workouts_with_strap']!['class'], 'unavailable');
    expect(before['hrv'],
        allOf(containsPair('class', 'unavailable'),
            containsPair('reason', Why.neverBeats.name)));
    final strainBefore = (await _scalars())['strain'] as num;

    await LocalDb.upsertDevice(id: _strap, adapterId: 'ble_hrs');
    final start = SyntheticDay.sec(DateTime(2026, 10, 4, 12));
    final end = start + 20 * 60;
    int bpm(int t) =>
        t <= end ? 150 : (150 - 30 * (t - end) / 60).round().clamp(100, 150);
    final (night, rmssd) = strapRestingBeats(
        SyntheticDay.sec(_truth.sleepOnset), SyntheticDay.sec(_truth.sleepOffset));
    await HrsLink.instance.ingestForTest(_strap, [
      ...night,
      for (var t = start; t <= end + kStrapTailSec; t++) (t, [0x00, bpm(t)]),
    ]);
    await LocalDb.putSession({
      'id': 'strap-session',
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'created_at': end,
    });

    // Flag off: the strap's rows are there and move nothing.
    await DerivationEngine().runDays(profile, {_dayId}, force: true);
    expect((await dayCells(_dayId))!['hrv']!['class'], 'unavailable');

    await useDevice(_strap, 'ble_hrs', true);
    await DerivationEngine().runDays(profile, {_dayId}, force: true);
    final c = (await dayCells(_dayId))!;
    expect(c['workouts_with_strap'],
        allOf(containsPair('class', 'ours'), containsPair('value', 1),
            containsPair('method', 'hr_1hz')));
    expect(c['hrr'], containsPair('method', 'hr_1hz'));
    expect(c['hrr']!['value'] as num, closeTo(30, 3));
    expect(c['hrv'],
        allOf(containsPair('class', 'ours'), containsPair('method', 'rr_strap')));
    expect(c['hrv']!['value'] as num, closeTo(rmssd, rmssd * 0.15),
        reason: 'the RMSSD of the beats the strap sent');
    expect(c['strain']!['value'] as num, greaterThan(strainBefore),
        reason: "the session's 150 bpm is the strap's, at 1 Hz");
    // The watch's own rows still decide the rest of the day.
    expect(c['resting_hr']!['method'], 'hr_1min');
    // Stored as made: the beat-only numbers are the strap's, the recovery
    // time constant its 1 Hz tail's.
    final stored = {
      for (final r in await (await LocalDb.instance).query('metric_method',
          where: 'date = ?', whereArgs: [_dayId]))
        r['key'] as String: r['method'],
    };
    for (final k in ['rmssd', 'sdnn', ...kStrapBeatSeriesKeys]) {
      expect(stored[k], 'rr_strap', reason: k);
    }
    expect(stored['hrr_tau_s'], 'hr_1hz');

    // Flag off again: the night's HRV goes with it.
    await useDevice(_strap, 'ble_hrs', false);
    await DerivationEngine().runDays(profile, {_dayId}, force: true);
    final off = (await dayCells(_dayId))!;
    expect(off['hrv']!['class'], 'unavailable');
    expect(off['workouts_with_strap']!['class'], 'unavailable');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a scale's weighing becomes the app's profile weight once its flag is "
      'on, and calories follow', () async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState.forTesting()..user = {..._profileMap};
    SessionLink.onSessionDone = app.adoptWeighing;
    addTearDown(() => SessionLink.onSessionDone = null);
    // Read as derived: adopting a weighing re-derives the open days itself.
    Future<num> kcal() async => (await _scalars())['calories'] as num;

    await LocalDb.upsertDevice(id: _scale, adapterId: 'miscale_bc');
    final at = DateTime.utc(2026, 10, 4, 6, 55, 10);
    final dt = [
      at.year & 0xff, at.year >> 8, at.month, at.day, at.hour, at.minute,
      at.second,
    ];
    // 78.00 kg (raw / 200) with a 498 ohm impedance, settled and stable.
    const raw = 15600, ohm = 498;
    await SessionLink.miScaleComposition.ingestForTest(
      _scale,
      nowSeconds: () => SyntheticDay.sec(DateTime(2026, 10, 4, 22, 30)),
      pushes: [
        (kMiScaleBodyCompositionChar,
            [0x02, 0x22, ...dt, ohm & 0xff, ohm >> 8, raw & 0xff, raw >> 8]),
      ],
    );

    // The weighing and its impedance are observations, shown attributed,
    // flag or no flag.
    final shown = {
      for (final o in await LocalDb.observationsForDay(_dayId))
        if (o['device_id'] == _scale) (o['key'] ?? o['vendor_key']): o['value'],
    };
    expect(shown, {'weight': 78.0, 'impedance': 498.0});

    // Flag off (rule R6): the scale moves no profile number, and the day
    // shows no BMI of ours off its weight.
    expect(await newestWeighing(), isNull);
    expect(await bmiScalesOf(await LocalDb.observationsForDay(_dayId)),
        isEmpty);
    // What the day screen lists: nothing of a flag-off scale (rule R6); with
    // the flag, the weighing and a BMI.
    Future<List<String>> timelineNotes() async => [
          for (final n in (await TimelineData.load(
                  LocalRepositoryImpl(getProfileMap: () => app.user),
                  want: _dayId, l: lookupAppLocalizations(const Locale('en'))))
              .notes)
            n.title,
        ];
    expect(await timelineNotes(),
        allOf(isNot(contains('Weight')), isNot(contains('Body impedance')),
            isNot(contains('BMI'))));
    await app.adoptWeighing();
    expect(app.user!['weight_kg'], 72.0);
    final kcal72 = await kcal();

    // The developer toggle turns its flag on and adopts the weighing.
    await WearableDisplay.instance
        .toggleDevice(_scale, 'miscale_bc', false, false);
    expect(app.user!['weight_kg'], 78.0);
    expect(app.user![kWeighedAtMs], at.millisecondsSinceEpoch);
    final saved = jsonDecode((await SharedPreferences.getInstance())
        .getString('local_profile_json')!) as Map;
    expect(saved['weight_kg'], 78.0, reason: 'the stored profile, not a copy');
    expect(bmiOf(app.user!['weight_kg'] as num, app.user!['height_cm'] as num),
        closeTo(25.2, 0.05));
    expect(await bmiScalesOf(await LocalDb.observationsForDay(_dayId)),
        {_scale});
    expect(await timelineNotes(),
        allOf(contains('Weight'), contains('Body impedance'), contains('BMI')));
    expect(await kcal(), greaterThan(kcal72),
        reason: 'the same heart rate costs more for 6 kg more body, with no '
            're-derive asked for');

    // Flag off again: the weight it handed over goes back (rule R6), and
    // calories with it; on again, it is adopted again.
    await WearableDisplay.instance
        .toggleDevice(_scale, 'miscale_bc', true, false);
    expect(app.user!['weight_kg'], 72.0);
    expect(await kcal(), kcal72);
    await WearableDisplay.instance
        .toggleDevice(_scale, 'miscale_bc', false, false);
    expect(app.user!['weight_kg'], 78.0);

    // Forgotten with its flag on: no paired scale holds the weighing, so the
    // weight goes back; paired again, it is adopted again.
    expect(await SessionLink.miScaleComposition.forget(_scale), isTrue);
    expect(app.user!['weight_kg'], 72.0);
    await LocalDb.upsertDevice(id: _scale, adapterId: 'miscale_bc');
    await SessionLink.onSessionDone!();
    expect(app.user!['weight_kg'], 78.0);

    // Once only: the next session's hook adopts nothing, and a weight typed
    // in after the weighing stays.
    await app.updateProfile({'weight_kg': 80.0});
    await SessionLink.onSessionDone!();
    expect(app.user!['weight_kg'], 80.0);

    // Someone else on the same scale: a newer 110 kg weighing is no
    // weighing of this user's, and the profile keeps 80.
    final later = DateTime.utc(2026, 10, 4, 21);
    const heavy = 22000;
    await SessionLink.miScaleComposition.ingestForTest(
      _scale,
      nowSeconds: () => SyntheticDay.sec(DateTime(2026, 10, 4, 22, 30)),
      pushes: [
        (kMiScaleBodyCompositionChar, [
          0x02, 0x22, later.year & 0xff, later.year >> 8, later.month,
          later.day, later.hour, later.minute, later.second, 0xF4, 0x01,
          heavy & 0xff, heavy >> 8,
        ]),
      ],
    );
    await SessionLink.onSessionDone!();
    expect(app.user!['weight_kg'], 80.0);
    // Nor does it get a BMI off this user's height.
    expect((await timelineNotes()).where((n) => n == 'BMI'), hasLength(1));
    await useDevice(_scale, 'miscale_bc', false);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
