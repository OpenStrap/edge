// ASSUMPTIONS G5: `GattBandLink.write` shipped without the two wire guards
// `BleEngine._write` has had since the batch-ACK path was written — write-chain
// serialisation, and the staleness guard that stops a write queued by a dead
// session landing on a live one. Both are silent when they are missing: the
// frame is simply dropped, reordered, or written to the wrong connection.
//
// `flutter_blue_plus` has no simulator path, so this drives the link with NO
// services and its `debugWriteHook` — which is why that hook exists. The guards
// are checked BEFORE the hook, so what is asserted here is the real path.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show Guid;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/gatt_link.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

GattBandLink _link() => GattBandLink(
      entry: kWhoopGen4,
      services: const [],
      onLog: (_) {},
    );

void main() {
  test('WriteChain runs one op at a time, in order', () async {
    final chain = WriteChain();
    final order = <String>[];
    var inFlight = 0;
    var maxInFlight = 0;

    Future<int> op(String name, int ms) => chain.add<int>(() async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await Future<void>.delayed(Duration(milliseconds: ms));
          order.add(name);
          inFlight--;
          return ms;
        });

    // The long one is queued FIRST: without serialisation the short one
    // finishes first and both are in flight together.
    final results = await Future.wait([op('slow', 40), op('fast', 1)]);

    expect(maxInFlight, 1);
    expect(order, <String>['slow', 'fast']);
    expect(results, <int>[40, 1]);
  });

  test('a failing op does not wedge the writes behind it', () async {
    final chain = WriteChain();
    await expectLater(
      chain.add<int>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(await chain.add<int>(() async => 7), 7);
  });

  test('the link serialises its writes onto one chain', () async {
    final link = _link();
    final order = <int>[];
    var inFlight = 0;
    var maxInFlight = 0;
    link.debugWriteHook = (value) async {
      inFlight++;
      maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
      await Future<void>.delayed(Duration(milliseconds: value.first));
      order.add(value.first);
      inFlight--;
      return true;
    };

    await Future.wait([
      link.write(kWhoopGen4.gatt!.cmdTo, const [40]),
      link.write(kWhoopGen4.gatt!.cmdTo, const [1]),
    ]);

    expect(maxInFlight, 1);
    expect(order, <int>[40, 1]);
  });

  test('a write queued before close() never reaches the radio after it',
      () async {
    // The shipped hazard: `flutter_blue_plus` resolves a characteristic against
    // whatever connection is live NOW, so a stale adapter's queued ACK writes
    // onto a brand-new link with a re-used sequence number.
    final link = _link();
    final written = <List<int>>[];
    final gate = Completer<void>();
    link.debugWriteHook = (value) async {
      written.add(value);
      await gate.future;
      return true;
    };

    final first = link.write(kWhoopGen4.gatt!.cmdTo, const [1]);
    final queued = link.write(kWhoopGen4.gatt!.cmdTo, const [2]);
    // Let the first write actually reach the hook. The guard is judged when a
    // write DEQUEUES, not when it is submitted — which is the whole point: a
    // write parked behind a long commit is judged against the link that will
    // carry it, not the one that queued it.
    await Future<void>.delayed(Duration.zero);
    // The host tears the link down while the first write is still in flight.
    link.close();
    gate.complete();

    expect(await first, isTrue);
    expect(await queued, isFalse, reason: 'refused on a link that is gone');
    expect(written, <List<int>>[
      const [1],
    ]);
  });

  test('close() does not weaken the dangerous-opcode block', () {
    // The block sits BEFORE the chain, so a destructive opcode is refused
    // without waiting behind a parked write — and it is still refused.
    final link = _link();
    var reached = false;
    link.debugWriteHook = (_) async {
      reached = true;
      return true;
    };
    final frame = buildCommand(7, Cmd.forceTrim, const <int>[0x01],
        kWhoopGen4.wire!);
    expect(link.write(kWhoopGen4.gatt!.cmdTo, frame), completion(isFalse));
    expect(reached, isFalse);
  });

  test('read() on a characteristic the peripheral does not expose returns '
      'null rather than throwing', () async {
    final link = _link();
    expect(await link.read(kHeartRateMeasurementUuid), isNull);
  });

  group('gattUuidMatches', () {
    test('a SIG 16-bit characteristic matches its registry entry', () {
      // `Guid.str` for `00002a37-0000-1000-8000-00805f9b34fb` is `2a37` — the
      // SHORTEST form, not the platform's whim — so a `00002a37` prefix match
      // against it fails on EVERY platform. `HrsLink.arm` then reported the
      // heart-rate measurement characteristic missing and aborted, which reads
      // as "the adapter doesn't work" and is four characters of comparison.
      expect(Guid(kHeartRateMeasurementUuid).str, '2a37');
      expect(gattUuidMatches(kHeartRateMeasurementUuid,
          Guid(kHeartRateMeasurementUuid)), isTrue);
      expect(gattUuidMatches(kHeartRateServiceUuid, Guid('180d')), isTrue);
    });

    test('WHOOP 128-bit uuids are unaffected, and a mismatch still misses', () {
      final cmdTo = kWhoopGen4.gatt!.cmdTo;
      expect(gattUuidMatches(cmdTo, Guid(cmdTo)), isTrue);
      expect(gattUuidMatches(cmdTo, Guid(kWhoopGen4.gatt!.cmdFrom)), isFalse);
      expect(gattUuidMatches(kHeartRateMeasurementUuid, Guid('2a38')), isFalse);
    });
  });
}
