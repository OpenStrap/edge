import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/file_log.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _SlowPaths extends PathProviderPlatform {
  _SlowPaths(this.docs);
  final String docs;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return docs;
  }
}

void main() {
  test('lines written while the log dir resolves are not dropped', () async {
    final dir = await Directory.systemTemp.createTemp('openstrap_filelog_');
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _SlowPaths(dir.path);

    await Future.wait([for (var i = 0; i < 20; i++) FileLog.write('line $i')]);

    final lines = await File('${dir.path}/openstrap_sync.log').readAsLines();
    expect(lines, [for (var i = 0; i < 20; i++) 'line $i']);
  });
}
