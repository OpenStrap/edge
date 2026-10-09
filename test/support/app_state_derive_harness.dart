// Shared helpers for the AppState derive tests: a throwaway database, the
// engine hooks AppState exposes for tests, and observers for the two signals a
// pass emits (notifyListeners ticks and insightsRevision).

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/app_state.dart';

/// Point LocalDb at an empty file called [name] and reset prefs.
Future<void> deriveDbSetUp(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  await _deleteDbFiles(name);
  SharedPreferences.setMockInitialValues({});
}

/// The database file and the WAL/shared-memory files a crashed run can leave
/// behind (a stale pair beside a fresh file makes SQLite crash on open).
Future<void> _deleteDbFiles(String name) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), name);
  await databaseFactory.deleteDatabase(path);
  for (final suffix in ['-wal', '-shm', '-journal']) {
    final f = File('$path$suffix');
    if (f.existsSync()) f.deleteSync();
  }
}

/// Empty the tables a derive test fills, and reset prefs, without closing the
/// database (a close under the scheduler's tail work is not safe).
Future<void> deriveDbReset() async {
  SharedPreferences.setMockInitialValues({});
  final db = await LocalDb.instance;
  for (final t in ['compute_jobs', 'day_result', 'notif_fired', 'notif_slots']) {
    await db.delete(t);
  }
}

Future<void> deriveDbTearDown(String name) async {
  await LocalDb.close();
  await _deleteDbFiles(name);
}

/// Polls until [ok]; fails the test, naming [what], if [within] runs out.
Future<void> until(bool Function() ok,
    {Duration within = const Duration(seconds: 6), String? what}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (!DateTime.now().isBefore(end)) {
      throw TestFailure('until(${what ?? 'condition'}) was not met within '
          '${within.inMilliseconds} ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A derive-engine stand-in that reports [days] the way the engine does (one
/// onDayDone per day, 1-based index) and returns the day count. [gate] holds
/// the pass before the first day; [throws] fails it before anything is
/// reported. [calls] records the `heavy` flag of every invocation.
DeriveRunHook deriveHook({
  List<String> days = const [],
  Object? throws,
  Completer<void>? gate,
  List<bool>? calls,
}) =>
    (Profile profile, {bool heavy = false, onDayDone}) async {
      calls?.add(heavy);
      if (gate != null) await gate.future;
      if (throws != null) throw throws;
      for (var i = 0; i < days.length; i++) {
        onDayDone?.call(days[i], i + 1, days.length);
      }
      return days.length;
    };

/// Everything one AppState emits, in order: `t` for each notifyListeners tick
/// and `r` for each insightsRevision change, so a test can pin the interleaving.
class SignalLog {
  SignalLog(this.app) {
    app.addListener(_tick);
    app.insightsRevision.addListener(_rev);
  }
  final AppState app;
  final events = <String>[];
  int get ticks => events.where((e) => e == 't').length;
  int get revisions => events.where((e) => e == 'r').length;
  void _tick() => events.add('t');
  void _rev() => events.add('r');
  void stop() {
    app.removeListener(_tick);
    app.insightsRevision.removeListener(_rev);
  }
}

/// A repo whose rescoreRecentSessions answers [fixed] and counts the calls.
class RescoreRepo extends LocalRepository {
  RescoreRepo({this.fixed = 0, this.throwsOnRescore = false});
  int fixed;
  bool throwsOnRescore;
  int rescoreCalls = 0;

  @override
  Future<int> rescoreRecentSessions({int sinceDays = 3}) async {
    rescoreCalls++;
    if (throwsOnRescore) throw StateError('rescore failed');
    return fixed;
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

/// Captures what reaches the OS notification sink and restores the real sink
/// when the test ends. Quiet hours are off so the outcome does not depend on
/// the wall clock.
class RecoverySink {
  RecoverySink() {
    _original = NotificationCenter.instance.presentSink;
    NotificationCenter.instance.presentSink = (e,
        {bool allowPermissionPrompt = true}) async {
      shown.add(e.dedupeKey);
      return true;
    };
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
  }
  late final Future<bool> Function(NotificationEvent e,
      {bool allowPermissionPrompt}) _original;
  final shown = <String>[];
  String get todayKey => '${todayLabel()}:recovery_ready';
  void restore() => NotificationCenter.instance.presentSink = _original;
}

/// Writes today's day_result with a computed readiness, the row the
/// recovery-ready check reads. [payloadJson] decides whether the night counts
/// as settled.
Future<void> putTodayReadiness({
  double readiness = 80,
  String payloadJson = '{}',
}) =>
    LocalDb.putDayResult(
      dayId: todayLabel(),
      algoVersion: kAlgoVersion,
      payloadJson: payloadJson,
      windowJson: '{}',
      readiness: readiness,
    );

/// Wraps a body in a zone that tracks every Timer created in it, so a test can
/// assert none is still live. Periodic timers count until cancelled.
class TimerSpy {
  final live = <_SpyTimer>{};

  ZoneSpecification get spec => ZoneSpecification(
        createTimer: (self, parent, zone, d, f) {
          late final _SpyTimer t;
          final real = parent.createTimer(zone, d, () {
            live.remove(t);
            f();
          });
          t = _SpyTimer(real, live);
          live.add(t);
          return t;
        },
        createPeriodicTimer: (self, parent, zone, d, f) {
          late final _SpyTimer t;
          final real = parent.createPeriodicTimer(zone, d, (_) => f(t));
          t = _SpyTimer(real, live);
          live.add(t);
          return t;
        },
      );

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneSpecification: spec);
}

class _SpyTimer implements Timer {
  _SpyTimer(this._inner, this._live);
  final Timer _inner;
  final Set<_SpyTimer> _live;
  @override
  void cancel() {
    _inner.cancel();
    _live.remove(this);
  }

  @override
  bool get isActive => _inner.isActive;
  @override
  int get tick => _inner.tick;
}
