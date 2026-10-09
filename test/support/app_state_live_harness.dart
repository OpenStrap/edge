// Shared helpers for the AppState live-stream tests. Everything goes through
// AppState's public and @visibleForTesting surface, so the same files keep
// passing wherever the live-stream ownership code lives.
//
// LiveRig is an AppState over an engine wired the way the production
// constructor wires it for the live path (onLiveFrame, liveOwners) with a fake
// gen5/gen4 link that records every command the engine writes. The engine's
// owner callback is counted, which is how a test sees that AppState nudged the
// engine (the engine reads the owner set once per reconcile pass).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef LiveWrite = ({int opcode, List<int> body});

int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Future<void> liveDbSetUp(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
  SharedPreferences.setMockInitialValues({});
}

Future<void> liveDbTearDown(String name) async {
  // Fire-and-forget writes from the last test (workout teardown, device rows)
  // must land before the handle closes under them.
  await settleMs(400);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
}

Future<void> settleMs([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Counts AppState notifications.
class TickCounter {
  TickCounter(this.app) {
    app.addListener(_tick);
  }
  final AppState app;
  int ticks = 0;
  void _tick() => ticks++;
  void stop() => app.removeListener(_tick);
}

/// SQLite's total_changes() on the app's own connection: any INSERT, UPDATE or
/// DELETE moves it.
Future<int> dbChanges() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT total_changes() AS n');
  return (r.single['n'] as num).toInt();
}

// ── frame builders (synthetic, shape-correct) ────────────────────────────────

/// 0x28 compact realtime HR: ts@2, hr@8, rr_count@9, rr i16@10.., wearing@18.
Uint8List hr28Inner({int hr = 62, List<int> rr = const [], int? ts}) {
  final b = Uint8List(20);
  final v = ByteData.sublistView(b);
  b[0] = 0x28;
  v.setUint32(2, ts ?? nowSec(), Endian.little);
  b[8] = hr;
  b[9] = rr.length;
  for (var i = 0; i < rr.length; i++) {
    v.setInt16(10 + 2 * i, rr[i], Endian.little);
  }
  b[18] = 1;
  return b;
}

/// gen5 live IMU: a 0x2B envelope carrying a record-21 buffer (100 accel and
/// 100 gyro samples per axis, raw int16 LSBs).
Uint8List r21LiveInner({int ax = 4096, int ay = 2048, int az = 0, int? unix}) {
  final b = Uint8List(kGen5V21InnerLen);
  final v = ByteData.sublistView(b);
  b[0] = 0x2B;
  b[1] = 21;
  b[2] = 0x80;
  v.setUint32(3, 1, Endian.little);
  v.setUint32(7, unix ?? nowSec(), Endian.little);
  v.setUint16(16, 100, Endian.little);
  v.setUint16(622, 100, Endian.little);
  for (var i = 0; i < 100; i++) {
    v.setInt16(20 + 2 * i, ax, Endian.little);
    v.setInt16(220 + 2 * i, ay, Endian.little);
    v.setInt16(420 + 2 * i, az, Endian.little);
  }
  return b;
}

/// gen4 live R10 (0x2B, rec 10, 1920 bytes): ts@7, hr@17, rr_count@18, rr@19,
/// accel X@85 (100 int16).
Uint8List r10LiveInner({int hr = 64, List<int> rr = const [900], int? ts}) {
  final b = Uint8List(1920);
  final v = ByteData.sublistView(b);
  b[0] = 0x2B;
  b[1] = 10;
  v.setUint32(3, 7, Endian.little);
  v.setUint32(7, ts ?? nowSec(), Endian.little);
  b[17] = hr;
  b[18] = rr.length;
  for (var i = 0; i < rr.length; i++) {
    v.setInt16(19 + 2 * i, rr[i], Endian.little);
  }
  for (var i = 0; i < 100; i++) {
    v.setInt16(85 + 2 * i, 4096, Endian.little);
  }
  return b;
}

/// gen4 0x33 IMU stream: ts@4, idx@14, 10 samples each of X, Y, Z int16 from 24.
Uint8List imu33Inner({int ax = 4096, int ay = 0, int az = 0, int? ts}) {
  final b = Uint8List(84);
  final v = ByteData.sublistView(b);
  b[0] = 0x33;
  v.setUint32(4, ts ?? nowSec(), Endian.little);
  v.setUint16(14, 1, Endian.little);
  for (var i = 0; i < 10; i++) {
    v.setInt16(24 + 2 * i, ax, Endian.little);
    v.setInt16(24 + 2 * (10 + i), ay, Endian.little);
    v.setInt16(24 + 2 * (20 + i), az, Endian.little);
  }
  return b;
}

/// Hex of an inner packet, the way the engine hands it to onLiveFrame.
String hexOf(Uint8List inner) =>
    inner.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// ── the rig ──────────────────────────────────────────────────────────────────

class LiveRig {
  LiveRig({this.band = BandProfile.gen5}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
      onLiveFrame: (pt, hex, ts) => app.debugOnLiveFrame(pt, hex, ts),
      liveOwners: () {
        ownerReads++;
        return app.debugLiveOwners;
      },
    );
    app = AppState.forTesting(engine: engine);
    engine.debugInstallFakeLink(
      band: band,
      listening: true,
      onWrite: (Uint8List frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        writes.add((opcode: inner[2], body: inner.sublist(3)));
        return true;
      },
    );
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1');
    engine.state.generation = band.isGen5 ? 'gen5' : 'gen4';
    engine.state.connection = 'connected';
  }

  final BandProfile band;
  late final BleEngine engine;
  late final AppState app;
  final logs = <String>[];

  /// Every write that reached the (fake) radio, in order.
  final writes = <LiveWrite>[];

  /// How many times the engine asked for the owner set.
  int ownerReads = 0;

  /// `(opcode, on/off)`. The gen5 IMU toggle carries `[rev1, on]`; HR a bare
  /// `[on]`.
  List<(int, int)> get ops => [
        for (final w in writes)
          (
            w.opcode,
            w.opcode == Cmd.toggleImuMode && band.isGen5 ? w.body[1] : w.body[0],
          ),
      ];

  /// One inbound live frame through the real engine immediate-frame path.
  void feed(Uint8List inner) =>
      engine.debugProcessImmediateFrame(Frame(inner, true, true));

  /// Wait for the engine's coalesced reconcile pass, write gaps included: a
  /// caller that arrives mid-pass is a barrier for the pass that sees it.
  Future<void> settle() => engine.reconcileLiveStreams();

  Future<void> dispose() async {
    app.dispose();
    BleEngine.resetBandClaimForTest();
  }
}
