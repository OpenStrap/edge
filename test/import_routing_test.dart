// Issues #160 / #199: the onboarding router picked an importer by FILE
// EXTENSION, and got it wrong in both directions at once.
//
//   • NOOP's Android "raw sensor CSV" export is a plain `.csv`, so it went to
//     the vendor importer, which told the user to re-download it with WHOOP
//     set to English. (That is the exact file attached to #160.)
//   • A WHOOP "My Data" export is a `.zip` of CSVs — the shape WHOOP actually
//     gives you — so it went to the NOOP importer, which refused it for
//     holding too many CSVs.
//
// Both files were fine. Both were refused, each with advice meant for the
// other one. These tests drive the real `runImport` and assert WHICH importer
// each shape reaches, so neither direction can come back.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/import/import_container.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

/// Records where `runImport` sent each path instead of importing it. Every
/// override replaces work that needs a database and a derivation engine; the
/// routing decision above them is what is under test.
class _RoutingSpy extends AppState {
  _RoutingSpy() : super.forTesting();

  final noop = <String>[];
  final vendor = <String>[];
  final backup = <String>[];

  @override
  Future<int> importEdgeBackup(String path) async {
    backup.add(path);
    return 1;
  }

  @override
  Future<int> importNoopCsv(String path,
      {void Function(int days)? onProgress}) async {
    noop.add(path);
    return 1;
  }

  @override
  Future<int> importWhoopCsvs(List<String> paths,
      {void Function(int days)? onProgress}) async {
    vendor.addAll(paths);
    return 1;
  }
}

class _ThrowingVendor extends _RoutingSpy {
  @override
  Future<int> importWhoopCsvs(List<String> paths,
      {void Function(int days)? onProgress}) async {
    vendor.addAll(paths);
    throw const FormatException('no recognised files');
  }
}

List<int> _zipOf(Map<String, String> members) {
  final a = Archive();
  members.forEach((name, body) {
    final bytes = utf8.encode(body);
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(a);
}

/// The header row a real NOOP raw-sensor export starts with (NOOP 9.1/9.2, as
/// observed on the #160 attachment).
const _noopCsv = 'unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z\n'
    '1754000000,2026-08-01T00:00:00Z,hr,61,,,,\n';

/// A WHOOP "My Data" export, which is several named CSVs in one archive.
const _whoopZipMembers = {
  'physiological_cycles.csv': 'Cycle start time,Recovery score %\n',
  'sleeps.csv': 'Cycle start time,Sleep performance %\n',
  'workouts.csv': 'Workout start time,Activity name\n',
  'journal_entries.csv': 'Cycle start time,Question text\n',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('import_routing_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<String> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('a NOOP raw-sensor CSV goes to the NOOP importer, not the vendor one',
      () async {
    final app = _RoutingSpy();
    final path = await write('noop-export.csv', utf8.encode(_noopCsv));

    final out = await runImport(app, [path]);

    expect(app.noop, [path]);
    expect(app.vendor, isEmpty,
        reason: 'this is the #160 file — the vendor importer answers it with '
            '"re-download it with WHOOP set to English"');
    expect(out.source, contains('Raw sensor export'));
  });

  test('a WHOOP My Data ZIP goes to the vendor importer, not the NOOP one',
      () async {
    final app = _RoutingSpy();
    final path = await write('my_whoop_data.zip', _zipOf(_whoopZipMembers));

    final out = await runImport(app, [path]);

    expect(app.vendor, [path]);
    expect(app.noop, isEmpty,
        reason: 'the NOOP importer refuses this for holding too many CSVs');
    expect(out.source, contains('Vendor CSV export'));
  });

  test('a .noopbak still routes to NOOP once the name stops deciding',
      () async {
    final app = _RoutingSpy();
    // The real shape: a ZIP whose member is NOOP's own SQLite database. The
    // magic is what identifies it, so the bytes have to be real.
    final path = await write(
      'backup.noopbak',
      _zipOf({'noop-backup.sqlite': 'SQLite format 3\x00 and then some rows'}),
    );

    await runImport(app, [path]);

    expect(app.noop, [path]);
    expect(app.vendor, isEmpty);
  });

  test('a NOOP CSV keeps routing to NOOP when someone zips it first', () async {
    final app = _RoutingSpy();
    final path =
        await write('noop.zip', _zipOf({'raw_sensor.csv': _noopCsv}));

    await runImport(app, [path]);

    expect(app.noop, [path]);
    expect(app.vendor, isEmpty);
  });

  // #606: the app's own backup, renamed on its way through Drive or a file
  // manager, was a SQLite file the NOOP path claimed: "That database is not a
  // NOOP backup — it has no `hrSample` table".
  group('own backup by content', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    Future<String> sqlite(String name, List<String> tables) async {
      final path = '${tmp.path}/$name';
      final db = await openDatabase(path, singleInstance: false);
      for (final t in tables) {
        await db.execute('CREATE TABLE $t (id INTEGER PRIMARY KEY)');
      }
      await db.close();
      return path;
    }

    const ours = ['samples', 'baselines', 'day_result'];

    test('a renamed backup goes to the backup importer', () async {
      final app = _RoutingSpy();
      final path = await sqlite('openstrap-backup (1)', ours);

      final out = await runImport(app, [path]);

      expect(app.backup, [path]);
      expect(app.noop, isEmpty, reason: 'this is the #606 refusal');
      expect(out.source, contains('OpenStrap backup'));
    });

    test('a renamed gzipped auto-backup goes to the backup importer',
        () async {
      final app = _RoutingSpy();
      final plain = await sqlite('auto', ['samples', 'baselines', 'derived_day']);
      final path = await write(
          'backup-2026-10-18.gz', gzip.encode(File(plain).readAsBytesSync()));

      await runImport(app, [path]);

      expect(app.backup, [path]);
      expect(app.noop, isEmpty);
      expect(app.vendor, isEmpty);
    });

    test('a bare NOOP database still goes to the NOOP importer', () async {
      final app = _RoutingSpy();
      final path = await sqlite('noop-backup.sqlite', ['hrSample', ...ours]);

      await runImport(app, [path]);

      expect(app.noop, [path]);
      expect(app.backup, isEmpty);
    });

    test('one generic table name does not make a database ours', () async {
      final app = _RoutingSpy();
      final path = await sqlite('someone-elses.sqlite', ['samples']);

      await runImport(app, [path]);

      expect(app.backup, isEmpty,
          reason: 'its rows would be merged into the user\'s history');
    });

    test('a file that vanished reports a failed inspection, not a throw',
        () async {
      expect(await isEdgeBackup('${tmp.path}/gone.sqlite'), isNull);
    });

    test('a database that will not open is not sent to the NOOP importer',
        () async {
      final app = _RoutingSpy();
      final path = await write('broken.sqlite',
          [...utf8.encode('SQLite format 3\x00'), ...List.filled(200, 7)]);

      await runImport(app, [path]);

      expect(app.noop, isEmpty,
          reason: 'the NOOP check claims every SQLite file');
      expect(app.vendor, [path]);
    });

    test('a vanished file after a backup does not lose the backup counts',
        () async {
      final app = _RoutingSpy();
      final good = await write('mine.db', utf8.encode('x'));

      final out = await runImport(app, [good, '${tmp.path}/gone.bin']);

      expect(app.backup, [good]);
      expect(out.days, greaterThan(0));
    });

    test('a file named .db is still ours without being opened', () async {
      final app = _RoutingSpy();
      final path = await write('damaged.db', utf8.encode('not a database'));

      await runImport(app, [path]);

      expect(app.backup, [path],
          reason: 'the backup importer owns the message for a damaged backup');
    });
  });

  test('a journal export re-saved as cp1252 is named, not handed to the '
      'vendor importer', () async {
    final app = _RoutingSpy();
    final journal = await write('journal.csv',
        latin1.encode('date,tags,note\n2026-08-01,,caf\u00e9\n'));
    final whoopPath = await write('whoop.zip', _zipOf(_whoopZipMembers));

    final out = await runImport(app, [journal, whoopPath]);

    expect(app.vendor, [whoopPath]);
    expect(out.rejectedRows.single, contains('journal.csv'));
    expect(out.rejectedRows.single, contains('UTF-8'));
  });

  test('a quoted, padded header is still recognised as our journal export',
      () async {
    final app = _RoutingSpy();
    final journal = await write('journal.csv',
        latin1.encode('date," tags ",note\n2026-08-01,,caf\u00e9\n'));

    final out = await runImport(app, [journal]);

    expect(app.vendor, isEmpty);
    expect(out.rejectedRows.single, contains('UTF-8'));
  });

  test('the encoding note survives a vendor file nothing could read',
      () async {
    final app = _ThrowingVendor();
    final journal = await write('journal.csv',
        latin1.encode('date,tags,note\n2026-08-01,,caf\u00e9\n'));
    final junk = await write('junk.csv', utf8.encode('a,b\n1,2\n'));

    final out = await runImport(app, [journal, junk]);

    expect(out.rejectedRows.single, contains('UTF-8'));
    expect(out.readError, contains('no recognised files'));
  });

  test('a cp1252 CSV that is not ours still goes to the vendor importer',
      () async {
    final app = _RoutingSpy();
    final path = await write('cycles.csv',
        latin1.encode('Cycle start time,Recovery score %\ncaf\u00e9,1\n'));

    await runImport(app, [path]);

    expect(app.vendor, [path]);
  });

  test('a mixed selection reaches both importers', () async {
    final app = _RoutingSpy();
    final noopPath = await write('noop-export.csv', utf8.encode(_noopCsv));
    final whoopPath = await write('whoop.zip', _zipOf(_whoopZipMembers));

    final out = await runImport(app, [noopPath, whoopPath]);

    expect(app.noop, [noopPath]);
    expect(app.vendor, [whoopPath]);
    expect(out.source, contains('Raw sensor export'));
    expect(out.source, contains('Vendor CSV export'));
  });
}
