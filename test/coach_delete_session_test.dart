// Deleting a chat and the history budget, both against the real engine.
//
// A chat deleted while its reply was still coming in was written back by the
// save that followed the reply, and a delete could interleave with a save
// already writing. The history budget counted characters while the limit and
// the request check are in bytes, so non-ASCII history slipped through.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

Future<Directory> _documents() async {
  final dir = await Directory.systemTemp.createTemp('coach-delete-');
  final original = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _DocumentsProvider(dir.path);
  addTearDown(() async {
    PathProviderPlatform.instance = original;
    await dir.delete(recursive: true);
  });
  return dir;
}

Map<String, dynamic> _answer(String text) => {
      'id': 'msg_${text.hashCode}',
      'type': 'message',
      'status': 'completed',
      'role': 'assistant',
      'phase': 'final_answer',
      'content': [
        {'type': 'output_text', 'text': text, 'annotations': []},
      ],
    };

http.Response _reply(String text) => http.Response(
      jsonEncode({
        'status': 'completed',
        'output': [_answer(text)],
      }),
      200,
    );

Future<CoachEngine> _engine(http.Client client) async {
  final config = CoachConfig();
  await config.save(model: 'gpt-6.1-sol');
  addTearDown(config.dispose);
  final engine = CoachEngine(
    config: config,
    api: _FakeRepo(),
    client: client,
    storageKey: 'local',
  );
  addTearDown(engine.dispose);
  return engine;
}

List<String> _coachFiles(Directory dir) => dir
    .listSync()
    .map((e) => e.uri.pathSegments.last)
    .where((n) => n.startsWith('coach_s_'))
    .toList();

Future<List<String>> _indexIds(Directory dir) async {
  final f = File('${dir.path}/coach_idx_local.json');
  if (!await f.exists()) return const [];
  return [
    for (final m in jsonDecode(await f.readAsString()) as List)
      (m as Map)['id'] as String,
  ];
}

void _send(CoachEngine engine, String text, List<Future<void>> into) =>
    into.add(engine.send(
      text,
      onItem: (_) {},
      onStatus: (_) {},
      confirm: (_) async => false,
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a chat deleted while its reply is coming in is not saved back',
      () async {
    final dir = await _documents();
    final answer = Completer<http.Response>();
    var calls = 0;
    final engine = await _engine(MockClient((_) {
      calls++;
      return calls == 1 ? Future.value(_reply('first')) : answer.future;
    }));

    // A saved chat, then a second question still waiting on its reply.
    final sends = <Future<void>>[];
    _send(engine, 'how did I sleep', sends);
    await sends.single;
    await engine.persist();
    final id = engine.sessionId;
    expect(_coachFiles(dir), hasLength(1));

    _send(engine, 'and last week', sends);
    await Future<void>.delayed(Duration.zero);
    await engine.deleteSession(id);
    answer.complete(_reply('the tail of a deleted chat'));
    await sends.last;
    await engine.persist(); // what the screen's finally does

    expect(_coachFiles(dir), isEmpty);
    expect(await _indexIds(dir), isEmpty);
  });

  test('a delete waits for a save already writing that chat', () async {
    final dir = await _documents();
    final engine = await _engine(MockClient((_) async => _reply('ok')));
    final sends = <Future<void>>[];
    _send(engine, 'how did I sleep', sends);
    await sends.single;
    await engine.persist();
    final id = engine.sessionId;

    final paused = Completer<void>(), release = Completer<void>();
    CoachEngine.debugAfterSaveCheck = () {
      paused.complete();
      return release.future;
    };
    addTearDown(() => CoachEngine.debugAfterSaveCheck = null);

    final saving = engine.persist();
    await paused.future;
    var deleted = false;
    final deleting = engine.deleteSession(id).then((_) => deleted = true);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(deleted, isFalse, reason: 'the delete waits for the save');

    release.complete();
    await Future.wait([saving, deleting]);
    expect(_coachFiles(dir), isEmpty);
    expect(await _indexIds(dir), isEmpty);
  });

  test('the history budget counts bytes, so non-ASCII turns are trimmed',
      () async {
    await _documents();
    final engine = await _engine(MockClient((_) async => _reply('ok')));
    // About 50k characters each way but over 100k bytes each in UTF-8: under
    // the budget by characters, well over it by bytes.
    final old = 'сон' * 17000;
    engine.debugHistory
      ..add({'role': 'user', 'content': old})
      ..add({'role': 'assistant', 'content': old});

    final sends = <Future<void>>[];
    _send(engine, 'and today', sends);
    await sends.single;

    expect(engine.debugHistory.any((m) => m['content'] == old), isFalse);
    expect(engine.debugHistory.first['content'], 'and today');
  });
}
