// A Garmin watch synced more than once: a sleep file read again as it grows,
// two monitoring files for one day, a vendor write that fails, the derive a
// sync must queue, and the words its numbers are shown with. Each case runs
// the real Garmin link, host and sqlite (GarminLink.ingestForTest).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/garmin_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/garmin_watch.dart';
import 'support/synthetic_day.dart';

const String _day = '2026-10-04';
int _sec(DateTime t) => SyntheticDay.sec(t);

/// A sleep file: each (start, level) begins a stage; [end] closes the last.
Uint8List _sleepFile(List<(DateTime, int)> levels, DateTime end) {
  final w = FitWriter()
    ..define(0, kFitMsgSleepLevel, [(253, 4, 0x86), (0, 1, 0x00)]);
  for (final (t, level) in levels) {
    w.data(0, [...u32le(fitSec(_sec(t))), level]);
  }
  return (w..data(0, [...u32le(fitSec(_sec(end))), 0xff])).build();
}

/// A monitoring file carrying one SpO2 and one respiration sample at [t].
Uint8List _monitorFile(DateTime t, int spo2, double resp) => (FitWriter()
      ..define(2, kFitMsgSpo2Data, [(253, 4, 0x86), (0, 1, 0x02)])
      ..define(3, kFitMsgRespirationRate, [(253, 4, 0x86), (0, 2, 0x84)])
      ..data(2, [...u32le(fitSec(_sec(t))), spo2])
      ..data(3, [...u32le(fitSec(_sec(t))), ...u16le((resp * 100).round())]))
    .build();

/// A monitoring file whose last walking record, at [t], counts [cycles].
Uint8List _stepsFile(DateTime t, int cycles) => (FitWriter()
      ..define(0, kFitMsgMonitoring, [(253, 4, 0x86), (5, 1, 0x00), (3, 4, 0x86)])
      ..data(0, [...u32le(fitSec(_sec(t))), 6, ...u32le(cycles)]))
    .build();

Future<void> _sync(String id, Map<int, (int, int, Uint8List)> files) async {
  await GarminLink.instance.ingestForTest(id, GarminWatchScript(files).reply,
      nowSeconds: () => _sec(DateTime(2026, 10, 4, 22, 30)));
}

Future<void> _watch(String id) async {
  await LocalDb.upsertDevice(
      id: id, adapterId: 'garmin', remoteId: 'AA:BB:CC:00:00:09', label: id);
  await LocalDb.setCursor(kActiveWearableCursor, id);
  await LocalDb.setCursor(wearableEnabledCursor('garmin'), '1');
}

const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

Future<num> _served(String row) async =>
    (await dayCells(_day))![row]!['value'] as num;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'garmin_sync_fixes_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    BandHost.onWearableStored = null;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a sleep file read again as it grows replaces its stage minutes',
      () async {
    const id = 'garmin-regrow';
    await _watch(id);
    final onset = DateTime(2026, 10, 3, 23);
    // A sync at 02:00, mid-night: 60 deep minutes so far.
    await _sync(id, {
      2: (kGarminFitSleep, _sec(DateTime(2026, 10, 4, 2)),
          _sleepFile([(onset, 2), (DateTime(2026, 10, 4, 1), 3)],
              DateTime(2026, 10, 4, 2))),
    });
    expect(await _served('sleep_stages'), 60);
    // The same file after the night: 90 deep minutes in all, not 60 + 90.
    await _sync(id, {
      2: (kGarminFitSleep, _sec(DateTime(2026, 10, 4, 7)),
          _sleepFile([
            (onset, 2),
            (DateTime(2026, 10, 4, 1), 3),
            (DateTime(2026, 10, 4, 2, 30), 2),
          ], DateTime(2026, 10, 4, 7))),
    });
    expect(await _served('sleep_stages'), 90);
  });

  test("two monitoring files of one day: the day's mean is both files'",
      () async {
    const id = 'garmin-two-files';
    await _watch(id);
    await _sync(id, {
      1: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 8)),
          _monitorFile(DateTime(2026, 10, 4, 8), 90, 12)),
      4: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 16)),
          _monitorFile(DateTime(2026, 10, 4, 16), 98, 16)),
    });
    expect(await _served('spo2'), 94);
    expect(await _served('respiratory_rate'), 14);
  });

  test("the day timeline lists the watch's split mean once, and not its "
      'stress index', () async {
    const id = 'garmin-two-files';
    final db = await LocalDb.instance;
    await db.insert('observation', {
      'device_id': id,
      'ts_ms': DateTime(2026, 10, 4, 12).millisecondsSinceEpoch,
      'date': _day,
      'source_kind': 'device',
      'vendor_key': 'stress_avg',
      'value': 31,
      'unit': '',
      'attribution': 'Garmin',
    });
    final rows = [
      for (final r
          in await timelineObservations(await LocalDb.observationsForDay(_day)))
        if (r['device_id'] == id) r,
    ];
    expect({for (final r in rows) r['vendor_key']: r['value']},
        {'spo2_avg': 94, 'respiration_avg': 14});
    expect(rows, hasLength(2));
  });

  test("an earlier monitoring file read after a later one keeps the day's "
      'larger step total', () async {
    const id = 'garmin-steps-reread';
    await _watch(id);
    final files = {
      1: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 12)),
          _stepsFile(DateTime(2026, 10, 4, 11, 59), 2880)),
      4: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 22)),
          _stepsFile(DateTime(2026, 10, 4, 21, 59), 5280)),
    };
    // The morning's file is refused past the retries: only the evening's
    // is read this sync, and the next reads the morning's alone.
    await GarminLink.instance.ingestForTest(
        id, GarminWatchScript(files, notReady: {1: 99}).reply,
        nowSeconds: () => _sec(DateTime(2026, 10, 4, 22, 30)));
    expect(await _served('steps'), 5280);
    await _sync(id, files);
    expect(await _served('steps'), 5280);
  });

  test('a failed vendor write leaves the file unread, so the next sync '
      'banks it', () async {
    const id = 'garmin-write-fails';
    await _watch(id);
    final files = {
      1: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 9)),
          _monitorFile(DateTime(2026, 10, 4, 9), 95, 15)),
    };
    final db = await LocalDb.instance;
    // The write fails; the read of the stored step totals before it does not.
    await db.execute('CREATE TRIGGER observation_off BEFORE INSERT ON '
        "observation BEGIN SELECT RAISE(ABORT, 'off'); END");
    try {
      await _sync(id, files);
    } finally {
      await db.execute('DROP TRIGGER observation_off');
    }
    expect(await LocalDb.getCursor('garmin_fit_files:$id'), isNull,
        reason: 'the bookmark must not outrun the numbers');
    await _sync(id, files);
    expect(await LocalDb.getCursor('garmin_fit_files:$id'), isNotNull);
    expect(await _served('spo2'), 95);
  });

  test("a sync that banked something queues a derive of the watch's days",
      () async {
    const id = 'garmin-derive';
    await _watch(id);
    var pokes = 0;
    BandHost.onWearableStored = () => pokes++;
    await _sync(id, {
      1: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 10)),
          _monitorFile(DateTime(2026, 10, 4, 10), 96, 14)),
    });
    expect(pokes, 1);
    // Headless (no app to poke): the job is queued for the app to drain.
    BandHost.onWearableStored = null;
    final db = await LocalDb.instance;
    await db.delete('compute_jobs');
    await _sync(id, {
      1: (kGarminFitMonitor, _sec(DateTime(2026, 10, 4, 11)),
          _monitorFile(DateTime(2026, 10, 4, 11), 96, 14)),
    });
    expect(
        await db.query('compute_jobs',
            where: 'state = ? AND type = ?',
            whereArgs: ['queued', 'derive_heavy']),
        isNotEmpty);
  });

  test('a sync that banks several days derives every one of them', () async {
    const id = 'garmin-days';
    await _watch(id);
    BandHost.onWearableStored = null;
    final db = await LocalDb.instance;
    await db.delete('compute_jobs');
    await _sync(id,
        SyntheticDay.garminDays([for (final d in [28, 29]) SyntheticDay(DateTime(2026, 9, d))]));
    // Drain the queued job the way the scheduler does.
    final job = (await LocalDb.takeNextComputeJob())!;
    await DerivationEngine().run(_profile,
        heavy: job['type'] == 'derive_heavy');
    for (final day in ['2026-09-28', '2026-09-29']) {
      expect(await LocalDb.dayResult(day), isNotNull, reason: day);
    }
  });

  test("a nap's sleep file on the night's date adds nothing to the night's "
      'stage minutes', () async {
    const id = 'garmin-nap';
    await _watch(id);
    BandHost.onWearableStored = null;
    final truth = SyntheticDay(DateTime(2026, 9, 20));
    await _sync(id, {
      ...SyntheticDay.garminDays([truth]),
      // 14:00 to 14:30 deep, the night's date.
      10: (kGarminFitSleep, _sec(DateTime(2026, 9, 20, 14, 30)),
          _sleepFile([(DateTime(2026, 9, 20, 14), 3)],
              DateTime(2026, 9, 20, 14, 30))),
    });
    await DerivationEngine().runDays(_profile, {'2026-09-20'}, force: true);
    final cells = (await dayCells('2026-09-20'))!;
    expect(cells['sleep_stages']!['value'], truth.deepMin);
    // The day timeline lists the night's deep minutes once, as the cell.
    final deep = [
      for (final r in await timelineObservations(
          await LocalDb.observationsForDay('2026-09-20'),
          date: '2026-09-20'))
        if (r['device_id'] == id && r['vendor_key'] == 'sleep_deep_min')
          r['value'],
    ];
    expect(deep, [truth.deepMin]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a second watch's stage rows on the timeline are its own files', "
      "not the active watch's night", () async {
    // Runs after the nap case: garmin-nap is active and 2026-09-20 is its.
    const id = 'garmin-nap-other';
    await LocalDb.upsertDevice(
        id: id, adapterId: 'garmin', remoteId: 'AA:BB:CC:00:00:0A', label: id);
    await _sync(id, {
      1: (kGarminFitSleep, _sec(DateTime(2026, 9, 20, 14, 30)),
          _sleepFile([(DateTime(2026, 9, 20, 14), 3)],
              DateTime(2026, 9, 20, 14, 30))),
      2: (kGarminFitSleep, _sec(DateTime(2026, 9, 20, 16, 20)),
          _sleepFile([(DateTime(2026, 9, 20, 16), 3)],
              DateTime(2026, 9, 20, 16, 20))),
    });
    final deep = [
      for (final r in await timelineObservations(
          await LocalDb.observationsForDay('2026-09-20'),
          date: '2026-09-20'))
        if (r['device_id'] == id && r['vendor_key'] == 'sleep_deep_min')
          r['value'],
    ];
    expect(deep, [30, 20]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("on a day the band derived, the watch's stage rows are its files', "
      'not their sum', () async {
    const id = 'garmin-nap';
    const day = '2026-09-21';
    await LocalDb.putDayResult(
        dayId: day,
        algoVersion: 1,
        payloadJson: jsonEncode({'device_family': 'gen4'}),
        windowJson: '{}');
    await _sync(id, {
      11: (kGarminFitSleep, _sec(DateTime(2026, 9, 21, 14, 30)),
          _sleepFile([(DateTime(2026, 9, 21, 14), 3)],
              DateTime(2026, 9, 21, 14, 30))),
      12: (kGarminFitSleep, _sec(DateTime(2026, 9, 21, 16, 20)),
          _sleepFile([(DateTime(2026, 9, 21, 16), 3)],
              DateTime(2026, 9, 21, 16, 20))),
    });
    expect(await dayCells(day), isNull);
    final deep = [
      for (final r in await timelineObservations(
          await LocalDb.observationsForDay(day),
          date: day))
        if (r['device_id'] == id && r['vendor_key'] == 'sleep_deep_min')
          r['value'],
    ];
    expect(deep, [30, 20]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a vendor row on the day timeline reads as words, to one decimal",
      () {
    expect(observationTitle('respiration_avg'), 'Respiration avg');
    expect(observationTitle('BioCharge'), 'BioCharge');
    expect(observationValue(14.333333333333334), '14.3');
    expect(observationValue(96.0), '96');
  });

  test("a value off a strap's beats names the strap", () {
    final l = lookupAppLocalizations(const Locale('en'));
    expect(sourceLine(l, MetricClass.ours, 'rr_strap', 'Garmin watch'),
        contains('strap'));
  });

  test('a failed Garmin sync does not call the watch a ring', () {
    final src = File('lib/ui2/profile/devices.dart').readAsStringSync();
    final body = src.substring(src.indexOf('Future<void> _syncGarminWatch'));
    final fn = body.substring(0, body.indexOf('\n}\n'));
    expect(fn, isNot(contains('devicesCouldNotReachRing')));
  });

  testWidgets("the watch's page on a day the band derived says so, not blank",
      (t) async {
    const id = 'garmin-band-day';
    await t.runAsync(() async {
      await _watch(id);
      await LocalDb.putDayResult(
          dayId: todayLabel(),
          algoVersion: 1,
          payloadJson: jsonEncode({'device_family': 'gen4'}),
          windowJson: '{}');
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const WearableDayScreen(deviceId: id, adapterId: 'garmin'),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pump();
    final l = lookupAppLocalizations(const Locale('en'));
    // The band's day never becomes the watch's: not "yet".
    expect(find.text(l.wearableBandDayTitle), findsOneWidget);
    expect(find.text(l.wearableNoDayTitle), findsNothing);
  });
}
