import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';

void main() {
  late Database db;
  late ActivityStore store;
  final now = DateTime.now();
  final start = now.millisecondsSinceEpoch ~/ 1000 - 7200;
  final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start * 1000));
  Map<String, dynamic> candidate() => {
    'start': start,
    'end': start + 1800,
    'duration_min': 24,
  };
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'review_regressions.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 1});
    store = ActivityStore(db);
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  Future<void> result(String date, {bool absentSleep = false}) =>
      LocalDb.putDayResult(
        dayId: date,
        algoVersion: kAlgoVersion,
        windowJson: '{}',
        finalized: true,
        payloadJson: jsonEncode({
          'scalars': {'nap_min': 0},
          'naps': {'value': [], 'count': 0},
          if (absentSleep)
            'sleep': {
              'window': {'value': '—'},
            },
        }),
      );

  test('a normal absent sleep window permits new nap detection', () async {
    await result(day, absentSleep: true);
    expect(
      await store.reconcile(ActivityKind.nap, [candidate()]),
      hasLength(1),
    );
  });

  test('a normal absent sleep window permits confirmation', () async {
    final suggestion = (await store.reconcile(ActivityKind.nap, [
      candidate(),
    ])).single;
    await result(day, absentSleep: true);
    await store.confirm(
      suggestion,
      startTs: suggestion.startTs,
      endTs: suggestion.endTs,
    );
    expect(
      (await store.get(suggestion.id))!.status,
      ActivityReviewStatus.confirmed,
    );
  });

  for (final kind in ActivityKind.values) {
    test(
      '$kind review does not promote older metrics to a new algorithm',
      () async {
        final suggestion = (await store.reconcile(kind, [candidate()])).single;
        await LocalDb.putDayResult(
          dayId: day,
          algoVersion: kAlgoVersion - 2,
          finalized: true,
          rhr: 51,
          payloadJson: jsonEncode({
            'naps': {'value': [], 'count': 0},
            'scalars': {'rhr': 51, 'nap_min': 0},
          }),
          windowJson: '{}',
        );
        if (kind == ActivityKind.nap) {
          await store.confirm(suggestion, startTs: start, endTs: start + 1800);
        } else {
          await store.discard(suggestion);
        }
        for (var retry = 0; retry < 2; retry++) {
          await LocalDb.applyPendingActivityReviews();
          final row = (await LocalDb.dayResult(day))!;
          expect(row['algo_version'], kAlgoVersion - 2);
          expect(row['rhr'], 51);
          final bundle = jsonDecode(row['payload_json'] as String);
          expect(bundle['scalars']['rhr'], 51);
          expect(
            bundle['scalars']['nap_min'],
            kind == ActivityKind.nap ? 24 : 0,
          );
          expect(
            await LocalDb.finalizedDayIds(kAlgoVersion),
            isNot(contains(day)),
          );
          expect(
            await LocalDb.dayResultIds(kAlgoVersion),
            isNot(contains(day)),
          );
        }
      },
    );
  }

  test('retry after restart keeps an unassessed sleep total absent', () async {
    final suggestion = (await store.reconcile(ActivityKind.nap, [
      candidate(),
    ])).single;
    await store.confirm(suggestion, startTs: start, endTs: start + 1800);
    for (var retry = 0; retry < 3; retry++) {
      // Leave the job pending, as when cross-day refresh is interrupted.
      await LocalDb.applyPendingActivityReviews();
      final row = (await LocalDb.dayResult(day))!;
      final bundle = jsonDecode(row['payload_json'] as String);
      expect(bundle['scalars']['nap_min'], 24);
      expect(bundle['sleep_periods']['total_asleep_min'], isNull);
      expect(row['partial'], 1);
      expect(row['finalized'], 0);
      await LocalDb.close();
      db = await LocalDb.instance;
      store = ActivityStore(db);
    }
  });

  for (final assessed in [false, true]) {
    test(
      'review preserves sleep-total assessment=$assessed on retries',
      () async {
        await result(day);
        await db.update('day_result', {
          'payload_json': jsonEncode({
            'naps': {'value': [], 'count': 0},
            'scalars': {'nap_min': 0},
            'sleep_periods': {
              'periods': [
                {'is_main': true, 'duration_min': 420},
              ],
              'total_asleep_min': assessed ? 420 : null,
            },
          }),
        });
        await LocalDb.putNapEdit(
          dayId: day,
          startTs: start,
          endTs: start + 1800,
          source: 'manual',
        );
        for (var retry = 0; retry < 2; retry++) {
          await LocalDb.applyPendingActivityReviews();
          final bundle = jsonDecode(
            (await LocalDb.dayResult(day))!['payload_json'] as String,
          );
          expect(
            bundle['sleep_periods']['total_asleep_min'],
            assessed ? 450 : null,
          );
        }
      },
    );
  }

  test(
    'moving a nap onto a skipped day credits a partial, visible result',
    () async {
      final suggestion = (await store.reconcile(ActivityKind.nap, [
        candidate(),
      ])).single;
      final target = DateTime(now.year, now.month, now.day - 1, 13);
      final targetDay = dayLabelOf(target);
      final targetStart = target.millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putDayResult(
        dayId: targetDay,
        algoVersion: kAlgoVersion,
        finalized: true,
        skipped: true,
        payloadJson: jsonEncode({
          'skipped': true,
          'reason': 'missing raw records',
        }),
        windowJson: '{}',
      );
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      expect(await repo.availableDays(), isNot(contains(targetDay)));
      await store.confirm(
        suggestion,
        startTs: targetStart,
        endTs: targetStart + 1800,
        edited: true,
      );
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isTrue,
      );
      final row = (await LocalDb.dayResult(targetDay))!;
      final bundle = jsonDecode(row['payload_json'] as String);
      expect(row['skipped'], 0);
      expect(row['partial'], 1);
      expect(row['finalized'], 0);
      expect(row['rhr'], isNull);
      expect(bundle['skipped'], isNot(true));
      expect(bundle['sleep_periods']['total_asleep_min'], isNull);
      expect(bundle['scalars']['nap_min'], 30);
      expect(await repo.availableDays(), contains(targetDay));
      final input = jsonDecode(
        (await LocalDb.baseline('crossday_input'))!['payload_json'] as String,
      );
      final credited = (input['days'] as List).cast<Map>().singleWhere(
        (d) => d['date'] == targetDay,
      );
      expect(credited['nap_min'], 30);
      expect(
        await LocalDb.dayResultIds(kAlgoVersion),
        isNot(contains(targetDay)),
      );
      expect(await db.query('activity_review_days'), isEmpty);
    },
  );

  test('all refresh batches update the cross-day input', () async {
    final dates = <String>[];
    for (var i = 26; i >= 1; i--) {
      final date = DateTime(now.year, now.month, now.day - i, 13);
      final label = dayLabelOf(date);
      dates.add(label);
      await result(label);
      final ts = date.millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putNapEdit(
        dayId: label,
        startTs: ts,
        endTs: ts + 1800,
        source: 'manual',
      );
    }
    final engine = DerivationEngine();
    expect(await engine.refreshActivityReviews(const Profile()), isFalse);
    expect(await engine.refreshActivityReviews(const Profile()), isTrue);
    expect(await db.query('activity_review_days'), isEmpty);
    final input =
        jsonDecode(
              (await LocalDb.baseline('crossday_input'))!['payload_json']
                  as String,
            )
            as Map;
    final last = (input['days'] as List).cast<Map>().singleWhere(
      (d) => d['date'] == dates.last,
    );
    final row = (await db.query(
      'day_result',
      where: 'day_id = ?',
      whereArgs: [dates.last],
    )).single;
    expect(
      (jsonDecode(row['payload_json'] as String)['scalars'] as Map)['nap_min'],
      30,
    );
    expect(
      last['nap_min'],
      30,
      reason:
          'The refresh queue is drained but the cross-day input still has the old total',
    );
  });

  test(
    'applying a batch rejects summaries started before its day writes',
    () async {
      await result(day);
      await LocalDb.putNapEdit(
        dayId: day,
        startTs: start,
        endTs: start + 1800,
        source: 'manual',
      );
      final revision = await LocalDb.activityReviewRevision();
      final jobs = await LocalDb.applyPendingActivityReviews();
      expect(jobs, isNotEmpty);
      expect(
        await LocalDb.putReviewedBaseline('crossday_input', '{}', revision),
        isFalse,
      );
      expect(
        await LocalDb.putReviewedBaseline('crossday', '{}', revision),
        isFalse,
      );
      await LocalDb.finishActivityReviews(jobs);
      expect(await db.query('activity_review_days'), isEmpty);
    },
  );

  test(
    'restore keeps a local confirmation without adding the backup version',
    () async {
      final suggestion = (await store.reconcile(ActivityKind.nap, [
        candidate(),
      ])).single;
      final dir = Directory.systemTemp.createTempSync('review-merge-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pendingPath = p.join(dir.path, 'pending.db');
      await db.execute('VACUUM INTO ?', [pendingPath]);
      await store.confirm(suggestion, startTs: start, endTs: start + 1800);
      await result(day);
      final path = p.join(dir.path, 'confirmed.db');
      await db.execute('VACUUM INTO ?', [path]);
      // Another copy of this pending activity was confirmed at corrected times.
      await LocalDb.wipeAll();
      await LocalDb.importFromDbFile(pendingPath);
      await store.confirm(
        suggestion,
        startTs: start + 2400,
        endTs: start + 4200,
        edited: true,
      );
      await LocalDb.importFromDbFile(path);
      expect(
        (await store.get(suggestion.id))!.status,
        ActivityReviewStatus.confirmed,
      );
      expect(
        await db.query('sleep_nap'),
        hasLength(1),
        reason: 'Only the locally kept decision should create an accepted nap',
      );
      await LocalDb.applyPendingActivityReviews();
      final bundle = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String,
      );
      expect(bundle['scalars']['nap_min'], 30);
      // Repeating a restore must not bring back the other answer either.
      await LocalDb.importFromDbFile(path);
      expect(await db.query('sleep_nap'), hasLength(1));
    },
  );

  test(
    'restore cannot credit a nap whose local decision is discarded',
    () async {
      final suggestion = (await store.reconcile(ActivityKind.nap, [
        candidate(),
      ])).single;
      final dir = Directory.systemTemp.createTempSync('review-discard-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pendingPath = p.join(dir.path, 'pending.db');
      await db.execute('VACUUM INTO ?', [pendingPath]);
      await store.confirm(suggestion, startTs: start, endTs: start + 1800);
      await result(day);
      final acceptedPath = p.join(dir.path, 'accepted.db');
      await db.execute('VACUUM INTO ?', [acceptedPath]);
      await LocalDb.wipeAll();
      await LocalDb.importFromDbFile(pendingPath);
      await store.discard(suggestion);
      await DerivationEngine().refreshActivityReviews(const Profile());
      expect(await db.query('activity_review_days'), isEmpty);
      await LocalDb.importFromDbFile(acceptedPath);
      expect(
        (await store.get(suggestion.id))!.status,
        ActivityReviewStatus.discarded,
      );
      expect(await db.query('sleep_nap'), isEmpty);
      expect(await db.query('activity_review_days'), isNotEmpty);
      await LocalDb.applyPendingActivityReviews();
      final bundle = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String,
      );
      expect(bundle['naps']['value'], isEmpty);
      expect(bundle['scalars']['nap_min'], 0);
    },
  );

  test(
    'a backup without the suggestion ledger still restores manual naps',
    () async {
      await LocalDb.putNapEdit(
        dayId: day,
        startTs: start,
        endTs: start + 1800,
        source: 'manual',
      );
      final dir = Directory.systemTemp.createTempSync('review-legacy-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'legacy.db');
      await db.execute('VACUUM INTO ?', [path]);
      final backup = await openDatabase(path);
      await backup.execute('DROP TABLE activity_suggestions');
      await backup.close();
      await LocalDb.wipeAll();
      await LocalDb.importFromDbFile(path);
      expect((await db.query('sleep_nap')).single['source'], 'manual');
    },
  );

  for (final source in ['confirmed', 'legacy', 'unmigrated']) {
    test('$source nap survives removal, restart and Put it back', () async {
      final snapshot = {...candidate(), 'in_bed_min': 30, 'confidence': 0.7};
      if (source == 'confirmed') {
        final suggestion = (await store.reconcile(ActivityKind.nap, [
          snapshot,
        ])).single;
        await store.confirm(suggestion, startTs: start, endTs: start + 1800);
        await result(day);
      } else {
        await db.update('activity_review_meta', {'activated_at': start + 3600});
        await db.insert('day_result', {
          'day_id': day,
          'algo_version': kAlgoVersion - 1,
          'payload_json': jsonEncode({
            'naps': {
              'value': [snapshot],
              'count': 1,
            },
            'scalars': {'nap_min': 24},
          }),
          'computed_at': 1,
        });
        await ActivityStore.markDayChanged(db, day);
      }
      if (source != 'unmigrated') {
        final jobs = await LocalDb.applyPendingActivityReviews();
        await LocalDb.finishActivityReviews(jobs);
      }
      // These are the same writes used by NapsScreen's remove/restore actions.
      await LocalDb.putNapEdit(
        dayId: day,
        startTs: start,
        endTs: start + 1800,
        source: 'rejected',
      );
      var jobs = await LocalDb.applyPendingActivityReviews();
      await LocalDb.finishActivityReviews(jobs);
      var bundle = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String,
      );
      expect(bundle['naps']['value'], isEmpty);
      expect(bundle['scalars']['nap_min'], 0);

      if (source == 'confirmed') {
        final dir = Directory.systemTemp.createTempSync('removed-nap-restore-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = p.join(dir.path, 'removed.db');
        await db.execute('VACUUM INTO ?', [path]);
        await LocalDb.wipeAll();
        await LocalDb.importFromDbFile(path);
      }
      await LocalDb.close();
      db = await LocalDb.instance;
      store = ActivityStore(db);
      await LocalDb.deleteNapEdit(day, start);
      jobs = await LocalDb.applyPendingActivityReviews();
      await LocalDb.finishActivityReviews(jobs);
      bundle = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String,
      );
      expect(bundle['scalars']['nap_min'], 24);
      final restored = (bundle['naps']['value'] as List).single as Map;
      expect(restored['in_bed_min'], 30);
      expect(restored['confidence'], 0.7);
      expect(
        restored['source'],
        source == 'confirmed' ? 'confirmed' : 'legacy',
      );
      expect(await store.pending(), isEmpty);
      expect(await db.query('decoded_onehz'), isEmpty);
    });
  }

  test('deleting a manually logged nap still removes it permanently', () async {
    await result(day);
    await LocalDb.putNapEdit(
      dayId: day,
      startTs: start,
      endTs: start + 1800,
      source: 'manual',
    );
    await LocalDb.applyPendingActivityReviews();
    await LocalDb.deleteNapEdit(day, start);
    await LocalDb.applyPendingActivityReviews();
    expect(await LocalDb.napEdits(day), isEmpty);
    final bundle = jsonDecode(
      (await LocalDb.dayResult(day))!['payload_json'] as String,
    );
    expect(bundle['naps']['value'], isEmpty);
    expect(bundle['scalars']['nap_min'], 0);
  });

  for (final localDecision in ['discarded', 'confirmed', 'none']) {
    test('workout restore respects $localDecision local decision', () async {
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      final suggestion = (await store.reconcile(ActivityKind.workout, [
        {'start_ts': start, 'end_ts': start + 1800},
      ])).single;
      final dir = Directory.systemTemp.createTempSync('review-workout-merge-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pendingPath = p.join(dir.path, 'pending.db');
      await db.execute('VACUUM INTO ?', [pendingPath]);
      await repo.confirmActivity(suggestion);
      final confirmedPath = p.join(dir.path, 'confirmed.db');
      await db.execute('VACUUM INTO ?', [confirmedPath]);
      await LocalDb.wipeAll();
      if (localDecision != 'none') {
        await LocalDb.importFromDbFile(pendingPath);
        if (localDecision == 'discarded') {
          await store.discard(suggestion);
        } else {
          await repo.confirmActivity(
            suggestion,
            startTs: start + 2400,
            endTs: start + 4200,
            workoutType: 'walking',
          );
        }
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        await LocalDb.importFromDbFile(confirmedPath);
        final sessions = await db.query('sessions');
        if (localDecision == 'discarded') {
          expect(sessions, isEmpty);
          expect(
            (await store.get(suggestion.id))!.status,
            ActivityReviewStatus.discarded,
          );
        } else {
          expect(sessions, hasLength(1));
          expect(
            sessions.single['start_ts'],
            localDecision == 'confirmed' ? start + 2400 : start,
          );
          expect(
            sessions.single['type'],
            localDecision == 'confirmed' ? 'walking' : 'other',
          );
          expect(
            (await store.get(suggestion.id))!.status,
            ActivityReviewStatus.confirmed,
          );
        }
      }
    });
  }
}
