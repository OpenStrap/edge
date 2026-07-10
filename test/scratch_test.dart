import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    Directory(dir).createSync(recursive: true);
    final dbPath = p.join(dir, 'test_export_null_profile.db');
    File('/Users/abdulsahil-garden/Downloads/openstrap_export_1783651054606.db').copySync(dbPath);
    LocalDb.dbName = 'test_export_null_profile.db';
    await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  test('Run derivation engine and catch error', () async {
    final de = DerivationEngine();
    try {
      await de.run(const Profile(), force: true);
      print('Engine run completed');
      
      final repo = LocalRepository();
      final today = await repo.getToday();
      print('Today readiness: ${today.readiness}');
      
      final db = await sqlite3.open('/Users/abdulsahil-garden/Downloads/openstrap_export_1783651054606.db');
      final results = db.select('SELECT day_id, readiness, payload_json FROM day_result');
      for (final r in results) {
        print('DAY ${r['day_id']}:');
        print('  readiness DB: ${r['readiness']}');
        print('  payload: ${r['payload_json']}');
      }
    } catch (e, s) {
      print('Engine crashed: $e');
      print(s);
    }
  });
}
