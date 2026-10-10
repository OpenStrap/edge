// "It got it wrong" corrections are stored as user overrides and must outlive
// a full re-analysis: the force pass re-runs detection and replays it through
// the same reconcile / nap-edit / sleep-override seams these tests drive.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/theme.dart';

void main() {
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
  Map<String, dynamic> workout([int delta = 0]) => {
    'start_ts': start + delta,
    'end_ts': start + 2400 + delta,
    'sport': 'Running',
  };

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'corrections_persist_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    final db = await LocalDb.instance;
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

  Future<void> restart() async {
    await LocalDb.close();
    store = ActivityStore(await LocalDb.instance);
  }

  test('"Not a workout" survives re-detection with moved edges and a restart',
      () async {
    final s = (await store.reconcile(ActivityKind.workout, [workout()])).single;
    await repo.discardActivity(s);
    await restart();
    // Re-analyse all: the detector runs again and its edges drift.
    expect(await store.reconcile(ActivityKind.workout, [workout(120)]), isEmpty);
    expect(await store.reconcile(ActivityKind.workout, [workout(-90)]), isEmpty);
    expect(await store.pending(), isEmpty);
    expect((await store.get(s.id))!.status, ActivityReviewStatus.discarded);
  });

  test('"Not a nap" on a confirmed nap removes it and is not re-offered',
      () async {
    final s = (await store.reconcile(ActivityKind.nap, [nap()])).single;
    await repo.confirmActivity(s);
    final saved = (await LocalDb.napEdits(day)).single;
    await LocalDb.putNapEdit(
      dayId: day,
      startTs: saved['start_ts'] as int,
      endTs: saved['end_ts'] as int,
      source: 'rejected',
    );
    await restart();
    expect(await store.reconcile(ActivityKind.nap, [nap(60)]), isEmpty);
    expect(await store.pending(), isEmpty);
    final edits = await ActivityStore.napEdits(await LocalDb.instance, day);
    expect(edits.single.kind, NapEditKind.rejected);
    // Replayed over a fresh detection, the window stays out of the day.
    expect(applyNapEdits([nap(60)], edits), isEmpty);
    expect(LocalDb.napEditDays(), completion(contains(day)));
  });

  test('"Not sleep" and "I was asleep" stay as overrides every pass reads',
      () async {
    const rejectedDay = '2026-01-10', addedDay = '2026-01-11';
    await LocalDb.putSleepOverride(
      dayId: rejectedDay,
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'rejected',
    );
    await LocalDb.putSleepOverride(
      dayId: addedDay,
      onsetTs: 3000,
      offsetTs: 30000,
      source: 'manual',
    );
    await restart();
    // The force pass pulls these days back in even when finalized and stages
    // each from its row (derive_prepare_test covers the staging itself).
    expect(await LocalDb.sleepOverrideDays(), {rejectedDay, addedDay});
    expect((await LocalDb.getSleepOverride(rejectedDay))!['source'], 'rejected');
    expect((await LocalDb.getSleepOverride(addedDay))!['offset_ts'], 30000);
  });

  group('proposal card says what the correction means', () {
    Future<void> pump(WidgetTester t, ActivityKind kind, Locale locale) =>
        t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ActivityProposalCard(
              suggestion: ActivitySuggestion(
                id: 'x',
                kind: kind,
                startTs: start,
                endTs: start + 1800,
                revision: 0,
              ),
              onConfirm: () {},
              onEdit: () {},
              onDiscard: () {},
            ),
          ),
        ));

    testWidgets('workout: not a workout, change sport', (t) async {
      await pump(t, ActivityKind.workout, const Locale('en'));
      expect(find.text('Not a workout'), findsOneWidget);
      expect(find.text('Change sport'), findsOneWidget);
      expect(find.text('Discard'), findsNothing);
    });

    testWidgets('nap: not a nap, edit', (t) async {
      await pump(t, ActivityKind.nap, const Locale('en'));
      expect(find.text('Not a nap'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('russian', (t) async {
      await pump(t, ActivityKind.workout, const Locale('ru'));
      expect(find.text('Не тренировка'), findsOneWidget);
      expect(find.text('Сменить вид спорта'), findsOneWidget);
    });
  });
}
