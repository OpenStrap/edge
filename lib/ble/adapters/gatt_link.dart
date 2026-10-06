// The real [BandLink]: `flutter_blue_plus` on one side, an adapter on the
// other.
//
// This file is HOST PLUMBING that happens to live in `adapters/` because
// MULTIBAND_PLAN §3.6 makes this directory the only place `protocol` may be
// imported, and the dangerous-opcode block below needs protocol's opcode
// tables. A contributor writing an adapter reads `adapter.dart` and their own
// `<id>.dart` and never this.
//
// It deliberately does NOT do: discovery, connect, bond, MTU negotiation,
// connection priority, CoreBluetooth restoration, AccessorySetupKit
// provisioning, or the process-wide band lock. Those are per-PLATFORM and
// per-APP concerns owned above the seam; a link is handed the services of an
// already-connected peripheral and does nothing but move bytes.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../ble_state.dart' show WriteChain;
import '_registry.dart';
import 'adapter.dart';

/// Whether the peripheral's [actual] uuid is the one [requested] names.
///
/// MATCHED ON `str128`, NOT `str`. `Guid.str` is the SHORTEST form: for any
/// SIG-assigned uuid (`0000xxxx-0000-1000-8000-00805f9b34fb`) it returns the
/// four-character short form, so `2a37` never starts with the `00002a37` prefix
/// a registry entry carries and the heart-rate measurement characteristic could
/// never be found — `HrsLink.arm` reported it MISSING on every strap and
/// aborted, which reads exactly like "the adapter doesn't work". WHOOP's uuids
/// are 128-bit either way, which is why gen4/gen5 never saw it and the first
/// SIG band did. `str128` is always the canonical lowercase full form.
///
/// Still a 32-bit prefix rather than equality: it is what the engine's own
/// match does, and it is what lets a registry entry name a family of uuids.
@visibleForTesting
bool gattUuidMatches(String requested, Guid actual) =>
    actual.str128.startsWith(requested.substring(0, 8).toLowerCase());

/// Forwards [source] verbatim, except the returned stream also ends the
/// moment [closeSignal] completes — even when [source] itself never emits
/// again and never completes on its own.
///
/// Factored out of [GattBandLink.notify] so the race can be unit-tested with
/// a plain, uncooperative [Stream] (`flutter_blue_plus` has no simulator
/// path, so a real [BluetoothCharacteristic] can't stand in for one here).
/// Without this, a source that goes quiet forever (an ordinary write+notify
/// band with nothing left to say) leaves a consumer's `await for` — and, in
/// turn, `StreamSubscription.cancel()` on that consumer — waiting on an event
/// that ends up never arriving.
@visibleForTesting
Stream<T> raceUntilClosed<T>(Stream<T> source, Future<void> closeSignal) {
  final controller = StreamController<T>();
  final sub = source.listen(
    controller.add,
    onError: controller.addError,
    onDone: () {
      if (!controller.isClosed) controller.close();
    },
  );
  unawaited(closeSignal.then((_) async {
    await sub.cancel();
    if (!controller.isClosed) await controller.close();
  }));
  return controller.stream;
}

/// A [BandLink] over an already-connected, already-discovered peripheral.
class GattBandLink implements BandLink {
  /// Which band this is, so [write] knows where the opcode byte sits. A band
  /// whose entry gets [BandEntry.frameOpcodeIndex] wrong reads the wrong byte
  /// and the dangerous-opcode block stops protecting it.
  final BandEntry entry;

  /// The peripheral's discovered services. Characteristics are matched on a
  /// 32-bit prefix of the 128-bit form, the same way `ble_engine` matches them
  /// — see [gattUuidMatches] for why the form, not the prefix, is the part
  /// that has to be said out loud.
  final List<BluetoothService> services;

  final void Function(String message) onLog;

  GattBandLink({
    required this.entry,
    required this.services,
    required this.onLog,
  });

  // Same numbers as the engine's, and for the same reason: an untimed GATT op
  // on a wedged stack hangs the session forever with no failure state to
  // recover from.
  static const Duration _notifyTimeout = Duration(seconds: 15);
  static const Duration _writeTimeout = Duration(seconds: 8);

  /// [read]'s own bound — deliberately shorter than [_notifyTimeout]. A
  /// one-shot status pull (Coros's battery/device-info reads) can run several
  /// of these BACK TO BACK before a session's bounded window ever reaches the
  /// notify phase; at 15s each, four sequential reads could burn a full
  /// minute on one unresponsive characteristic before the caller's own
  /// session timeout even has a chance to matter. 2s is still generous for a
  /// live GATT round trip, and it is what lets a caller doing four of these
  /// (Coros's status pull) size its own session window with real seconds left
  /// over for whatever comes after the reads, even in the fully-unresponsive
  /// worst case.
  static const Duration _readTimeout = Duration(seconds: 2);

  /// One write in flight at a time — the same [WriteChain] `BleEngine._write`
  /// runs on, one instance per link. Not shared with the engine's: two
  /// peripherals queueing behind each other is exactly what the per-remoteId
  /// ownership model exists to prevent.
  final WriteChain _chain = WriteChain();

  /// Set by the HOST when it tears this link down.
  ///
  /// This is `_write`'s `owner: session` guard, in the only currency a link
  /// has. A link is valid for exactly ONE connection (see [BandLink]), but a
  /// write queued before a teardown and reached after one would still land:
  /// `flutter_blue_plus` resolves a [BluetoothCharacteristic] against whatever
  /// connection to that peripheral is live NOW, not the one it was discovered
  /// on. So a stale adapter's offload ACK, with a re-used sequence number,
  /// writes onto a brand-new link — which is the failure `_write` has guarded
  /// against since the batch-ACK path was written.
  bool _closed = false;

  /// Completed by [close]. [notify] races its stream against this so a
  /// characteristic that never fires again (and never completes on its own —
  /// `BluetoothCharacteristic.onValueReceived` has no end) still lets an
  /// adapter's `await for` return instead of parking forever: without this,
  /// `StreamSubscription.cancel()` on that generator never resolves either,
  /// because a cancel can only be delivered at the generator's next
  /// suspension point and there isn't going to be one.
  final Completer<void> _closedSignal = Completer<void>();

  /// Refuse every write from here on, and end every live `notify()` stream.
  /// Idempotent; call it from the host's teardown, beside cancelling the
  /// `run()` subscription.
  void close() {
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
  }

  /// Test seam onto the write, the counterpart of `BleEngine.debugWriteHook`.
  /// [_closed] is checked BEFORE it, for the reason the engine's is: a seam
  /// that skips the guard it stands in for makes every test using it prove the
  /// wrong thing. `flutter_blue_plus` has no simulator path, so a link built
  /// with no services is the only way to exercise the guards at all.
  @visibleForTesting
  Future<bool> Function(List<int> value)? debugWriteHook;

  /// Which of [uuids] this peripheral does NOT expose. The host aborts the
  /// connect when it is non-empty — WHICH characteristics a link must have is
  /// registry data ([BandEntry.requiredCharacteristics]), and demanding four
  /// unconditionally is why a second parallel BLE stack once had to exist.
  List<String> missingCharacteristics(Iterable<String> uuids) =>
      [for (final u in uuids) if (_find(u) == null) u];

  BluetoothCharacteristic? _find(String uuid) {
    for (final s in services) {
      for (final c in s.characteristics) {
        if (gattUuidMatches(uuid, c.uuid)) return c;
      }
    }
    return null;
  }

  @override
  Stream<(int, List<int>)> notify(String characteristicUuid) {
    final c = _find(characteristicUuid);
    if (c == null) {
      log('notify: no characteristic ${characteristicUuid.substring(0, 8)} on '
          'this peripheral.');
      return const Stream.empty();
    }
    // THE SUBSCRIBE IS ISSUED HERE, synchronously, and NOT inside the generator
    // below. That ordering is the whole point of this being two statements.
    //
    // A generator's body does not run when its stream is listened to, only when
    // the scheduler next gets a turn. So with the `setNotifyValue` inside it,
    // the natural way to write "ask the device something and read the answer" —
    //
    //     final sub = link.notify(notifyChar).listen(...);
    //     await link.write(commandChar, askSomething());
    //
    // put the command into flutter_blue_plus's queue AHEAD of the CCCD write
    // that enables notifications, because there is no `await` between the two
    // and `.listen()` only schedules. The device answered into a subscription
    // that did not exist yet and the reply went on the floor.
    //
    // Traced on an Oura Gen3 (iOS 27): connected, two services discovered, the
    // nonce request written fine, then `no nonce came back within 10 s`, over
    // and over, against a ring that was working. The handshake reported that
    // the ring had stopped answering, which was exactly backwards — it
    // answered, nobody was listening.
    //
    // Issuing it before the stream is returned fixes it for every adapter at
    // once rather than for one caller, because flutter_blue_plus serialises all
    // GATT operations behind one global mutex (see [read]'s note on it), so a
    // write enqueued afterwards cannot overtake it.
    final subscribed = _closed
        ? Future.value(false)
        : c.setNotifyValue(true).timeout(_notifyTimeout).then(
            (_) => true,
            onError: (Object e) {
              log('notify: setNotifyValue failed: $e');
              return false;
            },
          );
    final raw = () async* {
      if (!await subscribed) return;
      // The arrival second is stamped HERE, at the edge of the radio, and
      // not inside the adapter — it is the closest we can get to when the
      // notification actually landed, and it keeps `DateTime.now()` out of
      // adapter code so a fixture can replay one deterministically.
      yield* c.onValueReceived.map(
        (v) => (DateTime.now().millisecondsSinceEpoch ~/ 1000, v),
      );
    }();
    return raceUntilClosed(raw, _closedSignal.future);
  }

  @override
  Future<List<int>?> read(String characteristicUuid) async {
    if (_closed) {
      log('read skipped: it belongs to a link that is no longer live.');
      return null;
    }
    final c = _find(characteristicUuid);
    if (c == null) {
      log('read: no characteristic ${characteristicUuid.substring(0, 8)} on '
          'this peripheral.');
      return null;
    }
    try {
      // The timeout goes INTO the call, not wrapped around it. flutter_blue_plus
      // serialises every GATT operation behind one global mutex and only
      // releases it when the operation's OWN future settles — an outer
      // `Future.timeout` does not cancel that future, so a wrapped read still
      // held the mutex (and the platform channel) for its internal default of
      // 15s regardless of how quickly this method gave up on it, and every
      // other BLE op on this phone — including the primary band's — queues
      // behind that same mutex.
      return await c.read(timeout: _readTimeout.inSeconds);
    } catch (e) {
      log('read error: $e');
      return null;
    }
  }

  /// Whether a write to a characteristic with [p] goes without response:
  /// only when that is the one write kind it declares.
  @visibleForTesting
  static bool writeWithoutResponseFor(CharacteristicProperties p) =>
      p.writeWithoutResponse && !p.write;

  @override
  Future<bool> write(String characteristicUuid, List<int> value) {
    // THE DANGEROUS-OPCODE BLOCK, at the one place every adapter's writes
    // funnel through. It is here rather than in adapter code precisely so no
    // adapter — including one a contributor wrote — can reach FORCE_TRIM
    // (whose full-erase form is two 0xFEFEFEFE args), REBOOT or POWER_CYCLE by
    // any path. There is no opt-out parameter: the one audited exception in
    // this app (gen5 deep buffers) writes through `ble_engine._write`, which
    // keeps its own carve-out, single and reviewed.
    final opcode = _opcodeOf(value);
    if (opcode != null &&
        (dangerousCmds.contains(opcode) || OpcodeSafety.isDestructive(opcode))) {
      log('REFUSED dangerous opcode 0x${opcode.toRadixString(16)} at BandLink');
      return Future.value(false);
    }
    // The Colmi ring has no envelope for the check above to read, but its
    // command byte is frame[0] on its write characteristic: reboot and
    // factory reset are refused here the same way.
    if (entry.id == kColmi.id &&
        characteristicUuid == kColmiWriteChar &&
        colmiIsDestructive(value)) {
      log('REFUSED dangerous Colmi command 0x${value[0].toRadixString(16)} '
          'at BandLink');
      return Future.value(false);
    }
    // A Coros link is read-only. Its vendor channel takes unauthenticated
    // commands (a factory reset, a Bluetooth-address rotation), and nothing
    // here has a reason to write to the watch, so every write is refused
    // rather than a denylist kept for that channel.
    if (entry.id == kCoros.id) {
      log('REFUSED: a Coros link is read-only.');
      return Future.value(false);
    }
    // Refused BEFORE the chain, as in the engine: a blocked opcode must not
    // wait behind a parked write to be refused.
    return _chain.add<bool>(() async {
      try {
        if (_closed) {
          log('write skipped: it belongs to a link that is no longer live.');
          return false;
        }
        final hook = debugWriteHook;
        if (hook != null) return await hook(value);
        final c = _find(characteristicUuid);
        if (c == null) {
          log('write: no characteristic ${characteristicUuid.substring(0, 8)} '
              'on this peripheral.');
          return false;
        }
        // With response wherever the characteristic allows it: that is what
        // triggers bonding AND what gets commands acknowledged; a
        // without-response write is silently dropped by the band. A
        // characteristic that only declares write-without-response (the
        // Ultrahuman command characteristic may) would refuse a
        // with-response write outright, so it gets the only kind it takes.
        // allowLongWrite covers the one frame that exceeds the 20-byte ATT
        // limit of a default MTU (the rich SET_ALARM_TIME), and is a no-op
        // below it; it needs a with-response write.
        final noResponse = writeWithoutResponseFor(c.properties);
        await c
            .write(value,
                withoutResponse: noResponse, allowLongWrite: !noResponse)
            .timeout(_writeTimeout);
        return true;
      } on TimeoutException {
        log('write timeout: no GATT response in ${_writeTimeout.inSeconds}s.');
        return false;
      } catch (e) {
        log('write error: $e');
        return false;
      }
    });
  }

  /// The command opcode carried by an already-framed outbound write, or null
  /// when this band has no envelope (nothing to read an opcode out of) or the
  /// frame is too short to carry one.
  int? _opcodeOf(List<int> raw) {
    if (!entry.isFramed) return null;
    final i = entry.frameOpcodeIndex;
    return i < raw.length ? raw[i] : null;
  }

  @override
  void log(String message) => onLog(message);
}
