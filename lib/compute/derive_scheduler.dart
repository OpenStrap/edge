import 'dart:async';

import '../data/db.dart';

enum DeriveJobKind { light, heavy }

/// Serializes derive work behind the capture pipeline using durable queued jobs.
///
/// While an offload is active we persist intent in `compute_jobs` and defer the
/// actual derive until capture has settled for a small window. On restart, any
/// interrupted running job is re-queued and resumed.
class DeriveScheduler {
  DeriveScheduler({
    required this.run,
    required this.log,
    required this.onChanged,
    this.lightSettle = const Duration(seconds: 8),
    this.heavySettle = const Duration(seconds: 2),
  });

  final Future<void> Function({required DeriveJobKind kind}) run;
  final void Function(String) log;
  final void Function() onChanged;
  final Duration lightSettle;
  final Duration heavySettle;

  bool _offloadActive = false;
  bool _running = false;
  bool _pendingLight = false;
  bool _pendingHeavy = false;
  Timer? _timer;
  bool _refreshing = false;

  Future<void> init() async {
    await LocalDb.recoverComputeJobs();
    await _refreshSnapshot();
    _arm();
  }

  bool get offloadActive => _offloadActive;
  bool get running => _running;
  bool get pendingLight => _pendingLight;
  bool get pendingHeavy => _pendingHeavy;

  Map<String, dynamic> snapshot() => {
        'offload_active': _offloadActive,
        'running': _running,
        'pending_light': _pendingLight,
        'pending_heavy': _pendingHeavy,
      };

  void markStoredData() {
    unawaited(_enqueue(type: 'derive_light', reason: 'stored_data'));
  }

  void requestHeavy() {
    unawaited(_enqueue(type: 'derive_heavy', reason: 'capture_settled'));
  }

  void setOffloadActive(bool active) {
    if (_offloadActive == active) return;
    _offloadActive = active;
    if (active) {
      _timer?.cancel();
      _timer = null;
      log('[derive-scheduler] capture active — holding derive work');
      onChanged();
      return;
    }
    log('[derive-scheduler] capture settled — derive may run');
    onChanged();
    _arm();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _enqueue({
    required String type,
    required String reason,
  }) async {
    await LocalDb.enqueueDeriveJob(type: type, reason: reason);
    await _refreshSnapshot();
    _arm();
  }

  void _arm() {
    if (_running || _offloadActive) return;
    if (!_pendingLight && !_pendingHeavy) {
      unawaited(_refreshSnapshot());
      return;
    }
    _timer?.cancel();
    _timer = Timer(_pendingHeavy ? heavySettle : lightSettle, () {
      unawaited(_drain());
    });
    onChanged();
  }

  Future<void> _drain() async {
    if (_running || _offloadActive) return;
    _timer?.cancel();
    _timer = null;
    final job = await LocalDb.takeNextComputeJob();
    if (job == null) {
      await _refreshSnapshot();
      return;
    }
    final id = job['id']?.toString();
    final kind = _parseKind(job['type']?.toString());
    _running = true;
    await _refreshSnapshot();
    log('[derive-scheduler] running ${kind == DeriveJobKind.heavy ? "heavy" : "light"} pass');
    try {
      await run(kind: kind);
      if (id != null && id.isNotEmpty) {
        await LocalDb.completeComputeJob(id);
      }
    } catch (e) {
      if (id != null && id.isNotEmpty) {
        await LocalDb.failComputeJob(id, '$e');
      }
      rethrow;
    } finally {
      _running = false;
      await _refreshSnapshot();
      if (_pendingHeavy || _pendingLight) _arm();
      onChanged();
    }
  }

  DeriveJobKind _parseKind(String? type) {
    switch (type) {
      case 'derive_heavy':
        return DeriveJobKind.heavy;
      case 'derive_light':
      default:
        return DeriveJobKind.light;
    }
  }

  Future<void> _refreshSnapshot() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final jobs = await LocalDb.computeJobs(state: 'queued', limit: 50);
      _pendingLight = jobs.any(
        (job) =>
            job['type']?.toString() == 'derive_light',
      );
      _pendingHeavy = jobs.any(
        (job) =>
            job['type']?.toString() == 'derive_heavy',
      );
    } finally {
      _refreshing = false;
      onChanged();
    }
  }
}
