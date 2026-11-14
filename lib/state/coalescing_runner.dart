// coalescing_runner.dart — serialise a job, and fold requests that arrive while
// another run is still waiting its turn into that one waiting run.
//
// The reminder pass reads the crossday rollup and the pending-notification list.
// It was triggered on every durable store path, so a drain of many batches
// queued one full pass per batch. A pass reads its inputs when it STARTS, so a
// request that arrives while a run is queued-but-not-started is already served
// by it: it joins instead of adding another. A request that arrives while a run
// is mid-flight still queues one more, because that run has already read.

class CoalescingRunner {
  CoalescingRunner(this._job);

  final Future<void> Function() _job;
  Future<void> _tail = Future.value();
  Future<void>? _queued;

  /// Run the job after anything already running. Completes with that run's
  /// result (joined callers share the queued run's completion).
  Future<void> run() {
    final queued = _queued;
    if (queued != null) return queued;
    late final Future<void> pass;
    pass = _tail.then((_) {
      // Started: later requests can no longer be served by this run.
      if (identical(_queued, pass)) _queued = null;
      return _job();
    });
    _queued = pass;
    _tail = pass.catchError((_) {});
    return pass;
  }
}
