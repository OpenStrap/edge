// A file that throws partway through a multi-select must not take the files
// before it down with it: no plaintext backup left in the temp directory, and
// no lost report for rows that already landed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _Spy extends AppState {
  _Spy() : super.forTesting();
  int noopCalls = 0;
  final vendor = <String>[];

  @override
  Future<int> importEdgeBackup(String path) async => 1;

  @override
  Future<int> importNoopCsv(String path,
      {void Function(int days)? onProgress}) async {
    if (++noopCalls == 2) throw const FileSystemException('disk full');
    return 3;
  }

  @override
  Future<int> importWhoopCsvs(List<String> paths,
      {void Function(int days)? onProgress}) async {
    vendor.addAll(paths);
    return 1;
  }
}

const _noopCsv = 'unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z\n'
    '1754000000,2026-08-01T00:00:00Z,hr,61,,,,\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp, scratch;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('import_partial_');
    scratch = await Directory('${tmp.path}/t').create();
    PathProviderPlatform.instance = _FakePathProvider(scratch.path);
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('a non-format throw on a later backup shreds the earlier plaintext',
      () async {
    final plain = File('${tmp.path}/plain.db')..writeAsStringSync('history');
    final enc = <String>[];
    for (final n in ['a', 'b']) {
      final f = File('${tmp.path}/$n.osbak');
      await encryptBackupFile(plain, f, 'pw', iterations: 1000);
      enc.add(f.path);
    }
    var asks = 0;
    await expectLater(
      runImport(_Spy(), enc, askPassphrase: () async {
        if (++asks == 2) throw const FileSystemException('evicted');
        return 'pw';
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect(asks, 2);
    expect(scratch.listSync(), isEmpty);
  });

  test('a raw file that throws keeps the counts and the later groups',
      () async {
    Future<String> write(String name, String body) async {
      final f = File('${tmp.path}/$name')..writeAsBytesSync(utf8.encode(body));
      return f.path;
    }

    final app = _Spy();
    final a = await write('a.csv', _noopCsv);
    final b = await write('b.csv', _noopCsv);
    final v = await write('v.bin', 'junk');

    final out = await runImport(app, [a, b, v]);

    expect(out.days, 3 + 1);
    expect(out.readError, contains('disk full'));
    expect(app.vendor, [v]);
    expect(out.error, isNull);
  });
}
