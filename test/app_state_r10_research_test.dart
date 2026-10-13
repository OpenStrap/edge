import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/debug/whoop4_r10_capture.dart';
import 'package:openstrap_edge/state/app_state.dart';

RawRecord record() {
  final b=Uint8List(1920);
  b[0]=0x2f; b[1]=10;
  ByteData.sublistView(b).setUint32(7,1750000000,Endian.little);
  return RawRecord(counter:1,packetType:0x2f,capturedAt:1750000100000,
    recTs:1750000000,
    hex:b.map((v)=>v.toRadixString(16).padLeft(2,'0')).join());
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory parent,root;
  late Whoop4R10Capture capture;
  late AppState app;
  setUp(() async {
    parent=await Directory.systemTemp.createTemp('app_r10_');
    root=Directory('${parent.path}/research');
    capture=Whoop4R10Capture.forTesting(root:root);
    app=AppState.forTesting(r10Research:capture);
  });
  tearDown(() async {
    app.dispose();
    await parent.delete(recursive:true);
  });

  test('normal durability must finish before any research retention', () async {
    await capture.start(consent:true);
    final gate=Completer<void>();
    final committed=app.commitWithR10Research(commit:()=>gate.future,
      raws:[record()],deviceFamily:'gen4');
    await Future<void>.delayed(Duration.zero);
    expect(capture.records,0);
    gate.complete();
    await committed;
    expect(capture.records,1);
    expect(await File('${root.path}/chunk_0.ndjson').exists(),isTrue);
  });

  test('normal commit failure propagates and does not retain research', () async {
    await capture.start(consent:true);
    await expectLater(app.commitWithR10Research(
      commit:() async=>throw StateError('normal commit failed'),
      raws:[record()],deviceFamily:'gen4'),throwsStateError);
    expect(capture.records,0);
  });

  test('research write failure does not fail a successful normal commit', () async {
    await capture.start(consent:true);
    await root.delete(recursive:true);
    await File(root.path).writeAsString('blocked');
    var normal=false;
    await app.commitWithR10Research(commit:() async {normal=true;},
      raws:[record()],deviceFamily:'gen4');
    expect(normal,isTrue);
    expect(capture.incomplete,isTrue);
    expect(capture.active,isFalse);
    expect(app.logLines.where((s)=>s.contains('2f0a')),isEmpty);
  });

  test('developer-off revokes collection while a normal commit is pending', () async {
    await capture.start(consent:true);
    final gate=Completer<void>();
    final commit=app.commitWithR10Research(commit:()=>gate.future,
      raws:[record()],deviceFamily:'gen4');
    app.revokeR10Research();
    gate.complete();
    await commit;
    expect(capture.records,0);
    expect(capture.active,isFalse);
  });

  test('disabled path creates no files and still commits normally', () async {
    var normal=false;
    await app.commitWithR10Research(commit:() async {normal=true;},
      raws:[record()],deviceFamily:'gen4');
    expect(normal,isTrue);
    expect(await root.exists(),isFalse);
  });

  test('capture stays outside existing backup/upload snapshot source', () {
    final db=File('lib/data/db.dart').readAsStringSync();
    final uploader=File('lib/telemetry/health_uploader.dart').readAsStringSync();
    expect(db.contains('whoop4_r10_research'),isFalse);
    expect(uploader.contains('whoop4_r10_research'),isFalse);
    expect(uploader,contains('LocalDb.exportCopy(includeSubstrateArchive: false)'));
    final appCode=File('lib/state/app_state.dart').readAsStringSync();
    expect(appCode,contains("_r10Research?.revoke('Data reset')"));
    expect(appCode,contains('_r10Research!.delete()'));
    expect(appCode,contains("_r10Research?.revoke('Pairing changed')"));
    expect(appCode,contains("_r10Research?.revoke('Band unpaired')"));
    expect(appCode,contains('_r10Research?.setForeground(false)'));
  });
  test('research sources use the Dart formatter', () async {
    final paths = <String>[
      'lib/debug/debug_mode.dart',
      'lib/debug/whoop4_r10_capture.dart',
      'lib/debug/whoop4_r10_export.dart',
      'lib/ui2/profile/whoop4_r10_research.dart',
      'test/whoop4_r10_capture_test.dart',
      'test/whoop4_r10_export_test.dart',
      'test/app_state_r10_research_test.dart',
      'lib/state/app_state.dart',
      'lib/ui2/profile/settings.dart',
    ];
    var changed = false;
    for (final path in paths) {
      final result = await Process.run('dart',
          ['format', '--output=none', '--set-exit-if-changed', path]);
      if (result.exitCode == 1) {
        changed = true;
        final formatted = await Process.run('dart', ['format', '--output=show', path]);
        // Source-only diagnostics for cloud development, never device data.
        final source = formatted.stdout as String;
        final marker = source.lastIndexOf('\nFormatted ');
        final text = marker < 0 ? source : source.substring(0, marker + 1);
        print('R10_FORMAT:$path:${base64Encode(utf8.encode(text))}');
      } else {
        expect(result.exitCode, 0, reason: 'Dart formatter must run successfully');
      }
    }
    expect(changed, isFalse, reason: 'Apply the formatter output before merging.');
  }, skip: Platform.environment['GITHUB_ACTIONS'] != 'true');

}
