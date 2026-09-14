// The live-preview ring buffer + repaint coalescing, the prefs-backed guard
// store, and retained-guard recovery.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_guard_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_recovery.dart';
import 'package:openstrap_edge/ecg/ecg_transport.dart';
import 'package:openstrap_edge/ecg/ecg_waveform_buffer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EcgWaveformBuffer', () {
    test('holds the newest samples oldest-first and wraps', () {
      final b = EcgWaveformBuffer(capacity: 5);
      b.push(Int16List.fromList([1, 2, 3]));
      expect(b.length, 3);
      expect([for (var i = 0; i < b.length; i++) b[i]], [1, 2, 3]);
      b.push(Int16List.fromList([4, 5, 6, 7]));
      expect(b.length, 5);
      expect([for (var i = 0; i < b.length; i++) b[i]], [3, 4, 5, 6, 7]);
      expect(b.maxAbs(), 7);
      b.push(Int16List.fromList([-9]));
      expect([for (var i = 0; i < b.length; i++) b[i]], [4, 5, 6, 7, -9]);
      expect(b.maxAbs(), 9);
      expect(() => b[5], throwsRangeError);
    });

    test('version bumps per push; clear empties', () {
      final b = EcgWaveformBuffer(capacity: 4);
      final v0 = b.version;
      b.push(Int16List.fromList([1]));
      b.push(Int16List(0));
      expect(b.version, v0 + 1, reason: 'an empty push is not a change');
      b.clear();
      expect(b.isEmpty, isTrue);
      expect(b.version, v0 + 2);
    });
  });

  group('EcgPreviewScheduler', () {
    test('many marks inside one tick coalesce to one notification', () {
      final s = EcgPreviewScheduler();
      var n = 0;
      s.addListener(() => n++);
      for (var i = 0; i < 50; i++) {
        s.markDirty();
      }
      expect(s.tick(), isTrue);
      expect(n, 1);
      expect(s.tick(), isFalse, reason: 'nothing changed since');
      expect(n, 1);
    });
  });

  group('PrefsEcgGuardStore', () {
    test(
      'guard, wrist and remembered-MG flag are per serial and durable',
      () async {
        SharedPreferences.setMockInitialValues({});
        final g = PrefsEcgGuardStore();
        expect(await g.isActive('A'), isFalse);
        expect(await g.setActive('A'), isTrue);
        expect(await g.isActive('A'), isTrue);
        expect(await g.isActive('B'), isFalse);
        expect(await g.clear('A'), isTrue);
        expect(await g.isActive('A'), isFalse);
        await g.setWrist('A', EcgWrist.left);
        expect(await g.wrist('A'), EcgWrist.left);
        expect(await g.wrist('B'), isNull);
        expect(await g.isRememberedMaverick('A'), isFalse);
        await g.rememberMaverick('A');
        expect(await g.isRememberedMaverick('A'), isTrue);
        final raw = await SharedPreferences.getInstance();
        expect(raw.getBool('ecg.maverick.A'), isTrue);
        expect(raw.getString('ecg.wrist.A'), 'left');
      },
    );
  });

  group('ecgRecoverRetainedGuard', () {
    EcgCommandListResult ok() => const EcgCommandListResult([
      EcgMemberOutcome('generationStop', written: true, succeeded: true),
      EcgMemberOutcome('filteredOff', written: true, succeeded: true),
      EcgMemberOutcome('rawSaveOff', written: true, succeeded: true),
    ]);
    EcgCommandListResult partial() => const EcgCommandListResult([
      EcgMemberOutcome('generationStop', written: true, succeeded: true),
      EcgMemberOutcome('filteredOff', written: true, succeeded: false),
      EcgMemberOutcome('rawSaveOff', written: true, succeeded: true),
    ]);

    test('no guard → nothing sent', () async {
      final g = MemoryEcgGuardStore();
      var sent = 0;
      final r = await ecgRecoverRetainedGuard(
        guard: g,
        serial: 'S',
        cleanup: () async {
          sent++;
          return ok();
        },
        log: (_) {},
      );
      expect(r, EcgRecoveryOutcome.noGuard);
      expect(sent, 0);
    });

    test('a retained guard runs cleanup; all-success clears it', () async {
      final g = MemoryEcgGuardStore()..active.add('S');
      final r = await ecgRecoverRetainedGuard(
        guard: g,
        serial: 'S',
        cleanup: () async => ok(),
        log: (_) {},
      );
      expect(r, EcgRecoveryOutcome.cleared);
      expect(g.active, isEmpty);
    });

    test('a failed member retains the guard', () async {
      final g = MemoryEcgGuardStore()..active.add('S');
      final r = await ecgRecoverRetainedGuard(
        guard: g,
        serial: 'S',
        cleanup: () async => partial(),
        log: (_) {},
      );
      expect(r, EcgRecoveryOutcome.retained);
      expect(g.active, contains('S'));
    });

    test('no serial → nothing happens', () async {
      final g = MemoryEcgGuardStore()..active.add('S');
      final r = await ecgRecoverRetainedGuard(
        guard: g,
        serial: null,
        cleanup: () async => ok(),
        log: (_) {},
      );
      expect(r, EcgRecoveryOutcome.noSerial);
      expect(g.active, contains('S'));
    });
  });
}
