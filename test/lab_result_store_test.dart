// lab_result storage.
//
// Two things matter more than the CRUD. A result is keyed on (marker, date
// drawn), so re-entering a value CORRECTS the typo rather than stacking a
// second reading a chart would then average. And each row carries its own
// unit, so a value keeps the unit it was entered under even if the catalogue's
// canonical unit changes later — silently reinterpreting 400 ng/mL as
// 400 nmol/L would be the worst kind of fabrication this app can make.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_lab_result_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async => LocalDb.close());

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('lab_result');
    await db.delete('lab_marker_def');
  });

  test('a result round-trips', () async {
    await LocalDb.putLabResult(
      marker: 'ferritin',
      takenOn: '2026-03-04',
      value: 42,
      unit: 'ng/mL',
      note: 'fasted',
    );
    final rows = await LocalDb.labResults();
    expect(rows, hasLength(1));
    expect(rows.single['marker'], 'ferritin');
    expect(rows.single['value'], 42.0);
    expect(rows.single['unit'], 'ng/mL');
    expect(rows.single['note'], 'fasted');
  });

  test('re-entering the same draw corrects it instead of duplicating', () async {
    await LocalDb.putLabResult(
      marker: 'ferritin',
      takenOn: '2026-03-04',
      value: 420,
      unit: 'ng/mL',
    );
    await LocalDb.putLabResult(
      marker: 'ferritin',
      takenOn: '2026-03-04',
      value: 42,
      unit: 'ng/mL',
    );
    final rows = await LocalDb.labResults(marker: 'ferritin');
    expect(rows, hasLength(1), reason: 'a typo must not become a data point');
    expect(rows.single['value'], 42.0);
  });

  test('two draws of the same marker are two rows', () async {
    await LocalDb.putLabResult(
      marker: 'ferritin',
      takenOn: '2026-03-04',
      value: 42,
      unit: 'ng/mL',
    );
    await LocalDb.putLabResult(
      marker: 'ferritin',
      takenOn: '2026-09-04',
      value: 61,
      unit: 'ng/mL',
    );
    final rows = await LocalDb.labResults(marker: 'ferritin');
    expect(rows.map((r) => r['taken_on']), ['2026-09-04', '2026-03-04'],
        reason: 'newest draw first');
  });

  test('markers do not collide with each other', () async {
    await LocalDb.putLabResult(
      marker: 'ferritin',
      takenOn: '2026-03-04',
      value: 42,
      unit: 'ng/mL',
    );
    await LocalDb.putLabResult(
      marker: 'hba1c',
      takenOn: '2026-03-04',
      value: 5.2,
      unit: '%',
    );
    expect(await LocalDb.labResults(), hasLength(2));
    expect(await LocalDb.labResults(marker: 'hba1c'), hasLength(1));
  });

  test('a row keeps the unit it was entered under', () async {
    // Even if the catalogue later changes its canonical unit, the stored
    // reading must not be reinterpreted.
    await LocalDb.putLabResult(
      marker: 'custom_lp_a',
      takenOn: '2026-03-04',
      value: 90,
      unit: 'nmol/L',
    );
    expect(
      (await LocalDb.labResults(marker: 'custom_lp_a')).single['unit'],
      'nmol/L',
    );
  });

  test('deleting removes only that draw', () async {
    for (final d in ['2026-03-04', '2026-09-04']) {
      await LocalDb.putLabResult(
        marker: 'ferritin',
        takenOn: d,
        value: 42,
        unit: 'ng/mL',
      );
    }
    await LocalDb.deleteLabResult('ferritin', '2026-03-04');
    final rows = await LocalDb.labResults(marker: 'ferritin');
    expect(rows.map((r) => r['taken_on']), ['2026-09-04']);
  });

  group('custom marker definitions', () {
    test('round-trip, and no reference range is invented', () async {
      await LocalDb.putLabMarkerDef({
        'key': customLabMarkerKey('Lp(a)'),
        'label': 'Lp(a)',
        'unit': 'nmol/L',
        'category': LabCategory.lipids.name,
        'decimals': 0,
        'ref_low': null,
        'ref_high': null,
      });
      final defs = await LocalDb.labMarkerDefs();
      expect(defs.single['key'], 'custom_lp_a');
      expect(defs.single['unit'], 'nmol/L');
      expect(
        defs.single['ref_low'],
        isNull,
        reason: 'a marker the app knows nothing about gets no verdict',
      );
    });

    test('deleting a definition keeps the readings', () async {
      await LocalDb.putLabMarkerDef({
        'key': 'custom_lp_a',
        'label': 'Lp(a)',
        'unit': 'nmol/L',
        'category': LabCategory.lipids.name,
        'decimals': 0,
      });
      await LocalDb.putLabResult(
        marker: 'custom_lp_a',
        takenOn: '2026-03-04',
        value: 90,
        unit: 'nmol/L',
      );

      await LocalDb.deleteLabMarkerDef('custom_lp_a');

      expect(await LocalDb.labMarkerDefs(), isEmpty);
      final rows = await LocalDb.labResults(marker: 'custom_lp_a');
      expect(rows, hasLength(1));
      expect(
        rows.single['unit'],
        'nmol/L',
        reason: 'the row carries its own unit, so it stays readable',
      );
    });
  });
}
