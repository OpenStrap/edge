// The Oura ring as a [BandAdapter]: authenticate, drain its history by cursor,
// bank every byte, decode only what has been proven.
//
// NOTHING HERE HAS MET HARDWARE, and unlike `ble_hrs` there is not even a
// public specification to fall back on. It ships EXPERIMENTAL (ASSUMPTIONS R6),
// its rows carry a non-null `source` and `kDerivableSources` does not contain
// it, so nothing it writes can become a number until the owner has held a ring
// in his own hands. That is correct behaviour for an uncalibrated decoder, not
// a limitation to work around.
//
// WHY THIS IS THE OPPOSITE SHAPE TO gen4, and why the seam fits it. gen4's
// offload is TRIM-ON-ACK: the band deletes flash when the host says so, the
// handshake has three wire outcomes, and the decision to trim depends on
// whether the HOST's durable commit landed (ASSUMPTIONS G1-G4 — which is why
// gen4 is not behind this seam). Oura's is FETCH-BY-CURSOR: the ring never
// deletes anything on our say-so, there is no acknowledgement in the protocol
// at all, and the host's only state is a bookmark. Re-reading a range is
// idempotent — 48.5% of our own capture is the same records delivered
// twice, and `decoded_onehz` is keyed `(device_id, ts_ms)` with REPLACE, so a
// re-read overwrites rather than duplicates.
//
// That is exactly the "fetch-by-range: `confirm()` advances the adapter's own
// cursor" row in [OffloadCheckpoint]'s own table, and this file is the first
// implementation of it. The ordering still holds and still means something: the
// cursor does not move until the host has committed, so an interrupted sync
// re-reads rather than skips.
//
// PAIRING EVICTS THE OURA APP, AND IT IS A PRECONDITION RATHER THAN A SIDE
// EFFECT. The ring holds exactly one 16-byte key and will only accept a new one
// while it is FACTORY RESET — so a ring that is currently onboarded to Oura's
// app cannot be paired here at all until the owner factory-resets it, which is
// what removes it from that app. There is no state in which both work. Any
// pairing UI must say that before the user commits, not after.
//
// THE KEY IS OURS AND IT NEVER LEAVES THE PHONE. It is generated locally, there
// is no vendor server anywhere in the handshake and no Oura account is needed —
// which is the whole reason this band is not declined the way a vendor-issued
// pairing token would be. Losing it costs another factory reset, nothing more.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;

import '../../data/observation.dart'
    show Observation, ObservationSource;
import '../../compute/vendor_sleep.dart' show VendorEpoch;
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Encrypt one authentication challenge.
///
/// The ring issues a 15-byte nonce; PKCS#7 pads it to exactly one 16-byte block
/// (a single 0x01), and the answer is that block under AES-128 in ECB mode with
/// the pairing key. One block, so ECB's usual objection — that identical
/// plaintext blocks repeat — has nothing to bite on, and the ring picks a fresh
/// nonce per connection.
///
/// Exposed rather than private so the test can pin it against a known vector
/// without a radio.
Uint8List ouraAuthResponse(List<int> key, List<int> nonce) {
  if (key.length != 16 || nonce.length != 15) {
    throw ArgumentError('Oura auth takes a 16-byte key and a 15-byte nonce');
  }
  final block = Uint8List(16)
    ..setRange(0, 15, nonce)
    ..[15] = 0x01;
  final out = Uint8List(16);
  ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)))
    ..processBlock(block, 0, out, 0);
  return out;
}

/// One Oura session.
///
/// NOT const and not a registry singleton, because it needs three things a
/// const adapter cannot hold: the pairing key, the cursor to resume from, and
/// the time origin to stamp against. All three belong to the HOST — the key is
/// a secret it stores, the other two are bookmarks it persists — and handing
/// them in at construction is what lets the seam stay a one-way
/// `Stream<BandEvent>` instead of growing an inbound command channel. Each one
/// comes back out as a [BandNote] when it moves, so the host never has to
/// re-derive a second copy of something this file already knows.
class OuraAdapter extends BandAdapter {
  /// The 16-byte pairing key this phone generated and wrote to this ring.
  final List<int> key;

  /// Where to resume the history drain, on the ring's decisecond clock. 0 asks
  /// for everything the ring still holds.
  final int startCursorDs;

  /// The `(ring decisecond, Unix second)` pair a previous session measured, if
  /// the host kept one.
  ///
  /// THIS IS WHAT MAKES A TIMESTAMP REPRODUCIBLE ACROSS CONNECTS. The ring
  /// stamps on a decisecond counter with no documented epoch and there is no
  /// command anywhere in the protocol that reads its clock back — a measured
  /// `time_sync` event is the ONLY bridge between the two, and it lands wherever
  /// the ring happened to record one. Handing the last known pair in means a
  /// given decisecond maps to the same second on every later session, so a
  /// re-read overwrites its own row instead of writing a second copy of the
  /// same physiological second under a key REPLACE can never collapse.
  final (int ds, int unix)? anchor;

  /// Wall-clock now, in Unix seconds. Injected so a fixture replay is
  /// deterministic — `DateTime.now()` does not appear in this file.
  final int Function() nowSeconds;

  /// How long to wait for a reply the ring owes us.
  final Duration replyTimeout;

  /// How long to wait for the host to commit a batch and call `confirm`.
  /// Expiring is SAFE: the cursor does not move, so the batch is re-read.
  /// Overridable only so a test does not have to sit through it.
  final Duration confirmTimeout;

  OuraAdapter({
    required this.key,
    this.startCursorDs = 0,
    this.anchor,
    int Function()? nowSeconds,
    this.replyTimeout = const Duration(seconds: 5),
    this.confirmTimeout = const Duration(seconds: 30),
  })  : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
        _anchor = anchor;

  @override
  BandEntry get entry => kOura;

  /// NOTHING, and that is the honest answer today rather than a placeholder.
  ///
  /// The ring emits beat-to-beat intervals and SpO2, and this adapter
  /// decodes neither: their layouts are bit-packed and there is not one
  /// captured byte of either to check a decoder against. A declared-but-absent
  /// signal is WORSE than a missing one (see [BandAdapter.signals]) — it turns
  /// a card that should delete itself into one that is permanently empty — so
  /// nothing is claimed until a decoder exists and a real capture has met it.
  ///
  /// Temperature is emitted below and still not declared here, deliberately:
  /// [InputSignal.skinTempRaw] means RELATIVE ADC COUNTS (I8), and this ring
  /// reports absolute degrees Celsius. They are not the same input and the
  /// per-family calibration that I8 exists to key does not apply. There is no
  /// member for absolute temperature and one should not be invented for a band
  /// nobody owns.
  ///
  /// The hypnogram's stage minutes are emitted too, and [InputSignal.vendorScalars]
  /// stays undeclared until a real ring has been checked against the decoder.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// How many events one history request may return. The wire field is a u8,
  /// so this is its ceiling, and it is also what tells a full batch from a
  /// short one when the cursor is advanced.
  static const int _kMaxEventsPerBatch = 255;

  /// The (ring decisecond, Unix second) pair this session is stamping against.
  ///
  /// Seeded from [anchor] and thereafter only IMPROVED — by a `time_sync`
  /// event, the one record that carries both clocks. Never re-derived per
  /// batch: a re-anchored batch would write the same physiological second under
  /// a different `ts_ms` and duplicate rows that REPLACE cannot collapse.
  ///
  /// THERE IS NO FALLBACK, and that is the whole point. Seeding this from the
  /// ARRIVAL of the first batch — the obvious-looking guess — produces an origin
  /// that moves by the BLE delivery jitter on every connect, which is exactly
  /// the duplication above with a plausible-looking number on it. When there is
  /// no anchor there is no timestamp, and a sample without one is not emitted.
  (int ds, int unix)? _anchor;

  /// Readings decoded before an origin existed, as `(ds, °C)`.
  ///
  /// Every connect sets the ring's clock, so the ring records a fresh
  /// `time_sync` — but it records it at its CURRENT decisecond, which is the
  /// END of the drain. On a first pairing that is after the whole of its
  /// history, so abstaining on the spot would throw all of it away. Held
  /// instead, and stamped by the batch that finally carries an origin. If none
  /// ever does, they are dropped: the frames are still handed over verbatim in
  /// every [SampleBatch], so nothing is lost that was not already banked.
  final List<(int ds, double tempC)> _held = [];

  /// Hypnogram events waiting for an origin, keyed by the event that carried
  /// them. Same lifecycle as [_held]. Keyed so a re-read decisecond overwrites
  /// its own entry instead of counting the same event twice.
  final Map<(int ds, int tag, int header), List<OuraSleepPhase>> _heldStages =
      {};

  /// The Unix second [ds] falls on, or null when no origin is known.
  int? _anchorUnixFor(int ds) {
    final a = _anchor;
    if (a == null) return null;
    // 10 deciseconds to the second. The subtraction is on the ring's own clock,
    // so the SPACING between records is exact however wrong the origin is.
    return a.$2 + (ds - a.$1) ~/ 10;
  }

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final sub = link.notify(kOuraNotifyChar).listen(
          (rec) {
            // ONE notification carries exactly ONE frame (`parseOuraFrame`'s
            // contract). The ring may append bytes past the declared length;
            // the parser ignores them, and so does this callback: they are
            // never read as a second frame. A notification that cannot be a
            // frame (too short, or a length running past the end) is dropped,
            // not decoded, so no samples are invented.
            //
            // The archived raw bytes are the WHOLE notification as the radio
            // delivered it, trailing bytes included, so a future decoder can
            // still see them (see the archive comment in the batch reader).
            final f = parseOuraFrame(rec.$2);
            if (f != null) inbox.add(rec.$1, f, Uint8List.fromList(rec.$2));
          },
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      final auth = await _authenticate(link, inbox);
      if (auth != _AuthOutcome.ok) {
        if (auth == _AuthOutcome.refused) {
          // The user-facing category: the ring rejected the key. Deliberately
          // NOT emitted for silence — a ring that never answered is a
          // transport/timeout case, and telling that user to re-pair would be
          // exactly the wrong remedy.
          yield const BandNote('oura_auth_refused');
        }
        return;
      }

      // Both writes are documented preconditions of a history drain rather than
      // housekeeping. The clock set is also what makes a later `time_sync`
      // event exist at all, and that event is the only anchor between the
      // ring's decisecond counter and a date. A silent write failure here does
      // not fail loud on its own: a refused notify-flag write leaves every
      // later batch waiting out a full `replyTimeout` for frames that will
      // never arrive, and a refused time-sync write leaves the session with no
      // measured origin — there is no arrival-time fallback here (that is
      // `TimeAnchor.arrival` on the *held* reading once SOME anchor exists,
      // never a substitute for having none), so every reading this session
      // sees is held in `_held` and stamped only if a stored anchor from an
      // earlier session covers it.
      if (!await link.write(kOuraCommandChar, ouraCmdSetNotifyFlags(0x3f))) {
        link.log('oura: notify-flag write refused; ending the drain.');
        // The user-facing category: the link took the write refusal. A
        // subscription/setup failure is not "could not reach the ring" and
        // not a key problem — the ring was reachable and answered nothing.
        yield const BandNote('oura_write_refused');
        return;
      }
      if (!await link.write(kOuraCommandChar, ouraCmdSyncTime(nowSeconds()))) {
        link.log('oura: time-sync write refused; no new origin this session. '
            'Readings are stamped only if a stored anchor covers them.');
      }

      var cursor = startCursorDs;
      // A misbehaving ring that answers every request with the same batch would
      // otherwise spin here forever on a live radio.
      for (var batch = 0; batch < 5000; batch++) {
        // Passed explicitly rather than left to the builder's default: the
        // cursor advance below compares the batch's own count against this
        // number, and two copies of it that could drift is a silent skip.
        final req = ouraCmdGetEvents(cursor, maxEvents: _kMaxEventsPerBatch);
        if (!await link.write(kOuraCommandChar, req)) {
          link.log('oura: history request refused; ending the drain.');
          yield const BandNote('oura_write_refused');
          return;
        }
        final got = await _collectBatch(inbox);
        if (got == null) {
          // No summary = the batch never ended. Leave the cursor put; the
          // next sync re-reads from the last confirmed boundary.
          link.log('oura: no batch summary within the reply window.');
          // The user-facing category: a protocol timeout / incomplete
          // answer — the ring was connected and authenticated, the batch
          // just never ended within the reply window.
          yield const BandNote('oura_no_batch_summary');
          return;
        }
        if (got.events.isEmpty) {
          // A CURSOR THE RING CANNOT ANSWER, told apart from an empty ring.
          //
          // The decisecond counter is an UPTIME, so a ring that reboots
          // restarts it near zero — and a bookmark from before the reboot is
          // then far AHEAD of everything it holds. Every request from there
          // matches nothing, forever, and the sync looks exactly like "no new
          // data" while the ring quietly fills up. `bytesLeft` is what
          // separates them: data remaining and none delivered is not an empty
          // ring, it is a bookmark pointing past the end. The host's remedy is
          // to drop the bookmark and re-read from zero, which is free — a
          // re-read of this band is idempotent by design.
          if (got.summary.bytesLeft > 0) {
            link.log('oura: the ring reports ${got.summary.bytesLeft} bytes '
                'left but answered this cursor with nothing.');
            yield const BandNote('oura_cursor_stranded');
            return;
          }
          // An empty, up-to-date ring: the drain reached its honest end.
          yield const BandNote('oura_drain_ok');
          return;
        }

        // A cursor past the newest event is answered with the last few
        // events again, not an empty batch. Drop anything below the cursor;
        // advancing on a replay would move the bookmark backwards.
        // `_collectBatch` fills events and raw in lockstep.
        final keep = [
          for (var i = 0; i < got.events.length; i++)
            if (got.events[i].tsDs >= cursor) i,
        ];
        if (keep.isEmpty) {
          link.log('oura: the ring replayed ${got.events.length} event(s) '
              'below the cursor; nothing new after $cursor.');
          // Stranded (counter restarted below the bookmark) when bytes are
          // still left, or when the ring's newest event is older than the
          // last one we read (cursor - 1): an up-to-date ring replays up to
          // exactly that one, a rebooted ring's tail stops short of it.
          if (got.summary.bytesLeft > 0 || got.maxDs + 1 < cursor) {
            yield const BandNote('oura_cursor_stranded');
            return;
          }
          // Everything below the cursor was a replay of what is already
          // banked and the ring reports nothing left (bytesLeft > 0 was
          // the stranded branch above): the drain is at the ring's end,
          // up to date.
          yield const BandNote('oura_drain_ok');
          return;
        }
        final fresh = [for (final i in keep) got.events[i]];
        final freshRaw = [for (final i in keep) got.raw[i]];
        got.raw
          ..clear()
          ..addAll(freshRaw);
        got.events.clear();
        got.events.addAll(fresh);

        for (final e in got.events) {
          final unix = decodeTimeSync(e);
          if (unix == null) continue;
          // A better origin for this record and every one after it, and for
          // everything still held. Applied BEFORE the batch is stamped so the
          // batch carrying the sync is itself correct.
          _anchor = (e.tsDs, unix);
          // Surfaced so the host can persist it without re-deriving one of its
          // own. Two implementations of an origin is two origins.
          yield BandNote('oura_anchor', '${e.tsDs},$unix');
        }

        // A full batch may have been cut inside its last decisecond, which the
        // next batch re-reads (see the cursor advance below). Decoding it here
        // too would stamp a partial sum now and the full one after a re-anchor,
        // on two different `ts_ms` that REPLACE cannot collapse. It is left to
        // the re-read, which sees all of it. With no bytes left nothing was
        // cut and no re-read comes, so the last decisecond is decoded here.
        final full = got.summary.received >= _kMaxEventsPerBatch &&
            got.summary.bytesLeft > 0;
        final reread = (full && got.maxDs > cursor) ? got.maxDs : null;
        yield* _emit(link, got, skipDs: reread);

        // THE ORDERING IS THE POINT. The host commits durably, then calls
        // confirm, and only then does the cursor move. Nothing is deleted
        // either way — the ring has no trim — so a host that never confirms
        // costs a re-read, never a record.
        final done = Completer<bool>();
        yield OffloadCheckpoint(
          () async {
            if (!done.isCompleted) done.complete(true);
            return true;
          },
          remaining: got.summary.bytesLeft,
        );
        final confirmed = await done.future
            .timeout(confirmTimeout, onTimeout: () => false);
        if (!confirmed) {
          link.log('oura: batch was not confirmed; leaving the cursor put.');
          // The checkpoint was not confirmed within the allowed wait. This
          // note alone does not identify the persistence outcome; a commit
          // failure the host actually observed is reported separately via
          // `host_commit_failed` and keeps priority in `OuraLink`.
          yield const BandNote('oura_batch_unconfirmed');
          return;
        }
        // A FULL BATCH RE-READS ITS LAST DECISECOND; A SHORT ONE MOVES PAST IT.
        //
        // The cursor is a TIMESTAMP, not a record index, and the batch cap is a
        // record count — so a batch that came back full may have been cut in
        // the middle of a decisecond that holds more records than fitted.
        // Jumping to `maxDs + 1` there silently drops the remainder, and
        // nothing downstream can tell: the gap is in the ring's flash, not in
        // ours. Re-reading `maxDs` instead costs one re-read decisecond, which
        // is decoded only by the batch that re-reads it.
        //
        // The `> cursor` guard is the escape: a ring with a whole batch inside
        // one decisecond would otherwise re-ask for the same thing forever, and
        // a bounded loss beats an unbounded stall.
        cursor = reread ?? got.maxDs + 1;
        yield BandNote('oura_cursor_ds', cursor);
        if (got.summary.bytesLeft <= 0) {
          yield const BandNote('oura_drain_ok');
          return;
        }
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Nonce, encrypt, answer. [ok] is the only way a session may carry on —
  /// a session that continues unauthenticated gets `auth required` to every
  /// command and looks identical to a dead link. [refused] is the ring's
  /// OWN explicit rejection, kept apart from [silent]: a refused key and a
  /// ring that never answered have different remedies, and the host's
  /// user-facing category hangs off exactly that difference.
  Future<_AuthOutcome> _authenticate(BandLink link, _Inbox inbox) async {
    if (!await link.write(kOuraCommandChar, ouraCmdAuthNonce())) {
      return _AuthOutcome.silent;
    }
    final challenge =
        await inbox.firstWhere((f) => ouraAuthNonce(f) != null, replyTimeout);
    if (challenge == null) {
      link.log('oura: no authentication challenge.');
      return _AuthOutcome.silent;
    }
    final answer = ouraAuthResponse(key, ouraAuthNonce(challenge)!);
    if (!await link.write(kOuraCommandChar, ouraCmdAuthenticate(answer))) {
      return _AuthOutcome.silent;
    }
    final reply =
        await inbox.firstWhere((f) => ouraAuthResult(f) != null, replyTimeout);
    if (reply == null) {
      // No verdict inside the reply window is silence, not a refusal: the
      // re-pair remedy that `refused` drives would be the wrong one.
      link.log('oura: no authentication result.');
      return _AuthOutcome.silent;
    }
    final result = ouraAuthResult(reply);
    if (result != 0) {
      // Worth naming, because the remedies differ: a wrong key needs re-pairing
      // and a ring in factory reset needs its key installed first.
      link.log('oura: authentication refused (result $result).');
      return _AuthOutcome.refused;
    }
    return _AuthOutcome.ok;
  }

  /// Read frames until the batch summary arrives.
  Future<_Batch?> _collectBatch(_Inbox inbox) async {
    final events = <OuraEvent>[];
    final raw = <Uint8List>[];
    var maxDs = 0;
    // A misbehaving ring that keeps streaming non-summary frames would
    // otherwise spin here forever — each frame resets `replyTimeout`'s
    // window, so the timeout alone never bounds this loop. Same shape as the
    // outer `batch < 5000` guard in `run`.
    for (var frame = 0; frame < 5000; frame++) {
      final rec = await inbox.next(replyTimeout);
      if (rec == null) return null;
      final (_, f, rawBytes) = rec;
      final summary = parseBatchSummary(f);
      if (summary != null) return _Batch(events, raw, maxDs, summary);
      if (ouraIsAuthRequired(f)) return null;
      final e = parseOuraEvent(f);
      if (e == null) continue;
      events.add(e);
      // The bytes AS THE RADIO DELIVERED THEM, not `[f.tag, f.payload.length,
      // ...f.payload]` reconstructed from the parsed frame: `parseOuraFrame`
      // truncates to the declared length and the ring is known to append
      // bytes past it (see its doc). Re-encoding here would bank this file's
      // idea of the frame instead of what a future decoder for the
      // still-undecoded event types actually needs, and the trailing bytes are
      // unrecoverable once dropped — `raw_archive` keeps what it is given but
      // it cannot un-truncate what was never written.
      raw.add(rawBytes);
      if (e.tsDs > maxDs) maxDs = e.tsDs;
    }
    return null;
  }

  /// Turn one collected batch into events for the host. Events at [skipDs]
  /// are archived but not decoded: the next batch re-reads that decisecond.
  Stream<BandEvent> _emit(BandLink link, _Batch got, {int? skipDs}) async* {
    final samples = <NeutralSample>[];
    for (final e in got.events) {
      if (e.tsDs == skipDs) continue;
      switch (e.tag) {
        case kOuraEvtTemp:
        case kOuraEvtTempPeriod:
          final t = decodeTemperatures(e);
          // The array's probes are not identified — one may be an ambient
          // reference — so the first is taken and the rest are left in the
          // archive rather than averaged into a number that means nothing.
          if (t != null && t.isNotEmpty) _held.add((e.tsDs, t.first));
        case kOuraEvtDebugData:
          final d = decodeDebugData(e.body);
          if (d == null) break;
          if (d.text != null) link.log('oura fw: ${d.text}');
          if (d.batteryPct != null) yield BandNote('battery', d.batteryPct);
          if (d.batteryMv != null) yield BandNote('battery_mv', d.batteryMv);
        case kOuraEvtSleepPhaseInformation:
        case kOuraEvtSleepPhaseDetails:
        case kOuraEvtSleepPhaseData:
          // The ring's own staging, kept per event (no night boundary is
          // known) as stage-minute totals under `vendorKey`, and the `data`
          // pages also as an epoch series (see [_emit]'s VendorHypnogram).
          final hyp = decodeSleepPhases(e);
          if (hyp == null) break;
          _heldStages[(e.tsDs, e.tag, hyp.header)] = hyp.phases;
      }
    }
    // Stamp everything an origin can now reach — this batch's readings and any
    // held from earlier ones. What still cannot be stamped stays held for a
    // later batch, and is dropped at the end of the drain rather than guessed
    // at: a plausible wrong second is worse than a missing one, because nothing
    // downstream can tell it apart from a measurement.
    _held.removeWhere((h) {
      final unix = _anchorUnixFor(h.$1);
      if (unix == null) return false;
      samples.add(NeutralSample(
        anchor: TimeAnchor.arrival,
        tsEpoch: unix,
        skinTempC: h.$2,
      ));
      return true;
    });
    // Rows are stamped at the event's own decisecond, and carriers sharing
    // one decisecond are summed: the row key is (ts_ms, vendorKey), so two
    // events on one stamp would otherwise REPLACE each other's minutes.
    final stageEpochs = <(int ms, OuraSleepPhase), int>{};
    final hypnogram = <VendorEpoch>[];
    final a = _anchor;
    if (a != null) {
      for (final MapEntry(:key, :value) in _heldStages.entries) {
        final ms = a.$2 * 1000 + (key.$1 - a.$1) * 100;
        for (final stage in value) {
          stageEpochs.update((ms, stage), (m) => m + 1, ifAbsent: () => 1);
        }
        // Only the numbered `data` pages become an epoch series. A page is
        // taken to END at its own stamp; that is unverified, which is why the
        // night is gated for contiguity and for edges that agree with our own
        // window (`vendorNightRejection`) before anything reads it. A shift of
        // one page passes both. One code we
        // have no stage for and the page is dropped — the hole then fails
        // that gate for the whole night instead of a guessed stage passing it.
        if (key.$2 != kOuraEvtSleepPhaseData) continue;
        final stages = [for (final p in value) ouraStage4(p.index)];
        if (stages.contains(null)) continue;
        final endSec = ms ~/ 1000;
        final startSec = endSec - stages.length * 30;
        for (var i = 0; i < stages.length; i++) {
          hypnogram.add(VendorEpoch(
              startSec + i * 30, startSec + (i + 1) * 30, stages[i]!));
        }
      }
      _heldStages.clear();
    }
    if (hypnogram.isNotEmpty) yield VendorHypnogram('oura', hypnogram);
    final stageRows = [
      for (final MapEntry(:key, :value) in stageEpochs.entries)
        Observation(
          at: DateTime.fromMillisecondsSinceEpoch(key.$1),
          sourceKind: ObservationSource.vendor,
          vendorKey: 'sleep_${key.$2.name}_min',
          value: value * 0.5,
          unit: 'min',
          attribution: 'Oura',
        ),
    ];
    if (stageRows.isNotEmpty) yield VendorScalars(stageRows);
    // EVERY event frame is archived, including the ones just decoded and every
    // one that was not. Beat intervals, SpO2 and steps all live in here
    // undecoded, and that is the point: the bytes are banked now so a decoder
    // written when someone owns a ring can be run over them, instead of a
    // guess being run over them today (owner rulings R1-R3).
    yield SampleBatch(samples, raw: got.raw);
  }
}

/// One batch of history, as collected off the wire.
class _Batch {
  final List<OuraEvent> events;
  final List<Uint8List> raw;
  final int maxDs;
  final OuraBatchSummary summary;
  const _Batch(this.events, this.raw, this.maxDs, this.summary);
}

/// Frames off the notify characteristic, buffered so that a reply landing
/// before anyone is waiting is not dropped.
///
/// Hand-rolled rather than `package:async`'s `StreamQueue` because that would
/// mean promoting a transitive dependency to a direct one for one class, and
/// the whole of what this session needs is "the next frame, or nothing".
class _Inbox {
  // Third element is the notification bytes AS DELIVERED — `raw_archive`'s
  // copy, kept alongside the parsed frame rather than re-derived from it. See
  // `_collectBatch` for why re-deriving loses bytes.
  final List<(int, OuraFrame, Uint8List)> _buf = [];
  Completer<(int, OuraFrame, Uint8List)?>? _waiter;
  bool _closed = false;

  void add(int atSec, OuraFrame f, Uint8List raw) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete((atSec, f, raw));
      return;
    }
    _buf.add((atSec, f, raw));
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  /// The next frame, or null on timeout or a closed link.
  Future<(int, OuraFrame, Uint8List)?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<(int, OuraFrame, Uint8List)?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame satisfying [test], discarding what comes before it.
  /// [timeout] bounds the whole search, not each frame.
  Future<OuraFrame?> firstWhere(
    bool Function(OuraFrame) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final rec = await next(timeout - deadline.elapsed);
      if (rec == null) return null;
      if (test(rec.$2)) return rec.$2;
    }
    return null;
  }
}

/// How the authentication handshake ended — the difference the host's
/// user-facing error category hangs off.
enum _AuthOutcome {
  /// The ring accepted the key.
  ok,

  /// The ring EXPLICITLY rejected the key (its own refusal frame).
  refused,

  /// No answer, a refused write, a missing challenge: everything that is NOT
  /// the ring's own verdict.
  silent,
}

/// The ring's 2-bit stage code in our `stages4` words, or null for a code we
/// have no stage for. The one place a ring code becomes one of ours.
String? ouraStage4(int code) => switch (code) {
      0 => 'deep',
      1 => 'light',
      2 => 'rem',
      3 => 'wake',
      _ => null,
    };
