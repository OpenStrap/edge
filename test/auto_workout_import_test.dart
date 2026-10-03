// Tests for the opt-in auto-import of Health workouts: the pure gate, and
// the runner's contract (silent when off, silent when ungranted, throttled
// to one full-window read per interval, cursor advanced only on real rows).

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/health/auto_workout_import.dart';
import 'package:openstrap_edge/health/health_import_state.dart';
import 'package:openstrap_edge/health/health_workout_import.dart';

class _FakeImporter implements HealthWorkoutImporter {
  _FakeImporter(this.granted, this.rows);

  final bool granted;
  final int rows;
  int syncCalls = 0;
  final List<bool> prompts = [];

  @override
  Future<bool> hasReadPermission() async => granted;

  @override
  Future<WorkoutImportResult> sync({DateTime? now, bool prompt = false}) async {
    syncCalls++;
    prompts.add(prompt);
    return WorkoutImportResult(
      workouts: rows,
      withRoutes: 0,
      routesSupported: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('shouldAutoImport (pure)', () {
    test('off means never, even with a grant and no history', () {
      expect(
        shouldAutoImport(
          enabled: false,
          permissionGranted: true,
          lastAttempt: null,
          now: DateTime(2026, 8, 22, 12),
        ),
        isFalse,
      );
    });

    test('on without a grant never runs — the cadence must not prompt', () {
      expect(
        shouldAutoImport(
          enabled: true,
          permissionGranted: false,
          lastAttempt: null,
          now: DateTime(2026, 8, 22, 12),
        ),
        isFalse,
      );
    });

    test('first run after the grant goes', () {
      expect(
        shouldAutoImport(
          enabled: true,
          permissionGranted: true,
          lastAttempt: null,
          now: DateTime(2026, 8, 22, 12),
        ),
        isTrue,
      );
    });

    test('inside the hour it throttles; past it, it goes', () {
      final last = DateTime(2026, 8, 22, 11);
      expect(
        shouldAutoImport(
          enabled: true,
          permissionGranted: true,
          lastAttempt: last,
          now: last.add(const Duration(minutes: 59)),
        ),
        isFalse,
        reason: '59 min < 1 h interval',
      );
      expect(
        shouldAutoImport(
          enabled: true,
          permissionGranted: true,
          lastAttempt: last,
          now: last.add(kAutoWorkoutImportInterval),
        ),
        isTrue,
      );
    });
  });

  group('AutoWorkoutImport.maybeRun', () {
    test('DEFAULT IS ON: no pref written still runs when granted', () async {
      final imp = _FakeImporter(true, 2);
      expect(await AutoWorkoutImport.maybeRun(importer: imp),
          AutoImportOutcome.ran);
      expect(imp.syncCalls, 1);
      expect(imp.prompts, [false],
          reason: 'a cadence read must never let the route fetch prompt');
    });

    test('switch off → skipped, importer untouched', () async {
      await AutoWorkoutImport.setEnabled(false); // explicit: default is ON
      final imp = _FakeImporter(true, 5);
      final out = await AutoWorkoutImport.maybeRun(importer: imp);
      expect(out, AutoImportOutcome.skipped);
      expect(imp.syncCalls, 0);
    });

    test('ungranted store → skipped even when enabled', () async {
      await AutoWorkoutImport.setEnabled(true);
      final imp = _FakeImporter(false, 5);
      final out = await AutoWorkoutImport.maybeRun(importer: imp);
      expect(out, AutoImportOutcome.skipped);
      expect(imp.syncCalls, 0);
    });

    test('granted + enabled → runs once, then throttles within the hour',
        () async {
      await AutoWorkoutImport.setEnabled(true);
      final imp = _FakeImporter(true, 3);

      expect(await AutoWorkoutImport.maybeRun(importer: imp),
          AutoImportOutcome.ran);
      expect(imp.syncCalls, 1);

      // The imported cursor only advances on real rows.
      final lastMs =
          (await SharedPreferences.getInstance())
              .getInt(kAutoWorkoutImportLastMs);
      expect(lastMs, isNotNull);
      expect(await lastImportAt(HealthImport.workouts), isNotNull);

      expect(await AutoWorkoutImport.maybeRun(importer: imp),
          AutoImportOutcome.throttled);
      expect(imp.syncCalls, 1, reason: 'throttled — no second full read');
    });

    test('a zero-row read still stamps the attempt', () async {
      await AutoWorkoutImport.setEnabled(true);
      final imp = _FakeImporter(true, 0);
      expect(await AutoWorkoutImport.maybeRun(importer: imp),
          AutoImportOutcome.ran);
      expect(
          (await SharedPreferences.getInstance())
              .getInt(kAutoWorkoutImportLastMs),
          isNotNull,
          reason:
              'an empty store would otherwise be re-read on every pass');
      expect(await lastImportAt(HealthImport.workouts), isNull,
          reason: 'zero rows must not put the UI to sleep on a denial');
    });
  });

  group('read probe', _probeTests);
}

class _ProbeHealth extends Health {
  _ProbeHealth(this.answer);
  final bool? answer;

  @override
  Future<void> configure() async {}

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types,
          {List<HealthDataAccess>? permissions}) async =>
      answer;
}

void _probeTests() {
  // HealthKit answers null for READ whether or not access was granted, so a
  // `== true` probe kept auto-import off on every iPhone.
  test('apple: an unknowable READ grant (null) still lets the auto read run',
      () async {
    final i = HealthWorkoutImporter(health: _ProbeHealth(null), isApple: true);
    expect(await i.hasReadPermission(), isTrue);
  });

  test('apple: an explicit false still skips', () async {
    final i = HealthWorkoutImporter(health: _ProbeHealth(false), isApple: true);
    expect(await i.hasReadPermission(), isFalse);
  });

  test('health connect: null is not a grant', () async {
    final i = HealthWorkoutImporter(health: _ProbeHealth(null), isApple: false);
    expect(await i.hasReadPermission(), isFalse);
  });
}
