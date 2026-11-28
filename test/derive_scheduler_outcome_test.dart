// A job is only retired when its pass really ran. A pass dropped on a held
// engine latch, or one that failed, used to be deleted all the same, so the
// data that queued it waited for some later sync to be derived.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_derive_scheduler_outcome.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(deriveDbReset);

  DeriveScheduler scheduler(List<DeriveRunOutcome> outcomes, List<int> runs) {
    final s = DeriveScheduler(
      run: ({required DeriveJobKind kind}) async {
        runs.add(1);
        return outcomes.length > 1 ? outcomes.removeAt(0) : outcomes.first;
      },
      log: (_) {},
      onChanged: () {},
      lightSettle: const Duration(milliseconds: 10),
    );
    addTearDown(s.dispose);
    return s;
  }

  test('a pass dropped on a busy engine keeps its job and runs again',
      () async {
    final runs = <int>[];
    final s = scheduler([
      DeriveRunOutcome.busy,
      DeriveRunOutcome.busy,
      DeriveRunOutcome.done,
    ], runs);
    s.markStoredData();
    await until(() => runs.length == 3 && !s.running && !s.pendingLight,
        within: const Duration(seconds: 3), what: 'the job ran to done');
    expect(await LocalDb.computeJobs(), isEmpty);
  });

  test('a failing pass is retried, then parked as failed', () async {
    final runs = <int>[];
    final s = scheduler([DeriveRunOutcome.failed], runs);
    s.markStoredData();
    await until(() => runs.length == DeriveScheduler.maxFailedAttempts &&
            !s.running && !s.pendingLight,
        within: const Duration(seconds: 3), what: 'retries ran out');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(runs.length, DeriveScheduler.maxFailedAttempts);
    final jobs = await LocalDb.computeJobs();
    expect(jobs.single['state'], 'failed');
  });
}
