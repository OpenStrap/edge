import 'dart:async';

class ShortcutSyncResult {
  final String status;
  final int records;
  const ShortcutSyncResult(this.status, {this.records = 0});

  Map<String, Object> toMap() => {'status': status, 'records': records};
}

/// The caller's deadline must not release BLE ownership before cleanup finishes.
class ShortcutSyncTask {
  final String id;
  final Duration budget;
  final void Function(Map<String, Object>)? onProgress;
  final Stopwatch _clock = Stopwatch()..start();
  final _stopped = Completer<ShortcutSyncResult>();
  String phase = 'starting';
  int records = 0;
  int batches = 0;
  void Function()? onStop;

  ShortcutSyncTask(this.id, this.budget, {this.onProgress});

  bool get stopped => _stopped.isCompleted;
  Duration get remaining {
    final value = budget - _clock.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  void update(String phase, {int? records, int? batches}) {
    if (stopped) return;
    this.phase = phase;
    this.records = records ?? this.records;
    this.batches = batches ?? this.batches;
    onProgress?.call({
      'id': id,
      'phase': phase,
      'records': this.records,
      'batches': this.batches,
    });
  }

  ShortcutSyncResult get expired => ShortcutSyncResult(
    phase == 'connecting'
        ? 'bandUnreachable'
        : phase == 'syncing' || phase == 'processing'
        ? 'partial'
        : 'timedOut',
    records: records,
  );

  void stop([String? status]) {
    if (stopped) return;
    _stopped.complete(
      status == null ? expired : ShortcutSyncResult(status, records: records),
    );
    onStop?.call();
  }

  Future<ShortcutSyncResult> waitFor(Future<ShortcutSyncResult> work) async {
    final timer = Timer(remaining, stop);
    try {
      return await Future.any([work, _stopped.future]);
    } finally {
      timer.cancel();
    }
  }
}
