import 'dart:async';

/// Serializes derive work behind the capture pipeline.
///
/// While an offload is active we only accumulate intent and defer the actual
/// derive until capture has settled for a small window.
class DeriveScheduler {
  DeriveScheduler({
    required this.run,
    required this.log,
    this.lightSettle = const Duration(seconds: 8),
    this.heavySettle = const Duration(seconds: 2),
  });

  final Future<void> Function({required bool heavy}) run;
  final void Function(String) log;
  final Duration lightSettle;
  final Duration heavySettle;

  bool _offloadActive = false;
  bool _running = false;
  bool _pendingLight = false;
  bool _pendingHeavy = false;
  Timer? _timer;

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
    _pendingLight = true;
    _arm();
  }

  void requestHeavy() {
    _pendingHeavy = true;
    _pendingLight = true;
    _arm();
  }

  void setOffloadActive(bool active) {
    if (_offloadActive == active) return;
    _offloadActive = active;
    if (active) {
      _timer?.cancel();
      _timer = null;
      log('[derive-scheduler] capture active — holding derive work');
      return;
    }
    log('[derive-scheduler] capture settled — derive may run');
    _arm();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    if (_running || _offloadActive) return;
    if (!_pendingLight && !_pendingHeavy) return;
    _timer?.cancel();
    _timer = Timer(_pendingHeavy ? heavySettle : lightSettle, () {
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (_running || _offloadActive) return;
    final heavy = _pendingHeavy;
    final light = _pendingLight;
    if (!heavy && !light) return;
    _pendingHeavy = false;
    _pendingLight = false;
    _running = true;
    log('[derive-scheduler] running ${heavy ? "heavy" : "light"} pass');
    try {
      await run(heavy: heavy);
    } finally {
      _running = false;
      if (_pendingHeavy || _pendingLight) _arm();
    }
  }
}
