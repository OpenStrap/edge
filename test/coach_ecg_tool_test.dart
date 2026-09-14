// The coach's `get_ecg_reading` tool: a bound read by id, a bounded min/max
// envelope, and nothing that identifies the band or leaks bytes. Plus the
// prompt and tool-definition pins.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_actions.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_prompt.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_coach_ecg_tool_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final reading = EcgReading(
      id: 'ecg_tool_1',
      deviceId: 'SERIAL-SECRET',
      wrist: EcgWrist.right,
      startTs: 1787823754,
      endTs: 1787823784,
      strapTerminalTs: 1787823784,
      strapTerminalSubsec: 0,
      resultCode: 1,
      category: EcgCategory.sinusRhythm,
      avgHr: 77,
      quality: 3,
      unreadableMask: 0,
      interruptions: 0,
      sampleCount: 3000,
      minUv: -531,
      maxUv: 731,
      rmsUv: 126.8,
      missingSegments: 1,
      status: EcgReadingStatus.completed,
      notes: 'private note',
      createdAt: 1787823784000,
    );
    // 30 packets of 100 samples with one placeholder; a lone spike so the
    // envelope's max/min survive.
    final packets = <EcgAcceptedPacket>[];
    for (var s = 0; s < 31; s++) {
      if (s == 10) {
        packets.add(EcgAcceptedPacket.placeholder(s));
        continue;
      }
      final samples = Int16List.fromList(
        List.generate(100, (i) => (i % 20) * 10 - 100),
      );
      if (s == 20) samples[50] = 731;
      if (s == 25) samples[7] = -531;
      packets.add(
        EcgAcceptedPacket(
          sequence: s,
          strapSeconds: 1787823754 + s,
          strapSubsec: 0,
          samples: samples,
          inner: Uint8List.fromList(List.filled(228, 0xab)),
        ),
      );
    }
    await LocalDb.insertEcgReading(reading.toRow(), [
      for (final x in packets) EcgPacketCodec.toRow(x),
    ]);

    // A window far longer than a completed reading, with wide (4-digit)
    // values, so the payload cannot fit whole and the stride has to widen.
    final long = <EcgAcceptedPacket>[];
    for (var s = 0; s < 200; s++) {
      long.add(
        EcgAcceptedPacket(
          sequence: s,
          strapSeconds: 1787823754 + s,
          strapSubsec: 0,
          samples: Int16List.fromList(
            List.generate(100, (i) => i.isEven ? -2582 : 2471),
          ),
          inner: Uint8List.fromList(List.filled(228, 0xab)),
        ),
      );
    }
    await LocalDb.insertEcgReading(
      EcgReading(
        id: 'ecg_tool_long',
        deviceId: 'SERIAL-SECRET',
        wrist: EcgWrist.right,
        startTs: 1787823754,
        endTs: 1787823954,
        strapTerminalTs: 1787823954,
        strapTerminalSubsec: 0,
        resultCode: 1,
        category: EcgCategory.sinusRhythm,
        avgHr: 77,
        quality: 3,
        unreadableMask: 0,
        interruptions: 0,
        sampleCount: 20000,
        minUv: -2582,
        maxUv: 2471,
        rmsUv: 2526.0,
        missingSegments: 0,
        status: EcgReadingStatus.completed,
        notes: 'private note',
        createdAt: 1787823954000,
      ).toRow(),
      [for (final x in long) EcgPacketCodec.toRow(x)],
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test(
    'returns the band summary and the full waveform; no identity, no bytes',
    () async {
      final out = await CoachActions.ecgReading(
        await LocalDb.instance,
        'ecg_tool_1',
      );
      final j = jsonDecode(out) as Map<String, dynamic>;
      expect(j['id'], 'ecg_tool_1');
      expect(j['band_category'], 'sinusRhythm');
      expect(j['result_code'], 1);
      expect(j['avg_hr'], 77);
      expect(j['duration_s'], 30);
      expect(j['sample_count'], 3000);
      expect(j['missing_segments'], 1);
      expect(j['unit'], kEcgSampleUnit);
      final wf = j['waveform'] as Map<String, dynamic>;
      final pts = wf['samples'] as List;
      expect(wf['stride'], 1, reason: 'a 30 s reading is sent whole');
      expect(wf['count'], pts.length);
      expect(wf['effective_rate_hz'], kEcgSampleRateHz);
      expect(
        pts.whereType<int>().length,
        j['sample_count'],
        reason: 'every sample the band sent, not a summary',
      );
      expect(
        pts.length,
        (j['sample_count'] as int) +
            (j['missing_segments'] as int) * kEcgSampleRateHz,
        reason: 'a missing segment holds its second open',
      );
      expect(
        pts.where((e) => e == null),
        isNotEmpty,
        reason: 'the placeholder second',
      );
      final real = pts.whereType<int>();
      expect(real, contains(731), reason: 'peaks are the real samples');
      expect(real, contains(-531));
      expect(out, isNot(contains('SERIAL-SECRET')));
      expect(out, isNot(contains('private note')));
      expect(out, isNot(contains('abab')));
      expect(out, isNot(contains('device_id')));
      expect(
        out.length,
        lessThan(CoachEngine.kMaxEcgToolResultChars),
        reason: 'fits one tool result without truncation',
      );
    },
  );

  test('an unknown id is an error, an empty id is a usage error', () async {
    final out = await CoachActions.ecgReading(await LocalDb.instance, 'nope');
    expect(jsonDecode(out), containsPair('error', contains('nope')));
    final db = await LocalDb.instance;
    await expectLater(
      () => CoachActions.ecgReading(db, ''),
      throwsA(isA<CoachActionError>()),
    );
  });

  test('an over-long window is decimated, never clipped', () async {
    final out = await CoachActions.ecgReading(
      await LocalDb.instance,
      'ecg_tool_long',
    );
    expect(
      out.length,
      lessThanOrEqualTo(CoachActions.ecgMaxPayloadChars),
      reason: 'the result parses whole',
    );
    final j = jsonDecode(out) as Map<String, dynamic>; // would throw if clipped
    final wf = j['waveform'] as Map<String, dynamic>;
    expect(wf['stride'], greaterThan(1));
    expect(wf['effective_rate_hz'], kEcgSampleRateHz / (wf['stride'] as int));
    expect(wf['count'], (wf['samples'] as List).length);
    expect(
      j['sample_count'],
      20000,
      reason: 'the summary still reports the true length',
    );
  });

  test('the payload budget stays under the engine ceiling', () {
    expect(
      CoachActions.ecgMaxPayloadChars,
      lessThan(CoachEngine.kMaxEcgToolResultChars),
      reason: 'decimate deliberately rather than be clipped mid-number',
    );
    // A bound single-reading lookup may be larger than a query the model
    // widens itself, but never larger than the running history it lives in.
    expect(
      CoachEngine.kMaxToolResultChars,
      lessThan(CoachEngine.kMaxEcgToolResultChars),
    );
    expect(
      CoachEngine.kMaxEcgToolResultChars,
      lessThan(CoachEngine.kMaxHistoryChars),
    );
  });

  test('the result explains the data it carries', () async {
    final out = await CoachActions.ecgReading(
      await LocalDb.instance,
      'ecg_tool_1',
    );
    final h =
        (jsonDecode(out) as Map<String, dynamic>)['how_to_read']
            as Map<String, dynamic>;
    expect(h['sample_rate'], contains('500 Hz'));
    expect(h['sample_rate'], contains('10 ms'));
    expect(h['avg_hr'], contains('not measured from these samples'));
    expect(h['polarity'], contains('NOT proven'));
  });

  test('the system prompt carries the ECG law and the tool', () {
    expect(kCoachSystemPrompt, contains('get_ecg_reading'));
    expect(kCoachSystemPrompt, contains('v_ecg_readings'));
    expect(kCoachSystemPrompt, contains('HeartKey'));
    expect(
      kCoachSystemPrompt,
      contains('not a cleared diagnostic device'),
      reason: 'interpretation is allowed; the standing caveat is not',
    );
    expect(kCoachSystemPrompt, contains('Not medical advice'));
    expect(kCoachSystemPrompt.toLowerCase(), contains('polarity'));
    expect(kCoachSystemPrompt.toLowerCase(), contains('emergency'));
  });
}
