import 'dart:io';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'dart:convert';

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
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/tap_router.dart';

void main() {
  late Database db;
  late ActivityStore store;
  late LocalRepositoryImpl repo;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final start = now - 7200;
  final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start * 1000));
  Map<String, dynamic> nap([int delta = 0]) => {
    'start': start + delta,
    'end': start + 1800 + delta,
    'duration_min': 24,
    'in_bed_min': 30,
    'confidence': 0.6,
  };

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'activity_review_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': start - 1});
    store = ActivityStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  Future<ActivitySuggestion> detectNap() async =>
      (await store.reconcile(ActivityKind.nap, [nap()])).single;

  Future<void> dayResult({
    int? version,
    List<dynamic> naps = const [],
    String? source = 'band',
  }) async {
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: version ?? kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'rhr': 53, 'readiness': 74, 'nap_min': 0},
        'naps': {'value': naps, 'count': naps.length},
        'sleep_periods': {
          'periods': [
            {'is_main': true, 'duration_min': 420},
          ],
          'total_asleep_min': 420,
        },
      }),
      windowJson: '{}',
      finalized: true,
      source: source,
      rhr: 53,
      readiness: 74,
      series: {'rhr': 53, 'readiness': 74, 'nap_min': 0},
    );
  }

  test('a workout confirmation rechecks overlapping accepted naps', () async {
    final workout = (await store.reconcile(ActivityKind.workout, [
      {'start_ts': start, 'end_ts': start + 1800},
    ])).single;
    await LocalDb.putNapEdit(
      dayId: day,
      startTs: start + 300,
      endTs: start + 1500,
      source: 'manual',
    );
    await expectLater(
      repo.confirmActivity(workout),
      throwsA(isA<ActivityReviewException>()),
    );
    expect(await db.query('sessions'), isEmpty);
    expect((await store.get(workout.id))!.status, ActivityReviewStatus.pending);
  });

  test('schema repair is idempotent and cutoff is stable', () async {
    await ActivityStore.create(db);
    await ActivityStore.create(db);
    expect(
      (await db.query('activity_review_meta')).single['activated_at'],
      start - 1,
    );
    expect(
      (await db.rawQuery(
        'PRAGMA table_info(sleep_nap)',
      )).any((r) => r['name'] == 'payload_json'),
      isTrue,
    );
  });

  test(
    'schema 54 upgrades additively and retains dismissed legacy workouts',
    () async {
      await db.insert('workout_suggestions', {
        'id': 'legacy-upgrade',
        'date': day,
        'start_ts': start,
        'end_ts': start + 1800,
        'dismissed': 1,
        'created_at': 1,
      });
      for (final table in [
        'activity_suggestions',
        'activity_review_days',
        'activity_review_meta',
      ]) {
        await db.execute('DROP TABLE $table');
      }
      await db.execute('PRAGMA user_version = 54');
      await LocalDb.close();
      db = await LocalDb.instance;
      store = ActivityStore(db);
      expect(await db.getVersion(), 55);
      expect(await store.pending(), isEmpty);
      expect(
        (await store.get('legacy-upgrade'))!.status,
        ActivityReviewStatus.discarded,
      );
      expect(await db.query('workout_suggestions'), hasLength(1));
    },
  );

  test('a logged legacy nap wins before its first recompute', () async {
    await dayResult(version: kAlgoVersion - 1, naps: [nap()], source: null);
    expect(await LocalDb.napEdits(day), isEmpty);
    expect(
      await store.reconcile(ActivityKind.workout, [
        {'start_ts': start + 300, 'end_ts': start + 1500},
      ]),
      isEmpty,
    );
  });

  test('imported recordings cannot alert on a later normal derive', () async {
    final proposal = await detectNap();
    expect(await store.mayNotifyNew(proposal, nowTs: now), isTrue);
    final dir = Directory.systemTemp.createTempSync('activity-review-alert-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'backup.db');
    await db.execute('VACUUM INTO ?', [path]);
    await LocalDb.importFromDbFile(path);
    expect(await store.mayNotifyNew(proposal, nowTs: now), isFalse);
    expect(await store.pending(), hasLength(1));
  });

  test(
    'review refresh replaces a same-day cached input and survives failure',
    () async {
      await dayResult();
      final proposal = await detectNap();
      await LocalDb.putBaseline(
        'crossday_input',
        jsonEncode({
          'algo_version': kAlgoVersion,
          'built_for_day': todayLabel(),
          'review_revision': await LocalDb.activityReviewRevision(),
          'days': [
            {'date': day, 'nap_min': 0},
          ],
        }),
      );
      await repo.confirmActivity(proposal);
      // Fail the rollup read after the accepted day has been written. The job
      // must survive and the next run must replace, not reuse, the old cache.
      await db.execute('ALTER TABLE baselines RENAME TO unavailable_baselines');
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isFalse,
      );
      expect(await db.query('activity_review_days'), isNotEmpty);
      await db.execute('ALTER TABLE unavailable_baselines RENAME TO baselines');
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isTrue,
      );
      final input = jsonDecode(
        (await LocalDb.baseline('crossday_input'))!['payload_json'] as String,
      );
      expect((input['days'] as List).single['nap_min'], 24);
      expect(input['review_revision'], await LocalDb.activityReviewRevision());
      expect(await db.query('activity_review_days'), isEmpty);
    },
  );

  test(
    'an evening proposal cannot overlap next morning\'s main sleep',
    () async {
      final date = DateTime.now().subtract(const Duration(days: 3));
      final evening = DateTime(date.year, date.month, date.day, 23);
      final wake = DateTime(date.year, date.month, date.day + 1, 7);
      final s = evening.millisecondsSinceEpoch ~/ 1000;
      await db.update('activity_review_meta', {'activated_at': s - 1});
      await LocalDb.putDayResult(
        dayId: dayLabelOf(wake),
        algoVersion: kAlgoVersion,
        source: 'band',
        windowJson: '{}',
        payloadJson: jsonEncode({
          'sleep': {
            'window': {
              'value': {
                'onset_ms': evening.millisecondsSinceEpoch,
                'offset_ms': wake.millisecondsSinceEpoch,
              },
            },
          },
        }),
      );
      expect(
        await store.reconcile(ActivityKind.nap, [
          {'start': s + 300, 'end': s + 1800},
        ]),
        isEmpty,
      );
    },
  );

  test('cutoff uses activity time, not time imported', () async {
    await db.update('activity_review_meta', {'activated_at': now});
    expect(await store.reconcile(ActivityKind.nap, [nap()]), isEmpty);
    expect(await store.pending(), isEmpty);
  });

  test(
    'accepted snapshot survives missing day and raw records without invented metrics',
    () async {
      final suggestion = await detectNap();
      await repo.confirmActivity(suggestion);
      await LocalDb.applyPendingActivityReviews();
      final row = (await LocalDb.dayResult(day))!;
      final bundle = jsonDecode(row['payload_json'] as String);
      expect(bundle['scalars']['nap_min'], 24);
      expect(row['partial'], 1);
      expect(row['rhr'], isNull);
      expect(row['readiness'], isNull);
      expect(bundle['sleep_periods']['total_asleep_min'], isNull);
    },
  );

  test(
    'pending naps do not enter totals; confirm preserves estimated asleep minutes',
    () async {
      await dayResult();
      final s = await detectNap();
      await dayResult(
        naps: [nap()],
      ); // A stale compute must not count its detection.
      var bundle = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String,
      );
      expect(bundle['scalars']['nap_min'], 0);
      expect(await LocalDb.napEdits(day), isEmpty);
      await repo.confirmActivity(s);
      await LocalDb.applyPendingActivityReviews();
      bundle = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String,
      );
      expect(bundle['scalars']['nap_min'], 24);
      expect(bundle['sleep_periods']['total_asleep_min'], 444);
      expect(bundle['scalars']['rhr'], 53);
      expect(bundle['scalars']['readiness'], 74);
      expect(await store.pending(), isEmpty);
    },
  );

  test(
    'edit saves a user-reported window without invented confidence',
    () async {
      final s = await detectNap();
      await repo.confirmActivity(s, startTs: start + 300, endTs: start + 2700);
      final saved = (await LocalDb.napEdits(day)).single;
      expect(saved['source'], 'manual');
      expect(saved['payload_json'], isNull);
      expect(saved['end_ts'], start + 2700);
    },
  );

  test('discard survives changed bounds, sync and restart', () async {
    final s = await detectNap();
    await store.discard(s);
    expect(await store.reconcile(ActivityKind.nap, [nap(60)]), isEmpty);
    await LocalDb.close();
    store = ActivityStore(await LocalDb.instance);
    expect(await store.pending(), isEmpty);
    expect((await store.get(s.id))!.status, ActivityReviewStatus.discarded);
  });

  test(
    'pending keeps its ID, updates bounds and rejects a stale confirmation',
    () async {
      final before = await detectNap();
      expect(await store.reconcile(ActivityKind.nap, [nap(60)]), isEmpty);
      final after = (await store.pending()).single;
      expect(after.id, before.id);
      expect(after.startTs, start + 60);
      await expectLater(
        repo.confirmActivity(before),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await LocalDb.napEdits(day), isEmpty);
      await repo.confirmActivity(after);
      expect(await store.pending(), isEmpty);
    },
  );

  test('concurrent confirmations save exactly one nap', () async {
    final s = await detectNap();
    await Future.wait([repo.confirmActivity(s), repo.confirmActivity(s)]);
    expect(await LocalDb.napEdits(day), hasLength(1));
  });

  test('overlap or invalid times leave the suggestion pending', () async {
    final s = await detectNap();
    await expectLater(
      repo.confirmActivity(s, endTs: now + 3600),
      throwsA(isA<ActivityReviewException>()),
    );
    await LocalDb.putNapEdit(
      dayId: day,
      startTs: start + 60,
      endTs: start + 900,
      source: 'manual',
    );
    await expectLater(
      repo.confirmActivity(s),
      throwsA(isA<ActivityReviewException>()),
    );
    expect(await store.pending(), hasLength(1));
  });

  test('a manually logged workout supersedes pending detections', () async {
    await store.reconcile(ActivityKind.workout, [
      {'start_ts': start, 'end_ts': start + 1800},
    ]);
    await repo.logManualWorkout(
      startTs: start,
      endTs: start + 1800,
      type: 'other',
    );
    expect(await store.pending(), isEmpty);
    expect(
      await store.reconcile(ActivityKind.workout, [
        {'start_ts': start + 60, 'end_ts': start + 1900},
      ]),
      isEmpty,
    );
  });

  test(
    'workout confirmation after raw expiry saves times with absent metrics',
    () async {
      final s = (await store.reconcile(ActivityKind.workout, [
        {'start_ts': start, 'end_ts': start + 1800},
      ])).single;
      await repo.confirmActivity(s);
      final row = (await db.query('sessions')).single;
      expect(row['type'], 'other');
      expect(row['strain'], isNull);
      expect(row['calories'], isNull);
      await repo.confirmActivity(s);
      expect(await db.query('sessions'), hasLength(1));
    },
  );

  test(
    'legacy workout migration preserves IDs and decisions without new alerts',
    () async {
      await db.insert('workout_suggestions', {
        'id': 'legacy',
        'date': day,
        'start_ts': start,
        'end_ts': start + 1800,
        'dismissed': 1,
        'created_at': 1,
      });
      await store.migrateLegacy();
      expect(
        (await store.get('legacy'))!.status,
        ActivityReviewStatus.discarded,
      );
      expect(await store.pending(), isEmpty);
      expect(
        await store.reconcile(ActivityKind.workout, [
          {'start_ts': start + 120, 'end_ts': start + 1800},
        ]),
        isEmpty,
      );
    },
  );

  test('pre-upgrade logged naps survive an algorithm bump', () async {
    await db.update('activity_review_meta', {'activated_at': now});
    await dayResult(version: kAlgoVersion - 1, naps: [nap()], source: null);
    await dayResult();
    final bundle = jsonDecode(
      (await LocalDb.dayResult(day))!['payload_json'] as String,
    );
    expect(bundle['scalars']['nap_min'], 24);
    expect((await LocalDb.napEdits(day)).single['source'], 'legacy');
    expect(await store.pending(), isEmpty);
  });

  test('older refresh cannot clear a newer durable review job', () async {
    final s = await detectNap();
    await store.discard(s);
    final first = await LocalDb.applyPendingActivityReviews();
    await ActivityStore.markDayChanged(db, day);
    await LocalDb.finishActivityReviews(first);
    expect(await db.query('activity_review_days'), hasLength(1));
  });

  test(
    'backup round trip preserves decisions, snapshots, cutoff and refresh jobs',
    () async {
      await dayResult();
      final accepted = await detectNap();
      await repo.confirmActivity(accepted);
      final discarded = (await store.reconcile(ActivityKind.nap, [
        nap(3600),
      ])).single;
      await store.discard(discarded);
      final pending = (await store.reconcile(ActivityKind.workout, [
        {'start_ts': start + 6000, 'end_ts': start + 6600, 'sport': 'other'},
      ])).single;
      final before = await db.query('activity_suggestions', orderBy: 'id');
      final snapshot = Directory.systemTemp.createTempSync(
        'activity-review-restore-',
      );
      addTearDown(() => snapshot.deleteSync(recursive: true));
      final path = p.join(snapshot.path, 'backup.db');
      await db.execute('VACUUM INTO ?', [path]);
      await LocalDb.wipeAll();
      await LocalDb.importFromDbFile(path);
      expect(await db.query('activity_suggestions', orderBy: 'id'), before);
      expect((await store.pending()).single.id, pending.id);
      expect(
        (await store.get(accepted.id))!.status,
        ActivityReviewStatus.confirmed,
      );
      expect(
        (await db.query('activity_review_meta')).single['activated_at'],
        start - 1,
      );
      expect(
        (await LocalDb.napEdits(day)).single['payload_json'],
        contains('24'),
      );
      expect(await db.query('activity_review_days'), isNotEmpty);
      await LocalDb.applyPendingActivityReviews();
      expect(
        jsonDecode(
          (await LocalDb.dayResult(day))!['payload_json'] as String,
        )['scalars']['nap_min'],
        24,
      );
    },
  );

  test(
    'restoring an older pending snapshot cannot undo a local decision',
    () async {
      final suggestion = await detectNap();
      final dir = Directory.systemTemp.createTempSync('activity-review-stale-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'before.db');
      await db.execute('VACUUM INTO ?', [path]);
      await store.discard(suggestion);
      await LocalDb.importFromDbFile(path);
      expect(
        (await store.get(suggestion.id))!.status,
        ActivityReviewStatus.discarded,
      );
      expect(await store.pending(), isEmpty);
    },
  );

  test(
    'pending duplicates consolidate, stay resolved after shifts, and never expire',
    () async {
      final first = await detectNap();
      final second = (await store.reconcile(ActivityKind.nap, [
        nap(2400),
      ])).single;
      await store.reconcile(ActivityKind.nap, [
        {...nap(), 'end': start + 4200},
      ]);
      expect((await store.pending()).single.id, first.id);
      expect(
        (await store.get(second.id))!.status,
        ActivityReviewStatus.superseded,
      );
      await store.reconcile(ActivityKind.nap, [
        {...nap(60), 'end': start + 4260},
      ]);
      expect((await store.pending()).single.id, first.id);
      await store.reconcile(ActivityKind.nap, []);
      expect(await store.pending(), hasLength(1));
      await store.discard((await store.pending()).single);
      await store.reconcile(ActivityKind.nap, [nap(3000)]);
      expect(await store.pending(), isEmpty);
    },
  );

  test('stale cross-day output cannot overwrite a newer review', () async {
    final revision = await LocalDb.activityReviewRevision();
    await store.discard(await detectNap());
    expect(
      await LocalDb.putReviewedBaseline('crossday', '{}', revision),
      isFalse,
    );
    expect(await LocalDb.baseline('crossday'), isNull);
    expect(
      await LocalDb.putReviewedBaseline(
        'crossday',
        '{}',
        await LocalDb.activityReviewRevision(),
      ),
      isTrue,
    );
  });

  test(
    'midnight edits and a DST fold use elapsed seconds and local day labels',
    () async {
      tz_data.initializeTimeZones();
      final rome = tz.getLocation('Europe/Rome');
      final a = tz.TZDateTime(rome, 2025, 10, 26, 1, 30);
      final b = tz.TZDateTime(rome, 2025, 10, 26, 3, 30);
      final st = a.millisecondsSinceEpoch ~/ 1000,
          en = b.millisecondsSinceEpoch ~/ 1000;
      expect(en - st, 3 * 3600); // repeated hour is real elapsed sleep time
      await db.update('activity_review_meta', {'activated_at': st - 86400});
      final proposal = (await store.reconcile(ActivityKind.nap, [
        {'start': st, 'end': en, 'duration_min': 150},
      ])).single;
      await repo.confirmActivity(proposal, startTs: st - 2 * 3600, endTs: en);
      final label = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch((st - 2 * 3600) * 1000),
      );
      final row = (await LocalDb.napEdits(label)).single;
      expect((row['end_ts'] as int) - (row['start_ts'] as int), 5 * 3600);
      expect(await db.query('activity_review_days'), hasLength(2));
    },
  );

  test(
    'raw cleanup never removes pending items, decisions or accepted naps',
    () async {
      final accepted = await detectNap();
      await repo.confirmActivity(accepted);
      await store.reconcile(ActivityKind.nap, [nap(3600)]);
      await LocalDb.pruneDecodedBeforeRecTs(now);
      await LocalDb.close();
      store = ActivityStore(await LocalDb.instance);
      expect(await store.pending(), hasLength(1));
      expect(
        (await store.get(accepted.id))!.status,
        ActivityReviewStatus.confirmed,
      );
      expect(await LocalDb.napEdits(day), hasLength(1));
    },
  );

  test(
    'alerts are optional, independent of weekly lookback, and respect quiet hours',
    () {
      NotificationEvent event(String kind) => NotificationEvent(
        dedupeKey: kind,
        category: NotifCategory.reminders,
        priority: NotifPriority.normal,
        title: '',
        body: '',
        date: day,
        route: activitySuggestionRoute('a', kind),
      );
      const defaults = NotificationPrefs(
        remindersEnabled: false,
        quietEnabled: false,
      );
      expect(defaults.shouldFireOs(event('workout'), 720), isTrue);
      expect(defaults.shouldFireOs(event('nap'), 720), isFalse);
      expect(
        defaults
            .copyWith(napDetectEnabled: true)
            .shouldFireOs(event('nap'), 720),
        isTrue,
      );
      expect(
        defaults
            .copyWith(quietEnabled: true)
            .shouldFireOs(event('workout'), 23 * 60),
        isFalse,
      );
      expect(
        resolveTapRoute(activitySuggestionRoute('a', 'nap')).screen,
        contains('id=a'),
      );
    },
  );
}
