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
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

/// Records where `runImport` sent each path instead of importing it. Every
/// override replaces work that needs a database and a derivation engine; the
/// routing decision above them is what is under test.
class _RoutingSpy extends AppState {
  _RoutingSpy() : super.forTesting();

  final noop = <String>[];
  final vendor = <String>[];

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
