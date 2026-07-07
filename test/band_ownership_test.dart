import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';

void main() {
  setUp(BandOwnership.resetForTest);

  test('headless cannot acquire while foreground intent is active', () {
    BandOwnership.markForegroundIntent(true);
    expect(BandOwnership.tryAcquireHeadless(), isNull);
  });

  test('foreground waits for active headless owner to release', () async {
    final headless = BandOwnership.tryAcquireHeadless();
    expect(headless, isNotNull);

    final future = BandOwnership.acquireForeground();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(BandOwnership.owner, BandOwnerKind.headless);

    BandOwnership.release(headless!);
    final foreground = await future;
    expect(foreground.kind, BandOwnerKind.foreground);
    expect(BandOwnership.owner, BandOwnerKind.foreground);
  });

  test(
    'headless acquires when band is free and no foreground intent exists',
    () {
      final lease = BandOwnership.tryAcquireHeadless();
      expect(lease, isNotNull);
      expect(BandOwnership.owner, BandOwnerKind.headless);
    },
  );

  test('released foreground owner allows later headless recovery', () async {
    final foreground = await BandOwnership.acquireForeground();
    expect(BandOwnership.owner, BandOwnerKind.foreground);

    BandOwnership.markForegroundIntent(false);
    BandOwnership.release(foreground);

    final headless = BandOwnership.tryAcquireHeadless();
    expect(headless, isNotNull);
    expect(BandOwnership.owner, BandOwnerKind.headless);
  });

  test('foreground acquire is re-entrant for the same process owner', () async {
    final first = await BandOwnership.acquireForeground();
    final second = await BandOwnership.acquireForeground();

    expect(first.kind, BandOwnerKind.foreground);
    expect(second.kind, BandOwnerKind.foreground);
    expect(second.token, first.token);
    expect(BandOwnership.owner, BandOwnerKind.foreground);
  });

  test(
    'headless cannot steal ownership while foreground lease is held',
    () async {
      final foreground = await BandOwnership.acquireForeground();

      BandOwnership.markForegroundIntent(false);
      final headless = BandOwnership.tryAcquireHeadless();

      expect(headless, isNull);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      BandOwnership.release(foreground);
      expect(BandOwnership.owner, isNull);
    },
  );
}
