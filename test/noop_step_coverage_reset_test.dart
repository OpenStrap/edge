// Import sessions carry their original reset generation through awaited reads.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/noop_ingest.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

import 'support/app_state_derive_harness.dart';

// Derivation is downstream of the real coverage write under test.
class _Engine extends DerivationEngine {
  @override
  Future<int> deriveImportedDays(Substrate sub, Profile profile, Set<String> dates,
      {void Function(String day)? onDayDone, int? resetGeneration}) async => 0;
  @override
  Future<void> finalizeImport(Profile profile) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await deriveDbSetUp('noop_step_coverage_reset.db');
    await LocalDb.instance;
  });
  tearDown(() async {
    LocalDb.debugAfterCoverageRead = null;
    ResetGate.resetForTest();
    await deriveDbTearDown('noop_step_coverage_reset.db');
  });

  for (final path in ['step-only finish', 'signal finish', 'day rollover']) {
    // WHY: a completed wipe must stay empty when an old import read resumes.
    // CLAIM(import-coverage-reset); catches: capturing generation at write time,
    // or forwarding it from only one of the three flushStepCoverage callers.
    test('pre-reset import cannot restore steps after $path', () async {
      final start = DateTime(2026, 8, 9, 12).millisecondsSinceEpoch ~/ 1000;
      final date = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start * 1000));
      final ingest = NoopIngest(const Profile(), _Engine());
      expect(await ingest.offer(start), isTrue);
      ingest.stepCounter(start, 100);
      expect(await ingest.offer(start + 60), isTrue);
      ingest.stepCounter(start + 60, 180);
      if (path != 'step-only finish') ingest.hr(start, 60);
      final entered = Completer<void>();
      final release = Completer<void>();
      LocalDb.debugAfterCoverageRead = () async {
        entered.complete();
        await release.future;
      };
      final flushing = path == 'day rollover'
          ? ingest.offer(DateTime(2026, 8, 10, 12).millisecondsSinceEpoch ~/ 1000)
          : ingest.finish();
      // Observe the error immediately so an expected failure isn't unhandled.
      Object? error;
      final observed = flushing.then<void>((_) {}, onError: (Object e) { error = e; });
      await entered.future;
      ResetGate.enter();
      try {
        await LocalDb.wipeAll();
      } finally {
        ResetGate.leave();
        LocalDb.debugAfterCoverageRead = null;
        release.complete();
      }
      await observed;
      expect(await (await LocalDb.instance).query('live_coverage'), isEmpty,
          reason: 'the import belongs to the deleted installation');
      expect(error, isA<StateError>());
      // Positive control: a genuinely new import still persists the measured 80 steps.
      final fresh = NoopIngest(const Profile(), _Engine());
      await fresh.offer(start);
      fresh.stepCounter(start, 100);
      await fresh.offer(start + 60);
      fresh.stepCounter(start + 60, 180);
      await fresh.finish();
      expect(await LocalDb.liveStepsForDay(date), 80);
    });
  }
}
