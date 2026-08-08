// "Don't get to know if syncing is happening or not" (TestFlight).
//
// The window has to hold across the gaps between batches (or an indicator
// strobes) and it has to expire (or a finished drain looks like a running one
// forever). Pure, so both edges are testable without a band.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  test('nothing has arrived, so nothing is syncing', () {
    final w = SyncActivityWindow();
    expect(w.isActive(1000), isFalse);
    expect(w.expiresAtMs(), isNull);
  });

  test('a batch holds the answer true across the gap to the next one', () {
    final w = SyncActivityWindow(windowMs: 6000);
    w.mark(10000);
    expect(w.isActive(10000), isTrue);
    expect(w.isActive(15999), isTrue, reason: 'still inside the window');
    expect(w.isActive(16000), isFalse, reason: 'the window is half-open');
    expect(w.expiresAtMs(), 16000);
  });

  test('each batch re-arms the window', () {
    final w = SyncActivityWindow(windowMs: 6000);
    w.mark(10000);
    w.mark(14000);
    expect(w.isActive(18000), isTrue, reason: 'measured from the LAST batch');
    expect(w.isActive(20000), isFalse);
  });

  test('a long-finished drain does not still read as syncing', () {
    final w = SyncActivityWindow(windowMs: 6000);
    w.mark(1000);
    expect(w.isActive(1000 + 60 * 60 * 1000), isFalse);
  });
}
