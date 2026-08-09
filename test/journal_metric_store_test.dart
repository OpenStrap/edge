// journal_metric round-trip: the numeric half of a journal entry.
//
// The behaviour worth pinning is the destructive one. `putJournalMetrics`
// treats the map it is given as THE day, not a patch on it, so a field the
// user cleared is deleted rather than left behind. A stale "3 coffees"
// surviving an edit becomes a reading nobody made, and it lands in a
// correlation as if it were real.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `exportDaysDb` writes into the temp directory, which is a platform channel.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_journal_metric_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    LocalDb.dbName = 'openstrap_journal_metric_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('journal_metric');
    await db.delete('journal_field_def');
  });

  test('a day round-trips, time included', () async {
    await LocalDb.putJournalMetrics('2026-06-01', {
      'mood': const JournalMetricValue(4),
      'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 855),
    });

    final back = await LocalDb.journalMetricsForDay('2026-06-01');
    expect(back['mood'], const JournalMetricValue(4));
    expect(back['caffeine_mg']!.value, 200);
    expect(back['caffeine_mg']!.atMinuteOfDay, 855);
  });

  test('a zero is stored as a real reading', () async {
    // "No caffeine today" is an answer. It has to survive a round trip as 0
    // and not come back as absent.
    await LocalDb.putJournalMetrics('2026-06-01', {
      'caffeine_mg': const JournalMetricValue(0),
    });
    final back = await LocalDb.journalMetricsForDay('2026-06-01');
    expect(back.containsKey('caffeine_mg'), isTrue);
    expect(back['caffeine_mg']!.value, 0);
  });

  test('a field left out of the map is cleared, not merged', () async {
    await LocalDb.putJournalMetrics('2026-06-01', {
      'mood': const JournalMetricValue(4),
      'water_ml': const JournalMetricValue(2000),
    });
    // The user cleared water and re-saved.
    await LocalDb.putJournalMetrics('2026-06-01', {
      'mood': const JournalMetricValue(4),
    });

    final back = await LocalDb.journalMetricsForDay('2026-06-01');
    expect(back.keys, ['mood']);
    expect(
      back.containsKey('water_ml'),
      isFalse,
      reason: 'a cleared field must not survive as a reading nobody made',
    );
  });

  test('saving one day never touches another', () async {
    await LocalDb.putJournalMetrics('2026-06-01', {
      'mood': const JournalMetricValue(2),
    });
    await LocalDb.putJournalMetrics('2026-06-02', {
      'mood': const JournalMetricValue(5),
    });

    expect((await LocalDb.journalMetricsForDay('2026-06-01'))['mood']!.value, 2);
    expect((await LocalDb.journalMetricsForDay('2026-06-02'))['mood']!.value, 5);
  });

  test('an empty map clears the day', () async {
    await LocalDb.putJournalMetrics('2026-06-01', {
      'mood': const JournalMetricValue(3),
    });
    await LocalDb.putJournalMetrics('2026-06-01', const {});
    expect(await LocalDb.journalMetricsForDay('2026-06-01'), isEmpty);
  });

  test('a day never recorded reads as empty, not as an error', () async {
    expect(await LocalDb.journalMetricsForDay('1999-01-01'), isEmpty);
  });

  test('the correlation read groups by day, oldest first', () async {
    await LocalDb.putJournalMetrics('2026-06-03', {
      'mood': const JournalMetricValue(1),
    });
    await LocalDb.putJournalMetrics('2026-06-01', {
      'mood': const JournalMetricValue(3),
      'water_ml': const JournalMetricValue(1500),
    });
    await LocalDb.putJournalMetrics('2026-06-02', {
      'mood': const JournalMetricValue(2),
    });

    final all = await LocalDb.journalMetricsByDay();
    expect(all.keys.toList(), ['2026-06-01', '2026-06-02', '2026-06-03']);
    expect(all['2026-06-01']!.keys.toSet(), {'mood', 'water_ml'});

    final since = await LocalDb.journalMetricsByDay(
      sinceDaysEpoch: '2026-06-02',
    );
    expect(since.keys.toList(), ['2026-06-02', '2026-06-03']);
  });

  test('field names are remembered across days', () async {
    // So a user-invented field keeps appearing in the editor after the day it
    // was invented on.
    await LocalDb.putJournalMetrics('2026-06-01', {
      'custom_magnesium': const JournalMetricValue(400),
    });
    await LocalDb.putJournalMetrics('2026-06-02', {
      'mood': const JournalMetricValue(3),
    });
    expect(await LocalDb.journalMetricFields(), [
      'custom_magnesium',
      'mood',
    ]);
  });

  test('a day export carries the custom definitions, not just the numbers',
      () async {
    // The definitions are not day-scoped, so without an explicit copy an
    // exported day holds values under `custom_magnesium` with no label, no
    // unit and no scale — the numbers survive and their meaning does not.
    await LocalDb.putJournalFieldDef(const JournalFieldSpec(
      key: 'custom_magnesium',
      label: 'Magnesium',
      kind: JournalFieldKind.dose,
      unit: 'mg',
      max: 1000,
      step: 50,
      custom: true,
    ));
    await LocalDb.putJournalMetrics('2026-06-01', {
      'custom_magnesium': const JournalMetricValue(400),
    });

    final path = await LocalDb.exportDaysDb({'2026-06-01'});
    final exported = await databaseFactory.openDatabase(path);
    try {
      final metrics = await exported.query('journal_metric');
      expect(metrics.single['field'], 'custom_magnesium');
      final defs = await exported.query('journal_field_def');
      expect(defs.single['label'], 'Magnesium');
      expect(defs.single['unit'], 'mg');
    } finally {
      await exported.close();
    }
  });

  group('custom field definitions', () {
    const spec = JournalFieldSpec(
      key: 'custom_magnesium',
      label: 'Magnesium',
      kind: JournalFieldKind.dose,
      unit: 'mg',
      max: 1000,
      step: 50,
      hasTime: true,
      custom: true,
    );

    test('round-trip preserves every part of the definition', () async {
      await LocalDb.putJournalFieldDef(spec);
      final back = (await LocalDb.journalFieldDefs()).single;
      expect(back.key, spec.key);
      expect(back.label, spec.label);
      expect(back.kind, JournalFieldKind.dose);
      expect(back.unit, 'mg');
      expect(back.max, 1000);
      expect(back.step, 50);
      expect(back.hasTime, isTrue);
      expect(back.custom, isTrue, reason: 'a stored def is always a custom');
    });

    test('deleting a definition keeps its readings', () async {
      await LocalDb.putJournalFieldDef(spec);
      await LocalDb.putJournalMetrics('2026-06-01', {
        'custom_magnesium': const JournalMetricValue(400),
      });

      await LocalDb.deleteJournalFieldDef(spec.key);

      expect(await LocalDb.journalFieldDefs(), isEmpty);
      expect(
        (await LocalDb.journalMetricsForDay('2026-06-01'))['custom_magnesium']
            ?.value,
        400,
        reason: 'forgetting a label must not delete history',
      );
    });

    test('an unknown kind from a newer build degrades instead of throwing',
        () async {
      final db = await LocalDb.instance;
      await db.insert('journal_field_def', {
        'key': 'custom_future',
        'label': 'From the future',
        'kind': 'something_new',
        'unit': 'x',
        'max_value': 10.0,
        'step': 1.0,
        'has_time': 0,
        'created_at': 0,
      });
      // One unreadable row must not take the whole journal screen down.
      final back = await LocalDb.journalFieldDefs();
      expect(back.single.kind, JournalFieldKind.dose);
    });
  });
}
