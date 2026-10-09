// Start-up and the derive scheduler: the scheduler's durable jobs are
// recovered, and a foreground start rolls up pending activity reviews while a
// headless one leaves them for the next resume.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_app_state_derive_startup.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(deriveDbReset);

  AppState make() {
    final a = AppState.forTesting();
    addTearDown(() async {
      // The fire-and-forget tails of start-up read the database and notify.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      a.dispose();
    });
    return a;
  }

  test('a foreground start-up rolls up pending activity reviews once',
      () async {
    final app = make();
    var calls = 0;
    app.debugRefreshActivityReviews = (_) async {
      calls++;
      return true;
    };
    final revs = SignalLog(app);
    await app.debugInit();
    await until(() => calls > 0, what: 'start-up asked for the rollup');
    expect(calls, 1);
    expect(app.initialized, isTrue);
    await until(() => revs.revisions >= 2, what: 'opening and success bumps');
  });

  test('a headless start-up does not roll up', () async {
    final app = make();
    var calls = 0;
    app.debugRefreshActivityReviews = (_) async {
      calls++;
      return true;
    };
    await app.pauseForBackground();
    await app.debugInit();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(app.initialized, isTrue);
    expect(calls, 0);
  });

  test('start-up recovers a derive job a killed process left running',
      () async {
    final db = await LocalDb.instance;
    await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
    await db.update('compute_jobs', {'state': 'running'});
    expect(await LocalDb.computeJobs(state: 'queued', limit: 10), isEmpty);

    final app = make();
    app.debugRefreshActivityReviews = (_) async => true;
    await app.debugInit();
    expect(await LocalDb.computeJobs(state: 'queued', limit: 10), hasLength(1));
    expect(app.derivePending, isTrue);
  });
}
