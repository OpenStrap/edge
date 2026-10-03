import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_engine.dart';
import '../ble/ble_state.dart';
import '../compute/derivation_engine.dart';
import '../data/db.dart';
import '../data/local_repository_impl.dart';
import '../state/prefs.dart';
import '../widget/widget_service.dart';
import 'background_sync.dart';
import 'band_ownership.dart';
import 'headless_gate.dart';
import 'paired_device.dart';
import 'reset_gate.dart';
import 'shortcut_sync_task.dart';

class IosShortcutSync {
  static const channel = MethodChannel('openstrap/shortcut_sync');
  static ShortcutSyncTask? _active;
  static void Function()? _onForegroundCommitFailure;

  static void foregroundCommitFailed() => _onForegroundCommitFailure?.call();

  static Future<SyncReport> Function(ShortcutSyncTask)? foregroundSync;
  static BleEngine? Function()? foregroundEngine;
  static bool _listening = false;

  /// Native holds Shortcut runs until 'ready'. Sending it only once AppState has
  /// registered its hooks keeps a cold launch off the headless path, which would
  /// hold the band lease while the app's own session waits on it.
  static void attachForeground(
    Future<SyncReport> Function(ShortcutSyncTask) sync,
    BleEngine? Function() engine,
  ) {
    foregroundSync = sync;
    foregroundEngine = engine;
    if (!_listening) return;
    unawaited(
      channel
          .invokeMethod<void>('ready')
          .catchError(
            (Object error) => debugPrint('[shortcut-sync] ready: $error'),
          ),
    );
  }

  static Future<void> init() async {
    if (!Platform.isIOS) return;
    channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'run':
          final id = args['id'] as String;
          final milliseconds = (args['budgetMs'] as int).clamp(1, 600000);
          return (await run(id, Duration(milliseconds: milliseconds))).toMap();
        case 'cancel':
          if (_active?.id == args['id']) _active?.stop('cancelled');
          return null;
        default:
          throw MissingPluginException();
      }
    });
    _listening = true;
  }

  static Future<ShortcutSyncResult> run(String id, Duration budget) async {
    if (_active != null) return const ShortcutSyncResult('alreadyRunning');
    final task = ShortcutSyncTask(
      id,
      budget,
      onProgress: (progress) {
        unawaited(
          channel
              .invokeMethod<void>('progress', progress)
              .catchError(
                (Object error) =>
                    debugPrint('[shortcut-sync] progress: $error'),
              ),
        );
      },
    );
    _active = task;
    final work = () async {
      try {
        return await HeadlessSyncGate.tryRun('shortcut', () => _sync(task)) ??
            const ShortcutSyncResult('alreadyRunning');
      } catch (e, st) {
        debugPrint('[shortcut-sync] failed: $e\n$st');
        return ShortcutSyncResult('failed', records: task.records);
      } finally {
        task.onStop = null;
        if (identical(_active, task)) _active = null;
      }
    }();
    return task.waitFor(work);
  }

  static ShortcutSyncResult? _blockerResult(BleBlocker? blocker) {
    if (blocker == null) return null;
    return ShortcutSyncResult(
      blocker == BleBlocker.permissionDenied
          ? 'permissionDenied'
          : 'bluetoothUnavailable',
    );
  }

  static Future<ShortcutSyncResult> _sync(ShortcutSyncTask task) async {
    if (ResetGate.active) throw StateError('data reset in progress');
    final paired = await PairedDevice.load();
    if (paired == null) return const ShortcutSyncResult('notPaired');
    final prefs = await SharedPreferences.getInstance();
    // AccessorySetupKit provisioning requires that no Bluetooth central is created yet.
    if (prefs.getBool(Prefs.kAskAddPendingKey) ?? false) {
      return const ShortcutSyncResult('setupRequired');
    }
    if (task.stopped) return task.expired;

    final adapter = await FlutterBluePlus.adapterState
        .firstWhere(
          (s) =>
              s != BluetoothAdapterState.unknown &&
              s != BluetoothAdapterState.turningOn,
        )
        .timeout(const Duration(seconds: 3));
    final blocked = _blockerResult(
      classifyBleBlocker(adapterState: adapter.name),
    );
    if (blocked != null) return blocked;
    if (task.stopped) return task.expired;
    if (ResetGate.active) throw StateError('data reset in progress');

    final liveSync = foregroundSync;
    final liveEngine = foregroundEngine?.call();
    if (liveSync != null && liveEngine != null) {
      _onForegroundCommitFailure = () => task.stop('failed');
      task.update(liveEngine.isConnected ? 'syncing' : 'connecting');
      var radioConnected = liveEngine.isConnected;
      final radio = BluetoothDevice.fromId(paired.remoteId).connectionState
          .listen((state) {
            if (state == BluetoothConnectionState.connected) {
              radioConnected = true;
              if (task.phase == 'connecting') task.update('initializing');
            }
          });
      var lastBatches = liveEngine.offloadSnapshot['batches_acked'] as int;
      final progress = Timer.periodic(const Duration(seconds: 1), (_) {
        final batches = liveEngine.offloadSnapshot['batches_acked'] as int;
        if (liveEngine.isConnected &&
            (task.phase == 'connecting' || task.phase == 'initializing')) {
          task.update('syncing');
        }
        if (batches != lastBatches) {
          final delta = batches >= lastBatches
              ? batches - lastBatches
              : batches;
          lastBatches = batches;
          task.update(task.phase, batches: task.batches + delta);
        }
      });
      task.onStop = progress.cancel;
      try {
        // A cancelled Shortcut must not tear down the app's own live session.
        final report = await liveSync(task);
        if (task.stopped) return task.expired;
        final blocker = _blockerResult(liveEngine.bluetoothBlocker);
        if (blocker != null) return blocker;
        if (!liveEngine.isConnected && report.records == 0) {
          return ShortcutSyncResult(
            radioConnected ? 'failed' : 'bandUnreachable',
          );
        }
        task.records = report.records;
        if (!report.complete || await _backlogRemains(liveEngine)) {
          return ShortcutSyncResult('partial', records: report.records);
        }
        // A resumed app's DeriveScheduler derives and refreshes the UI; a second
        // pass here would take DerivationEngine's lock and turn its job into a no-op.
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          return ShortcutSyncResult('complete', records: report.records);
        }
        return await _derive(task);
      } finally {
        _onForegroundCommitFailure = null;
        task.onStop = null;
        progress.cancel();
        await radio.cancel();
      }
    }

    final lease = BandOwnership.tryAcquireHeadless();
    if (lease == null) return const ShortcutSyncResult('alreadyRunning');
    try {
      return await _headless(task, paired);
    } finally {
      BandOwnership.release(lease);
    }
  }

  static Future<ShortcutSyncResult> _headless(
    ShortcutSyncTask task,
    PairedDevice paired,
  ) async {
    final engine = createHeadlessSyncEngine(
      paired: paired,
      onCommitted: (count) => task.update(
        'syncing',
        records: task.records + count,
        batches: task.batches + 1,
      ),
      onCommitError: (_) => task.stop('failed'),
    );
    task.onStop = () {
      // Keep the gate and lease until the engine's serialized teardown completes.
      unawaited(
        engine.disconnect().catchError(
          (Object error) => debugPrint('[shortcut-sync] teardown: $error'),
        ),
      );
    };
    var radioConnected = false;
    final radio = BluetoothDevice.fromId(paired.remoteId).connectionState
        .listen((state) {
          if (state == BluetoothConnectionState.connected) {
            radioConnected = true;
            if (task.phase == 'connecting') task.update('initializing');
          }
        });
    try {
      task.update('connecting');
      final connected = await engine.connectToRemoteId(
        paired.remoteId,
        generationHint: paired.generation,
      );
      if (task.stopped) return task.expired;
      final blocker = _blockerResult(engine.bluetoothBlocker);
      if (blocker != null) return blocker;
      if (!connected) {
        return ShortcutSyncResult(
          radioConnected ? 'failed' : 'bandUnreachable',
        );
      }
      // connect already started the offload.
      task.update('syncing');
      await prepareHeadlessLink(engine, paired);
      // The band holds one armed epoch; this may be the only connect it gets.
      await rearmHeadlessAlarm(engine);
      if (task.stopped) return task.expired;
      for (var session = 0; session < 20 && !task.stopped; session++) {
        final report = await engine.runSync(timeout: task.remaining);
        if (task.stopped) return task.expired;
        final backlogRemains = await _backlogRemains(engine);
        if (report.complete && !backlogRemains) {
          await engine.disconnect();
          task.onStop = null;
          return await _derive(task);
        }
        if (!report.complete ||
            report.batches == 0 ||
            engine.historyStuckThisSession ||
            !engine.isConnected) {
          break;
        }
        // HISTORY_COMPLETE can end one session while the advertised backlog still remains.
        if (!task.stopped) await engine.requestHistorySync();
      }
      return ShortcutSyncResult('partial', records: task.records);
    } finally {
      task.onStop = null;
      try {
        await engine.disconnect();
      } finally {
        await radio.cancel();
      }
    }
  }

  static Future<ShortcutSyncResult> _derive(ShortcutSyncTask task) async {
    if (task.stopped) return task.expired;
    task.update('processing');
    final profile = await loadHeadlessProfile();
    if (task.stopped) return task.expired;
    if (ResetGate.active) throw StateError('data reset in progress');
    await DerivationEngine(
      log: (line) => debugPrint('[shortcut-derive] $line'),
      background: true,
    ).run(profile, heavy: false);
    if (task.stopped) return task.expired;
    if (ResetGate.active) throw StateError('data reset in progress');
    await WidgetService.refresh(
      LocalRepositoryImpl(getProfileMap: () => profile.toMap()),
    );
    return ShortcutSyncResult('complete', records: task.records);
  }

  static Future<bool> _backlogRemains(BleEngine engine) async {
    final frontier = await LocalDb.getCursorInt('rec_ts_hw');
    final newest = engine.strapHistoryNewestTs;
    return frontier != null && newest != null && newest - frontier > 300;
  }
}
