// Amazfit Helio Strap (Huami2021/ZeppOS protocol family) as a [BandAdapter]:
// authenticate over the chunked transport, then walk the plaintext
// activity-fetch channel for every record type the strap stores.
//
// THE WIRE lives in `protocol` (`huami2021_chunks.dart`, `huami2021_auth.dart`,
// `huami2021_fetch.dart`, `huami2021_records.dart`): a B-163 ECDH handshake on
// chars 0016/0017, then a plaintext "give me everything since T" exchange on
// chars 0004/0005, one record type at a time.
//
// THE AUTH KEY IS A PRECONDITION THIS ADAPTER DOES NOT BUILD. The strap's
// first pairing has to go through the real Zepp app and its cloud — nothing
// here attempts that. [authKeyReader] reads a key that already exists in
// secure storage; a session with no key yields [kHelioNoKeyNote] and ends.
// How the key GETS into storage (a typed/scanned key, same shape as this
// project's Oura and Mi Band flows) is a separate, unbuilt piece.
//
// THE STRAP COMPUTES EVERYTHING ITSELF. Unlike WHOOP, there is no raw
// beat-level or accelerometer stream anywhere in this protocol — every
// record is already a finished, device-computed result (its own stress
// score, its own HRV figure, its own sleep stages). Only `hr`, `steps` and
// `temperature_c` are measured quantities comparable to our own; everything
// else is shown attributed to the strap and never feeds a derivation or a
// baseline (ADDING_A_DEVICE.md's honesty contract).
//
// WHAT BECOMES WHAT:
//  * `hr` -> [NeutralSample.hr], signal `hrSparse` (the strap reports once a
//    minute, not continuously).
//  * `temperature_c` -> [NeutralSample.skinTempC] (already absolute Celsius,
//    not a raw ADC count — the protocol layer does that conversion).
//  * `hrv` (0x49) and `respiratory_rate` (0x38) readings -> also
//    [NeutralSample.deviceRmssdMs] / [NeutralSample.deviceRespBrpm] at their
//    own seconds: raw samples our readiness may take under policy exception
//    PE-1 (`kAdmittedDeviceSamples`), never the strap's own aggregate.
//  * `steps` -> a daily `steps` observation (comparable quantity, like
//    Colmi's).
//  * `stress`, `hrv_sdnn`, `pai`, `odi summary` -> daily VENDOR
//    observations, attributed and never fed back into our own analytics.
//  * `hrv`, `respiratory_rate`, `spo2`/`spo2_sleep` -> the strap's mean over
//    each night it staged, on the night's wake date ([nightMeans]); the
//    device slots they fill name the night's value, so a calendar-day mean
//    there would pass waking hours off as the night.
//  * Sleep sessions -> [VendorHypnogram] (the strap's own hypnogram, already
//    mapped to our stage words) plus per-night stage-minute vendor
//    observations and a `nap_min` row per nap — the same shape Colmi uses.
//  * Workout summaries -> vendor observations keyed to the workout's own
//    start time (sport type, duration, calories, HR range). NOTE: this does
//    NOT yet write into the `sessions` table the way a full workout-tracking
//    adapter would — that is a known, deliberate gap, not something this file
//    pretends to have solved.
//
// SCOPE OF THE FETCH ITSELF: one round per type, covering roughly the last
// two days, every session. The real protocol supports persistent per-type
// cursors, stale-feed recovery and DST-robust paging (protocol's
// `huami2021_fetch.dart` header) — none of that multi-session sophistication
// is built here yet. Building it against a protocol nobody has run on real
// hardware has no way to be validated, so it is deliberately deferred rather
// than built speculatively.
//
// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project has run this against
// a physical strap. Every reply is archived verbatim so a corrected decoder
// can be re-run over what was already banked.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;

import '../../compute/vendor_sleep.dart' show VendorEpoch;
import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Shown next to every value the strap computed itself.
const String kHelioStrapAttribution = 'Amazfit';

/// The [BandNote] a session carries when no auth key is in secure storage —
/// the session ends immediately, nothing else is attempted.
const String kHelioNoKeyNote = 'helio_no_key';

/// The [BandNote] a session carries when the handshake was rejected or
/// timed out, with a short machine-readable reason as its value.
const String kHelioAuthFailedNote = 'helio_auth_failed';

/// How far back one session's single fetch round reaches, for every type,
/// counted in whole local days: the fetch starts at the local midnight this
/// many days before today.
const Duration kHelioFetchWindow = Duration(days: 2);

/// The secure-storage key the adapter reads from and the pairing screen
/// writes to — shared so the two can never drift onto different items.
const String kHelioStrapSecureStorageKey = 'helio_strap_auth_key';

/// FIRST-UNLOCK, not the plugin's default WHEN-UNLOCKED — same choice as
/// `oura_link.dart`'s `_kApple`, for the identical reason: this app is
/// relaunched in the background while the phone is LOCKED (BGProcessingTask,
/// the BLE restore central waking on a link drop), exactly when a
/// `whenUnlocked` item cannot be read. A background sync that read nothing
/// would conclude the strap has no key at all. Exported so the pairing
/// function (`helio_strap_link.dart`) writes under the identical
/// accessibility level this reads under.
const IOSOptions kHelioStrapIosKeyOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
);
const MacOsOptions kHelioStrapMacosKeyOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock,
);

const FlutterSecureStorage _secure = FlutterSecureStorage();

/// Reads this device's 16-byte auth key, or null if none is stored yet, the
/// keychain is unavailable, or the stored value is malformed. Never throws —
/// a session with no readable key is `kHelioNoKeyNote`, the same as a
/// session with no key at all, not an uncaught crash.
Future<Uint8List?> _defaultAuthKeyReader() async {
  String? hex;
  try {
    hex = await _secure.read(
      key: kHelioStrapSecureStorageKey,
      iOptions: kHelioStrapIosKeyOptions,
      mOptions: kHelioStrapMacosKeyOptions,
    );
  } catch (_) {
    return null;
  }
  if (hex == null || hex.length != 32) return null;
  return Uint8List.fromList(
      [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

Uint8List _aesEcb(Uint8List key, Uint8List data, bool encrypt) {
  final c = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

Uint8List _aesEncrypt(Uint8List k, Uint8List d) => _aesEcb(k, d, true);
Uint8List _aesDecrypt(Uint8List k, Uint8List d) => _aesEcb(k, d, false);

/// The outcome of [runHelioHandshake]: either the strap authenticated, or it
/// didn't — with a short machine-readable reason either a session's
/// [BandNote] or a pairing screen's error sentence can be built from.
sealed class HelioHandshakeResult {
  const HelioHandshakeResult(this.rawFrames);

  /// Every raw chunk the strap sent during the handshake, win or lose —
  /// banked the same "capture everything, decide what to do with it later"
  /// way every fetch-channel frame already is, so a session that fails
  /// partway through authentication still leaves something to re-decode.
  final List<Uint8List> rawFrames;
}

class HelioHandshakeOk extends HelioHandshakeResult {
  const HelioHandshakeOk(this.event, List<Uint8List> rawFrames) : super(rawFrames);
  final Huami2021Authenticated event;
}

class HelioHandshakeFailed extends HelioHandshakeResult {
  const HelioHandshakeFailed(this.reason, List<Uint8List> rawFrames) : super(rawFrames);
  final String reason;
}

/// Runs the Huami2021 auth handshake over [link]'s chunked transport
/// (chars 0016/0017) with [authKey]. Shared by [HelioStrapAdapter.run] (a
/// full session) and the pairing screen (which only needs to prove the key
/// works, never touches the fetch channel) — kept in one place so the two
/// callers cannot silently drift apart on how the handshake is actually
/// driven.
Future<HelioHandshakeResult> runHelioHandshake(
  BandLink link,
  Uint8List authKey, {
  required Duration timeout,
}) async {
  final chunkInbox = _Inbox();
  final rawFrames = <Uint8List>[];
  final sub = link.notify(kHuami2021ChunkNotifyChar).listen(
      (r) => chunkInbox.add(Uint8List.fromList(r.$2)),
      onDone: chunkInbox.close,
      onError: (Object _) => chunkInbox.close());
  try {
    final encoder = Huami2021Encoder(encrypt: _aesEncrypt);
    final decoder = Huami2021Decoder(decrypt: _aesDecrypt);
    final auth = Huami2021Auth(authKey, aesEcb: _aesEncrypt);

    Future<bool> sendAuthPayload(List<int> body) async {
      for (final chunk in encoder.encode(kHuami2021AuthEndpoint, body)) {
        if (!await link.write(kHuami2021ChunkWriteChar, chunk)) return false;
      }
      return true;
    }

    if (!await sendAuthPayload(auth.start())) {
      return HelioHandshakeFailed('link_write_failed', rawFrames);
    }

    while (true) {
      final chunk = await chunkInbox.next(timeout);
      if (chunk == null) return HelioHandshakeFailed('timeout', rawFrames);
      rawFrames.add(chunk);
      final frame = decoder.feed(chunk, sessionKey: null);
      if (frame == null) continue;
      if (frame.needsAck) {
        // Per the chunked-transport spec: any reassembled frame flagged
        // needs-ack gets this written back on the same characteristic,
        // regardless of which endpoint it was for — the spec's own rule is
        // "a failed ack write is logged, not fatal", so a failure here
        // doesn't end the handshake; it's logged and the loop continues.
        final acked = await link.write(
            kHuami2021ChunkWriteChar, huami2021Ack(frame.handle, frame.count));
        if (!acked) link.log('helio_strap: chunk ack write failed.');
      }
      if (frame.endpoint != kHuami2021AuthEndpoint) continue;
      final event = auth.onPayload(frame.payload);
      if (event is Huami2021AuthSendProof) {
        if (!await sendAuthPayload(event.payload)) {
          return HelioHandshakeFailed('link_write_failed', rawFrames);
        }
        continue;
      }
      if (event is Huami2021Authenticated) {
        return HelioHandshakeOk(event, rawFrames);
      }
      if (event is Huami2021AuthFailed) {
        final failure = event.failure;
        return HelioHandshakeFailed(
            switch (failure) {
              WrongAuthKey() => 'wrong_key',
              AuthRejected(:final step, :final status) =>
                'rejected_step${step}_status$status',
              AuthMalformed(:final reason) => 'malformed_$reason',
            },
            rawFrames);
      }
      // Huami2021AuthIgnored: keep waiting.
    }
  } finally {
    await sub.cancel();
  }
}

class HelioStrapAdapter extends BandAdapter {
  /// Wall-clock now, in Unix seconds. Injected so a replay is deterministic.
  final int Function() nowSeconds;

  /// Reads the auth key from secure storage. Injected for testability.
  final Future<Uint8List?> Function() authKeyReader;

  /// How long to wait for the handshake's first reply before giving up.
  final Duration authTimeout;

  /// How long to wait for a fetch round's first reply, and between later
  /// packets of the same round.
  final Duration firstReplyTimeout;
  final Duration quietTimeout;

  HelioStrapAdapter({
    int Function()? nowSeconds,
    Future<Uint8List?> Function()? authKeyReader,
    this.authTimeout = const Duration(seconds: 8),
    this.firstReplyTimeout = const Duration(seconds: 10),
    this.quietTimeout = const Duration(milliseconds: 800),
  })  : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
        authKeyReader = authKeyReader ?? _defaultAuthKeyReader;

  @override
  BandEntry get entry => kHelioStrap;

  @override
  Map<InputSignal, Duration> get signals => kHelioStrapSignals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final key = await authKeyReader();
    if (key == null) {
      yield const BandNote(kHelioNoKeyNote);
      return;
    }

    final dataInbox = _Inbox();
    final subData = link.notify(kHuami2021FetchDataChar).listen(
        (r) => dataInbox.add(Uint8List.fromList(r.$2)),
        onDone: dataInbox.close,
        onError: (Object _) => dataInbox.close());
    final controlInbox = _Inbox();
    final subControl = link.notify(kHuami2021FetchControlChar).listen(
        (r) => controlInbox.add(Uint8List.fromList(r.$2)),
        onDone: controlInbox.close,
        onError: (Object _) => controlInbox.close());

    try {
      final handshake = await runHelioHandshake(link, key, timeout: authTimeout);
      if (handshake.rawFrames.isNotEmpty) {
        yield SampleBatch(const [], raw: handshake.rawFrames);
      }
      if (handshake is HelioHandshakeFailed) {
        yield BandNote(kHelioAuthFailedNote, handshake.reason);
        return;
      }

      // ── authenticated: the fetch channel itself is plaintext ──
      final now = DateTime.fromMillisecondsSinceEpoch(nowSeconds() * 1000);
      // From a local midnight, never mid-day: each day's step total and
      // daily means replace the stored ones (one row per day), so a day the
      // window cut into would overwrite the whole day an earlier sync read.
      final since = DateTime(
          now.year, now.month, now.day - kHelioFetchWindow.inDays);
      final utcOffsetMinutes = now.timeZoneOffset.inMinutes;

      Future<_FetchRound?> fetch(int type) => _fetchOneRound(
          link, controlInbox, dataInbox, type, since, utcOffsetMinutes,
          firstReplyTimeout: firstReplyTimeout, quietTimeout: quietTimeout);

      final raw = <Uint8List>[];
      final samples = <NeutralSample>[];
      final steps = <DateTime, int>{};
      final stress = <DateTime, List<num>>{};
      final hrvSdnn = <DateTime, List<num>>{};
      // The strap's own night readings, kept with their times: they are
      // averaged over the night it staged ([nightMeans]), never over a
      // calendar day, which would fold waking hours into a "night" figure.
      final night = <String, List<(int, num)>>{
        'hrv_avg': [],
        'respiration_avg': [],
        'spo2_avg': [],
      };
      DateTime dayOf(int ms) {
        final t = DateTime.fromMillisecondsSinceEpoch(ms);
        return DateTime(t.year, t.month, t.day);
      }

      final activity = await fetch(kHuami2021TypeActivity);
      if (activity != null) {
        raw.addAll(activity.raw);
        for (final s in parseHuami2021Activity(activity.bytes, activity.roundStartMs,
            expectedRecordCount: activity.expectedCount)) {
          if (s.metric == 'hr') {
            samples.add(NeutralSample(
                anchor: TimeAnchor.measured, tsEpoch: s.ms ~/ 1000, hr: s.value.round()));
          } else if (s.metric == 'steps') {
            final d = dayOf(s.ms);
            steps[d] = (steps[d] ?? 0) + s.value.round();
          }
        }
      }

      final temperature = await fetch(kHuami2021TypeTemperature);
      if (temperature != null) {
        raw.addAll(temperature.raw);
        for (final s in parseHuami2021Temperature(temperature.bytes, temperature.roundStartMs)) {
          samples.add(NeutralSample(
              anchor: TimeAnchor.measured, tsEpoch: s.ms ~/ 1000, skinTempC: s.value));
        }
      }

      final stressFetch = await fetch(kHuami2021TypeStress);
      if (stressFetch != null) {
        raw.addAll(stressFetch.raw);
        for (final s in parseHuami2021Stress(stressFetch.bytes, stressFetch.roundStartMs)) {
          (stress[dayOf(s.ms)] ??= []).add(s.value);
        }
      }

      final hrvFetch = await fetch(kHuami2021TypeHrv);
      if (hrvFetch != null) {
        raw.addAll(hrvFetch.raw);
        for (final s in parseHuami2021Hrv(hrvFetch.bytes)) {
          night['hrv_avg']!.add((s.ms, s.value));
          // The raw reading too, at its own second (PE-1): our readiness
          // takes the night's samples, not the strap's mean of them.
          samples.add(NeutralSample(
              anchor: TimeAnchor.measured,
              tsEpoch: s.ms ~/ 1000,
              deviceRmssdMs: s.value.toDouble()));
        }
      }

      final sdnnFetch = await fetch(kHuami2021TypeHrvSdnn);
      if (sdnnFetch != null) {
        raw.addAll(sdnnFetch.raw);
        for (final s in parseHuami2021HrvSdnn(sdnnFetch.bytes)) {
          (hrvSdnn[dayOf(s.ms)] ??= []).add(s.value);
        }
      }

      final respFetch = await fetch(kHuami2021TypeRespiratoryRate);
      if (respFetch != null) {
        raw.addAll(respFetch.raw);
        for (final s in parseHuami2021RespiratoryRate(respFetch.bytes)) {
          night['respiration_avg']!.add((s.ms, s.value));
          samples.add(NeutralSample(
              anchor: TimeAnchor.measured,
              tsEpoch: s.ms ~/ 1000,
              deviceRespBrpm: s.value.toDouble()));
        }
      }

      final spo2Fetch = await fetch(kHuami2021TypeSpo2Spot);
      if (spo2Fetch != null) {
        raw.addAll(spo2Fetch.raw);
        for (final s in parseHuami2021Spo2Spot(spo2Fetch.bytes)) {
          night['spo2_avg']!.add((s.ms, s.value));
        }
      }
      final spo2SleepFetch = await fetch(kHuami2021TypeSpo2Sleep);
      if (spo2SleepFetch != null) {
        raw.addAll(spo2SleepFetch.raw);
        for (final s in parseHuami2021Spo2Sleep(spo2SleepFetch.bytes)) {
          night['spo2_avg']!.add((s.ms, s.value));
        }
      }

      if (samples.isNotEmpty || raw.isNotEmpty) {
        yield SampleBatch(samples, raw: raw);
      }

      // Each section below is fetched, decoded and YIELDED on its own,
      // deliberately not batched into one list collected across the whole
      // session: a `yield` yields what the host already has, so a problem
      // decoding a LATER section (a firmware shape this decoder doesn't
      // expect, say) can never retroactively lose an EARLIER section's
      // already-emitted data. A workout-record crash used to wipe out
      // every scalar fetched before it, and stop sleep from being fetched
      // at all — this structure is what prevents that class of bug, not
      // just the one instance of it that's already been hardened.
      final earlyRows = <Observation>[
        for (final MapEntry(:key, :value) in steps.entries)
          _obs(key, value, unit: 'steps', key: 'steps'),
        for (final MapEntry(:key, :value) in stress.entries)
          _obs(key, _mean(value), vendorKey: 'stress_avg'),
        for (final MapEntry(:key, :value) in hrvSdnn.entries)
          _obs(key, _mean(value), unit: 'ms', vendorKey: 'hrv_sdnn_avg'),
      ];
      if (earlyRows.isNotEmpty) yield VendorScalars(earlyRows);

      // ── PAI ──
      final paiFetch = await fetch(kHuami2021TypePai);
      if (paiFetch != null) {
        final paiRows = <Observation>[];
        for (final p in parseHuami2021Pai(paiFetch.bytes)) {
          final d = dayOf(p.ms);
          paiRows.add(_obs(d, p.daily, vendorKey: 'pai_daily'));
          paiRows.add(_obs(d, p.total, vendorKey: 'pai_total'));
        }
        if (paiRows.isNotEmpty) yield VendorScalars(paiRows);
        if (paiFetch.raw.isNotEmpty) yield SampleBatch(const [], raw: paiFetch.raw);
      }

      // ── ODI (sleep-apnea) summary ──
      final odiFetch = await fetch(kHuami2021TypeOdiSummary);
      if (odiFetch != null) {
        final odiRows = <Observation>[];
        for (final o in parseHuami2021OdiSummary(odiFetch.bytes)) {
          final d = dayOf(o.belongTimeMs);
          odiRows.add(_obs(d, o.validTimeSec, unit: 's', vendorKey: 'odi_valid_time'));
          if (o.odiRefined != null) {
            odiRows.add(_obs(d, o.odiRefined!, vendorKey: 'odi_refined'));
          }
          if (o.score != null) {
            odiRows.add(_obs(d, o.score!, vendorKey: 'odi_score'));
          }
        }
        if (odiRows.isNotEmpty) yield VendorScalars(odiRows);
        if (odiFetch.raw.isNotEmpty) yield SampleBatch(const [], raw: odiFetch.raw);
      }

      // ── workouts: vendor-attributed summary fields, not yet a `sessions`
      // row (see the file header's known-gap note) ──
      final workoutFetch = await fetch(kHuami2021TypeWorkout);
      if (workoutFetch != null) {
        final workoutRows = <Observation>[];
        for (final w in parseHuami2021Workouts(workoutFetch.bytes)) {
          final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
          workoutRows.add(Observation(
            at: start,
            sourceKind: ObservationSource.vendor,
            vendorKey: 'workout_sport_type',
            value: w.sportType,
            attribution: kHelioStrapAttribution,
          ));
          workoutRows.add(Observation(
            at: start,
            sourceKind: ObservationSource.vendor,
            vendorKey: 'workout_duration_sec',
            value: w.durationSec,
            unit: 's',
            attribution: kHelioStrapAttribution,
          ));
          workoutRows.add(Observation(
            at: start,
            sourceKind: ObservationSource.vendor,
            vendorKey: 'workout_calories',
            value: w.calories,
            unit: 'kcal',
            attribution: kHelioStrapAttribution,
          ));
          workoutRows.add(Observation(
            at: start,
            sourceKind: ObservationSource.vendor,
            vendorKey: 'workout_avg_hr',
            value: w.avgHr,
            unit: 'bpm',
            attribution: kHelioStrapAttribution,
          ));
          workoutRows.add(Observation(
            at: start,
            sourceKind: ObservationSource.vendor,
            vendorKey: 'workout_max_hr',
            value: w.maxHr,
            unit: 'bpm',
            attribution: kHelioStrapAttribution,
          ));
          workoutRows.add(Observation(
            at: start,
            sourceKind: ObservationSource.vendor,
            vendorKey: 'workout_min_hr',
            value: w.minHr,
            unit: 'bpm',
            attribution: kHelioStrapAttribution,
          ));
        }
        if (workoutRows.isNotEmpty) yield VendorScalars(workoutRows);
        if (workoutFetch.raw.isNotEmpty) {
          yield SampleBatch(const [], raw: workoutFetch.raw);
        }
      }

      // ── sleep: the strap's own hypnogram ──
      final sleepFetch = await fetch(kHuami2021TypeSleep);
      if (sleepFetch != null) {
        final epochs = <VendorEpoch>[];
        final stageRows = <Observation>[];
        // Only sessions the window holds whole: one begun before `since`
        // is read from `since` on, and its stage minutes and night means
        // would replace the whole night an earlier sync stored.
        final sessions = wholeSessions(parseHuami2021Sleep(sleepFetch.bytes),
            since.millisecondsSinceEpoch);
        for (final session in sessions) {
          _emitSleepSession(session, epochs, stageRows);
        }
        stageRows.addAll(nightMeans(sessions, night));
        if (epochs.isNotEmpty) {
          yield VendorHypnogram('helio_strap', epochs, wholeNights: true);
        }
        if (stageRows.isNotEmpty) yield VendorScalars(stageRows);
        if (sleepFetch.raw.isNotEmpty) {
          yield SampleBatch(const [], raw: sleepFetch.raw);
        }
      }
    } finally {
      await subData.cancel();
      await subControl.cancel();
    }
  }

  static void _emitSleepSession(
    Huami2021SleepSession session,
    List<VendorEpoch> epochs,
    List<Observation> rows,
  ) {
    if (session.isNap) {
      final asleep = session.stages
          .where((s) => s.type != kHuami2021StageAwake)
          .fold(0, (sum, s) => sum + ((s.endMs - s.startMs) ~/ 60000));
      if (asleep > 0) {
        rows.add(Observation(
          at: DateTime.fromMillisecondsSinceEpoch(session.sessionStartMs),
          sourceKind: ObservationSource.vendor,
          vendorKey: 'nap_min',
          value: asleep,
          unit: 'min',
          attribution: kHelioStrapAttribution,
        ));
      }
      return;
    }
    // The night's wake date: a night begun at 23:00 is the next day's.
    final dayStamp =
        _wakeDate(_nightSpan(session)?.$2 ?? session.sessionStartMs);
    for (final stage in session.stages) {
      final name = _stageName(stage.type);
      if (name != null && stage.endMs > stage.startMs) {
        epochs.add(VendorEpoch(stage.startMs ~/ 1000, stage.endMs ~/ 1000, name));
      }
    }
    for (final entry in <String, int>{
      'rem': session.remMin,
      'light': session.lightMin,
      'deep': session.deepMin,
      'wake': session.wakeMin,
    }.entries) {
      rows.add(Observation(
        at: dayStamp,
        sourceKind: ObservationSource.vendor,
        vendorKey: 'sleep_${entry.key}_min',
        value: entry.value,
        unit: 'min',
        attribution: kHelioStrapAttribution,
      ));
    }
  }

  /// [sessions] that start at or after [sinceMs] (first stage, else the
  /// session start): the ones a fetch from [sinceMs] holds whole.
  @visibleForTesting
  static List<Huami2021SleepSession> wholeSessions(
          List<Huami2021SleepSession> sessions, int sinceMs) =>
      [
        for (final s in sessions)
          if ((_nightSpan(s)?.$1 ?? s.sessionStartMs) >= sinceMs) s,
      ];

  /// The strap's own mean of each reading in [samples] (vendor key ->
  /// (epoch ms, value)) over each night it staged, stamped on the night's
  /// wake date, the day our day model files that night under. A reading
  /// outside every staged night is dropped, and a night with none gets no
  /// row: absent, never a calendar-day mean standing in for the night's.
  @visibleForTesting
  static List<Observation> nightMeans(
    List<Huami2021SleepSession> sessions,
    Map<String, List<(int, num)>> samples,
  ) {
    final rows = <Observation>[];
    for (final session in sessions) {
      if (session.isNap) continue;
      final span = _nightSpan(session);
      if (span == null) continue;
      final (start, end) = span;
      for (final MapEntry(:key, :value) in samples.entries) {
        final inNight = [
          for (final (ms, v) in value)
            if (ms >= start && ms < end) v,
        ];
        if (inNight.isEmpty) continue;
        rows.add(_obs(_wakeDate(end), _mean(inNight),
            unit: _nightUnit[key], vendorKey: key));
      }
    }
    return rows;
  }

  static const Map<String, String> _nightUnit = {
    'hrv_avg': 'ms',
    'respiration_avg': 'breaths/min',
    'spo2_avg': '%',
  };

  /// First stage start to last stage end, epoch ms; null with no stages.
  static (int, int)? _nightSpan(Huami2021SleepSession session) {
    if (session.stages.isEmpty) return null;
    var start = session.stages.first.startMs, end = session.stages.first.endMs;
    for (final st in session.stages) {
      if (st.startMs < start) start = st.startMs;
      if (st.endMs > end) end = st.endMs;
    }
    return end > start ? (start, end) : null;
  }

  static DateTime _wakeDate(int endMs) {
    final t = DateTime.fromMillisecondsSinceEpoch(endMs);
    return DateTime(t.year, t.month, t.day);
  }

  static String? _stageName(int type) => switch (type) {
        kHuami2021StageAwake => 'wake',
        kHuami2021StageLight => 'light',
        kHuami2021StageDeep => 'deep',
        kHuami2021StageRem => 'rem',
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
        attribution: kHelioStrapAttribution,
      );
}

/// One completed fetch round's accumulated bytes, raw frames (for
/// `raw_archive`), and the round's own `roundStart` (for the record types
/// that need it — activity, stress, temperature).
class _FetchRound {
  const _FetchRound(this.bytes, this.raw, this.roundStart, this.expectedCount);
  final Uint8List bytes;
  final List<Uint8List> raw;
  final DateTime roundStart;
  /// The start reply's own announced record/byte count — for type 0x01,
  /// passed to [parseHuami2021Activity] so it never has to guess at the
  /// 4-byte-vs-8-byte record size (see that function's own doc for why the
  /// guess is unsafe).
  final int expectedCount;
  int get roundStartMs => roundStart.millisecondsSinceEpoch;
}

/// One start -> send -> data -> end -> ack round for [type], with up to 2
/// retries on a counter gap or a byte-count mismatch (per the spec's
/// documented retry policy). Returns null on "nothing to send", a refused
/// start, or exhausted retries.
Future<_FetchRound?> _fetchOneRound(
  BandLink link,
  _Inbox controlInbox,
  _Inbox dataInbox,
  int type,
  DateTime since,
  int utcOffsetMinutes, {
  required Duration firstReplyTimeout,
  required Duration quietTimeout,
}) async {
  for (var attempt = 0; attempt <= 2; attempt++) {
    // A frame that arrived late for an EARLIER round (a previous type, or
    // a previous attempt at this same type) must never be read as part of
    // THIS round — drain both channels before this round's first write.
    controlInbox.drain();
    dataInbox.drain();
    if (!await link.write(kHuami2021FetchControlChar,
        huami2021FetchStartRequest(type, since, utcOffsetMinutes))) {
      return null;
    }
    final startFrame = await controlInbox.next(firstReplyTimeout);
    if (startFrame == null) return null;
    final start = parseHuami2021FetchStart(startFrame);
    if (start == null || !start.ok) return null;
    if (!start.hasData) {
      await link.write(kHuami2021FetchControlChar, kHuami2021FetchAckKeep);
      return null;
    }

    if (!await link.write(kHuami2021FetchControlChar, kHuami2021FetchSendData)) {
      return null;
    }

    final buffer = Huami2021FetchBuffer();
    final rawFrames = <Uint8List>[];
    var timeout = firstReplyTimeout;
    while (true) {
      final packet = await dataInbox.next(timeout);
      if (packet == null) break; // quiet: assume the round-end reply follows
      rawFrames.add(packet);
      buffer.add(packet);
      timeout = quietTimeout;
      if (!buffer.ok) break;
    }

    final endFrame = await controlInbox.next(firstReplyTimeout);
    final endStatus = endFrame == null ? null : parseHuami2021FetchRoundEnd(endFrame);

    final countOk = buffer.ok &&
        endStatus != null &&
        huami2021FetchCountMatches(type, start.expected, buffer.bytes.length);
    if (!countOk) {
      // ack(keep), discard, retry same cursor.
      await link.write(kHuami2021FetchControlChar, kHuami2021FetchAckKeep);
      continue;
    }

    await link.write(kHuami2021FetchControlChar, kHuami2021FetchAckKeep);
    return _FetchRound(buffer.bytes, rawFrames, start.roundStart, start.expected);
  }
  return null;
}

/// The signals this strap supplies. Mirrored in `kAdapterSignals`.
const Map<InputSignal, Duration> kHelioStrapSignals = {
  InputSignal.hrSparse: Duration(minutes: 1),
  InputSignal.steps: Duration(minutes: 1),
  InputSignal.skinTempC: Duration(minutes: 1),
  InputSignal.deviceStress: Duration(minutes: 1),
  InputSignal.deviceHrv: Duration(minutes: 2),
  InputSignal.deviceResp: Duration(minutes: 30),
  InputSignal.deviceSpo2: Duration(minutes: 5),
  InputSignal.deviceStages: Duration.zero,
  InputSignal.vendorScalars: Duration.zero,
};

/// The single instance. Holds no per-strap state.
final HelioStrapAdapter kHelioStrapAdapter = HelioStrapAdapter();

/// Notifications buffered so a reply landing before anyone waits is kept.
/// Identical shape to Colmi's `_Inbox` — duplicated rather than shared,
/// since promoting it to a shared utility is a separate decision this file
/// should not make unilaterally.
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

  /// Discards anything currently buffered. Called before every fetch round
  /// starts (a fresh type, or a retry of the same one): without this, a
  /// frame that arrived late for the PREVIOUS round — after this function
  /// had already given up waiting for it — sits here and gets consumed by
  /// the NEXT round's own first read instead, misreading a stale end-of-
  /// round reply as the new round's start reply, or a trailing data packet
  /// as something else entirely.
  void drain() => _buf.clear();

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
