// WHOOP MG ECG — the lifecycle owner of one reading.
//
// Owns: the transport lease, the PREPARE/START/RESTART/CLEANUP sequence
// through [EcgTransport], the durable may-be-active guard, the pure reducer
// ([reduceEcg]) fed with live R17, the accepted window, the live-preview
// ring, the capture timeout, cancel/pause/link-loss/parse-failure exits, the
// durable save (before "completed" is ever shown), cleanup on EVERY exit,
// and the ordinary history sync request that follows.
//
// Single-flight: every public entry bumps an epoch, every continuation after
// an await re-checks it, and there is exactly ONE cleanup per capture.
// Frames are gated on the lease's link generation, on `_armed`, and are
// dropped while a RESTART list is in flight.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ecg_guard_store.dart';
import 'ecg_models.dart';
import 'ecg_policy.dart';
import 'ecg_recovery.dart';
import 'ecg_transport.dart';
import 'ecg_waveform_buffer.dart';

enum EcgCapturePhase {
  idle,
  incompatible,
  disconnected,
  busy,
  recovering,
  preparing,
  starting,
  waiting,
  active,
  contactLost,
  restarting,
  saving,
  cleaningUp,
  completed,
  unreadable,
  inconclusiveRetry,
  cancelled,
  failed,
}

/// What the capture screen renders. Immutable snapshot.
class EcgCaptureState {
  final EcgCapturePhase phase;
  final EcgWrist? wrist;
  final int progress;
  final int? liveHr;
  final int quality;
  final int interruptions;

  /// Why the phase is [EcgCapturePhase.busy] / [EcgCapturePhase.failed].
  final String? reason;

  /// The saved reading, once [EcgCapturePhase.completed].
  final String? readingId;

  /// The band's unreadable-reason mask for [EcgCapturePhase.unreadable].
  final int unreadableMask;

  /// True when a cleanup member failed: the durable guard is retained and
  /// the next connection retries the cleanup triplet.
  final bool cleanupIncomplete;

  const EcgCaptureState({
    this.phase = EcgCapturePhase.idle,
    this.wrist,
    this.progress = 0,
    this.liveHr,
    this.quality = 0,
    this.interruptions = 0,
    this.reason,
    this.readingId,
    this.unreadableMask = 0,
    this.cleanupIncomplete = false,
  });

  EcgCaptureState copyWith({
    EcgCapturePhase? phase,
    EcgWrist? wrist,
    int? progress,
    int? liveHr,
    bool clearLiveHr = false,
    int? quality,
    int? interruptions,
    String? reason,
    String? readingId,
    int? unreadableMask,
    bool? cleanupIncomplete,
  }) => EcgCaptureState(
    phase: phase ?? this.phase,
    wrist: wrist ?? this.wrist,
    progress: progress ?? this.progress,
    liveHr: clearLiveHr ? null : (liveHr ?? this.liveHr),
    quality: quality ?? this.quality,
    interruptions: interruptions ?? this.interruptions,
    reason: reason ?? this.reason,
    readingId: readingId ?? this.readingId,
    unreadableMask: unreadableMask ?? this.unreadableMask,
    cleanupIncomplete: cleanupIncomplete ?? this.cleanupIncomplete,
  );

  /// The phases in which the band may be generating: from the first ON
  /// write until cleanup finished.
  bool get capturing => switch (phase) {
    EcgCapturePhase.recovering ||
    EcgCapturePhase.preparing ||
    EcgCapturePhase.starting ||
    EcgCapturePhase.waiting ||
    EcgCapturePhase.active ||
    EcgCapturePhase.contactLost ||
    EcgCapturePhase.restarting ||
    EcgCapturePhase.saving ||
    EcgCapturePhase.cleaningUp => true,
    _ => false,
  };
}

typedef EcgSave =
    Future<void> Function(EcgReading reading, List<EcgAcceptedPacket> packets);

class EcgController extends ChangeNotifier {
  final EcgTransport transport;
  final EcgGuardStore guard;
  final EcgSave save;

  /// A reason the app is busy with another live feature (workout, breathing
  /// session), or null when ECG may start.
  final String? Function() busyReason;
  final Future<void> Function(String owner) holdScreen;
  final Future<void> Function(String owner) releaseScreen;
  final void Function(String) log;
  final Duration captureTimeout;
  final int Function() nowMs;

  static const String screenOwner = 'ecg';

  EcgController({
    required this.transport,
    required this.guard,
    required this.save,
    required this.busyReason,
    required this.holdScreen,
    required this.releaseScreen,
    void Function(String)? log,
    this.captureTimeout = const Duration(seconds: 120),
    int Function()? nowMs,
  }) : log = log ?? ((_) {}),
       nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  EcgCaptureState _state = const EcgCaptureState();
  EcgCaptureState get state => _state;

  /// The live-preview ring (RAM only) and its repaint coalescer.
  final EcgWaveformBuffer live = EcgWaveformBuffer();
  final EcgPreviewScheduler preview = EcgPreviewScheduler();

  int _epoch = 0;
  EcgLeaseHandle? _lease;
  int _gen = -1;
  String? _serial;
  EcgWrist? _wrist;
  bool _armed = false;
  bool _restartInFlight = false;
  bool _cleanupDone = false;
  bool _screenHeld = false;
  int _retriesUsed = 0;
  int? _windowStartMs;
  EcgReducerState _reducer = const EcgReducerState.initial();
  StreamSubscription<EcgTransportEvent>? _sub;
  Timer? _timer;

  bool get isCapturing => _lease != null;

  @visibleForTesting
  EcgReducerState get reducerState => _reducer;

  void _set(EcgCaptureState s) {
    _state = s;
    notifyListeners();
  }

  bool _stale(int epoch) => _epoch != epoch || _lease == null;

  /// Start a reading on [wrist]. Every precondition failure lands in a
  /// terminal phase with a reason; nothing is written to the band before
  /// the durable guard is acknowledged.
  Future<void> begin(EcgWrist wrist) async {
    if (_lease != null) return; // single-flight
    final epoch = ++_epoch;
    live.clear();
    preview.markDirty();
    if (!transport.isReady) {
      _set(EcgCaptureState(phase: EcgCapturePhase.disconnected, wrist: wrist));
      return;
    }
    if (!transport.isMaverick) {
      _set(EcgCaptureState(phase: EcgCapturePhase.incompatible, wrist: wrist));
      return;
    }
    final busy = busyReason();
    if (busy != null) {
      _set(
        EcgCaptureState(
          phase: EcgCapturePhase.busy,
          wrist: wrist,
          reason: busy,
        ),
      );
      return;
    }
    final serial = transport.serial;
    if (serial == null || serial.isEmpty) {
      _set(
        EcgCaptureState(
          phase: EcgCapturePhase.failed,
          wrist: wrist,
          reason: 'no_serial',
        ),
      );
      return;
    }
    final lease = transport.acquire();
    if (lease == null) {
      _set(
        EcgCaptureState(
          phase: EcgCapturePhase.busy,
          wrist: wrist,
          reason: 'transport',
        ),
      );
      return;
    }
    _lease = lease;
    _gen = lease.linkGeneration;
    _serial = serial;
    _wrist = wrist;
    _cleanupDone = false;
    _armed = false;
    _restartInFlight = false;
    _windowStartMs = null;
    final retries = _retriesUsed;
    _retriesUsed = 0;
    _reducer = EcgReducerState.initial(retriesUsed: retries);
    _set(EcgCaptureState(phase: EcgCapturePhase.preparing, wrist: wrist));
    try {
      await guard.setWrist(serial, wrist);
      if (await guard.isActive(serial)) {
        _set(_state.copyWith(phase: EcgCapturePhase.recovering));
        final r = await ecgRecoverRetainedGuard(
          guard: guard,
          serial: serial,
          cleanup: () => transport.cleanup(lease),
          log: log,
        );
        if (_stale(epoch)) return;
        if (r == EcgRecoveryOutcome.retained) {
          await _finish(epoch, EcgCapturePhase.failed, reason: 'recovery');
          return;
        }
        _set(_state.copyWith(phase: EcgCapturePhase.preparing));
      }
      await transport.cancelHistory(lease);
      if (_stale(epoch)) return;
      // The durable guard goes down BEFORE the first ON write and is
      // acknowledged; a write that did not land does not get a band enabled.
      if (!await guard.setActive(serial)) {
        await _finish(epoch, EcgCapturePhase.failed, reason: 'guard');
        return;
      }
      if (_stale(epoch)) return;
      // Subscribe BEFORE any generation write: the first post-START packet
      // can arrive at the write/response boundary.
      _sub ??= transport.events.listen(_onEvent);
      final prep = await transport.prepare(lease, wrist);
      if (_stale(epoch)) return;
      if (!prep.allSucceeded) {
        log('[ECG] PREPARE not accepted: $prep');
        await _finish(epoch, EcgCapturePhase.failed, reason: 'prepare');
        return;
      }
      _armed = true;
      _set(_state.copyWith(phase: EcgCapturePhase.starting));
      _screenHeld = true;
      await holdScreen(screenOwner);
      final st = await transport.start(lease);
      if (_stale(epoch)) return;
      if (!st.allSucceeded) {
        log('[ECG] START not accepted: $st');
        _armed = false;
        await _finish(epoch, EcgCapturePhase.failed, reason: 'start');
        return;
      }
      _timer = Timer(captureTimeout, () {
        unawaited(_finish(epoch, EcgCapturePhase.failed, reason: 'timeout'));
      });
      if (_state.phase == EcgCapturePhase.starting) {
        _set(_state.copyWith(phase: EcgCapturePhase.waiting));
      }
    } catch (e, st) {
      log('[ECG] begin failed: $e\n$st');
      if (!_stale(epoch)) {
        await _finish(epoch, EcgCapturePhase.failed, reason: 'error');
      }
    }
  }

  /// After a first-attempt inconclusive result: one more reading, with the
  /// retry budget spent so a second inconclusive is final.
  Future<void> retry() async {
    if (_lease != null || _state.phase != EcgCapturePhase.inconclusiveRetry) {
      return;
    }
    final wrist = _wrist;
    if (wrist == null) return;
    _retriesUsed = 1;
    await begin(wrist);
  }

  /// Back / explicit cancel. Cleans up; the band stops generating.
  Future<void> cancel() async {
    if (_lease == null) return;
    final epoch = ++_epoch;
    await _finish(epoch, EcgCapturePhase.cancelled, reason: 'cancelled');
  }

  /// The app went to the background mid-capture — same as cancel (the
  /// official screen stops on ON_PAUSE too).
  Future<void> onAppPaused() async {
    if (_lease == null) return;
    final epoch = ++_epoch;
    await _finish(epoch, EcgCapturePhase.cancelled, reason: 'paused');
  }

  /// Awaited teardown for the owner (AppState shutdown, tests).
  Future<void> shutdown() async {
    await cancel();
    await _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(EcgTransportEvent e) {
    if (e.linkGeneration != _gen || _lease == null) return;
    final epoch = _epoch;
    switch (e) {
      case EcgTransportLinkDown():
        unawaited(
          _finish(epoch, EcgCapturePhase.failed, reason: 'disconnected'),
        );
      case EcgTransportMalformed():
        if (_armed) {
          unawaited(
            _finish(epoch, EcgCapturePhase.failed, reason: 'malformed'),
          );
        }
      case EcgTransportFrame():
        _onFrame(epoch, e);
    }
  }

  void _onFrame(int epoch, EcgTransportFrame e) {
    if (!_armed || _restartInFlight) return;
    final r17 = e.r17;
    // The live preview shows real samples from the moment the pipeline is
    // armed (zeros before contact); only the accepted window is ever saved.
    live.push(r17.samples);
    preview.markDirty();
    final before = _reducer;
    final step = reduceEcg(before, r17);
    _reducer = step.state;
    if (before.accepted.isEmpty && step.state.accepted.isNotEmpty) {
      _windowStartMs = nowMs();
    }
    var next = _state.copyWith(
      progress: r17.progress == 255 ? _state.progress : r17.progress,
      liveHr: r17.liveHr > 0 ? r17.liveHr : null,
      clearLiveHr: r17.liveHr == 0,
      quality: r17.quality,
      interruptions: step.state.interruptions,
    );
    switch (step.state.phase) {
      case EcgPhase.waiting:
        if (_state.phase != EcgCapturePhase.starting) {
          next = next.copyWith(phase: EcgCapturePhase.waiting);
        }
      case EcgPhase.active:
        next = next.copyWith(phase: EcgCapturePhase.active);
      case EcgPhase.contactLost:
        next = next.copyWith(phase: EcgCapturePhase.contactLost);
      case EcgPhase.done:
        break;
    }
    _set(next);
    for (final effect in step.effects) {
      switch (effect) {
        case EcgAppend():
        case EcgAppendPlaceholder():
        case EcgClear():
          break;
        case EcgSendRestart():
          unawaited(_restart(epoch));
        case EcgFail(:final reason):
          unawaited(_finish(epoch, EcgCapturePhase.failed, reason: reason));
        case EcgTerminal(:final outcome):
          unawaited(_handleTerminal(epoch, outcome));
      }
    }
  }

  Future<void> _restart(int epoch) async {
    final lease = _lease;
    if (lease == null || _restartInFlight) return;
    _restartInFlight = true;
    _set(_state.copyWith(phase: EcgCapturePhase.restarting));
    final res = await transport.restart(lease);
    if (_stale(epoch) || !identical(_lease, lease)) return;
    if (!res.allSucceeded) {
      log('[ECG] RESTART not accepted: $res');
      await _finish(epoch, EcgCapturePhase.failed, reason: 'restart');
      return;
    }
    _restartInFlight = false;
    _set(_state.copyWith(phase: EcgCapturePhase.active));
  }

  Future<void> _handleTerminal(int epoch, EcgTerminalOutcome outcome) async {
    _armed = false;
    _timer?.cancel();
    switch (outcome.kind) {
      case EcgTerminalKind.unreadable:
        await _finish(
          epoch,
          EcgCapturePhase.unreadable,
          unreadableMask: outcome.unreadableMask,
        );
      case EcgTerminalKind.inconclusiveOfferRetry:
        await _finish(epoch, EcgCapturePhase.inconclusiveRetry);
      case EcgTerminalKind.completed:
      case EcgTerminalKind.inconclusiveFinal:
        _set(_state.copyWith(phase: EcgCapturePhase.saving));
        final packets = List<EcgAcceptedPacket>.from(_reducer.accepted);
        final reading = _buildReading(outcome, packets);
        try {
          await save(reading, packets);
        } catch (e) {
          log('[ECG] save failed: $e');
          if (_stale(epoch)) return;
          await _finish(epoch, EcgCapturePhase.failed, reason: 'save');
          return;
        }
        if (_stale(epoch)) return;
        await _finish(epoch, EcgCapturePhase.completed, readingId: reading.id);
        // The band saved raw R16 under raw-save ON; ordinary incremental
        // history brings it back through the normal safe path.
        try {
          await transport.requestSync();
        } catch (e) {
          log('[ECG] post-reading sync request failed: $e');
        }
    }
  }

  EcgReading _buildReading(
    EcgTerminalOutcome outcome,
    List<EcgAcceptedPacket> packets,
  ) {
    final now = nowMs();
    final startMs = _windowStartMs ?? now;
    final stats = EcgWindowStats.of(packets);
    final t = outcome.terminal;
    return EcgReading(
      id: ecgReadingId(startEpochMs: startMs, terminalStrapS: t.strapSeconds),
      deviceId: '',
      wrist: _wrist ?? EcgWrist.right,
      startTs: startMs ~/ 1000,
      endTs: now ~/ 1000,
      strapTerminalTs: t.strapSeconds,
      strapTerminalSubsec: t.subseconds,
      resultCode: t.result,
      category: outcome.persistedCategory,
      avgHr: t.averageHr > 0 ? t.averageHr : null,
      quality: t.quality,
      unreadableMask: t.unreadable.raw,
      interruptions: _reducer.interruptions,
      sampleCount: stats.sampleCount,
      minUv: stats.minUv,
      maxUv: stats.maxUv,
      rmsUv: stats.rmsUv,
      missingSegments: stats.missingSegments,
      status: outcome.kind == EcgTerminalKind.inconclusiveFinal
          ? EcgReadingStatus.inconclusive
          : EcgReadingStatus.completed,
      notes: null,
      createdAt: now,
    );
  }

  /// THE one exit path. Idempotent per capture: cleanup runs once, the
  /// screen hold and the lease are released, and the final phase is set
  /// only after cleanup so a "completed" never precedes a stopped band.
  Future<void> _finish(
    int epoch,
    EcgCapturePhase phase, {
    String? reason,
    String? readingId,
    int? unreadableMask,
  }) async {
    final lease = _lease;
    if (lease == null || _epoch != epoch) return;
    _armed = false;
    _restartInFlight = false;
    _timer?.cancel();
    _timer = null;
    var incomplete = false;
    if (!_cleanupDone) {
      _cleanupDone = true;
      _set(_state.copyWith(phase: EcgCapturePhase.cleaningUp, reason: reason));
      final res = await transport.cleanup(lease);
      final serial = _serial;
      if (res.allSucceeded && serial != null) {
        if (!await guard.clear(serial)) {
          log('[ECG] guard clear was not acknowledged — retained.');
          incomplete = true;
        }
      } else {
        log('[ECG] cleanup incomplete ($res) — guard retained.');
        incomplete = true;
      }
    }
    if (_screenHeld) {
      _screenHeld = false;
      await releaseScreen(screenOwner);
    }
    transport.release(lease);
    if (identical(_lease, lease)) _lease = null;
    _set(
      _state.copyWith(
        phase: phase,
        reason: reason,
        readingId: readingId,
        unreadableMask: unreadableMask,
        cleanupIncomplete: incomplete,
      ),
    );
  }
}
