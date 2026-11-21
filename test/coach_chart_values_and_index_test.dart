// Chart string values that are not one plain number read as absent, and a
// truncated chat index is rebuilt from the chat files instead of emptied.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo extends LocalRepository {}

class _DocumentsProvider extends PathProviderPlatform {
  _DocumentsProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('chart values: only a single plain number is read', () {
    final c = ChartSpec.tryParse({
      'series': [
        {
          'name': 's',
          'values': ['62', '62 ms', '62ms', '-3.5', '12,345', '7:30', '1.2k', '2h 15m', 'n/a'],
        },
      ],
    })!;
    expect(c.series.single.values,
        [62.0, 62.0, 62.0, -3.5, null, null, null, null, null]);
  });

  test('truncated index is rebuilt from chat files, not emptied', () async {
    final dir = await Directory.systemTemp.createTemp('coach-index-');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DocumentsProvider(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      await dir.delete(recursive: true);
    });

    SharedPreferences.setMockInitialValues({});
    final config = CoachConfig();
    addTearDown(config.dispose);
    final engine = CoachEngine(config: config, api: _FakeRepo(), storageKey: 'local');
    addTearDown(engine.dispose);
    const key = 'local';
    for (final (id, at) in [('1000-aa', 1000), ('2000-bb', 2000)]) {
      await File('${dir.path}/coach_s_${key}_$id.json').writeAsString(jsonEncode(
          {'title': 'chat $id', 'createdAt': at, 'updatedAt': at, 'history': [], 'transcript': []}));
    }
    await File('${dir.path}/coach_idx_$key.json').writeAsString('[{"id":"1000-a');

    final metas = await engine.listSessions();
    expect(metas.map((m) => m.id), ['2000-bb', '1000-aa']);
  });
}
