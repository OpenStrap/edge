// The Ultrahuman Ring Air as a [BandAdapter]: no auth, no envelope. Set the
// clock, drain the history by record index, decode each 32-byte record, bank
// every byte.
//
// WHAT BECOMES WHAT (the honesty contract):
//  * HR (one reading per record) -> [NeutralSample]s, signal `hrSparse`.
//    Never part of a band's day (`kDerivableSources`); a day the band never
//    saw derives off it only while the ring is the active wearable and its
//    flag is on (`compute/inputs/canonical.dart`).
//  * Steps -> a daily `steps` observation (a comparable quantity).
//  * HRV (RMSSD), SpO2, skin temperature -> calendar-day-mean VENDOR
//    observations (the column serves these over the night instead),
//    attributed to Ultrahuman: the ring computes them with methods nobody
//    outside the vendor can describe. A record whose quality byte says the
//    ring was off the finger, charging or not reading contributes steps only.
//
// DAY-ANCHORED BOOKMARK. A daily mean computed from one session's records
// would overwrite the full day with a partial one, so the bookmark this
// adapter hands back is the index of the FIRST record of the latest day it
// saw, not the next unread index. The next session re-reads that day from its
// start (cheap: one day of records, and re-banking is idempotent —
// `raw_archive` is keyed on the bytes and `decoded_onehz` on the second), so
// every day a session reports on is complete from its first record. The
// days before the latest go out with each confirmed batch, ahead of the
// bookmark that passes them, so a session cut short keeps them.
//
// FETCH-BY-INDEX, LIKE OURA'S FETCH-BY-CURSOR BUT SIMPLER. `0x04` asks for
// recordings starting at a record index, and nothing in this protocol deletes
// on read or acknowledges a fetch — the host's only state is a bookmark, and
// re-reading a range is idempotent. That is the "fetch-by-range: `confirm()`
// advances the adapter's own cursor" row in [OffloadCheckpoint]'s own table.
//
// TERMINATION. One `0x04` streams the history from the requested index as
// many notifications; how many records fit in each depends on the MTU, so
// frame size says nothing about where the stream ends. A pull ends when a
// record's own index reaches the ring's latest index, on `0xee` (nothing more)
// or any other non-ok result (a failure: stop, keep the cursor), or after a
// reply gap. `0x07`/`0x08` (earliest/latest index) are a u16-LE index at
// offset 3 of an ok reply; a failure to read either is "no hint available",
// never a reason to stop draining.
//
// THE INDEX IS A WRAPPING u16. The cursor is always the last received
// record's own index + 1, mod 65536. It is re-anchored to the earliest index
// only when it lies outside `earliest..latest+1` on a ring that has not
// wrapped (earliest <= latest); a wrapped ring's cursor is kept as is.
//
// NO DESTRUCTIVE COMMAND IS REACHABLE FROM HERE. The ring's destructive
// opcodes (device reset / shipping mode `0x17`, software reset `0x98`,
// airplane mode `0x70`, power saving `0xd1`-`0xd4` and the rest listed in
// `protocol`'s `ultrahuman.dart`) have no builder there, and this file writes
// nothing it did not get from a builder there.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Shown next to every value this ring computed itself.
const String kUltrahumanAttribution = 'Ultrahuman';

/// The ring's first record index, and where a drain with no bookmark starts.
const int kUltrahumanFirstIndex = 1;

/// The signals this ring supplies. Mirrored in `kAdapterSignals`. The 5-min
/// cadence is the ring's nominal record interval.
const Map<InputSignal, Duration> kUltrahumanSignals = {
  InputSignal.hrSparse: Duration(minutes: 5),
  InputSignal.steps: Duration(days: 1),
  InputSignal.skinTempC: Duration(minutes: 5),
  InputSignal.activityLevel: Duration(minutes: 5),
  InputSignal.deviceHrv: Duration(days: 1),
  InputSignal.deviceSpo2: Duration(days: 1),
};

/// One session. Not const: it holds the cursor to resume from, which belongs
/// to the host (see `ultrahuman_link.dart`) the same way Oura's cursor and
/// anchor do.
class UltrahumanAdapter extends BandAdapter {
  /// Record index to resume the drain from. The ring numbers its records
  /// from 1, so the default 1 asks for everything it still holds (or as much
  /// of it as the ring's own earliest index allows — see the re-anchor in
  /// [run]).
  final int startIndex;

  /// How long to wait for a reply the ring owes us.
  final Duration replyTimeout;

  /// How long to wait for the host to commit a batch and call `confirm`.
  /// Expiring is SAFE: the cursor does not move, so the batch is re-read.
  final Duration confirmTimeout;

  /// Wall-clock now, in Unix seconds. Injected so a replay is deterministic.
  final int Function() nowSeconds;

  UltrahumanAdapter({
    this.startIndex = kUltrahumanFirstIndex,
    this.replyTimeout = const Duration(seconds: 5),
    this.confirmTimeout = const Duration(seconds: 30),
    int Function()? nowSeconds,
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  @override
  BandEntry get entry => kUltrahuman;

  @override
  Map<InputSignal, Duration> get signals => kUltrahumanSignals;

  /// Records banked per checkpoint while the ring is still streaming. Not a
  /// terminator: the next batch keeps reading the same stream without a new
  /// request.
  static const int _kMaxRecordsPerBatch = 700;

  static int _u16(int v) => v & 0xffff;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final days = _Days(nowSeconds());
    yield* _drain(link, days);
    final rows = days.observations();
    if (rows.isNotEmpty) yield VendorScalars(rows);
  }

  Stream<BandEvent> _drain(BandLink link, _Days days) async* {
    final inbox = _Inbox();
    final sub = link.notify(kUltrahumanNotifyChar).listen(
          (rec) {
            final r = parseUltrahumanResponse(rec.$2);
            if (r != null) inbox.add(r);
          },
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );

    // Best-effort battery, on a SEPARATE service this ring is not required to
    // expose (`kUltrahuman.requiredCharacteristics` does not include it) — a
    // ring that never notifies here simply never gets a `battery` note.
    // Checked at yield points below rather than turned into its own event
    // stream: one link.notify per characteristic already drives everything
    // this session needs, and a second `yield*` source would have to be
    // merged with the first one's timing-sensitive collection loop for a
    // single scalar nobody is waiting on in real time.
    int? pendingBatteryPct;
    final stateSub = link.notify(kUltrahumanDeviceStateChar).listen((rec) {
      final pct = _deviceStateBatteryPct(rec.$2);
      if (pct != null) pendingBatteryPct = pct;
    });

    try {
      // The ring stamps every record against its own clock: set it first.
      await link.write(kUltrahumanWriteChar, ultrahumanCmdSetTime(nowSeconds()));

      // Both best-effort and both OPTIONAL — see the module doc on why the
      // drain loop below never depends on either succeeding.
      final earliest =
          await _getIndex(link, inbox, kUltrahumanOpGetEarliestIndex);
      final latest = await _getIndex(link, inbox, kUltrahumanOpGetLatestIndex);

      var cursor = _u16(startIndex);
      // Checked before the re-anchor: a bookmark one past a latest of 65535
      // is 0, which the re-anchor below would read as "below earliest".
      if (latest != null && cursor == _u16(latest + 1)) {
        link.log('ultrahuman: nothing new since record $latest.');
        return;
      }
      if (earliest != null &&
          latest != null &&
          earliest <= latest &&
          (cursor > latest + 1 || cursor < earliest)) {
        // The bookmark is outside what this ring holds: its records aged out
        // below it, or its counter restarted below it. Either way, start from
        // the oldest record it still has. A wrapped ring (earliest > latest)
        // never lands here; its cursor is kept as is.
        link.log('ultrahuman: bookmark ($cursor) is outside the ring\'s '
            '$earliest..$latest; starting from $earliest.');
        cursor = earliest;
      }

      // A misbehaving ring answering forever would otherwise spin here.
      var request = true;
      for (var pull = 0; pull < 5000; pull++) {
        if (request &&
            !await link.write(
                kUltrahumanWriteChar, ultrahumanCmdGetRecordings(cursor))) {
          link.log('ultrahuman: history request refused; ending the drain.');
          return;
        }
        final got = await _collectPull(inbox, cursor, latest);
        if (pendingBatteryPct != null) {
          yield BandNote('battery', pendingBatteryPct);
          pendingBatteryPct = null;
        }

        if (got.records.isNotEmpty) {
          final samples = <NeutralSample>[];
          for (final r in got.records) {
            final hr = days.add(r);
            if (hr != null) samples.add(hr);
          }
          yield SampleBatch(samples, raw: got.raw);

          // The ring's own index of the last record received, not a count
          // from where we asked: a dropped frame or a skipped index cannot
          // make the cursor drift.
          final newCursor = _u16(got.records.last.index + 1);
          final done = Completer<bool>();
          yield OffloadCheckpoint(
            () async {
              if (!done.isCompleted) done.complete(true);
              return true;
            },
            remaining: latest == null
                ? null
                : got.reachedLatest
                    ? 0
                    : _u16(latest - newCursor + 1),
          );
          final confirmed =
              await done.future.timeout(confirmTimeout, onTimeout: () => false);
          if (!confirmed) {
            link.log('ultrahuman: batch was not confirmed; leaving the cursor '
                'where it is.');
            return;
          }
          cursor = newCursor;
          // The days before the latest one are never read again once the
          // bookmark below passes them: their values go out now, ahead of
          // it, or a session cut short after this batch loses them for good.
          final complete = days.takeCompleted();
          if (complete.isNotEmpty) yield VendorScalars(complete);
          // Day-anchored: resume from the first record of the latest day seen.
          yield BandNote('ultrahuman_cursor', days.latestDayStart ?? cursor);
        }
        if (got.failedResult != null) {
          // Any records banked above are real; only what came after them
          // failed. The cursor stays where they left it.
          link.log('ultrahuman: the ring answered with result '
              '0x${got.failedResult!.toRadixString(16)}; ending the drain.');
          return;
        }
        if (got.reachedLatest) return;
        if (got.records.isEmpty) {
          // Empty, or a reply gap with nothing in it: stop and keep the cursor.
          link.log('ultrahuman: nothing more from $cursor.');
          return;
        }
        // Still streaming: keep reading the same answer. Otherwise the ring
        // went quiet short of its latest index; ask again from the cursor.
        request = !got.streaming;
      }
    } finally {
      await sub.cancel();
      await stateSub.cancel();
    }
  }

  /// Ask for [opcode] (earliest or latest index) and read its own u16-LE
  /// payload back. Null on any refusal, timeout or unparsable reply — never a
  /// guess, since neither is load-bearing for the drain to terminate
  /// correctly. See the module doc for why this response shape is read this
  /// way at all.
  Future<int?> _getIndex(BandLink link, _Inbox inbox, int opcode) async {
    final cmd = opcode == kUltrahumanOpGetEarliestIndex
        ? ultrahumanCmdGetEarliestIndex()
        : ultrahumanCmdGetLatestIndex();
    if (!await link.write(kUltrahumanWriteChar, cmd)) return null;
    final r = await inbox.firstWhere((f) => f.opcode == opcode, replyTimeout);
    if (r == null || !r.ok || r.payload.length < 2) return null;
    return r.payload[0] | (r.payload[1] << 8);
  }

  /// Collect `0x04` notifications from one stream, starting at [from]. Ends
  /// when a record's own index reaches [latest], on an empty result or an ok
  /// frame with no records, on any failure result, after a reply gap, or once
  /// [_kMaxRecordsPerBatch] records are in hand (then [_Pull.streaming] is
  /// set: the ring has not finished, so the caller must not ask again).
  Future<_Pull> _collectPull(_Inbox inbox, int from, int? latest) async {
    final records = <UltrahumanRecord>[];
    final raw = <Uint8List>[];
    // How far [latest] is from where this pull started, in the wrapping
    // counter. A record at that distance or beyond is the end of history.
    final span = latest == null ? null : _u16(latest - from);
    while (records.length < _kMaxRecordsPerBatch) {
      final r = await inbox.next(kUltrahumanOpGetRecordings, replyTimeout);
      if (r == null) return _Pull(records, raw); // reply gap
      if (r.failed) return _Pull(records, raw, failedResult: r.result);
      if (r.empty || r.count == 0) return _Pull(records, raw);
      var reached = false;
      for (var off = 0;
          off + kUltrahumanRecordLen <= r.payload.length;
          off += kUltrahumanRecordLen) {
        final rec = parseUltrahumanRecord(r.payload, off)!;
        records.add(rec);
        raw.add(
            Uint8List.sublistView(r.payload, off, off + kUltrahumanRecordLen));
        if (span != null && _u16(rec.index - from) >= span) reached = true;
      }
      if (reached) return _Pull(records, raw, reachedLatest: true);
    }
    return _Pull(records, raw, streaming: true);
  }

  /// Device-state notify, variable length (at least 7 bytes): `[0]` battery
  /// % u8; `[1..4]` current in µA, i32 LE (the sign is the direction); `[5]`
  /// charge state u8 (0 not charging, 3 charging, anything else unknown);
  /// `[6]` temperature u8 (unit not stated); when 9+ bytes, `[7..8]` voltage
  /// in mV, u16 BIG-endian; when 10+ bytes, `[9]` charger status (0 off, 1
  /// idle, 2 pre-charge, 3 fast 1, 4 fast 2, 5 fast CV, 6 maintain, 7 maintain
  /// done, 8 fault 1, 9 fault 2, 14 CC track, 15 suspend); `[10..13]` further
  /// u8 status fields; 33+ bytes carry an extended block (cycles, capacity,
  /// time to empty/full). Only `[0]` is read here.
  static int? _deviceStateBatteryPct(List<int> value) {
    if (value.length < 7) return null;
    final pct = value[0];
    return (pct >= 0 && pct <= 100) ? pct : null;
  }
}

/// Per-local-day accumulation of one session's records, plus the index of the
/// first record of the latest day seen (the next session's bookmark).
class _Days {
  final int nowSec;
  _Days(this.nowSec);

  /// Records stamped before this, or after now, are a ring whose clock was
  /// never set — dropped rather than filed on 1970.
  static final int _floorSec =
      DateTime.utc(2020).millisecondsSinceEpoch ~/ 1000;

  final _steps = <DateTime, int>{};
  final _hrv = <DateTime, List<num>>{};
  final _spo2 = <DateTime, List<num>>{};
  final _temp = <DateTime, List<num>>{};
  DateTime? _lastDay;

  /// The first record (in arrival order) with any of its three clocks on
  /// each day.
  final _firstIndex = <DateTime, int>{};

  /// The bookmark: the first record with any clock on the latest day seen,
  /// so a resumed session re-reads every step, skin and HR stamp of that day
  /// and never files it short.
  int? get latestDayStart => _lastDay == null ? null : _firstIndex[_lastDay];

  bool _ok(int ts) => ts >= _floorSec && ts <= nowSec + 3600;

  static DateTime _day(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return DateTime(t.year, t.month, t.day);
  }

  /// Accumulates [r]; returns its HR sample, if any.
  NeutralSample? add(UltrahumanRecord r) {
    final clocks = [
      for (final ts in [r.tsA, r.tsB, r.tsC])
        if (_ok(ts)) _day(ts),
    ];
    for (final d in clocks) {
      _firstIndex.putIfAbsent(d, () => r.index);
    }
    // A session resumes at the first record touching the bookmark day, whose
    // other clocks may still read the day before: the latest of them is the
    // first day this session owns.
    if (_firstDay == null && clocks.isNotEmpty) {
      _firstDay = clocks.reduce((a, b) => a.isAfter(b) ? a : b);
    }
    if (_ok(r.tsA)) _lastDay = _day(r.tsA);
    if (_ok(r.tsC) && r.steps > 0 && _open(_day(r.tsC))) {
      final d = _day(r.tsC);
      _steps[d] = (_steps[d] ?? 0) + r.steps;
    }
    if (!ultrahumanHrQualityValid(r.hrQuality)) return null;
    if (_ok(r.tsA) && _open(_day(r.tsA))) {
      final d = _day(r.tsA);
      if (r.hrv > 0) (_hrv[d] ??= []).add(r.hrv);
      if (r.spo2 > 0 && r.spo2 <= 100) (_spo2[d] ??= []).add(r.spo2);
    }
    // The skin-facing sensor only; bytes 16-19 are the ambient one. A zero
    // temperature quality means the ring itself does not trust the reading.
    final t = r.skinTempC;
    if (r.tempQuality > 0 &&
        _ok(r.tsB) &&
        t >= 20 &&
        t <= 45 &&
        _open(_day(r.tsB))) {
      (_temp[_day(r.tsB)] ??= []).add(t);
    }
    if (!_ok(r.tsA) || r.hr < 25 || r.hr > 230) return null;
    return NeutralSample(
        anchor: TimeAnchor.measured, tsEpoch: r.tsA, hr: r.hr);
  }

  static double _mean(List<num> v) =>
      v.fold<double>(0, (s, x) => s + x) / v.length;

  static Observation _obs(DateTime day, num value,
          {String? unit, String? key, String? vendorKey}) =>
      Observation(
        at: day,
        sourceKind: ObservationSource.vendor,
        key: key,
        vendorKey: vendorKey,
        value: value,
        unit: unit,
        attribution: kUltrahumanAttribution,
      );

  /// Days already handed out by [takeCompleted]: a stray later record for
  /// one must not file a partial mean over the full one.
  final _taken = <DateTime>{};

  /// The latest day on this session's first record's clocks. A session
  /// resumes at the first record touching a day, so a stamp before that day
  /// (the record's three clocks can differ) belongs to a day the previous
  /// session already filed in full: filing it again would replace that total
  /// with a part of it.
  DateTime? _firstDay;

  bool _open(DateTime d) =>
      !_taken.contains(d) && (_firstDay == null || !d.isBefore(_firstDay!));

  /// The observations of every day before the latest seen, removed from
  /// what [observations] returns: complete, since records arrive in order.
  List<Observation> takeCompleted() {
    final last = _lastDay;
    if (last == null) return const [];
    final before = {
      for (final m in [_steps, _hrv, _spo2, _temp]) ...m.keys,
    }.where((d) => d.isBefore(last)).toSet();
    final out = [
      for (final o in observations())
        if (before.contains(o.at)) o,
    ];
    for (final m in [_steps, _hrv, _spo2, _temp]) {
      m.removeWhere((d, _) => before.contains(d));
    }
    _taken.addAll(before);
    return out;
  }

  List<Observation> observations() => [
        for (final MapEntry(:key, :value) in _steps.entries)
          _obs(key, value, unit: 'steps', key: 'steps'),
        for (final MapEntry(:key, :value) in _hrv.entries)
          _obs(key, _mean(value), unit: 'ms', vendorKey: 'hrv_avg'),
        for (final MapEntry(:key, :value) in _spo2.entries)
          _obs(key, _mean(value), unit: '%', vendorKey: 'spo2_avg'),
        for (final MapEntry(:key, :value) in _temp.entries)
          _obs(key, _mean(value), unit: '°C', vendorKey: 'skin_temp_avg'),
      ];
}

class _Pull {
  final List<UltrahumanRecord> records;
  final List<Uint8List> raw;

  /// The result byte of a failed frame, or null.
  final int? failedResult;
  final bool reachedLatest;
  final bool streaming;
  const _Pull(this.records, this.raw,
      {this.failedResult, this.reachedLatest = false, this.streaming = false});
}

/// Response frames off the notify characteristic, buffered so a reply landing
/// before anyone is waiting is not dropped. Same shape as `oura.dart`'s
/// private `_Inbox`, and hand-rolled for the same reason: the whole of what
/// this session needs is "the next frame [matching X], or nothing".
class _Inbox {
  final List<UltrahumanResponse> _buf = [];
  Completer<UltrahumanResponse?>? _waiter;
  bool _closed = false;

  void add(UltrahumanResponse r) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(r);
      return;
    }
    _buf.add(r);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  /// The next buffered frame, or null on timeout or a closed link.
  Future<UltrahumanResponse?> _next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<UltrahumanResponse?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame with opcode [opcode], discarding anything else that
  /// arrives first. [timeout] bounds the whole search, not each frame.
  Future<UltrahumanResponse?> next(int opcode, Duration timeout) =>
      firstWhere((f) => f.opcode == opcode, timeout);

  Future<UltrahumanResponse?> firstWhere(
    bool Function(UltrahumanResponse) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final r = await _next(timeout - deadline.elapsed);
      if (r == null) return null;
      if (test(r)) return r;
    }
    return null;
  }
}
