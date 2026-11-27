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

  test('chart values: NaN and Infinity read as gaps, so the chat still saves', () {
    final c = ChartSpec.tryParse({
      'series': [
        {'name': 's', 'values': ['NaN', 'Infinity', '-Infinity', 62]},
      ],
    })!;
    expect(c.series.single.values, [null, null, null, 62.0]);
    expect(() => jsonEncode(c.toJson()), returnsNormally);
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

  test('a chat file missing from a valid index is still listed', () async {
    final dir = await _documents();
    final engine = _engine();
    await File('${dir.path}/coach_s_local_1000-aa.json').writeAsString(jsonEncode(
        {'title': 'a', 'createdAt': 1000, 'updatedAt': 1000, 'history': [], 'transcript': []}));
    await File('${dir.path}/coach_s_local_2000-bb.json').writeAsString(jsonEncode(
        {'title': 'b', 'createdAt': 2000, 'updatedAt': 2000, 'history': [], 'transcript': []}));
    await File('${dir.path}/coach_idx_local.json').writeAsString(jsonEncode([
      {'id': '1000-aa', 'title': 'a', 'updatedAt': 1000, 'preview': ''},
    ]));

    final metas = await engine.listSessions();
    expect(metas.map((m) => m.id), ['2000-bb', '1000-aa']);
  });

  test('two engines on one chat keep both turns', () async {
    final dir = await _documents();
    final a = _engine();
    a.transcript.add(CoachItem.user('first'));
    await a.persist();
    final id = a.sessionId;

    // A second screen opens the same chat, then both add a turn.
    final b = _engine();
    await b.restore();
    expect(b.sessionId, id);
    a.transcript.add(CoachItem.user('from a'));
    b.transcript.add(CoachItem.user('from b'));
    await a.persist();
    await b.persist();

    expect(b.sessionId, isNot(id));
    final texts = <String>[];
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.startsWith('coach_s_') || !name.endsWith('.json')) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map;
      texts.addAll([for (final t in j['transcript'] as List) (t as Map)['text'] as String]);
    }
    expect(texts, containsAll(['from a', 'from b']));
    expect((await b.listSessions()).length, 2);
  });
}

Future<Directory> _documents() async {
  final dir = await Directory.systemTemp.createTemp('coach-files-');
  final original = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _DocumentsProvider(dir.path);
  addTearDown(() async {
    PathProviderPlatform.instance = original;
    await dir.delete(recursive: true);
  });
  SharedPreferences.setMockInitialValues({});
  return dir;
}

CoachEngine _engine() {
  final config = CoachConfig();
  addTearDown(config.dispose);
  final engine = CoachEngine(config: config, api: _FakeRepo(), storageKey: 'local');
  addTearDown(engine.dispose);
  return engine;
}
