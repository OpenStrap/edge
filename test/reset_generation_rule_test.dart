// "Delete everything" — one rule for every path that persists.
//
// A session captures [ResetGate.generation] when it STARTS and every write it
// makes checks `ResetGate.changedSince` against that, so nothing that began
// before a reset writes after it, even once the gate has lowered again. The
// reset itself ends what it can before it lowers the gate: the primary link,
// the derive pass, the secondary links. A failed lookup aborts it before
// anything is deleted.
//
// The database-level and derive-lock halves run for real. The rest is pinned
// structurally, for the reason `reset_quiesces_ingest_test.dart` gives: the
// paths need a radio or the whole plugin stack, and the failure mode is a new
// path that forgets the check.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

String _read(String path) => File(path).readAsStringSync();

String _resetBody() {
  final src = _read('lib/state/app_state.dart');
  final at = src.indexOf('Future<String?> resetAllData() async');
  return src.substring(at, src.indexOf('\n  }\n', at));
}

void main() {
  group('the commit gate checks the writer\'s own generation', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });
    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'reset_generation_rule_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDown(() async {
      ResetGate.resetForTest();
      await LocalDb.close();
    });

    test('a batch from a session that started before a finished reset is '
        'refused, though the gate is down again', () async {
      await LocalDb.instance;
      final startedUnder = ResetGate.generation;
      ResetGate.enter();
      await LocalDb.wipeAll();
      ResetGate.leave();
      expect(ResetGate.active, isFalse);
      await expectLater(
          LocalDb.commitSyncBatch(const [], const [],
              resetGeneration: startedUnder),
          throwsStateError);
      // A session that started after it commits normally.
      await LocalDb.commitSyncBatch(const [], const [],
          resetGeneration: ResetGate.generation);
    });
  });

  group('the derive lock', () {
    tearDown(() => DerivationEngine.debugRunning = false);

    test('the reset waits for a running pass, then no pass can start',
        () async {
      DerivationEngine.debugRunning = true; // a pass in flight
      expect(
          await DerivationEngine.acquireForReset(
              bound: const Duration(milliseconds: 300)),
          isFalse,
          reason: 'a pass that will not finish is not waited for forever');
      DerivationEngine.debugRunning = false;
      expect(await DerivationEngine.acquireForReset(), isTrue);
      expect(await DerivationEngine().run(const Profile()), 0,
          reason: 'a pass that tries to start during the wipe is skipped');
      DerivationEngine.releaseForReset();
      expect(DerivationEngine().running, isFalse);
    });

    test('resetAllData holds it from before the wipe until the finally', () {
      final body = _resetBody();
      final take = body.indexOf('await DerivationEngine.acquireForReset()');
      final wipe = body.indexOf('LocalDb.wipeAll()');
      final fin = body.indexOf('} finally {');
      final release = body.indexOf('DerivationEngine.releaseForReset()');
      expect(take, greaterThanOrEqualTo(0));
      expect(take, lessThan(wipe));
      expect(release, greaterThan(fin));
      expect(release, lessThan(body.indexOf('ResetGate.leave();')));
    });
  });

  group('resetAllData', () {
    test('a failed sensor lookup aborts it before anything is deleted', () {
      final src = _read('lib/state/app_state.dart');
      final helper = src.substring(
          src.indexOf('Future<List<String>> _secondaryDeviceIdsForReset()'));
      final helperBody = helper.substring(0, helper.indexOf('\n  }\n'));
      expect(helperBody.contains('rethrow;'), isTrue);
      expect(helperBody.contains('return const []'), isFalse,
          reason: 'an empty list wipes the rows and skips the key deletes');

      final body = _resetBody();
      final ids = body.indexOf('await _secondaryDeviceIdsForReset();');
      for (final destructive in [
        'Prefs.setString(Prefs.backupCadence',
        'backup.deleteAutomaticBackups()',
        '_stopSecondaryLinksForReset()',
        'LocalDb.wipeAll()',
      ]) {
        expect(ids, lessThan(body.indexOf(destructive)),
            reason: 'the lookup runs before $destructive');
      }
    });

    test('the primary link ends before the gate lowers, on every exit', () {
      final body = _resetBody();
      final fin = body.indexOf('} finally {');
      final tail = body.substring(fin);
      final disconnect =
          tail.indexOf('if (!primaryEnded && pastLookup) await engine.disconnect();');
      final banks = tail.indexOf('await engine.settleShutdownBanks();');
      final rebuild = tail.indexOf('_bandHost = _newPrimaryBandHost();');
      final lower = tail.indexOf('ResetGate.leave();');
      expect(disconnect, greaterThanOrEqualTo(0),
          reason: 'an exit before signOut must still close the link');
      expect(banks, greaterThan(disconnect));
      expect(rebuild, greaterThan(banks),
          reason: 'the replacement host must never serve the old link');
      expect(lower, greaterThan(rebuild));
      expect(body.indexOf('primaryEnded = true;'),
          greaterThan(body.indexOf('await signOut();')));
    });

    test('a failed sensor lookup leaves the primary band connected', () {
      final body = _resetBody();
      final ids = body.indexOf('await _secondaryDeviceIdsForReset();');
      final past = body.indexOf('pastLookup = true;');
      expect(past, greaterThan(ids));
      // Nothing between the lookup and the flag can throw.
      expect(body.substring(ids, past).split('\n').length, 2);
      expect(past, lessThan(body.indexOf('Prefs.setString(Prefs.backupCadence')));
    });

    test('a surface cleanup that throws does not skip signOut', () {
      final body = _resetBody();
      for (final call in [
        'await NotificationService.instance.cancelAll();',
        'await WidgetService.clear();',
      ]) {
        final at = body.indexOf(call);
        expect(at, greaterThanOrEqualTo(0), reason: call);
        final before = body.substring(0, at).trimRight();
        expect(before.endsWith('try {'), isTrue, reason: '$call is not caught');
      }
    });
  });

  test('every secondary link captures the generation before its first await '
      'and hands it to the host it builds', () {
    for (final f in [
      'ultrahuman',
      'colmi',
      'garmin',
      'pebble',
      'coros',
      'miband',
    ]) {
      final src = _read('lib/ble/${f}_link.dart');
      final sync = src.indexOf(RegExp(r'Future<bool> _sync\([^)]*\) async \{'));
      expect(sync, greaterThanOrEqualTo(0), reason: f);
      final firstAwait = src.indexOf('await ', sync);
      final cap = src.indexOf('final resetGen = ResetGate.generation;', sync);
      expect(cap, greaterThan(sync), reason: f);
      expect(cap, lessThan(firstAwait), reason: '$f reads it after an await');
      expect(
          src.contains(
              'if (_deviceId != deviceId || ResetGate.changedSince(resetGen))'),
          isTrue,
          reason: '$f: a sync parked on the slot must see the reset');
      expect(src.contains('resetGeneration: resetGen'), isTrue,
          reason: '$f builds its host without the session\'s generation');
    }
    for (final f in ['hrs', 'polar_pmd']) {
      final src = _read('lib/ble/${f}_link.dart');
      expect(src.contains('resetGeneration: resetGen,'), isTrue, reason: f);
    }
  });

  test('every BandHost commit carries the host\'s generation into the gate',
      () {
    final host = _read('lib/ble/adapters/host.dart');
    var at = host.indexOf('LocalDb.commitSyncBatch(');
    var n = 0;
    while (at >= 0) {
      final end = host.indexOf(');', at);
      expect(host.substring(at, end).contains('resetGeneration: _resetGeneration'),
          isTrue,
          reason: 'commit at offset $at');
      n++;
      at = host.indexOf('LocalDb.commitSyncBatch(', at + 1);
    }
    expect(n, 3);
  });

  test('a forget during the key read stops a keyed sync from connecting', () {
    for (final (f, forget) in [
      ('miband', 'static Future<bool> forgetBand(String id) async {'),
      ('oura', 'static Future<bool> forgetRing(String id) async {'),
    ]) {
      final src = _read('lib/ble/${f}_link.dart');
      final fg = src.indexOf(forget);
      final bump = src.indexOf('instance._forgets++;', fg);
      expect(bump, greaterThan(fg), reason: f);
      expect(bump, lessThan(src.indexOf('await ', fg)),
          reason: '$f bumps the count after an await');
      final sync = src.indexOf(RegExp(r'Future<bool> _sync\([^)]*\) async \{'));
      final cap = src.indexOf('final forgets = _forgets;', sync);
      expect(cap, greaterThan(sync), reason: f);
      expect(cap, lessThan(src.indexOf('await ', sync)), reason: f);
      final slot = src.indexOf('withSecondaryLinkSlot(', sync);
      final check = src.indexOf('if (_forgets != forgets) return false;', slot);
      expect(check, greaterThan(slot), reason: f);
      expect(check, lessThan(src.indexOf('.connect(', slot)), reason: f);
    }
  });

  test('a rejected Ultrahuman cursor write fails the sync', () {
    final src = _read('lib/ble/ultrahuman_link.dart');
    final w = src.indexOf('void _writeCursor(int index) {');
    final body = src.substring(w, src.indexOf('\n  }\n', w));
    expect(body.contains('_drainFailed = true;'), isTrue);
    expect(
        src.contains('!(host?.sessionFailed ?? false) &&\n'
            '            !ResetGate.changedSince(resetGen);'),
        isTrue);
  });

  test('a sync that did not save everything does not report success', () {
    for (final (f, result) in [
      ('garmin', 'return !lastSyncRefused && !host.sessionFailed;'),
      ('miband', 'return lastSyncFailure == null && !host.sessionFailed;'),
      ('pebble',
          'return lastSyncHeard && !lastSyncWriteRefused && !host.sessionFailed;'),
      ('colmi', 'return !lastSyncUnanswered && !host.sessionFailed;'),
      ('coros', 'return !host.sessionFailed;'),
      ('session', 'return !host.sessionFailed;'),
    ]) {
      expect(_read('lib/ble/${f}_link.dart').contains(result), isTrue,
          reason: f);
    }
  });

  test('a SessionLink session stopped while it ran does not report success',
      () {
    final src = _read('lib/ble/session_link.dart');
    final run = src.indexOf('await h.run(link)');
    final ret = src.indexOf('return !host.sessionFailed;', run);
    final window = src.substring(run, ret);
    expect(window.contains('if (stopped()) return false;'), isTrue,
        reason: 'a forget during the run would fire the done-hook');
  });

  test('the headless drain checks the generation it started under', () {
    final bg = _read('lib/sync/background_sync.dart');
    expect(bg.contains('bool stale() => ResetGate.changedSince(resetGen);'),
        isTrue);
    expect(bg.contains('resetGeneration: resetGen,'), isTrue,
        reason: 'its host');
    final run = bg.substring(bg.indexOf('Future<bool> runHeadlessSync('));
    final derive = run.indexOf('await DerivationEngine(');
    final check = run.lastIndexOf('if (ResetGate.changedSince(runGen))', derive);
    expect(check, greaterThanOrEqualTo(0),
        reason: 'no derive over a store a reset emptied mid-drain');
  });

  test('a workout\'s route is never written after a reset', () {
    final wc = _read('lib/state/workout_controller.dart');
    final at = wc.indexOf('final tracker = RouteTracker(');
    final sink = wc.substring(at, wc.indexOf('LocalDb.appendRoutePoints', at));
    expect(sink.contains('ResetGate.changedSince(resetGen)'), isTrue);
  });
}
