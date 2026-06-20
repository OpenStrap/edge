// Pure-Dart protocol tests. Run with: dart test test/protocol_test.dart
//
// Ground truth: whoop.py + whoop_hist.jsonl (550 real records).
// If this disagrees with whoop.py, the Dart port is wrong.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_edge/protocol/commands.dart';
import 'package:openstrap_edge/protocol/framing.dart';
import 'package:openstrap_edge/protocol/records.dart';
import 'package:openstrap_edge/protocol/constants.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('framing + CRC (INIT byte-exactness)', () {
    // These are HCI-snoop verbatim. Matching them validates buildFrame, crc8, crc32.
    const expected = [
      'aa0800a823002300ada86a2d',
      'aa0800a823014c00f2b5cdce',
      'aa0800a823022200824df537',
      'aa0800a823034301c54dd63d',
      'aa0800a823041600c7c25288',
    ];
    test('5-packet INIT regenerates byte-for-byte', () {
      for (int i = 0; i < expected.length; i++) {
        expect(_hex(initPackets[i]), expected[i], reason: 'INIT seq$i');
      }
    });

    test('round-trip: parseFrame(buildCommand(...)) is valid', () {
      final raw = buildCommand(0, Cmd.getHelloHarvard, const [0x00]);
      final f = parseFrame(raw);
      expect(f, isNotNull);
      expect(f!.crc8Ok, isTrue);
      expect(f.crc32Ok, isTrue);
      expect(f.packetType, PacketType.command);
      expect(f.opcode, Cmd.getHelloHarvard);
    });
  });

  group('batch ACK (the fragile breaking point)', () {
    test('ACK has the exact 12-byte inner shape [0x23][seq][0x17][0x01]+token', () {
      final token = List<int>.generate(8, (i) => i + 1);
      final raw = buildBatchAck(5, token);
      final f = parseFrame(raw)!;
      expect(f.crc8Ok && f.crc32Ok, isTrue);
      expect(f.inner.sublist(0, 4), [PacketType.command, 5, Cmd.historicalDataResult, revision1]);
      expect(f.inner.sublist(4, 12), token);
    });

    test('token must be 8 bytes', () {
      expect(() => buildBatchAck(5, [1, 2, 3]), throwsArgumentError);
    });

    test('parseMetadata extracts token inner[13:21] from a HistoryEnd marker', () {
      // Build a synthetic 0x31 metadata END frame: inner = [0x31][seq][0x02] + 18 bytes
      // such that [13:21] is a known token.
      final inner = List<int>.filled(21, 0);
      inner[0] = PacketType.metadata;
      inner[1] = 0;
      inner[2] = SyncMeta.historyEnd;
      final token = [9, 8, 7, 6, 5, 4, 3, 2];
      for (int i = 0; i < 8; i++) {
        inner[13 + i] = token[i];
      }
      final m = parseMetadata(Uint8ListOf(inner));
      expect(m, isNotNull);
      expect(m!.sub, SyncMeta.historyEnd);
      expect(m.token, token);
    });
  });

  group('R24 decode against golden fixture', () {
    late List<Map<String, dynamic>> records;

    setUpAll(() {
      // Fixture lives at the repo root, one level above openstrap-edge/.
      final candidates = [
        '../whoop_hist.jsonl',
        'whoop_hist.jsonl',
      ];
      File? f;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          f = File(c);
          break;
        }
      }
      if (f == null) {
        throw StateError('whoop_hist.jsonl fixture not found (looked in $candidates)');
      }
      records = f
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .map((l) => json.decode(l) as Map<String, dynamic>)
          .toList();
    });

    test('record 0 matches whoop.py exactly', () {
      final r = parseR24(hexToBytes(records[0]['hex'] as String))!;
      // Edge decodes the HEADER only (ts/counter/hr); the cloud owns the sensor
      // block. Sensor-field decoding is covered by the cloud golden test
      // (openstrap-protocol/ts/test_decoder.ts) + the Python reference.
      expect(r.tsEpoch, 1775395266);
      expect(r.hr, 98);
    });

    test('all 550 records decode without throwing', () {
      int ok = 0;
      for (final rec in records) {
        final r = parseR24(hexToBytes(rec['hex'] as String));
        if (r != null) ok++;
      }
      expect(ok, records.length);
    });
  });
}

// Small helper to make a Uint8List from an int list in tests.
// ignore: non_constant_identifier_names
Uint8List Uint8ListOf(List<int> b) => Uint8List.fromList(b);
