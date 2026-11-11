// #625: the opt-in "log clear naps automatically" setting. Off, nothing is
// logged without a tap. On, only a pending nap at or above the confidence bar,
// ended after the switch was turned on, and settled behind the data edge, is
// confirmed exactly as detected. Everything else stays a suggestion.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';

void main() {
  late Database db;
  late ActivityStore store;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final start = now - 7200;
  final end = start + 1800;
  const settle = 300;

  Map<String, dynamic> nap(double confidence) => {
    'start': start,
    'end': end,
    'duration_min': 24,
    'in_bed_min': 30,
    'confidence': confidence,
  };

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'nap_auto_log_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': start - 1});
    store = ActivityStore(db);
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  Future<ActivitySuggestion> detect(double confidence) async =>
      (await store.reconcile(ActivityKind.nap, [nap(confidence)])).single;

  Future<void> run({int? since, int? edge}) => store.autoLogNaps(
    sinceSec: since,
    dataEdgeSec: edge ?? now,
    settleSec: settle,
  );

  Future<List<Map<String, Object?>>> logged() => db.query('sleep_nap');

  test('off: a clear nap stays a suggestion', () async {
    final s = await detect(0.85);
    await run(since: null);
    expect(await logged(), isEmpty);
    expect((await store.get(s.id))!.status, ActivityReviewStatus.pending);
  });

  test('on: a clear, settled nap is logged once, as detected', () async {
    final s = await detect(0.85);
    await run(since: start - 1);
    await run(since: start - 1);
    final rows = await logged();
    expect(rows, hasLength(1));
    expect(rows.single['start_ts'], start);
    expect(rows.single['end_ts'], end);
    expect(rows.single['source'], 'confirmed');
    final payload = jsonDecode(rows.single['payload_json'] as String) as Map;
    expect(payload['auto_logged'], true);
    expect(payload['duration_min'], 24);
    expect((await store.get(s.id))!.status, ActivityReviewStatus.confirmed);
  });

  test('a tap-confirmed nap is not marked as auto-logged', () async {
    final s = await detect(0.85);
    await store.confirm(s, startTs: start, endTs: end);
    final payload =
        jsonDecode((await logged()).single['payload_json'] as String) as Map;
    expect(payload.containsKey('auto_logged'), isFalse);
  });

  test('on: a nap below the bar stays a suggestion', () async {
    final s = await detect(0.79);
    await run(since: start - 1);
    expect(await logged(), isEmpty);
    expect((await store.get(s.id))!.status, ActivityReviewStatus.pending);
  });

  test('on: waits until the data edge is past the nap by the settle time',
      () async {
    await detect(0.85);
    await run(since: start - 1, edge: end + settle - 1);
    expect(await logged(), isEmpty);
    await run(since: start - 1, edge: end + settle);
    expect(await logged(), hasLength(1));
  });

  test('on: a nap that ended before the switch was turned on is left alone',
      () async {
    await detect(0.85);
    await run(since: end + 1);
    expect(await logged(), isEmpty);
  });

  test('on: a nap the user discarded is never logged', () async {
    final s = await detect(0.85);
    await store.discard(s);
    await store.reconcile(ActivityKind.nap, [nap(0.85)]);
    await run(since: start - 1);
    expect(await logged(), isEmpty);
  });

  test('only pending naps with a measured confidence qualify', () {
    ActivitySuggestion s(
      ActivityKind kind,
      Object? confidence, [
      ActivityReviewStatus status = ActivityReviewStatus.pending,
    ]) => ActivitySuggestion(
      id: 'x',
      kind: kind,
      startTs: start,
      endTs: end,
      revision: 0,
      status: status,
      details: {'confidence': confidence},
    );
    bool ok(ActivitySuggestion x) =>
        ActivityStore.napAutoLoggable(x, start - 1);
    expect(ok(s(ActivityKind.nap, 0.8)), isTrue);
    expect(ok(s(ActivityKind.nap, null)), isFalse);
    expect(ok(s(ActivityKind.workout, 0.85)), isFalse);
    expect(
      ok(s(ActivityKind.nap, 0.85, ActivityReviewStatus.discarded)),
      isFalse,
    );
    expect(
      ActivityStore.napAutoLoggable(s(ActivityKind.nap, 0.85), null),
      isFalse,
    );
  });
}
