// Shared helpers for the AppState band-gesture tests. Everything goes through
// AppState's public and @visibleForTesting surface (plus the dispatcher's
// clock hook), so the same files keep passing wherever the dispatcher lives.
//
// A strap double tap travels the real path: an EVENT frame handed to the
// engine's immediate-frame handler (the engine's onEvent is AppState's live
// event entry in AppState.forTesting), then event persistence (a real LocalDb
// over sqflite_ffi), the alarm handler, the GestureDispatcher, and either the
// native-action channel (mocked here) or one of AppState's three in-app
// handlers (a fake journal repository and the haptics channel are mocked).
//
// The dispatcher's recency window and debounce read a clock; the rig replaces
// it with a fake one so a test can place a tap exactly at a boundary.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// EventId.doubleTap, the only event the dispatcher acts on.
const int kDoubleTapEventId = 14;

Future<void> gestureDbSetUp(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
  SharedPreferences.setMockInitialValues({});
}

Future<void> gestureDbTearDown(String name) async {
  // Fire-and-forget writes (event rows, workout teardown) must land before the
  // handle closes under them.
  await settleMs(400);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
}

/// Polls until [ok]; fails the test, naming [what], if [within] runs out.
Future<void> until(bool Function() ok,
    {Duration within = const Duration(seconds: 4), String? what}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (!DateTime.now().isBefore(end)) {
      throw TestFailure('until(${what ?? 'condition'}) was not met within '
          '${within.inMilliseconds} ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
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

/// The `openstrap/device_actions` method channel: records every `perform`.
class ActionChannel {
  ActionChannel({this.ok = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, (call) async {
      if (call.method == 'perform') {
        performed.add((call.arguments as Map)['action'] as String);
        return ok;
      }
      return null;
    });
  }
  static const _ch = MethodChannel('openstrap/device_actions');
  bool ok;
  final performed = <String>[];

  void dispose() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ch, null);
}

/// The platform channel's haptic calls (HapticFeedback.mediumImpact etc.).
class HapticSpy {
  HapticSpy() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') calls.add('${call.arguments}');
      return null;
    });
  }
  final calls = <String>[];

  void dispose() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

/// An in-memory journal and workout seam. Every hook is optional so a test can
/// block, fail or observe one call.
class FakeJournalRepo extends LocalRepository {
  /// Journal entries as `getJournal` returns them: date, tags, note.
  final entries = <Map<String, dynamic>>[];

  /// Per-day metrics as `getJournalMetrics` returns them.
  final metrics = <String, Map<String, JournalMetricValue>>{};

  /// Every `postJournal` and `postJournalMetrics`, in order.
  final journalPosts = <({String date, List<String> tags, String note})>[];
  final metricPosts = <({String date, Map<String, JournalMetricValue> fields})>[];
  final calls = <String>[];

  Object? getJournalThrows;
  Object? postJournalThrows;
  Object? getMetricsThrows;
  Object? postMetricsThrows;
  Object? startWorkoutThrows;
  Object? endWorkoutThrows;
  Map<String, dynamic>? startWorkoutAnswer = {'workout_id': 'srv-1'};

  /// When set, `getJournalMetrics` waits for it after reading the day (the
  /// read-modify-write window the water latch guards).
  Completer<void>? metricsReadGate;

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async {
    calls.add('getJournal:$range');
    if (getJournalThrows != null) throw getJournalThrows!;
    return [for (final e in entries) {...e}];
  }

  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {
    calls.add('postJournal');
    if (postJournalThrows != null) throw postJournalThrows!;
    journalPosts.add((date: date, tags: List.of(tags), note: note));
  }

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async {
    calls.add('getJournalMetrics');
    if (getMetricsThrows != null) throw getMetricsThrows!;
    final snapshot = {...?metrics[date]};
    final gate = metricsReadGate;
    if (gate != null) await gate.future;
    return snapshot;
  }

  @override
  Future<void> postJournalMetrics(
      String date, Map<String, JournalMetricValue> fields) async {
    calls.add('postJournalMetrics');
    if (postMetricsThrows != null) throw postMetricsThrows!;
    metricPosts.add((date: date, fields: {...fields}));
    metrics[date] = {...fields};
  }

  @override
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) async {
    calls.add('start:$type');
    if (startWorkoutThrows != null) throw startWorkoutThrows!;
    return startWorkoutAnswer!;
  }

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    calls.add('end:$workoutId');
    if (endWorkoutThrows != null) throw endWorkoutThrows!;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

/// An AppState (default forTesting engine) a test taps the band on. The
/// dispatcher's clock is [now], advanced with [advance].
class GestureRig {
  GestureRig({DateTime? start})
      : now = start ?? DateTime(2026, 10, 5, 12, 0, 0),
        app = AppState.forTesting() {
    GestureDispatcher.now = () => now;
    engine = app.engine;
  }

  final AppState app;
  late final BleEngine engine;

  /// The dispatcher's wall clock.
  DateTime now;

  int _seq = 0;
  bool _disposed = false;

  void advance(Duration d) => now = now.add(d);

  int get nowSec => now.millisecondsSinceEpoch ~/ 1000;

  /// Hand the engine one band event, exactly as the radio does. Every call is
  /// a distinct event (its own strap sub-second). [atSec] is the strap's own
  /// timestamp (default: the rig clock's now).
  void event(int id, {int? atSec}) {
    final sec = atSec ?? nowSec;
    _seq++;
    final inner = Uint8List(12);
    final v = ByteData.sublistView(inner);
    inner[0] = PacketType.event;
    inner[1] = 0x07;
    v.setUint16(2, id, Endian.little);
    v.setUint32(4, sec, Endian.little);
    v.setUint16(8, 100 + 37 * _seq, Endian.little);
    v.setUint16(10, 0, Endian.little);
    engine.debugProcessImmediateFrame(Frame(inner, true, true));
  }

  /// One band double tap at the strap time [atSec] (default: the rig clock).
  void doubleTap({int? atSec}) => event(kDoubleTapEventId, atSec: atSec);

  /// A double tap whose strap timestamp is [age] behind the rig clock.
  void doubleTapAged(Duration age) =>
      doubleTap(atSec: nowSec - age.inSeconds);

  Future<void> map(DeviceAction a) => app.gestureSettings.setDoubleTap(a);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    GestureDispatcher.now = DateTime.now;
    app.dispose();
    BleEngine.resetBandClaimForTest();
  }
}

/// Stored band events, oldest first: (event_id, ts, device_id).
Future<List<({int id, int ts, String device})>> storedEvents() async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT event_id, ts, device_id FROM events ORDER BY rowid');
  return [
    for (final r in rows)
      (
        id: (r['event_id'] as num).toInt(),
        ts: (r['ts'] as num).toInt(),
        device: '${r['device_id']}',
      ),
  ];
}
