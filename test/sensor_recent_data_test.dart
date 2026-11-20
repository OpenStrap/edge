import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart'
    show liveSources, sensorRowHasRecentData;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _App extends AppState {
  final List<Map<String, Object?>> rows;
  final Set<String> off;
  _App(this.rows, [this.off = const {}]) : super.forTesting();
  @override
  List<Map<String, Object?>> get sensors => rows;
  @override
  Set<String> get flagOffSensorIds => off;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000);
  const t = 1000000000;
  test('never synced, stale and fresh rows', () {
    expect(sensorRowHasRecentData({'first_seen': t - 100, 'last_seen': t - 100}, now: now), isFalse);
    expect(sensorRowHasRecentData({'first_seen': 1, 'last_seen': t - 90 * 86400}, now: now), isFalse);
    expect(sensorRowHasRecentData({'first_seen': 1, 'last_seen': t - 3600}, now: now), isTrue);
  });

  test('liveSources: only an unflagged ring with a recent sync is connected', () {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Map<String, Object?> row(String id, int seen) => {
          'id': id, 'adapter_id': 'oura', 'first_seen': 1, 'last_seen': seen,
        };
    final app = _App(
      [row('fresh', nowS - 60), row('stale', nowS - 90 * 86400), row('off', nowS - 60)],
      {'off'},
    );
    addTearDown(app.dispose);
    final c = {
      for (final s in liveSources(app).where((s) => !s.isBand)) s.deviceId: s.connected
    };
    expect(c, {'fresh': true, 'stale': false, 'off': false});
  });

  test('re-pairing a paired sensor does not move last_seen', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'sensor_recent_data_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    addTearDown(LocalDb.close);
    await LocalDb.upsertDevice(id: 'r1', adapterId: 'oura');
    final db = await LocalDb.instance;
    await db.rawUpdate('UPDATE device SET last_seen = 5, first_seen = 5');
    await LocalDb.upsertDevice(id: 'r1', adapterId: 'oura', label: 'Ring');
    expect((await LocalDb.deviceRow('r1'))!['last_seen'], 5);
  });
}
