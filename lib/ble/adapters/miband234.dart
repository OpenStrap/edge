// Mi Band 2 and 3 — the shared "Huami legacy" GATT protocol — as a
// [BandAdapter]. Mi Band 4 is not covered: it only accepts a key issued
// through the vendor's own pairing.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). [signals] is
// [kMiBand234Signals]; its metrics (`compute/inputs/miband_inputs.dart`)
// sit behind the default-off `wearable_enabled:miband234` flag, so nothing
// it supplies becomes a metric for a user until the owner has held one.
//
// THE SESSION:
//   1. AUTH — a locally-generated AES-128 key, not a vendor one. The band
//      holds exactly one 16-byte key and only accepts a NEW one while it has
//      none (a factory-reset or never-paired unit); the band may ask for a tap
//      to confirm the install. Then challenge/response: ask for a random number, answer
//      with it AES-ECB-encrypted under the key. See `miband_link.dart` for
//      the pairing side.
//   2. CLOCK — set from the phone (`huamiTimeValue`).
//   3. HISTORY — the stored minute records, in paged rounds from the
//      `miband_since` cursor (`huami_legacy.dart` has the wire format). Each
//      round, a day at a time, yields its HR samples, the daily steps and
//      closed nights so far (the band's own hypnogram), a `miband_since`
//      [BandNote], then an [OffloadCheckpoint]; the host commits the rows and
//      the cursor together. The band's drop-acknowledgement is never sent,
//      so its flash is left alone.
//   4. OPTIONAL CHANNELS — battery, live steps and the standard heart-rate
//      characteristic, each archived verbatim and undecoded until the link
//      ends.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../compute/vendor_sleep.dart' show VendorEpoch;
import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Encrypt one authentication challenge.
///
/// AES-128 in ECB mode, one 16-byte block, no padding — the band's challenge
/// already arrives exactly block-sized, which is simpler than a scheme that
/// has to pad first (contrast `oura.dart`'s `ouraAuthResponse`, which pads a
/// 15-byte nonce). One block only, so ECB's usual objection has nothing to
/// bite on here either.
///
/// Exposed rather than private so a test can pin it against a known AES
/// vector without a radio.
Uint8List miBand234AuthResponse(List<int> key, List<int> challenge) {
  if (key.length != 16 || challenge.length != 16) {
    throw ArgumentError(
        'Mi Band 2/3 auth takes a 16-byte key and a 16-byte challenge');
  }
  final out = Uint8List(16);
  ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)))
    ..processBlock(Uint8List.fromList(challenge), 0, out, 0);
  return out;
}

/// Install [key]. The band answers `10 01 <status>` on the auth
/// characteristic, possibly only after the user taps it to confirm.
List<int> miBand234KeyInstall(List<int> key) => <int>[0x01, 0x00, ...key];

/// Ask for the authentication challenge: the first form, then the second if
/// the band gives no usable answer to it.
const List<List<int>> kMiBand234ChallengeRequests = <List<int>>[
  <int>[0x02, 0x00, 0x02],
  <int>[0x02, 0x00],
];

/// Answer the challenge with its encryption under the key.
List<int> miBand234AuthAnswer(List<int> encrypted) =>
    <int>[0x03, 0x00, ...encrypted];

/// Status 0x02 in an auth reply: the band was in the wrong state for the
/// command, which a retry can clear; 0x04 and others are a refusal.
const int kMiBand234AuthInvalidState = 0x02;

/// Host-side tags distinguishing which optional channel an archived frame
/// came from. NEVER transmitted and never part of `raw_archive.hex` — see
/// `miband_link.dart`'s archive builder, which strips the tag back off
/// before hexing so the stored bytes are exactly what the radio sent.
const int kMiBand234ArchiveBattery = 0xf0;
const int kMiBand234ArchiveSteps = 0xf1;
const int kMiBand234ArchiveHr = 0xf2;
const int kMiBand234ArchiveActivity = 0xf3;

/// The signals this band supplies: one HR reading per stored minute, its
/// daily step total and its own per-minute sleep kind. Mirrored in
/// `kAdapterSignals`.
const Map<InputSignal, Duration> kMiBand234Signals = {
  InputSignal.hrSparse: Duration(minutes: 1),
  InputSignal.steps: Duration(days: 1),
  InputSignal.deviceStages: Duration(minutes: 1),
};

/// Shown next to every value this band computed itself.
const String kMiBandAttribution = 'Mi Band';

/// One connection to a Mi Band 2 or 3.
class MiBand234Adapter extends BandAdapter {
  /// The 16-byte key this phone generated and either has, or is about to,
  /// install on the band.
  final List<int> key;

  /// True only on the very first connection after pairing installed a key the
  /// band did not have — see [entry]'s own doc. False on every reconnect: a
  /// band that already holds this key does not accept a second install, and
  /// nothing here needs it to.
  final bool needsKeyWrite;

  /// How long to wait for a reply the band owes us.
  final Duration replyTimeout;

  /// How long to wait for the key-install reply, which can wait on a tap.
  final Duration confirmTimeout;

  /// How long to wait for a history round's header, and the longest silence
  /// between its packets.
  final Duration fetchTimeout;

  /// Where to resume the activity fetch, Unix seconds; null reads the last
  /// [kMiBandFirstFetchDays] days.
  final int? sinceSec;

  /// Wall-clock now, in Unix seconds. Injected so a replay is deterministic.
  final int Function() nowSeconds;

  MiBand234Adapter({
    required this.key,
    this.needsKeyWrite = false,
    this.replyTimeout = const Duration(seconds: 5),
    this.confirmTimeout = const Duration(seconds: 30),
    this.fetchTimeout = const Duration(seconds: 20),
    this.sinceSec,
    int Function()? nowSeconds,
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  static const int kMiBandFirstFetchDays = 7;

  @override
  BandEntry get entry => kMiBand234;

  @override
  Map<InputSignal, Duration> get signals => kMiBand234Signals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox<Uint8List>();
    final sub = link.notify(kHuami234AuthChar).listen(
          (rec) => inbox.add(Uint8List.fromList(rec.$2)),
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      if (!await _authenticate(link, inbox)) return;
      yield* _fetchHistory(link);
      yield* _subscribeOptional(link);
    } finally {
      await sub.cancel();
    }
  }

  /// Install-then-prove. False on any refusal — a session that carries on
  /// unauthenticated would sit waiting on channels the band will never answer.
  Future<bool> _authenticate(BandLink link, _Inbox<Uint8List> inbox) async {
    if (needsKeyWrite) {
      if (!await link.write(kHuami234AuthChar, miBand234KeyInstall(key))) {
        return false;
      }
      final sent = await inbox.firstWhere(
        (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x01,
        confirmTimeout,
      );
      if (sent == null || sent[2] != 0x01) {
        link.log('miband234: key install refused or unanswered '
            '(status ${sent == null ? "none" : sent[2]}).');
        return false;
      }
    }
    Uint8List? challengeFrame;
    for (final request in kMiBand234ChallengeRequests) {
      if (!await link.write(kHuami234AuthChar, request)) return false;
      challengeFrame = await inbox.firstWhere(
        (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x02,
        replyTimeout,
      );
      if (challengeFrame != null &&
          challengeFrame.length >= 19 &&
          challengeFrame[2] == 0x01) {
        break;
      }
      challengeFrame = null;
    }
    if (challengeFrame == null) {
      link.log('miband234: no usable authentication challenge.');
      return false;
    }
    final answer =
        miBand234AuthResponse(key, challengeFrame.sublist(3, 19));
    if (!await link.write(kHuami234AuthChar, miBand234AuthAnswer(answer))) {
      return false;
    }
    final result = await inbox.firstWhere(
      (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x03,
      replyTimeout,
    );
    if (result == null || result[2] != 0x01) {
      // Worth naming, because the remedies differ: 0x04 means the wrong key
      // (or a band still bound to another one); silence means the band
      // stopped answering mid-handshake.
      link.log('miband234: authentication refused '
          '(status ${result == null ? "none" : result[2]}).');
      return false;
    }
    return true;
  }

  /// Best-effort subscribe to whatever optional channel this unit exposes,
  /// and forward every notification verbatim. Ends when the link ends — there
  /// is no completion signal on any of these channels to wait for, unlike the
  /// history fetch.
  Stream<BandEvent> _subscribeOptional(BandLink link) {
    // Fan-in of 3 upstream notify subscriptions into one stream. A bare
    // StreamController has no idea those subscriptions exist, so cancelling
    // a *listener* of `controller.stream` (which is all `run()`'s finally
    // can reach once this stream has been handed off via `yield*`) would
    // otherwise leave battery/steps/HR listening forever. `onCancel` is the
    // controller's own hook for exactly this: it fires when the stream's one
    // listener cancels, which is what happens when `BandHost.stop()` cancels
    // `run()`'s subscription and that cancellation propagates through
    // `yield*`.
    final subs = <StreamSubscription<(int, List<int>)>>[];
    late final StreamController<BandEvent> controller;
    controller = StreamController<BandEvent>(onCancel: () async {
      for (final s in subs) {
        await s.cancel();
      }
    });
    const channels = <(String uuid, int archiveTag)>[
      (kHuami234BatteryChar, kMiBand234ArchiveBattery),
      (kHuami234StepsChar, kMiBand234ArchiveSteps),
      (kHeartRateMeasurementUuid, kMiBand234ArchiveHr),
    ];
    var open = channels.length;
    void endOne() {
      open--;
      if (open <= 0 && !controller.isClosed) controller.close();
    }

    for (final (uuid, tag) in channels) {
      subs.add(link.notify(uuid).listen(
        (rec) {
          if (controller.isClosed) return;
          // The tag is prepended for the archive builder to key `reason`
          // and `packet_type` on, and stripped back off before hexing — see
          // `miband_link.dart`. Never part of what a decoder would see as
          // the wire bytes.
          controller.add(SampleBatch(
            const [],
            raw: [Uint8List.fromList([tag, ...rec.$2])],
          ));
        },
        onDone: endOne,
        onError: (Object _) => endOne(),
      ));
    }
    return controller.stream;
  }
}

extension on MiBand234Adapter {
  /// Set the clock, then fetch stored activity in rounds from [sinceSec].
  /// Never sends the band's drop-acknowledgement (see `huami_legacy.dart`).
  Stream<BandEvent> _fetchHistory(BandLink link) async* {
    // ONE inbox for both characteristics, each frame tagged with which one it
    // came on (true = control): a round ends on whichever comes first, its
    // last data packet or the band's done notification, and the next round's
    // header wait discards anything a previous round left behind.
    final inbox = _Inbox<(bool, Uint8List)>();
    final subs = [
      link.notify(kHuamiActivityControlChar).listen(
          (r) => inbox.add((true, Uint8List.fromList(r.$2))),
          onDone: inbox.close),
      link.notify(kHuamiActivityDataChar).listen(
          (r) => inbox.add((false, Uint8List.fromList(r.$2))),
          onDone: inbox.close),
    ];
    try {
      final nowSec = nowSeconds();
      DateTime local(int sec) => DateTime.fromMillisecondsSinceEpoch(sec * 1000);
      await link.write(kCurrentTimeChar, huamiTimeValue(local(nowSec)));

      final sessionSince = sinceSec ??
          nowSec - MiBand234Adapter.kMiBandFirstFetchDays * 86400;
      var since = sessionSince;
      final minutes = <HuamiMinute>[];
      for (var round = 0; round < 10 && since < nowSec - 60; round++) {
        if (!await link.write(kHuamiActivityControlChar,
            huamiActivityFetchStart(local(since)))) {
          break;
        }
        final startFrame = await inbox.firstWhere(
            (f) =>
                f.$1 && f.$2.length >= 3 && f.$2[0] == 0x10 && f.$2[1] == 0x01,
            fetchTimeout);
        final start =
            startFrame == null ? null : parseHuamiFetchStart(startFrame.$2);
        if (start == null) {
          link.log('miband234: activity fetch refused or unanswered.');
          break;
        }
        if (start.count == 0) break;
        if (!await link.write(kHuamiActivityControlChar, kHuamiActivityFetchData)) {
          break;
        }
        // The header counts 4-byte minute samples, not bytes.
        final want = start.count * 4;
        final buf = HuamiActivityBuffer();
        var raw = <Uint8List>[];
        final previousKind = minutes.isEmpty ? 1 : minutes.last.kind;
        // How many of this round's minutes are already banked.
        var banked = 0;
        List<HuamiMinute> decoded() => buf
            .minutes(start.startSec, previousKind: previousKind)
            .take(start.count)
            .toList();
        // Ends with all the announced samples, or shortly after the band's
        // done notification: packets on the data characteristic can still be
        // in flight behind it.
        // ponytail: fixed grace after done; tune it if a real band's last
        // packets trail further.
        var done = false;
        while (buf.bytes.length < want) {
          final f = await inbox.firstWhere(
              (_) => true, done ? _kAfterDoneGrace : fetchTimeout);
          if (f == null) break;
          final (isControl, p) = f;
          if (isControl) {
            if (huamiFetchDone(p)) done = true;
            continue;
          }
          buf.add(p);
          raw.add(Uint8List.fromList([kMiBand234ArchiveActivity, ...p]));
          // A first sync answers one fetch with up to a week in one round:
          // bank it a day at a time, so a session the sync window (or a
          // drop) cuts mid-round still keeps, and resumes after, what came.
          if (buf.ok && buf.bytes.length ~/ 4 - banked >= _kBankEveryMinutes) {
            final got = decoded();
            minutes.addAll(got.skip(banked));
            for (final e in _bank(got.skip(banked), raw, minutes, sessionSince,
                nowSec)) {
              yield e;
            }
            banked = got.length;
            raw = [];
          }
        }
        if (!done) {
          await inbox.firstWhere(
              (f) => f.$1 && huamiFetchDone(f.$2), replyTimeout);
        }
        if (!buf.ok) {
          link.log('miband234: activity packets arrived out of order; this '
              'round is banked raw but not decoded.');
          yield SampleBatch(const [], raw: raw);
          break;
        }
        final got = decoded();
        if (got.isEmpty) break;
        if (got.length > banked) {
          minutes.addAll(got.skip(banked));
          for (final e
              in _bank(got.skip(banked), raw, minutes, sessionSince, nowSec)) {
            yield e;
          }
        } else if (raw.isNotEmpty) {
          yield SampleBatch(const [], raw: raw);
        }
        // The header's time plus the minutes received: count minutes when
        // the round arrived whole.
        since = got.last.tsSec + 60;
      }
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }
}

/// Bank [got] (new minutes, in order) as one committed step: their HR and
/// [raw] packets, the daily steps and closed nights over every minute this
/// session has read ([all], which ends with [got]), the resume cursor, then a
/// checkpoint. Steps and nights are re-banked whole each time (same rows,
/// same instants, so idempotent): banked only once the session ended, a cut
/// session would move the cursor past days whose steps and sleep never
/// landed. The link holds the cursor behind these vendor writes.
Iterable<BandEvent> _bank(Iterable<HuamiMinute> got, List<Uint8List> raw,
    List<HuamiMinute> all, int sessionSince, int nowSec) sync* {
  yield SampleBatch([
    for (final m in got)
      if (m.hr != null && m.hr! >= 25 && m.hr! <= 230 && m.tsSec <= nowSec)
        NeutralSample(anchor: TimeAnchor.measured, tsEpoch: m.tsSec, hr: m.hr),
  ], raw: raw);
  final epochs = <VendorEpoch>[];
  final (nights, openSec) = _nights(all, sessionSince, epochs);
  final rows = <Observation>[..._dailySteps(all, sessionSince), ...nights];
  if (epochs.isNotEmpty) yield VendorHypnogram(kMiBand234.id, epochs);
  if (rows.isNotEmpty) yield VendorScalars(rows);
  // From the start of the first day not read whole (the next one when the
  // last minute seen is 23:59), or of the day holding the awake minute before
  // a night still running: the next session reads both from their beginnings
  // and moves forward even when each session only gets through a day or two.
  DateTime day(int sec) {
    final t = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return DateTime(t.year, t.month, t.day);
  }
  var resume = day(all.last.tsSec + 60).millisecondsSinceEpoch ~/ 1000;
  if (openSec != null) {
    resume = math.min(resume, day(openSec - 60).millisecondsSinceEpoch ~/ 1000);
  }
  yield BandNote('miband_since', math.max(sessionSince, resume));
  yield OffloadCheckpoint(() async => true);
}

/// Minutes a history round banks at a time (one day).
const int _kBankEveryMinutes = 1440;

/// How long data packets may trail the band's done notification.
const Duration _kAfterDoneGrace = Duration(milliseconds: 500);

/// Daily step totals, only for days this session read from local midnight.
List<Observation> _dailySteps(List<HuamiMinute> minutes, int sessionSince) {
  final byDay = <DateTime, int>{};
  for (final m in minutes) {
    final t = DateTime.fromMillisecondsSinceEpoch(m.tsSec * 1000);
    final day = DateTime(t.year, t.month, t.day);
    if (day.millisecondsSinceEpoch ~/ 1000 < sessionSince) continue;
    byDay[day] = (byDay[day] ?? 0) + m.steps;
  }
  return [
    for (final MapEntry(:key, :value) in byDay.entries)
      if (value > 0)
        Observation(
          at: key,
          sourceKind: ObservationSource.vendor,
          key: 'steps',
          value: value,
          unit: 'steps',
          attribution: kMiBandAttribution,
        ),
  ];
}

/// The band's sleep blocks as hypnogram epochs plus per-night stage minutes.
/// A block is a run of sleep minutes; up to 15 non-sleep minutes inside one
/// count as wake. Only blocks this session read whole are used: from an awake
/// minute before their start (one already asleep at the session's first
/// minute began before it) to more than 15 awake minutes after their end.
/// A night still running at a sync is left for the next one, which re-reads
/// it from its start: its stage minutes are stamped at the block's end, so a
/// partial copy would sit beside the full one and both would count. Returns
/// the rows and the start of such a running night, if any.
(List<Observation>, int?) _nights(
    List<HuamiMinute> minutes, int sessionSince, List<VendorEpoch> epochs) {
  final rows = <Observation>[];
  int? openSec;
  var i = 0;
  while (i < minutes.length) {
    if (!minutes[i].asleep) {
      i++;
      continue;
    }
    var j = i, lastSleep = i;
    while (j + 1 < minutes.length &&
        (minutes[j + 1].asleep || j + 1 - lastSleep <= 15)) {
      j++;
      if (minutes[j].asleep) lastSleep = j;
    }
    final block = minutes.sublist(i, lastSleep + 1);
    final whole = i > 0 && j + 1 < minutes.length;
    if (i > 0 && j + 1 >= minutes.length) openSec = block.first.tsSec;
    i = lastSleep + 1;
    if (!whole || block.length < 30 || block.first.tsSec < sessionSince) {
      continue;
    }
    final perStage = <String, int>{};
    for (final m in block) {
      final stage = m.kind == kHuamiKindDeepSleep
          ? 'deep'
          : m.kind == kHuamiKindLightSleep
              ? 'light'
              : 'wake';
      perStage[stage] = (perStage[stage] ?? 0) + 1;
      if (epochs.isNotEmpty &&
          epochs.last.stage == stage &&
          epochs.last.endSec == m.tsSec) {
        epochs[epochs.length - 1] =
            VendorEpoch(epochs.last.startSec, m.tsSec + 60, stage);
      } else {
        epochs.add(VendorEpoch(m.tsSec, m.tsSec + 60, stage));
      }
    }
    final end = DateTime.fromMillisecondsSinceEpoch(
        (block.last.tsSec + 60) * 1000);
    for (final MapEntry(:key, :value) in perStage.entries) {
      rows.add(Observation(
        at: end,
        sourceKind: ObservationSource.vendor,
        vendorKey: 'sleep_${key}_min',
        value: value,
        unit: 'min',
        attribution: kMiBandAttribution,
      ));
    }
  }
  return (rows, openSec);
}

/// Notifications buffered so a reply landing before anyone is waiting is not
/// dropped: one inbox for the auth characteristic, one for the history
/// fetch's two characteristics.
class _Inbox<T> {
  final List<T> _buf = [];
  Completer<T?>? _waiter;
  bool _closed = false;

  void add(T f) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(f);
      return;
    }
    _buf.add(f);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  Future<T?> _next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<T?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame satisfying [test], discarding what comes before it.
  /// [timeout] bounds the whole search, not each frame.
  Future<T?> firstWhere(
    bool Function(T) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final rec = await _next(timeout - deadline.elapsed);
      if (rec == null) return null;
      if (test(rec)) return rec;
    }
    return null;
  }
}
