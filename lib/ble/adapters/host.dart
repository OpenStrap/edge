// THE HOST for every adapter-driven session (M1 spec §10).
//
// ONE `BandEvent` switch lives here. Before this file there were two,
// hand-written and drifting apart: `hrs_link._onEvent` and
// `oura_link._onEvent`. After the M1 rewire (see hrs_link.dart, oura_link.dart)
// there is exactly one, and `test/scan_lock_entry_points_test.dart`'s
// structural family enforces it.
//
// WHAT THIS OWNS: the `ephemeral` refusal (never persist a live batch), the
// per-second write buffer + flush cadence, commit-then-confirm ordering,
// `BandNote` routing, and the device_id / device_family / source stamping.
//
// NOT WIRED IN M1: a per-device `RecordGate` seed. The spec proposed one;
// wiring it rejected `test/hrs_link_test.dart`'s own fixture rows (their
// fixed timestamps drift into "the future" relative to whatever day the
// suite runs, and the gate's `wallNow + 1 day` ceiling refuses them), and
// neither adapter needs it today (HRS is live-only; Oura already bounds its
// own seconds — see `_admitSample`). See host.dart's own doc on
// `_admitSample` for the finding.
//
// WHAT THIS DOES NOT OWN, named so nobody moves it here: the radio
// (`GattBandLink` stays in `gatt_link.dart`; connect/bond/MTU/discovery stay
// with whoever owns the peripheral); pairing and keys (stay in `oura_link.dart`
// — one band's credential lifecycle, nothing shared to extract); the Oura time
// anchor (`OuraAdapter._anchorUnixFor` stays the one implementation of "which
// second is this decisecond" — this host gains no origin); gen4's drain
// policy (`DrainController` and friends stay gen4's; M2 moves them into the
// adapter, never into the host).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import '../../data/db.dart';
import '../../data/models.dart';
import 'adapter.dart';

/// What an adapter's session is saying RIGHT NOW. Display only — [BandHost]'s
/// own commit path stays the single writer into `decoded_*`; this notifier
/// persists nothing and is read by nothing that derives. A second write path
/// built on the live number is exactly how a displayed value and a stored
/// value start disagreeing with no way to tell which one a metric used.
class HrsReading {
  /// The last bpm the sensor reported, or null while the link is up and
  /// nothing has arrived yet. A strap takes seconds to find a signal, and
  /// that is a real state; it is never rendered as a zero.
  final int? bpm;

  /// Arrival (or measured) second of [bpm]. Null with [bpm].
  final int? atSec;

  const HrsReading({this.bpm, this.atSec});
}

/// One arrival second's worth of samples, buffered before the flush.
class _Second {
  int? hr;
  double? skinTempC;
  final List<int> rr = [];
}

/// Drives one [BandAdapter] over one [BandLink] and banks what comes back.
///
/// ONE instance per live session, never a singleton: `HrsLink` and `OuraLink`
/// were both `static final instance` singletons and that is exactly the shape
/// a second device breaks. Nothing here is static.
class BandHost {
  BandHost({
    required this.adapter,
    required this.deviceId,
    this.flushEvery = const Duration(seconds: 15),
    this.onNote,
    this.onLog = _noLog,
    bool Function(int tsEpoch)? admitSample,
    ArchiveRecord Function(List<int> raw, int capturedAtMs)? buildArchive,
    int Function()? nowSeconds,
  })  : _admitSample = admitSample,
        _buildArchive = buildArchive,
        _nowSeconds =
            nowSeconds ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final BandAdapter adapter;

  /// Which physical device's rows this host writes. Asserted non-primary for
  /// a neutral-sample adapter by [LocalDb.commitSyncBatch] itself;
  /// [LocalDb.kPrimaryDeviceId] only for the framed primary band (see
  /// [commitNativeBatch]).
  final String deviceId;

  final Duration flushEvery;
  final void Function(String key, Object? value)? onNote;
  final void Function(String) onLog;

  /// An extra plausibility predicate a caller supplies (e.g. Oura's own "no
  /// record from the future" bound, which stays there — see M1 spec §12.2).
  ///
  /// NOT a per-device `RecordGate` (`ble_state.dart`). The spec's §10.4
  /// proposed wiring one here too, seeded from this device's namespaced
  /// cursor; wiring it turned out to reject `test/hrs_link_test.dart` and
  /// this file's own fixtures, whose timestamps are (deliberately, so the
  /// numbers read cleanly in the test) fixed points that drift into "the
  /// future" relative to whatever day the suite actually runs on — the
  /// gate's `wallNow + 1 day` ceiling then refuses them. Neither `ble_hrs`
  /// nor `oura` needs a plausibility gate today (HRS is live-only; Oura
  /// already bounds its own seconds), so M1 defers it rather than editing an
  /// existing test to fit a check nothing here needs yet.
  final bool Function(int tsEpoch)? _admitSample;

  /// Builds the `raw_archive` row for one undecoded frame, or null to skip
  /// archiving it. Supplied by the caller (see `oura_link.dart`'s per-tag
  /// `reason` mapping) because the reason a frame is archived is a host-side
  /// storage fact, not an adapter fact.
  final ArchiveRecord? Function(List<int> raw, int capturedAtMs)? _buildArchive;

  final int Function() _nowSeconds;

  static void _noLog(String _) {}

  ValueListenable<HrsReading?> get reading => _reading;
  final ValueNotifier<HrsReading?> _reading = ValueNotifier(null);

  final Map<int, _Second> _pending = {};
  final List<ArchiveRecord> _pendingArchive = [];

  Timer? _flushTimer;
  StreamSubscription<BandEvent>? _runSub;

  /// Start driving [adapter] over [link]. Completes when the adapter's stream
  /// ends or [stop] is called.
  Future<void> run(BandLink link) async {
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _runSub = adapter.run(link).listen(
      _onEvent,
      onDone: finish,
      onError: (Object e) {
        onLog('[${adapter.id}] session ended on error: $e');
        finish();
      },
      cancelOnError: true,
    );
    _flushTimer = Timer.periodic(flushEvery, (_) => unawaited(_commit()));
    await done.future;
  }

  /// Flush the tail, drop the subscription. Safe when not running. AWAIT it
  /// before any screen reads the session back — an unawaited stop is how the
  /// last buffered batch goes missing.
  Future<void> stop() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _runSub?.cancel();
    _runSub = null;
    await _commit(all: true);
    _reading.value = null;
  }

  void _onEvent(BandEvent e) {
    switch (e) {
      case SampleBatch(:final samples, :final raw, :final ephemeral):
        // EPHEMERAL IS NEVER PERSISTED, and this check is the HOST's, not the
        // adapter's promise — the one place that decides what reaches the
        // database is the one place that reads the flag.
        if (ephemeral) {
          _publishLive(samples);
          return;
        }
        _bufferArchive(raw);
        for (final s in samples) {
          _bufferSample(s);
        }
        _publishLive(samples);
      case OffloadCheckpoint():
        unawaited(_commitThenConfirm(e));
      case BandNote(:final key, :final value):
        onNote?.call(key, value);
        onLog('[${adapter.id}] $key = $value');
    }
  }

  void _publishLive(List<NeutralSample> samples) {
    for (final s in samples) {
      if (s.hr != null) {
        _reading.value = HrsReading(bpm: s.hr, atSec: s.tsEpoch);
      }
    }
  }

  void _bufferArchive(List<Uint8List>? raw) {
    final builder = _buildArchive;
    if (raw == null || builder == null) return;
    final capturedAt = _nowSeconds() * 1000;
    for (final bytes in raw) {
      final rec = builder(bytes, capturedAt);
      if (rec != null) _pendingArchive.add(rec);
    }
  }

  void _bufferSample(NeutralSample s) {
    final extra = _admitSample;
    if (extra != null && !extra(s.tsEpoch)) return;
    final slot = _pending.putIfAbsent(s.tsEpoch, _Second.new);
    if (s.hr != null) slot.hr = s.hr;
    if (s.skinTempC != null) slot.skinTempC = s.skinTempC;
    slot.rr.addAll(s.rrMs);
  }

  Future<void> _commitThenConfirm(OffloadCheckpoint cp) async {
    // Verbatim in spirit from `oura_link.dart`'s version, the canonical
    // statement of the invariant: the host commits durably FIRST and calls
    // confirm() second. A commit that fails must leave the adapter's cursor
    // where it was — confirming it would authorise deleting data never
    // banked.
    if (!await _commit(all: true)) {
      onLog('[${adapter.id}] batch not committed; leaving the cursor where '
          'it is.');
      return;
    }
    await cp.confirm();
  }

  /// Write out every second that can no longer receive more notifications.
  /// Returns whether the flush committed (true when there was nothing to
  /// commit). The CURRENT second is held back unless [all].
  Future<bool> _commit({bool all = false}) async {
    final archive = List<ArchiveRecord>.from(_pendingArchive);
    if (_pending.isEmpty && archive.isEmpty) return true;
    final now = _nowSeconds();
    final ready =
        _pending.keys.where((s) => all || s < now).toList()..sort();
    if (ready.isEmpty && archive.isEmpty) return true;
    final batchRows = [for (final s in ready) (s, _pending.remove(s)!)];
    _pendingArchive.clear();
    final neutrals = [
      for (final (sec, slot) in batchRows)
        NeutralSample(
          anchor: adapter.entry.timeAnchor,
          tsEpoch: sec,
          hr: slot.hr,
          rrMs: slot.rr,
          skinTempC: slot.skinTempC,
        ),
    ];
    try {
      await LocalDb.commitSyncBatch(
        const [],
        const [],
        deviceId: deviceId,
        deviceFamily: adapter.id,
        neutrals: neutrals,
        archives: archive.isEmpty ? null : archive,
        onCheckpoint: onLog,
      );
      return true;
    } catch (e) {
      // Put the snapshot back so the next flush can retry it, same shape as
      // `DrainController.commit`'s own restore-on-failure.
      for (final (sec, slot) in batchRows) {
        _pending[sec] = slot;
      }
      _pendingArchive.insertAll(0, archive);
      onLog('[${adapter.id}] commit failed, ${batchRows.length} second(s) '
          'and ${archive.length} archived frame(s) re-buffered: $e');
      return false;
    }
  }

  /// THE NATIVE PATH. A framed band's already-decoded rows, committed with
  /// the trim cursor in one transaction. Called by the gen4/gen5 facade,
  /// never by a [BandAdapter] — which is why it takes protocol types the
  /// adapter seam deliberately does not expose (see M1 spec §9.1).
  Future<bool> commitNativeBatch(
    List<RawRecord> raws,
    List<Sample?> samples,
    String? trimTokenHex, {
    List<ArchiveRecord>? archives,
    String? deviceFamily,
  }) async {
    try {
      await LocalDb.commitSyncBatch(
        raws,
        samples,
        trimToken: trimTokenHex,
        archives: archives,
        deviceFamily: deviceFamily,
        deviceId: deviceId,
        onCheckpoint: onLog,
      );
      return true;
    } catch (e) {
      onLog('[${adapter.id}] native commit failed: $e');
      return false;
    }
  }
}
