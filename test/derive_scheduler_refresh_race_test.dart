// A refresh of the scheduler's pending snapshot that is already in flight when
// an enqueue asks for its own must not swallow that request: the enqueue arms
// its settle timer off the snapshot it awaited, and a refresh that returned
// early left it reading "nothing pending" with the job sitting queued.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_derive_scheduler_refresh_race.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(deriveDbReset);

  Future<({int runs, DeriveScheduler s})> scenario({required bool flip}) async {
    final db = await LocalDb.instance;
    var runs = 0;
    final s = DeriveScheduler(
      run: ({required DeriveJobKind kind}) async => runs++,
      log: (_) {},
      onChanged: () {},
      lightSettle: const Duration(milliseconds: 50),
    );
    addTearDown(s.dispose);
    // Hold the database so the enqueue transaction, and anything issued after
    // it, queue up behind this one in a known order.
    final gate = Completer<void>();
    final holder = db.transaction((txn) => gate.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    s.markStoredData();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (flip) {
      // An offload settling while the enqueue is still in its transaction:
      // with nothing pending yet, _arm starts a refresh that arms nothing.
      s.setOffloadActive(true);
      s.setOffloadActive(false);
    }
    gate.complete();
    await holder;
    await until(() => runs > 0,
        within: const Duration(seconds: 3), what: 'the queued job drained');
    return (runs: runs, s: s);
  }

  test('a queued job drains with no concurrent refresh', () async {
    final r = await scenario(flip: false);
    expect(r.runs, 1);
  });

  test('a queued job still drains when an idle refresh was in flight',
      () async {
    final r = await scenario(flip: true);
    expect(r.runs, 1);
    await until(() => !r.s.pendingLight, what: 'snapshot caught up');
    expect(await LocalDb.computeJobs(state: 'queued'), isEmpty);
  });
}
