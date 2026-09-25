import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';

void main() {
  setUp(HeadlessSyncGate.resetForTest);

  test('returns completed work without cancelling it', () async {
    final task = ShortcutSyncTask('one', const Duration(seconds: 1));
    var stopped = false;
    task.onStop = () => stopped = true;
    final result = await task.waitFor(
      Future.value(const ShortcutSyncResult('complete', records: 12)),
    );
    expect(result.toMap(), {'status': 'complete', 'records': 12});
    expect(stopped, isFalse);
  });

  test(
    'a connection deadline is distinguishable from a partial drain',
    () async {
      for (final phase in [
        'starting',
        'initializing',
        'connecting',
        'syncing',
        'processing',
      ]) {
        final task = ShortcutSyncTask('one', Duration.zero)
          ..update(phase, records: 9);
        final result = await task.waitFor(
          Completer<ShortcutSyncResult>().future,
        );
        expect(result.status, switch (phase) {
          'starting' || 'initializing' => 'timedOut',
          'connecting' => 'bandUnreachable',
          _ => 'partial',
        });
        expect(result.records, 9);
      }
    },
  );

  test(
    'cancellation stops once and does not report subsequent progress',
    () async {
      final updates = <Map<String, Object>>[];
      final task = ShortcutSyncTask(
        'one',
        const Duration(seconds: 1),
        onProgress: updates.add,
      );
      var stops = 0;
      task.onStop = () => stops++;
      task.update('syncing', records: 15, batches: 2);
      final result = task.waitFor(Completer<ShortcutSyncResult>().future);
      task.stop('cancelled');
      task.stop('failed');
      task.update('syncing', records: 40);
      expect((await result).status, 'cancelled');
      expect(stops, 1);
      expect(updates, [
        {'id': 'one', 'phase': 'syncing', 'records': 15, 'batches': 2},
      ]);
    },
  );

  test(
    'deadline returns without releasing the ownership gate during cleanup',
    () async {
      final cleanup = Completer<ShortcutSyncResult>();
      final task = ShortcutSyncTask('one', Duration.zero)..update('syncing');
      final work = HeadlessSyncGate.tryRun('shortcut', () => cleanup.future);
      final result = await task.waitFor(work.then((value) => value!));
      expect(result.status, 'partial');
      expect(HeadlessSyncGate.busy, isTrue);
      var secondRan = false;
      expect(
        await HeadlessSyncGate.tryRun('other', () async => secondRan = true),
        isNull,
      );
      expect(secondRan, isFalse);
      cleanup.complete(const ShortcutSyncResult('partial'));
      await work;
      expect(HeadlessSyncGate.busy, isFalse);
    },
  );

  test('unexpected failures are not converted to connectivity skips', () async {
    final task = ShortcutSyncTask('one', const Duration(seconds: 1));
    final work = Future<ShortcutSyncResult>.error(StateError('storage failed'));
    await expectLater(task.waitFor(work), throwsStateError);
  });
}
