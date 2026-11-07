// Nap -> Apple Health export: only confirmed/manual naps, never windows
// overlapping the derived main sleep; delete-then-write makes repeated
// exports idempotent; removing a nap deletes its Health window.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/nap_edits.dart'
    show kMaxNapSec, kMinManualNapSec;
import 'package:openstrap_edge/health/health_nap_export.dart';

class FakeNapWriter implements HealthKitNapWriter {
  final calls = <({String method, DateTime start, DateTime end})>[];
  bool nextResult = true;
  bool throwOnCall = false;
  int throwOnCallNumber = 0; // 1-based; 0 = never

  @override
  Future<bool> replaceNap({required DateTime start, required DateTime end}) =>
      _record('replaceNap', start, end);

  @override
  Future<bool> deleteRange({required DateTime start, required DateTime end}) =>
      _record('deleteNapRange', start, end);

  Future<bool> _record(String method, DateTime start, DateTime end) async {
    calls.add((method: method, start: start, end: end));
    final n = calls.length;
    if (throwOnCall || (throwOnCallNumber > 0 && n == throwOnCallNumber)) {
      throw Exception('store error');
    }
    return nextResult;
  }
}

HealthNapExporter exporter({
  required FakeNapWriter writer,
  bool isApple = true,
  bool healthSync = true,
  Map<String, dynamic>? row,
  List<Map<String, dynamic>>? dayRows,
  bool overlaps = false,
}) =>
    HealthNapExporter(
      writer: writer,
      isApple: isApple,
      healthSyncEnabled: () async => healthSync,
      napRow: (dayId, startTs) async => row,
      dayNapRows: (dayId) async => dayRows ?? (row == null ? [] : [row]),
      overlapsMainSleep: (s, e) async => overlaps,
    );

void main() {
  // Derived from the real clock: exportNap validates "not in the future"
  // against DateTime.now(), so fixed timestamps would rot.
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // A 30 min nap window that ended an hour ago.
  final start = nowSec - 7200;
  final end = start + 1800;

  group('napWindowExportable', () {
    test('confirmed and manual naps inside the bounds are exportable', () {
      for (final source in ['confirmed', 'manual']) {
        expect(
          napWindowExportable(
              source: source, startTs: start, endTs: end, nowSec: nowSec),
          isTrue,
        );
      }
    });

    test('pending, rejected and legacy rows are never exportable', () {
      for (final source in ['pending', 'rejected', 'legacy', null]) {
        expect(
          napWindowExportable(
              source: source, startTs: start, endTs: end, nowSec: nowSec),
          isFalse,
        );
      }
    });

    test('windows outside the shared nap bounds are not exportable', () {
      // The export honors the same 5 min - kMaxNapSec (3 h) bounds as entry:
      // anything longer is a sleep, not a nap, and must not reach HealthKit
      // as one. The window starts far enough in the past that even the 3 h
      // bound ends before nowSec.
      final s0 = nowSec - 5 * 3600;
      expect(
        napWindowExportable(
            source: 'confirmed',
            startTs: s0,
            endTs: s0 + kMinManualNapSec - 60,
            nowSec: nowSec),
        isFalse,
      );
      expect(
        napWindowExportable(
            source: 'confirmed', startTs: s0, endTs: s0 + kMaxNapSec,
            nowSec: nowSec),
        isTrue,
      );
      expect(
        napWindowExportable(
            source: 'confirmed',
            startTs: s0,
            endTs: s0 + kMaxNapSec + 1,
            nowSec: nowSec),
        isFalse,
      );
    });

    test('a nap ending in the future is not exportable', () {
      expect(
        napWindowExportable(
            source: 'manual',
            startTs: nowSec - 600,
            endTs: nowSec + 600,
            nowSec: nowSec),
        isFalse,
      );
    });
  });

  group('napOverlapsWindowMs', () {
    test('overlap detection on epoch-ms main-sleep windows', () {
      final onsetMs = (start + 3600) * 1000;
      final offsetMs = (start + 3600 + 8 * 3600) * 1000;
      expect(napOverlapsWindowMs(start, end, onsetMs, offsetMs), isFalse);
      expect(
        napOverlapsWindowMs(start + 3600, end + 3600, onsetMs, offsetMs),
        isTrue,
      );
      expect(napOverlapsWindowMs(start, end, null, offsetMs), isFalse);
    });
  });

  group('HealthNapExporter.exportNap', () {
    test('a confirmed nap is written via replaceNap', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(
        writer: writer,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isTrue);
      expect(writer.calls, hasLength(1));
      expect(writer.calls.single.method, 'replaceNap');
      expect(writer.calls.single.start.millisecondsSinceEpoch, start * 1000);
      expect(writer.calls.single.end.millisecondsSinceEpoch, end * 1000);
    });

    test('a repeated export re-runs replaceNap (native delete-then-write)', () async {
      final writer = FakeNapWriter();
      final e = exporter(
        writer: writer,
        row: {'source': 'manual', 'start_ts': start, 'end_ts': end},
      );
      expect(
          await e.exportNap(dayId: '2026-08-03', startTs: start, endTs: end),
          isTrue);
      expect(
          await e.exportNap(dayId: '2026-08-03', startTs: start, endTs: end),
          isTrue);
      expect(
        writer.calls.where((c) => c.method == 'replaceNap'),
        hasLength(2),
      );
    });

    test('a pending or rejected row is not exported', () async {
      for (final source in ['pending', 'rejected']) {
        final writer = FakeNapWriter();
        final ok = await exporter(
          writer: writer,
          row: {'source': source, 'start_ts': start, 'end_ts': end},
        ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
        expect(ok, isFalse);
        expect(writer.calls, isEmpty);
      }
    });

    test('a caller endTs that differs from the stored row is rejected', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(
        writer: writer,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end + 600},
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isFalse);
      expect(writer.calls, isEmpty);
    });

    test('a nap overlapping the main sleep is not exported', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(
        writer: writer,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
        overlaps: true,
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isFalse);
      expect(writer.calls, isEmpty);
    });

    test('nothing is written when the health sync switch is off', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(
        writer: writer,
        healthSync: false,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isFalse);
      expect(writer.calls, isEmpty);
    });

    test('nothing is written on Android (no Health Connect nap export)', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(
        writer: writer,
        isApple: false,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isFalse);
      expect(writer.calls, isEmpty);
    });

    test('a store error reads as false, never throws', () async {
      final writer = FakeNapWriter()..throwOnCall = true;
      final ok = await exporter(
        writer: writer,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isFalse);
    });

    test('a failed native write reports false (no fake success)', () async {
      final writer = FakeNapWriter()..nextResult = false;
      final ok = await exporter(
        writer: writer,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
      ).exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      expect(ok, isFalse);
    });
  });

  group('HealthNapExporter.deleteNapWindow', () {
    test('a removed nap window is deleted from the store', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(writer: writer)
          .deleteNapWindow(startTs: start, endTs: end);
      expect(ok, isTrue);
      expect(writer.calls.single.method, 'deleteNapRange');
    });

    test('delete is skipped when the switch is off or on Android', () async {
      final off = FakeNapWriter();
      expect(
        await exporter(writer: off, healthSync: false)
            .deleteNapWindow(startTs: start, endTs: end),
        isFalse,
      );
      final android = FakeNapWriter();
      expect(
        await exporter(writer: android, isApple: false)
            .deleteNapWindow(startTs: start, endTs: end),
        isFalse,
      );
      expect(off.calls, isEmpty);
      expect(android.calls, isEmpty);
    });

    test('an empty window is not deleted', () async {
      final writer = FakeNapWriter();
      expect(
        await exporter(writer: writer)
            .deleteNapWindow(startTs: end, endTs: start),
        isFalse,
      );
      expect(writer.calls, isEmpty);
    });
  });

  group('HealthNapExporter.exportDayNaps', () {
    final confirmed = {
      'source': 'confirmed',
      'start_ts': start,
      'end_ts': end,
    };
    final rejected = {
      'source': 'rejected',
      'start_ts': start + 7200,
      'end_ts': start + 7200 + 1800,
    };

    test('writes only the exportable rows of the day', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(writer: writer, dayRows: [confirmed, rejected])
          .exportDayNaps('2026-08-03');
      expect(ok, isTrue);
      expect(
        writer.calls.where((c) => c.method == 'replaceNap'),
        hasLength(1),
      );
    });

    test('a failed attempted write reports false', () async {
      final writer = FakeNapWriter()..nextResult = false;
      final ok = await exporter(writer: writer, dayRows: [confirmed])
          .exportDayNaps('2026-08-03');
      expect(ok, isFalse);
    });

    test('rows overlapping the main sleep are skipped, not failed', () async {
      final writer = FakeNapWriter();
      final ok = await exporter(
        writer: writer,
        dayRows: [confirmed],
        overlaps: true,
      ).exportDayNaps('2026-08-03');
      expect(ok, isTrue);
      expect(writer.calls, isEmpty);
    });

    test('Android and switch-off are no-ops, not failures', () async {
      final android = FakeNapWriter();
      expect(
        await exporter(writer: android, isApple: false, dayRows: [confirmed])
            .exportDayNaps('2026-08-03'),
        isTrue,
      );
      final off = FakeNapWriter();
      expect(
        await exporter(writer: off, healthSync: false, dayRows: [confirmed])
            .exportDayNaps('2026-08-03'),
        isTrue,
      );
      expect(android.calls, isEmpty);
      expect(off.calls, isEmpty);
    });

    test('a store error during the day pass reports false, never throws',
        () async {
      final writer = FakeNapWriter()..throwOnCall = true;
      final ok = await exporter(writer: writer, dayRows: [confirmed])
          .exportDayNaps('2026-08-03');
      expect(ok, isFalse);
    });

    test('synchronized is reentrant: a health call inside a wrapped DB edit '
        'does not deadlock', () async {
      final writer = FakeNapWriter();
      final e = exporter(
        writer: writer,
        row: {'source': 'confirmed', 'start_ts': start, 'end_ts': end},
      );
      final ok = await e.synchronized(() async {
        // Simulates a call site wrapping DB edit + health call together.
        return e.exportNap(dayId: '2026-08-03', startTs: start, endTs: end);
      });
      expect(ok, isTrue);
      expect(writer.calls, hasLength(1));
    });

    test('one failing row does not skip the remaining naps', () async {
      final second = {
        'source': 'manual',
        'start_ts': start + 3600,
        'end_ts': start + 5400, // ends in the past
      };
      final writer = FakeNapWriter()..throwOnCallNumber = 1;
      final ok = await exporter(writer: writer, dayRows: [confirmed, second])
          .exportDayNaps('2026-08-03');
      expect(ok, isFalse);
      expect(
        writer.calls.where((c) => c.method == 'replaceNap'),
        hasLength(2),
      );
    });
  });
}
