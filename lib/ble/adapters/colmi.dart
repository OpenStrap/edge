// Colmi smart ring family as a [BandAdapter]: set the clock, walk the
// ring's stored history, decode it, bank every reply byte.
//
// THE WIRE lives in `protocol` (`colmi.dart`): 16-byte checksummed frames on
// Service A for battery, clock and the paged HR / stress / HRV / activity
// walks, and length-prefixed CRC-16 "big data" replies on Service B for
// sleep, SpO2 and temperature. No handshake, no key.
//
// WHAT BECOMES WHAT. The split is the honesty contract, not a convenience:
//  * HR history (5-min slots by default; the walk's page 0 says) ->
//    [NeutralSample]s, signal `hrSparse`. A real
//    measured quantity, the only thing here our own analytics could ever
//    consume. Still gated out of derivation by `kDerivableSources` until the
//    decode has met a real ring.
//  * The ring's own sleep stages -> [VendorHypnogram], plus per-night stage
//    minutes as vendor observations for display. Naps are a `nap_min`
//    observation and never join the night. A ring whose SetTime reply says
//    it has no big-data sleep is asked per day on Service A instead; those
//    rows are banked but not decoded into stages (the mapping is unknown).
//  * Steps -> a daily `steps` observation (a comparable quantity).
//  * Stress, HRV, SpO2, skin temperature -> daily-mean VENDOR observations.
//    The ring computes all four with methods nobody outside the vendor can
//    describe, so they are shown attributed and never fed to a baseline.
//
// TIME. The ring keeps the local wall-clock time we set (no zone) and reports
// history as "N days ago" + minute-of-day. A paged walk's page 1 names the
// day it holds, and that answer wins over the day that was asked for. Every
// such pair is resolved here against the phone's local calendar via
// `DateTime(y, m, d - n, 0, minute)`, which is what makes a DST day come out
// right. The clock is set at the start of every session, so a ring that lost
// power re-learns the time before any history is read.
//
// STALE SLOTS. The ring's per-time-of-day buffer is not reliably cleared for
// a slot it has not measured yet today; a leftover byte from the same slot
// yesterday would land in the future. Any decoded point later than now is
// dropped.
//
// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project has run this against
// a physical ring. Every reply is archived verbatim so a corrected decoder
// can be re-run over what was already banked.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../compute/vendor_sleep.dart' show VendorEpoch;
import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Shown next to every value this ring computed itself.
const String kColmiAttribution = 'Colmi';

/// Days of history walked per session (today plus six).
const int kColmiHistoryDays = 7;

class ColmiAdapter extends BandAdapter {
  /// Wall-clock now, in Unix seconds. Injected so a replay is deterministic.
  final int Function() nowSeconds;

  /// How long to wait for the FIRST reply to a request.
  final Duration firstReplyTimeout;

  /// How long after the last reply before a walk with no explicit end marker
  /// is treated as finished.
  final Duration quietTimeout;

  ColmiAdapter({
    int Function()? nowSeconds,
    this.firstReplyTimeout = const Duration(seconds: 5),
    this.quietTimeout = const Duration(milliseconds: 800),
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  @override
  BandEntry get entry => kColmi;

  @override
  Map<InputSignal, Duration> get signals => kColmiSignals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final a = _Inbox(), b = _Inbox();
    final subA = link.notify(kColmiNotifyChar).listen(
        (r) => a.add(Uint8List.fromList(r.$2)),
        onDone: a.close,
        onError: (Object _) => a.close());
    final subB = link.notify(kColmiBigNotifyChar).listen(
        (r) => b.add(Uint8List.fromList(r.$2)),
        onDone: b.close,
        onError: (Object _) => b.close());
    final now = DateTime.fromMillisecondsSinceEpoch(nowSeconds() * 1000);
    final today = DateTime(now.year, now.month, now.day);
    DateTime at(int daysAgo, int minute) =>
        DateTime(today.year, today.month, today.day - daysAgo, 0, minute);
    try {
      // ── clock; the reply says which sleep protocol the ring speaks ──
      // No reply keeps the big-data sleep request, which is what every ring
      // that answers it needs.
      var newSleep = true;
      if (await link.write(kColmiWriteChar, colmiSetTimeRequest(now))) {
        final got = await _walk(a, kColmiCmdSetTime, (_) => true, link.log);
        if (got.isNotEmpty) {
          newSleep = colmiNewSleepProtocol(got.last) ?? true;
          yield SampleBatch(const [], raw: got);
        }
      }

      // ── battery ──
      if (await link.write(kColmiWriteChar, colmiBatteryRequest())) {
        final got = await _walk(a, kColmiCmdBattery, (_) => true, link.log);
        final pct = got.isEmpty ? null : colmiBatteryPct(got.last);
        if (pct != null) yield BandNote('battery', pct);
        if (got.isNotEmpty) yield SampleBatch(const [], raw: got);
      }

      final samples = <NeutralSample>[];
      final steps = <DateTime, int>{};
      final hrv = <DateTime, List<int>>{};
      final stress = <DateTime, List<int>>{};
      final raw = <Uint8List>[];

      // The day a walk's page 1 says it holds, against the day asked for. The
      // ring's own answer wins; a disagreement is logged.
      int dayOf(int asked, int? replied, String what) {
        if (replied == null || replied == asked) return asked;
        link.log('colmi: $what for $asked days ago came back for $replied.');
        return replied;
      }

      for (var d = 0; d < kColmiHistoryDays; d++) {
        // ── activity: one 15-min slot per frame, explicit last page ──
        if (await link.write(kColmiWriteChar, colmiActivityRequest(d))) {
          final got = await _walk(
              a, kColmiCmdActivityHistory, colmiActivityDone, link.log);
          raw.addAll(got);
          var x10 = false;
          for (final f in got) {
            final h = colmiActivityCaloriesX10(f);
            if (h != null) {
              x10 = h;
              continue;
            }
            final s = colmiActivitySlot(f, caloriesX10: x10);
            if (s == null || s.steps == 0) continue;
            final day = DateTime(s.year, s.month, s.day);
            steps[day] = (steps[day] ?? 0) + s.steps;
          }
        }

        // ── HR: page 0 announces the page count and slot interval ──
        final hrFrom = d == 0 ? now : at(d, 0);
        if (await link.write(
            kColmiWriteChar,
            colmiHrHistoryRequest(hrFrom.millisecondsSinceEpoch ~/ 1000 +
                hrFrom.timeZoneOffset.inSeconds))) {
          final w = await _paged(a, kColmiCmdHrHistory, 5, link.log);
          raw.addAll(w.got);
          int? replied;
          for (final f in w.got) {
            final ts = colmiHrPageTimestamp(f);
            if (ts == null) continue;
            final u = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
            replied = DateTime.utc(today.year, today.month, today.day)
                .difference(DateTime.utc(u.year, u.month, u.day))
                .inDays;
          }
          final day = dayOf(d, replied, 'HR');
          for (final f in w.got) {
            for (final p
                in colmiHrHistoryPoints(f, slotMinutes: w.slotMinutes)) {
              final t = at(day, p.minuteOfDay);
              if (t.isAfter(now) || p.value < 25 || p.value > 230) continue;
              samples.add(NeutralSample(
                anchor: TimeAnchor.measured,
                tsEpoch: t.millisecondsSinceEpoch ~/ 1000,
                hr: p.value,
              ));
            }
          }
        }

        // ── HRV and stress: same paged layout, page 1 names the day ──
        for (final (cmd, req, into) in [
          (kColmiCmdHrvHistory, colmiHrvRequest(d), hrv),
          (kColmiCmdStressHistory, colmiStressRequest(d), stress),
        ]) {
          if (!await link.write(kColmiWriteChar, req)) continue;
          final w = await _paged(a, cmd, 30, link.log);
          raw.addAll(w.got);
          int? replied;
          for (final f in w.got) {
            replied ??= colmiPagedDaysAgo(f);
          }
          final day = dayOf(
              d, replied, cmd == kColmiCmdHrvHistory ? 'HRV' : 'stress');
          for (final f in w.got) {
            final points = cmd == kColmiCmdHrvHistory
                ? colmiHrvPoints(f, slotMinutes: w.slotMinutes)
                : colmiStressPoints(f, slotMinutes: w.slotMinutes);
            for (final p in points) {
              if (at(day, p.minuteOfDay).isAfter(now)) continue;
              (into[at(day, 0)] ??= []).add(p.value);
            }
          }
        }

        // ── sleep on Service A, for a ring without the big-data request ──
        // Banked only: how its quality bytes map to stages is not known. The
        // ring keeps more days than this, but the window is deliberately the
        // same [kColmiHistoryDays] as every other walk here.
        if (!newSleep &&
            await link.write(kColmiWriteChar, colmiSleepDetailsRequest(d))) {
          raw.addAll(await _walk(
              a, kColmiCmdSleepDetails, colmiSleepDetailsDone, link.log));
        }
      }

      if (samples.isNotEmpty || raw.isNotEmpty) {
        yield SampleBatch(samples, raw: raw);
      }

      // ── Service B: SpO2, sleep (+ naps), temperature ──
      final replies = <Uint8List>[];
      if (await link.write(kColmiCommandChar, colmiSpo2Request())) {
        final r = await _big(b, link.log);
        if (r != null) replies.add(r);
      }
      if (newSleep && await link.write(kColmiCommandChar, colmiSleepRequest())) {
        final r = await _big(b, link.log);
        if (r != null) {
          replies.add(r);
          // A ring that records naps sends them as a second reply. Drained
          // here so it cannot be taken for the temperature reply below.
          final nap = await _big(b, link.log, timeout: quietTimeout);
          if (nap != null) replies.add(nap);
        }
      }
      if (await link.write(kColmiCommandChar, colmiTemperatureRequest())) {
        // One reply per stored day, until the ring goes quiet.
        for (var t = firstReplyTimeout;; t = quietTimeout) {
          final r = await _big(b, link.log, timeout: t);
          if (r == null) break;
          replies.add(r);
        }
      }

      final spo2 = <DateTime, List<double>>{};
      final temp = <DateTime, List<double>>{};
      final epochs = <VendorEpoch>[];
      final stageRows = <Observation>[];
      for (final r in replies) {
        switch (r[1]) {
          case kColmiBigSpo2:
            for (final h in colmiSpo2Hours(r)) {
              if (at(h.daysAgo, h.hour * 60).isAfter(now)) continue;
              (spo2[at(h.daysAgo, 0)] ??= []).add((h.min + h.max) / 2);
            }
          case kColmiBigTemperature:
            for (final t in colmiTemperatures(r)) {
              if (at(t.daysAgo, t.minuteOfDay).isAfter(now)) continue;
              (temp[at(t.daysAgo, 0)] ??= []).add(t.celsius);
            }
          case kColmiBigSleep:
          case kColmiBigNap:
            for (final n in colmiSleepNights(r)) {
              _night(n, at, epochs, stageRows);
            }
        }
      }
      if (replies.isNotEmpty) yield SampleBatch(const [], raw: replies);
      if (epochs.isNotEmpty) yield VendorHypnogram('colmi', epochs);

      final rows = <Observation>[
        ...stageRows,
        for (final MapEntry(:key, :value) in steps.entries)
          _obs(key, value, unit: 'steps', key: 'steps'),
        for (final MapEntry(:key, :value) in hrv.entries)
          _obs(key, _mean(value), unit: 'ms', vendorKey: 'hrv_avg'),
        for (final MapEntry(:key, :value) in stress.entries)
          _obs(key, _mean(value), vendorKey: 'stress_avg'),
        for (final MapEntry(:key, :value) in spo2.entries)
          _obs(key, _mean(value), unit: '%', vendorKey: 'spo2_avg'),
        for (final MapEntry(:key, :value) in temp.entries)
          _obs(key, _mean(value), unit: '°C', vendorKey: 'skin_temp_avg'),
      ];
      if (rows.isNotEmpty) yield VendorScalars(rows);
    } finally {
      await subA.cancel();
      await subB.cancel();
    }
  }

  /// One night into hypnogram epochs + per-stage minute totals, or one nap
  /// into a `nap_min` row (naps never join the night's hypnogram).
  ///
  /// A night is anchored at its end and starts the sum of its blocks before
  /// it, which is how the ring lays its own data out; the start field is not
  /// used. A nap runs forward from its start field.
  static void _night(
    ColmiSleepNight n,
    DateTime Function(int, int) at,
    List<VendorEpoch> epochs,
    List<Observation> rows,
  ) {
    if (n.nap) {
      final asleep = n.blocks
          .where((b) => b.stage != 0)
          .fold(0, (s, b) => s + b.minutes);
      if (asleep > 0) {
        rows.add(Observation(
          at: at(n.daysAgo, n.startMinute + n.totalMinutes),
          sourceKind: ObservationSource.vendor,
          vendorKey: 'nap_min',
          value: asleep,
          unit: 'min',
          attribution: kColmiAttribution,
        ));
      }
      return;
    }
    final end = at(n.daysAgo, n.endMinute);
    final start = end.subtract(Duration(minutes: n.totalMinutes));
    if (!end.isAfter(start)) return;
    final endSec = end.millisecondsSinceEpoch ~/ 1000;
    var t = start.millisecondsSinceEpoch ~/ 1000;
    final minutes = <String, int>{};
    for (final blk in n.blocks) {
      final stage = _stage(blk.stage);
      final stop = (t + blk.minutes * 60).clamp(t, endSec);
      if (stage != null && stop > t) {
        epochs.add(VendorEpoch(t, stop, stage));
        minutes[stage] = (minutes[stage] ?? 0) + (stop - t) ~/ 60;
      }
      t = stop;
      if (t >= endSec) break;
    }
    for (final MapEntry(:key, :value) in minutes.entries) {
      rows.add(Observation(
        at: end,
        sourceKind: ObservationSource.vendor,
        vendorKey: 'sleep_${key}_min',
        value: value,
        unit: 'min',
        attribution: kColmiAttribution,
      ));
    }
  }

  static String? _stage(int code) => switch (code) {
        kColmiStageLight => 'light',
        kColmiStageDeep => 'deep',
        kColmiStageRem => 'rem',
        kColmiStageAwake => 'wake',
        _ => null,
      };

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
        attribution: kColmiAttribution,
      );

  /// Every valid frame tagged [cmd] until [done] says the walk is over, or
  /// [quietTimeout] passes with nothing new. A frame for another command
  /// (an unsolicited push mid-walk) is skipped without shortening the wait.
  /// A frame tagged `cmd | 0x80` is the ring rejecting the request: it is
  /// kept (for the archive), logged, and ends the walk.
  Future<List<Uint8List>> _walk(_Inbox inbox, int cmd,
      bool Function(Uint8List) done, void Function(String) log) async {
    final out = <Uint8List>[];
    var timeout = firstReplyTimeout;
    while (true) {
      final f = await inbox.next(timeout);
      if (f == null) return out;
      if (!colmiFrameValid(f)) continue;
      if (f[0] == (cmd | kColmiErrorFlag)) {
        log('colmi: ring rejected command 0x${cmd.toRadixString(16)}.');
        out.add(f);
        return out;
      }
      if (f[0] != cmd) continue;
      out.add(f);
      if (done(f)) return out;
      timeout = quietTimeout;
    }
  }

  /// One paged HR / stress / HRV walk, ended by page 0's page count (or
  /// "no data"), plus the slot interval page 0 announced ([defaultSlot] when
  /// it announced none).
  Future<({List<Uint8List> got, int slotMinutes})> _paged(
      _Inbox inbox, int cmd, int defaultSlot, void Function(String) log) async {
    var pages = 0, slot = defaultSlot;
    final got = await _walk(inbox, cmd, (f) {
      final h = colmiPagedHeader(f, cmd);
      if (h != null) {
        pages = h.pages;
        if (h.slotMinutes > 0) slot = h.slotMinutes;
      }
      return f[1] == kColmiNoData || (pages > 0 && f[1] >= pages - 1);
    }, log);
    return (got: got, slotMinutes: slot);
  }

  /// One reassembled Service B reply, or null on timeout.
  ///
  /// A CRC mismatch is LOGGED, NOT DROPPED. Whether the ring fills header
  /// bytes 4-5 of a reply with CRC-16/MODBUS of the payload has never been
  /// checked against a real ring, and nothing else that reads these replies
  /// checks it; a firmware that writes something else there would otherwise
  /// lose every sleep, SpO2 and temperature reply, raw bytes included. BLE's
  /// own link-layer CRC already guards each notification, and the
  /// reassembler's length check catches a misaligned reassembly. Tighten
  /// this back to a drop only once a capture shows the ring's CRC matching.
  Future<Uint8List?> _big(_Inbox inbox, void Function(String) log,
      {Duration? timeout}) async {
    final r = ColmiBigDataReassembler();
    var wait = timeout ?? firstReplyTimeout;
    while (true) {
      final chunk = await inbox.next(wait);
      if (chunk == null) return null;
      final whole = r.add(chunk);
      if (whole == null) {
        if (r.pending) wait = quietTimeout;
        continue;
      }
      if (!colmiBigDataCrcOk(whole)) {
        final len = whole[2] | (whole[3] << 8);
        final got = whole[4] | (whole[5] << 8);
        final want = crc16Modbus(whole.sublist(
            kColmiBigHeaderLength, kColmiBigHeaderLength + len));
        log('colmi: big-data reply 0x${whole[1].toRadixString(16)} CRC '
            'mismatch (got 0x${got.toRadixString(16)}, want '
            '0x${want.toRadixString(16)}); keeping it.');
      }
      return Uint8List.fromList(whole);
    }
  }
}

/// The signals this ring supplies. Mirrored in `kAdapterSignals`.
const Map<InputSignal, Duration> kColmiSignals = {
  InputSignal.hrSparse: Duration(minutes: 5),
};

/// The single instance. Holds no per-ring state.
final ColmiAdapter kColmiAdapter = ColmiAdapter();

/// Notifications buffered so a reply landing before anyone waits is kept.
class _Inbox {
  final List<Uint8List> _buf = [];
  Completer<Uint8List?>? _waiter;
  bool _closed = false;

  void add(Uint8List frame) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(frame);
      return;
    }
    _buf.add(frame);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  Future<Uint8List?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<Uint8List?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }
}
