import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/debug/debug_mode.dart';
import 'package:openstrap_edge/debug/whoop4_r10_capture.dart';

String payload({
  int ts = 1750000000,
  int packet = 0x2f,
  int type = 10,
  int length = 1920,
}) {
  final b = Uint8List(length);
  b[0] = packet;
  b[1] = type;
  if (length >= 11) ByteData.sublistView(b).setUint32(7, ts, Endian.little);
  return b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}

RawRecord raw(String hex, {int ts = 1750000000}) => RawRecord(
  counter: 1,
  packetType: int.parse(hex.substring(0, 2), radix: 16),
  hex: hex,
  capturedAt: 1750000100000,
  recTs: ts,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory parent, root;
  late Whoop4R10Capture capture;
  setUp(() async {
    parent = await Directory.systemTemp.createTemp('r10_test_');
    root = Directory('${parent.path}/research');
    capture = Whoop4R10Capture.forTesting(root: root);
  });
  tearDown(() async {
    capture.dispose();
    await parent.delete(recursive: true);
  });

  test('default gate is off and no consent cannot create files', () async {
    expect(whoop4R10ResearchEnabled, isFalse);
    await expectLater(capture.start(consent: false), throwsStateError);
    expect(await root.exists(), isFalse);
    final disabled = Whoop4R10Capture.forTesting(root: root, enabled: false);
    await expectLater(disabled.start(consent: true), throwsStateError);
    await disabled.captureBatch([raw(payload())], deviceFamily: 'gen4');
    expect(await root.exists(), isFalse);
    disabled.dispose();
  });

  test(
    'only known gen4 historical R10 is retained, exact bytes survive',
    () async {
      await capture.start(consent: true);
      final hex = payload();
      await capture.captureBatch([
        raw(hex),
        raw(payload(packet: 0x2b)),
        raw(payload(type: 24, length: 96)),
        raw(payload(length: 96)),
        raw('2f0a${List.filled(3836, 'g').join()}'),
      ], deviceFamily: 'gen4');
      await capture.captureBatch([raw(hex)], deviceFamily: 'gen5');
      await capture.captureBatch([raw(hex)], deviceFamily: null);
      await capture.stop();
      expect(capture.records, 1);
      expect(capture.unsupported, 2);
      final chunk = File('${root.path}/chunk_0.ndjson');
      final lines = await chunk.readAsLines();
      final row = jsonDecode(lines.first) as Map;
      expect(row['inner_hex'], hex);
      expect(row['received_at_epoch_ms'], 1750000100000);
      expect(row['record_ts_epoch_s'], 1750000000);
      expect(row['payload_scope'], 'inner');
      expect((jsonDecode(lines.last) as Map)['ack_status'], 'not_observed');
    },
  );

  test('retry duplicates do not inflate unique retained data', () async {
    await capture.start(consent: true);
    for (var i = 0; i < 3; i++) {
      await capture.captureBatch([raw(payload())], deviceFamily: 'gen4');
    }
    expect(capture.records, 1);
    expect(capture.duplicates, 2);
    expect(capture.eligible, 3);
  });

  test(
    'archive disposition stays untrusted and does not become a sample',
    () async {
      await capture.start(consent: true);
      await capture.captureBatch(
        [],
        deviceFamily: 'gen4',
        archives: [
          ArchiveRecord(
            hex: payload(),
            packetType: 0x2f,
            capturedAt: 10,
            reason: 'gate_dropped',
          ),
        ],
      );
      await capture.stop();
      final row =
          jsonDecode(
                (await File('${root.path}/chunk_0.ndjson').readAsLines()).first,
              )
              as Map;
      expect(row['timestamp_status'], 'untrusted');
      expect(row['record_ts_epoch_s'], isNull);
      expect(row['archive_reason'], 'gate_dropped');
    },
  );

  test('byte cap stops without silently retaining partial coverage', () async {
    capture.dispose();
    capture = Whoop4R10Capture.forTesting(root: root, maxBytes: 3000);
    await capture.start(consent: true);
    await capture.captureBatch([raw(payload())], deviceFamily: 'gen4');
    expect(capture.active, isFalse);
    expect(capture.incomplete, isTrue);
    expect(capture.bytes, lessThanOrEqualTo(3000));
    expect(capture.records, 0);
    expect(capture.status, 'Size limit reached');
  });

  test('wall-clock expiry stops even if the timer did not fire', () async {
    capture.dispose();
    var now = DateTime.utc(2026, 10, 13);
    capture = Whoop4R10Capture.forTesting(root: root, now: () => now);
    await capture.start(consent: true);
    now = now.add(const Duration(minutes: 31));
    await capture.captureBatch([raw(payload())], deviceFamily: 'gen4');
    expect(capture.active, isFalse);
    expect(capture.records, 0);
    expect(capture.status, 'Time limit reached');
  });

  test('background suspension and context are honest and bounded', () async {
    await capture.start(consent: true);
    capture.setForeground(false);
    await capture.captureBatch([raw(payload())], deviceFamily: 'gen4');
    expect(capture.records, 0);
    capture.setForeground(true);
    for (var i = 0; i < 400; i++) {
      capture.observeContext(
        batteryPct: (i % 100).toDouble(),
        connected: true,
        generation: 'gen4',
      );
    }
    expect(capture.manifest['events'], hasLength(256));
    expect(capture.contextTruncated, isTrue);
    expect(capture.incomplete, isTrue);
  });

  test(
    'delete invalidates queued work and removes exports and raw files',
    () async {
      await capture.start(consent: true);
      final write = capture.captureBatch([
        raw(payload()),
      ], deviceFamily: 'gen4');
      await capture.delete();
      await write;
      expect(await root.exists(), isFalse);
      expect(capture.active, isFalse);
      expect(capture.hasSession, isFalse);
    },
  );

  test('start queued then revoked never re-arms', () async {
    final starting = capture.start(consent: true);
    capture.revoke('Revoked');
    await starting;
    expect(capture.active, isFalse);
    expect(await root.exists(), isFalse);
  });

  test('storage failure stops research without throwing to sync', () async {
    await capture.start(consent: true);
    await root.delete(recursive: true);
    await File(root.path).writeAsString('not a directory');
    await capture.captureBatch([raw(payload())], deviceFamily: 'gen4');
    expect(capture.active, isFalse);
    expect(capture.incomplete, isTrue);
  });

  test('cleanup deletes expired sessions only in its namespace', () async {
    capture.dispose();
    var now = DateTime.utc(2026, 10, 13);
    capture = Whoop4R10Capture.forTesting(root: root, now: () => now);
    await capture.start(consent: true);
    await capture.stop();
    final unrelated = File('${parent.path}/keep.txt');
    await unrelated.writeAsString('keep');
    now = now.add(const Duration(hours: 25));
    await capture.cleanupExpired();
    expect(await root.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
  });
  test('cleanup also works after research is disabled', () async {
    await capture.start(consent: true);
    await capture.captureBatch([raw(payload())], deviceFamily: 'gen4');
    await capture.stop();
    final disabled = Whoop4R10Capture.forTesting(root: root, enabled: false);
    await disabled.delete();
    expect(await root.exists(), isFalse);
    disabled.dispose();
  });

}
