// The band-result category table (every boundary), the row codecs and the
// window statistics.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';

void main() {
  group('categoryFor — the official result + HR table', () {
    test('codes 0 and 2 are unreadable at any HR', () {
      for (final hr in [0, 50, 75, 200, 255]) {
        expect(categoryFor(0, hr), EcgCategory.unreadable);
        expect(categoryFor(2, hr), EcgCategory.unreadable);
      }
    });

    test('code 1: sinus rhythm only for 51..99', () {
      expect(categoryFor(1, 50), EcgCategory.unreadable);
      expect(categoryFor(1, 51), EcgCategory.sinusRhythm);
      expect(categoryFor(1, 99), EcgCategory.sinusRhythm);
      expect(categoryFor(1, 100), EcgCategory.unreadable);
    });

    test('code 3: low heart rate only at 50 or below', () {
      expect(categoryFor(3, 0), EcgCategory.lowHeartRate);
      expect(categoryFor(3, 50), EcgCategory.lowHeartRate);
      expect(categoryFor(3, 51), EcgCategory.unreadable);
    });

    test(
      'code 4: possible AFib 51..99, AFib high HR 100..150, high HR 151..200',
      () {
        expect(categoryFor(4, 50), EcgCategory.unreadable);
        expect(categoryFor(4, 51), EcgCategory.possibleAfib);
        expect(categoryFor(4, 99), EcgCategory.possibleAfib);
        expect(categoryFor(4, 100), EcgCategory.afibHighHeartRate);
        expect(categoryFor(4, 150), EcgCategory.afibHighHeartRate);
        expect(categoryFor(4, 151), EcgCategory.highHeartRate);
        expect(categoryFor(4, 200), EcgCategory.highHeartRate);
        expect(categoryFor(4, 201), EcgCategory.unreadable);
      },
    );

    test('code 5: high HR no AFib 100..150, high HR 151..200', () {
      expect(categoryFor(5, 99), EcgCategory.unreadable);
      expect(categoryFor(5, 100), EcgCategory.highHeartRateNoAfib);
      expect(categoryFor(5, 150), EcgCategory.highHeartRateNoAfib);
      expect(categoryFor(5, 151), EcgCategory.highHeartRate);
      expect(categoryFor(5, 200), EcgCategory.highHeartRate);
      expect(categoryFor(5, 201), EcgCategory.unreadable);
    });

    test('code 6 is inconclusive at any HR; unknown codes are unreadable', () {
      expect(categoryFor(6, 0), EcgCategory.inconclusive);
      expect(categoryFor(6, 180), EcgCategory.inconclusive);
      expect(categoryFor(7, 75), EcgCategory.unreadable);
      expect(categoryFor(99, 75), EcgCategory.unreadable);
      expect(categoryFor(-1, 75), EcgCategory.unreadable);
    });
  });

  group('codecs', () {
    test('samples round-trip as signed i16 LE bytes', () {
      final s = Int16List.fromList([-1, 1, 32767, -32768, 0, -5396, 3377]);
      final bytes = EcgPacketCodec.encodeSamples(s);
      expect(bytes.length, 14);
      expect(bytes.sublist(0, 4), [0xff, 0xff, 0x01, 0x00]);
      expect(EcgPacketCodec.decodeSamples(bytes), s);
    });

    test('packet rows carry a placeholder faithfully', () {
      final p = EcgAcceptedPacket.placeholder(42);
      final row = EcgPacketCodec.toRow(p);
      expect(row['is_placeholder'], 1);
      expect(row['sample_count'], 0);
      expect(row['inner_hex'], '');
      final back = EcgPacketCodec.fromRow(row);
      expect(back.placeholder, isTrue);
      expect(back.sequence, 42);
      expect(back.samples, isEmpty);
    });

    test('reading rows round-trip', () {
      final r = EcgReading(
        id: ecgReadingId(
          startEpochMs: 1787823754000,
          terminalStrapS: 1787823784,
        ),
        deviceId: '',
        wrist: EcgWrist.left,
        startTs: 1787823754,
        endTs: 1787823784,
        strapTerminalTs: 1787823784,
        strapTerminalSubsec: 5,
        resultCode: 1,
        category: EcgCategory.sinusRhythm,
        avgHr: 77,
        quality: 3,
        unreadableMask: 0,
        interruptions: 1,
        sampleCount: 3000,
        minUv: -531,
        maxUv: 731,
        rmsUv: 126.773,
        missingSegments: 0,
        status: EcgReadingStatus.completed,
        notes: null,
        createdAt: 1787823784000,
      );
      expect(r.id, 'ecg_1787823754000_1787823784');
      final row = r.toRow();
      expect(row['sample_unit'], kEcgSampleUnit);
      expect(row['sample_rate_hz'], 100);
      expect(row['source'], kEcgSource);
      final back = EcgReading.fromRow(row)!;
      expect(back.wrist, EcgWrist.left);
      expect(back.category, EcgCategory.sinusRhythm);
      expect(back.durationS, 30);
      expect(back.rmsUv, closeTo(126.773, 1e-9));
      expect(EcgReading.fromRow({'id': 'x'}), isNull);
    });
  });

  group('window stats', () {
    test('min, max, rms and missing segments; placeholders add nothing', () {
      final stats = EcgWindowStats.of([
        EcgAcceptedPacket(
          sequence: 1,
          strapSeconds: 1,
          strapSubsec: 0,
          samples: Int16List.fromList([3, -4]),
          inner: Uint8List(0),
        ),
        EcgAcceptedPacket.placeholder(2),
        EcgAcceptedPacket(
          sequence: 3,
          strapSeconds: 3,
          strapSubsec: 0,
          samples: Int16List.fromList([0, 12]),
          inner: Uint8List(0),
        ),
      ]);
      expect(stats.sampleCount, 4);
      expect(stats.minUv, -4);
      expect(stats.maxUv, 12);
      expect(stats.rmsUv, closeTo(6.5, 1e-9)); // sqrt((9+16+0+144)/4)
      expect(stats.missingSegments, 1);
      final empty = EcgWindowStats.of(const []);
      expect(empty.sampleCount, 0);
      expect(empty.rmsUv, isNull);
    });
  });
}
