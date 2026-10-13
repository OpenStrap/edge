import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/debug/whoop4_r10_capture.dart';
import 'package:openstrap_edge/debug/whoop4_r10_export.dart';

String payload(int ts, {int variant = 0}) {
  final b = Uint8List(1920);
  b[0]=0x2f; b[1]=10; b[15]=variant;
  final data = ByteData.sublistView(b);
  data.setUint32(7, ts, Endian.little);
  for (var i=0; i<100; i++) {
    data.setInt16(85+2*i, i-50, Endian.little);
    data.setInt16(285+2*i, 4096, Endian.little);
    data.setInt16(485+2*i, -i, Endian.little);
  }
  return b.map((v) => v.toRadixString(16).padLeft(2,'0')).join();
}
RawRecord raw(int ts, {int variant=0}) => RawRecord(counter: 1,
    packetType: 0x2f, hex: payload(ts, variant: variant),
    capturedAt: 1750000100000, recTs: ts);
Future<List<Map<String,dynamic>>> read(String path) async =>
    (await File(path).readAsLines()).map((s) => jsonDecode(s) as Map<String,dynamic>).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory parent, root;
  late Whoop4R10Capture capture;
  setUp(() async {
    parent=await Directory.systemTemp.createTemp('r10_export_');
    root=Directory('${parent.path}/research');
    capture=Whoop4R10Capture.forTesting(root: root);
    await capture.start(consent: true);
  });
  tearDown(() async {
    capture.dispose();
    await parent.delete(recursive: true);
  });

  test('export requires Stop and produces only local raw/array data', () async {
    await capture.captureBatch([raw(1750000000)], deviceFamily: 'gen4');
    await expectLater(exportWhoop4R10(capture), throwsStateError);
    await capture.stop();
    final path=await exportWhoop4R10(capture);
    expect(path, startsWith(root.path));
    final rows=await read(path);
    final record=rows.first;
    expect(record['inner_hex'], payload(1750000000));
    expect(record['accel_x_lsb'], List.generate(100,(i)=>i-50));
    expect(record['accel_y_lsb'], List.filled(100,4096));
    expect(record['accel_z_lsb'], List.generate(100,(i)=>-i));
    expect(record['accel_scale_g_per_lsb'], 1/4096);
    final manifest=rows.last;
    expect(manifest['no_step_estimate_computed'], isTrue);
    expect(manifest['coverage']['study_timestamp_presence_fraction'], isNull);
    expect(manifest['coverage']['continuous_motion_duration_s'], isNull);
    expect(record.containsKey('stepsInc'), isFalse);
  });

  test('gaps, conflicts and duplicates cannot become continuous coverage', () async {
    const t=1750000000;
    await capture.captureBatch([raw(t),raw(t),raw(t+1),raw(t+3),
      raw(t+3,variant:1),raw(t+5)], deviceFamily:'gen4');
    await capture.stop();
    final rows=await read(await exportWhoop4R10(capture,
      interval:const R10StudyInterval(startEpochS:t,endEpochS:t+10,
        countedSteps:20,label:'counted walk')));
    final m=rows.last;
    expect(m['duplicate_observations'],1);
    expect(m['coverage']['distinct_trusted_record_seconds'],3);
    expect(m['coverage']['conflicting_record_seconds_excluded'],1);
    expect(m['coverage']['study_timestamp_presence_fraction'],0.3);
    expect(m['coverage']['internal_missing_second_ranges'],[
      {'from_epoch_s':t+2,'to_epoch_s_exclusive':t+5}]);
    expect(m['study_interval']['source'],'user_annotation_not_band_output');
  });

  test('archived timestamps are excluded from trusted coverage', () async {
    await capture.captureBatch([],deviceFamily:'gen4',archives:[
      ArchiveRecord(hex:payload(1750000000),packetType:0x2f,
        capturedAt:5,reason:'gate_dropped')]);
    await capture.stop();
    final rows=await read(await exportWhoop4R10(capture));
    expect(rows.first['record_ts_epoch_s'],isNull);
    expect(rows.first['decoded_header_ts_epoch_s'],1750000000);
    expect(rows.last['coverage']['distinct_trusted_record_seconds'],0);
  });

  test('incomplete chunk is declared and corrupt completed chunk is refused', () async {
    await capture.captureBatch([raw(1750000000)],deviceFamily:'gen4');
    await capture.stop();
    await File('${root.path}/chunk_99.partial').writeAsString('interrupted');
    final rows=await read(await exportWhoop4R10(capture));
    expect(rows.last['incomplete'],isTrue);
    expect(rows.last['partial_chunks_excluded'],1);
    await File('${root.path}/chunk_0.ndjson').writeAsString('{}\n');
    await expectLater(exportWhoop4R10(capture),throwsStateError);
    expect(await File('${root.path}/exports/whoop4_r10.partial').exists(),isFalse);
  });

  test('cache eviction cannot leave export claiming complete capture', () async {
    await capture.captureBatch([raw(1750000000)],deviceFamily:'gen4');
    await capture.stop();
    await File('${root.path}/chunk_0.ndjson').delete();
    final rows=await read(await exportWhoop4R10(capture));
    expect(rows.last['incomplete'],isTrue);
    expect(rows.last['retained_record_count_matches_export'],isFalse);
  });

  test('export size limit removes the failed output', () async {
    await capture.captureBatch([raw(1750000000)],deviceFamily:'gen4');
    await capture.stop();
    await expectLater(exportWhoop4R10(capture,maxExportBytes:10),throwsStateError);
    expect(await File('${root.path}/exports/whoop4_r10.partial').exists(),isFalse);
    expect(await File('${root.path}/exports/whoop4_r10.ndjson').exists(),isFalse);
  });

  test('invalid reference interval cannot manufacture a denominator', () async {
    await capture.stop();
    await expectLater(exportWhoop4R10(capture,
      interval:const R10StudyInterval(startEpochS:10,endEpochS:10)),throwsArgumentError);
  });

  test('no uploader, sharing, database or telemetry code is reachable from tool', () {
    for (final path in ['lib/debug/whoop4_r10_capture.dart',
        'lib/debug/whoop4_r10_export.dart']) {
      final code=File(path).readAsStringSync();
      for (final token in ['HttpClient(', 'CompanionClient', 'Share.share',
          'HealthUploader', 'LocalDb.', 'FileLog.', 'debugPrint(', 'Crashlytics']) {
        expect(code.contains(token),isFalse,reason:'$path must not use $token');
      }
    }
    final pubspec=File('pubspec.yaml').readAsStringSync();
    expect(pubspec,contains(r10ProtocolSha));
  });
}
