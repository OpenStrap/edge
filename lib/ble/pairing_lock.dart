// The one lock typed-key pairing, forget and "delete everything" share,
// across every family that pairs with a vendor key (the Helio Strap and the
// Zepp OS devices, Mi Band 4-6 and the first Amazfit watches). Each holds it
// only around its own short critical section, never across a Bluetooth
// connection, a handshake or the secondary-link slot, and nothing that holds
// it waits on another lock, so it cannot hold up a radio or deadlock.

import 'dart:async';

/// A FIFO async lock: [run]s take turns, in call order.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() op) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }
}

final AsyncMutex pairingLock = AsyncMutex();
