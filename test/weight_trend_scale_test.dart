// The weight trend merges scale weighings with the journal's manual weight.
// Pins: one value per LOCAL day, the later of journal/scale wins, a flag-off
// scale and an out-of-band (someone else's) weighing never reach the line.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/measurement_inputs.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

int _ms(int d, int h, [int m = 0]) =>
    DateTime(2026, 10, d, h, m).millisecondsSinceEpoch;

/// `weightByDay` with a fixed clock after every fixture reading, so the
/// future-dated filter never depends on the date the tests run.
Map<String, double> _byDay(
  Map<String, Map<String, JournalMetricValue>> manual,
  List<({double kg, int atMs})> scaled, {
  int? nowMs,
  int fromMs = 0,
}) => weightByDay(manual, scaled, nowMs: nowMs ?? _ms(30, 0), fromMs: fromMs);

({double kg, int atMs}) _w(double kg, int atMs) => (kg: kg, atMs: atMs);

Map<String, Map<String, JournalMetricValue>> _j(
  String day,
  double kg, [
  int? atMin,
]) => {
  day: {'weight_kg': JournalMetricValue(kg, atMinuteOfDay: atMin)},
};

void main() {
  group('weightByDay', () {
    test('scale-only day', () {
      expect(_byDay({}, [_w(80, _ms(3, 7))]), {'2026-10-03': 80.0});
    });

    test('manual-only day', () {
      expect(_byDay(_j('2026-10-03', 79.5), []), {'2026-10-03': 79.5});
    });

    test('no data stays absent', () {
      expect(_byDay({}, []), isEmpty);
    });

    test('latest weighing of the day stands for it', () {
      expect(_byDay({}, [_w(81, _ms(3, 20)), _w(80, _ms(3, 7))]), {
        '2026-10-03': 81.0,
      });
    });

    test('both on one day: the later one wins', () {
      // Scale at 07:00 (420), journal at 21:00 (1260): journal is later.
      expect(_byDay(_j('2026-10-03', 79, 1260), [_w(80, _ms(3, 7))]), {
        '2026-10-03': 79.0,
      });
      // Journal at 06:00, scale at 07:00: scale is later.
      expect(_byDay(_j('2026-10-03', 79, 360), [_w(80, _ms(3, 7))]), {
        '2026-10-03': 80.0,
      });
      // Journal without a time: the scale wins.
      expect(_byDay(_j('2026-10-03', 79), [_w(80, _ms(3, 7))]), {
        '2026-10-03': 80.0,
      });
    });

    test('a gradual 95 to 80 kg loss keeps every weighing', () {
      final ws = [
        for (var i = 0; i < 16; i++)
          _w(95.0 - i, _ms(1, 7) + i * 86400000),
      ];
      expect(_byDay({}, ws).length, 16);
    });

    test('a household outlier amid ~80 kg is dropped', () {
      final out = _byDay({}, [
        _w(80, _ms(3, 7)),
        _w(120, _ms(4, 7)),
        _w(79.5, _ms(5, 7)),
      ]);
      expect(out, {'2026-10-03': 80.0, '2026-10-05': 79.5});
    });

    test('a guest seeding the chain does not lock the user out', () {
      final out = _byDay({}, [
        _w(20, _ms(1, 7)),
        _w(70, _ms(2, 7)),
        _w(71, _ms(3, 7)),
        _w(70, _ms(4, 7)),
      ]);
      expect(out['2026-10-02'], 70.0);
      expect(out['2026-10-03'], 71.0);
      expect(out['2026-10-04'], 70.0);
    });

    test('a lasting step in weight re-seeds after three weighings', () {
      final out = _byDay({}, [
        _w(90, _ms(1, 7)),
        _w(79, _ms(2, 7)),
        _w(79, _ms(3, 7)),
        _w(80, _ms(4, 7)),
        _w(80, _ms(5, 7)),
      ]);
      expect(out, {
        '2026-10-01': 90.0,
        '2026-10-02': 79.0,
        '2026-10-03': 79.0,
        '2026-10-04': 80.0,
        '2026-10-05': 80.0,
      });
    });

    test('a lone outlier or a two-weighing run stays dropped', () {
      final lone = _byDay({}, [
        _w(70, _ms(1, 7)),
        _w(120, _ms(2, 7)),
        _w(71, _ms(3, 7)),
      ]);
      expect(lone, {'2026-10-01': 70.0, '2026-10-03': 71.0});
      final two = _byDay({}, [
        _w(70, _ms(1, 7)),
        _w(120, _ms(2, 7)),
        _w(121, _ms(3, 7)),
        _w(71, _ms(4, 7)),
      ]);
      expect(two, {'2026-10-01': 70.0, '2026-10-04': 71.0});
    });

    test('three unrelated outliers do not re-seed', () {
      final out = _byDay({}, [
        _w(70, _ms(1, 7)),
        _w(120, _ms(2, 7)),
        _w(40, _ms(3, 7)),
        _w(120, _ms(4, 7)),
        _w(71, _ms(5, 7)),
      ]);
      expect(out, {'2026-10-01': 70.0, '2026-10-05': 71.0});
    });

    test('readings before the window anchor the chain; only the window plots',
        () {
      final ws = [
        _w(70, _ms(1, 7)),
        _w(70, _ms(2, 7)),
        _w(30, _ms(5, 7)),
        _w(71, _ms(6, 7)),
      ];
      // The window opens on the 4th: the 30 kg reading is judged against the
      // earlier 70 kg history, not allowed to seed a chain of its own.
      expect(_byDay({}, ws, fromMs: _ms(4, 0)), {'2026-10-06': 71.0});
      // Moving the window start must not change a day that is still inside it.
      expect(_byDay({}, ws, fromMs: _ms(5, 0)), {'2026-10-06': 71.0});
    });

    test('weighings dated after now are dropped', () {
      final out = _byDay(
        {},
        [_w(80, _ms(3, 7)), _w(80, _ms(9, 7))],
        nowMs: _ms(5, 7),
      );
      expect(out, {'2026-10-03': 80.0});
    });

    test('buckets by local day near midnight', () {
      final out = _byDay({}, [
        _w(80, DateTime(2026, 10, 3, 23, 59).millisecondsSinceEpoch),
        _w(81, DateTime(2026, 10, 4, 0, 1).millisecondsSinceEpoch),
      ]);
      expect(out, {'2026-10-03': 80.0, '2026-10-04': 81.0});
    });
  });

  group('weighings gate', () {
    late Directory tmp;
    const scale = 'scale-1';

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = await Directory.systemTemp.createTemp('openstrap_weight_trend_');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      LocalDb.dbName = 'openstrap_weight_trend_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(id: scale, adapterId: 'miscale_bc');
      for (final (d, kg) in [(3, 78.0), (4, 120.0)]) {
        await LocalDb.putObservation(
          Observation(
            sourceKind: ObservationSource.vendor,
            key: 'weight',
            value: kg,
            unit: 'kg',
            attribution: 'Mi Scale',
            at: DateTime(2026, 10, d, 7),
          ),
          deviceId: scale,
        );
      }
    });

    tearDownAll(() async {
      await LocalDb.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('flag off: excluded; flag on: only in-band weighings', () async {
      await LocalDb.setCursor(wearableEnabledCursor('miscale_bc'), '0');
      expect(await weighings(near: 80), isEmpty);

      await LocalDb.setCursor(wearableEnabledCursor('miscale_bc'), '1');
      final w = await weighings(near: 80); // 120 kg is outside the band
      expect([for (final x in w) x.kg], [78.0]);
      expect(w.single.atMs, _ms(3, 7));
      // No profile weight: nothing to compare against, both count.
      expect((await weighings()).length, 2);
    });
  });
}
