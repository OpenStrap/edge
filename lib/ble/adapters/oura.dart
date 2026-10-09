// The Oura ring as a [BandAdapter]: authenticate, drain its history by cursor,
// bank every byte, decode only what has been proven.
//
// NO DECODE HERE HAS MET HARDWARE. Discovery and first connect have met a real
// ring (see `kOura`'s doc); nothing past them has, and unlike `ble_hrs` there is
// not even a public specification to fall back on. It ships EXPERIMENTAL (ASSUMPTIONS R6),
// its rows carry a non-null `source` and `kDerivableSources` does not contain
// it, so the band's own derive never reads them. What it writes becomes a
// number only through the ring's own column (compute/inputs/oura_inputs.dart:
// its temperatures, its night) and only while the per-wearable flag is on and
// the ring is the active wearable; flag off, nothing it wrote reaches a day.
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

  /// The phone's UTC offset in half-hour steps, sent with the clock set so the
  /// ring records the real timezone rather than UTC. Injected for the same
  /// reason as [nowSeconds].
  final int Function() tzHalfHours;

  /// How long to wait for a reply the ring owes us, and for each frame after
  /// the first one of a history batch.
  final Duration replyTimeout;

  /// How long to wait for the FIRST frame of a history batch. The ring can take
  /// far longer to start a batch than to continue one (it may be finishing a
  /// sleep analysis), so the first frame gets a 120 s window.
  final Duration firstFrameTimeout;

  /// How long to wait before asking again while the ring reports sleep
  /// analysis in progress with nothing left to send.
  final Duration analysisPollDelay;

  /// How long to wait for the host to commit a batch and call `confirm`.
  /// Expiring is SAFE: the cursor does not move, so the batch is re-read.
  /// Overridable only so a test does not have to sit through it.
  final Duration confirmTimeout;

  OuraAdapter({
    required this.key,
    this.startCursorDs = 0,
    this.anchor,
    int Function()? nowSeconds,
    int Function()? tzHalfHours,
    this.replyTimeout = const Duration(seconds: 5),
    this.firstFrameTimeout = const Duration(seconds: 120),
    this.analysisPollDelay = const Duration(milliseconds: 500),
    this.confirmTimeout = const Duration(seconds: 30),
  })  : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
        tzHalfHours = tzHalfHours ??
            (() => DateTime.now().timeZoneOffset.inMinutes ~/ 30),
        _anchor = anchor;

  @override
  BandEntry get entry => kOura;

  /// What the ring stores, at the resolution it stores it. Mirrored in
  /// `kAdapterSignals`. Its HR is a reading every 5 minutes (night pairs and
  /// daytime bursts alike), its beats come in short runs at no stated
  /// cadence, its temperature events at none either.
  ///
  /// Temperature is [InputSignal.skinTempC], never [InputSignal.skinTempRaw]:
  /// that one means RELATIVE ADC COUNTS (I8), and this ring reports absolute
  /// degrees Celsius.
  @override
  Map<InputSignal, Duration> get signals => kOuraSignals;

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

  /// Heart rates `(ds, bpm)`, beat runs `(ds the last beat ended, intervals
  /// ms)` and the ring's own values `(ds, vendor key, value, unit)` waiting
  /// for an origin. Same lifecycle as [_held].
  final List<(int ds, int bpm)> _heldHr = [];
  final List<(int ds, List<int> ibis)> _heldBeats = [];
  final List<(int ds, String key, num value, String unit)> _heldValues = [];

  /// Hypnogram pages waiting for an origin, keyed by (sleep period, page
  /// index). Same lifecycle as [_held]. `0x4e` and `0x5a` are pages of ONE
  /// buffer, so a later page with the same index REPLACES the earlier one
  /// whichever tag carries it; keyed by event instead, the same 52 epochs
  /// were counted twice.
  final Map<(int period, int page), (int ds, List<OuraSleepPhase>)>
      _heldStages = {};

  /// A `time_sync` from this session's clock set has arrived, so a skip of
  /// that same set is not reported as "no origin this session".
  /// ponytail: a skip in an earlier batch than its `time_sync` is still
  /// reported; defer the note to the end of the drain if that ever matters.
  bool _syncedThisSession = false;

  /// Bumped by every sleep-summary event: pages after it are a new night.
  int _period = 0;

  /// Pages already stamped this drain. A page seen again in a later batch is
  /// the same epochs again and is not counted a second time.
  /// ponytail: per drain only; across syncs a re-read page collapses on its
  /// own row key (ts_ms, vendorKey), but a page the ring rewrote under the
  /// same index at a later stamp is a second row.
  final Set<(int period, int page)> _stampedPages = {};

  /// Empty or no-progress batches with bytes left that get a 1 ds step before
  /// the bookmark is declared stranded. Session-wide, so a ring that keeps
  /// answering a stepped cursor with the same tail cannot oscillate forever.
  static const int _kMaxSteps = 3;

  /// Re-polls while the ring reports sleep analysis in progress.
  /// ponytail: a fixed cap (~10 s at 500 ms); raise it if a real ring needs
  /// longer to finish a night.
  static const int _kMaxAnalysisPolls = 20;

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
            // One notification can carry several frames back to back. The
            // notification bytes AS DELIVERED ride on its first event-range
            // frame only, so `raw_archive` gets one row per notification (its
            // copy, not the parser's) and never the same bytes twice.
            var rawGiven = false;
            final frames = parseOuraFrames(rec.$2);
            for (final f in frames) {
              final carries = !rawGiven && f.tag >= kOuraFirstEventTag;
              if (carries) rawGiven = true;
              inbox.add(rec.$1, f, carries ? Uint8List.fromList(rec.$2) : null);
            }
            // A notification with no trusted frame (an event declaring more
            // than 18 bytes) is decoded as nothing but still BANKED: an empty
            // frame under its first byte carries the bytes to `raw_archive`
            // and decodes to no event.
            if (frames.isEmpty &&
                rec.$2.isNotEmpty &&
                rec.$2.first >= kOuraFirstEventTag) {
              inbox.add(rec.$1, OuraFrame(rec.$2.first, Uint8List(0)),
                  Uint8List.fromList(rec.$2));
            }
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
      // FORCED ONLY WITH NO ORIGIN AT ALL (first pairing, or after a reset
      // dropped the stored one). The ring may skip an unforced set while it is
      // measuring, and with no stored anchor a skipped set means nothing this
      // session can be stamped. With an anchor, extrapolating from it is fine.
      final sentAt = nowSeconds();
      final syncTime = ouraCmdSyncTime(sentAt,
          tzHalfHours: tzHalfHours(), force: anchor == null);
      if (!await link.write(kOuraCommandChar, syncTime)) {
        link.log('oura: time-sync write refused; no new origin this session. '
            'Readings are stamped only if a stored anchor covers them.');
      }

      var cursor = startCursorDs;
      var steps = 0;
      var polls = 0;
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
        final got = await _collectBatch(link, inbox);
        // No summary = the batch never ended. Leave the cursor put; the next
        // sync re-reads from the last confirmed boundary. `_collectBatch`
        // already logged why. The user-facing category: a protocol timeout /
        // incomplete answer, the ring connected and authenticated.
        if (got == null) {
          yield const BandNote('oura_no_batch_summary');
          return;
        }
        final s = got.summary;

        // A full batch may have been cut inside its last decisecond, which the
        // next batch re-reads (see the cursor advance below).
        final full = s.received >= _kMaxEventsPerBatch && s.bytesLeft > 0;
        final reread = (full && got.lastDs != cursor) ? got.lastDs : null;
        final next = reread ?? got.lastDs + 1;

        // NO PROGRESS: nothing delivered, or a batch whose next cursor is the
        // one just asked for. With bytes left that would send the same request
        // forever (a reboot crossing whose new-boot tail ends on cursor - 1
        // does it even after delivering newer events). With none left it is a
        // replay only when every event is below the cursor (an up-to-date ring
        // answers a cursor past its newest event with its last few again).
        final stale = got.events.isEmpty ||
            (next == cursor &&
                (s.bytesLeft > 0 ||
                    got.events.every((e) => e.tsDs < cursor)));
        if (stale) {
          if (s.bytesLeft > 0) {
            // Data remaining and no progress. Step the cursor forward one
            // decisecond and ask again. Only when that keeps failing is the
            // bookmark STRANDED: the counter is an uptime, a reboot restarts
            // it near zero, and a bookmark from before then points past
            // everything the ring holds. The host then re-reads from zero,
            // which is free (re-reads are idempotent by design).
            if (steps++ < _kMaxSteps) {
              cursor++;
              continue;
            }
            link.log('oura: the ring reports ${s.bytesLeft} bytes left but '
                'answered this cursor with nothing new.');
            yield const BandNote('oura_cursor_stranded');
            return;
          }
          if (s.sleepAnalysisProgress > 0 && polls++ < _kMaxAnalysisPolls) {
            await Future<void>.delayed(analysisPollDelay);
            continue;
          }
          if (got.events.isNotEmpty) {
            link.log('oura: the ring replayed ${got.events.length} event(s); '
                'nothing new after $cursor.');
          }
          // Nothing left and nothing new: the drain reached its honest end.
          yield const BandNote('oura_drain_ok');
          return;
        }

        // A full batch's last decisecond is left to the re-read. Decoding it
        // here too would stamp a partial sum now and the full one after a
        // re-anchor, on two different `ts_ms` that REPLACE cannot collapse. It is left to
        // the re-read, which sees all of it. With no bytes left nothing was
        // cut and no re-read comes, so the last decisecond is decoded here.
        yield* _emit(link, got, skipDs: reread, sentAt: sentAt);

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
          remaining: s.bytesLeft < 0 ? null : s.bytesLeft,
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
        // THE CURSOR FOLLOWS DELIVERY ORDER: the LAST event delivered, not the
        // largest. A batch that crosses a reboot ends on the new boot's small
        // stamps, and the bookmark has to land there, below where it was.
        //
        // A FULL BATCH RE-READS ITS LAST DECISECOND; A SHORT ONE MOVES PAST IT.
        // The cursor is a TIMESTAMP and the batch cap a record count, so a full
        // batch may have been cut in the middle of a decisecond that holds more
        // records than fitted. Re-reading `lastDs` costs one re-read
        // decisecond, decoded only by the batch that re-reads it. The
        // `!= cursor` guard is the escape: a ring with a whole batch inside one
        // decisecond would otherwise re-ask for the same thing forever.
        cursor = next;
        yield BandNote('oura_cursor_ds', cursor);
        if (s.bytesLeft > 0) continue;
        // Nothing left NOW, but the ring is still analysing the night: its
        // newest sleep events are not written yet. Ask again shortly from the
        // new cursor instead of leaving them to the next sync.
        if (s.sleepAnalysisProgress > 0 && polls++ < _kMaxAnalysisPolls) {
          await Future<void>.delayed(analysisPollDelay);
          continue;
        }
        yield const BandNote('oura_drain_ok');
        return;
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Nonce, encrypt, answer. [ok] is the only way a session may carry on —
  /// a session that continues unauthenticated gets `auth required` to every
  /// command and looks identical to a dead link. [refused] is the ring's
  /// OWN explicit rejection of the key, kept apart from [silent]: a refused
  /// key and a ring that never answered have different remedies, and the
  /// host's user-facing category hangs off exactly that difference. A ring
  /// that answers auth as unsupported (0x2f) did not judge the key, so that
  /// is [silent] too: re-pairing would be the wrong remedy.
  Future<_AuthOutcome> _authenticate(BandLink link, _Inbox inbox) async {
    if (!await link.write(kOuraCommandChar, ouraCmdAuthNonce())) {
      return _AuthOutcome.silent;
    }
    final challenge = await inbox.firstWhere(
        (f) => ouraAuthNonce(f) != null || ouraIsUnsupported(f, 0x2f),
        replyTimeout);
    if (challenge == null) {
      link.log('oura: no authentication challenge.');
      return _AuthOutcome.silent;
    }
    if (ouraIsUnsupported(challenge, 0x2f)) {
      link.log('oura: ring rejected auth (0x2f) as unsupported.');
      return _AuthOutcome.silent;
    }
    final answer = ouraAuthResponse(key, ouraAuthNonce(challenge)!);
    if (!await link.write(kOuraCommandChar, ouraCmdAuthenticate(answer))) {
      return _AuthOutcome.silent;
    }
    final reply = await inbox.firstWhere(
        (f) => ouraAuthResult(f) != null || ouraIsUnsupported(f, 0x2f),
        replyTimeout);
    if (reply != null && ouraIsUnsupported(reply, 0x2f)) {
      link.log('oura: ring rejected auth (0x2f) as unsupported.');
      return _AuthOutcome.silent;
    }
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

  /// Read frames until the batch summary arrives. Null (after logging why)
  /// when the batch never ended.
  Future<_Batch?> _collectBatch(BandLink link, _Inbox inbox) async {
    final events = <OuraEvent>[];
    final raw = <Uint8List>[];
    var lastDs = 0;
    // A misbehaving ring that keeps streaming non-summary frames would
    // otherwise spin here forever — each frame resets `replyTimeout`'s
    // window, so the timeout alone never bounds this loop. Same shape as the
    // outer `batch < 5000` guard in `run`.
    for (var frame = 0; frame < 5000; frame++) {
      final rec =
          await inbox.next(frame == 0 ? firstFrameTimeout : replyTimeout);
      if (rec == null) {
        link.log('oura: no batch summary within the reply window.');
        return null;
      }
      final (_, f, rawBytes) = rec;
      final summary = parseBatchSummary(f);
      if (summary != null) return _Batch(events, raw, lastDs, summary);
      if (ouraIsAuthRequired(f)) {
        link.log('oura: the ring asked for authentication mid-drain.');
        return null;
      }
      if (ouraIsUnsupported(f, 0x10)) {
        link.log('oura: ring rejected GetEvent (0x10) as unsupported.');
        return null;
      }
      // The bytes AS THE RADIO DELIVERED THEM, once per notification, decoded
      // or not (an extended event is archived without being decoded). Not
      // re-encoded from the parsed frame: a future decoder for the
      // still-undecoded event types needs what the radio saw, and
      // `raw_archive` cannot un-truncate what was never written.
      if (rawBytes != null) raw.add(rawBytes);
      final e = parseOuraEvent(f);
      if (e == null) continue;
      events.add(e);
      lastDs = e.tsDs;
    }
    link.log('oura: no batch summary within the reply window.');
    return null;
  }

  /// Turn one collected batch into events for the host, IN DELIVERY ORDER.
  /// Events at [skipDs] are archived but not decoded: the next batch re-reads
  /// that decisecond.
  Stream<BandEvent> _emit(BandLink link, _Batch got,
      {int? skipDs, required int sentAt}) async* {
    final samples = <NeutralSample>[];
    // Rows are stamped at the page's own decisecond, and pages sharing one
    // stamp are summed: the row key is (ts_ms, vendorKey), so two pages on one
    // stamp would otherwise REPLACE each other's minutes.
    final stageEpochs = <(int ms, OuraSleepPhase), int>{};
    final hypnogram = <VendorEpoch>[];
    final values = <Observation>[];
    // The batch's SpO2, one mean stamped at its first reading: per event
    // would be a row a few seconds of a night, thousands a night.
    final spo2 = <int>[];
    int? spo2Ds;
    int? skipReason;
    for (final e in got.events) {
      if (e.tsDs == skipDs) continue;
      // A RING START THAT RESTARTED THE COUNTER ENDS AN EPOCH. Everything held
      // so far belongs to the boot before it: stamp it with that boot's origin
      // now, or drop it if there is none, then forget the origin. What follows
      // waits for the new boot's own `time_sync`. A ring start stamped below
      // the origin means the same thing (the counter went backwards).
      final a = _anchor;
      if (e.tag == kOuraEvtRingStart &&
          (ouraRingStartResetsClock(e) || (a != null && e.tsDs < a.$1))) {
        _stampHeld(samples, stageEpochs, hypnogram, values);
        _held.clear();
        _heldHr.clear();
        _heldBeats.clear();
        _heldValues.clear();
        _heldStages.clear();
        if (a != null) {
          _anchor = null;
          yield const BandNote('oura_anchor', null);
        }
        continue;
      }
      switch (e.tag) {
        case kOuraEvtTimeSync:
          final unix = decodeTimeSync(e);
          if (unix == null) break;
          // A better origin for this record, every one after it in this boot,
          // and everything still held from it.
          _anchor = (e.tsDs, unix);
          if (unix >= sentAt - 300) _syncedThisSession = true;
          // Surfaced so the host can persist it without re-deriving one of its
          // own. Two implementations of an origin is two origins.
          yield BandNote('oura_anchor', '${e.tsDs},$unix');
        case kOuraEvtTimeSyncSkipped:
          // Never an anchor. Reported (after the batch) when it is about THIS
          // session's write and no `time_sync` from it arrived, so "no origin
          // this session" is said rather than inferred. 5 minutes of slack for
          // a ring clock that runs behind ours.
          final sk = decodeTimeSyncSkipped(e);
          if (sk != null && sk.unix >= sentAt - 300) skipReason = sk.reason;
        case kOuraEvtSleepSummary1:
          _period++;
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
        case kOuraEvtHrv:
          // One pair per 5-minute window, the last ending as the event is
          // written. The HR is a reading of ours to derive from; the RMSSD is
          // the ring's own, kept as its value per event.
          final pairs = decodeHrvPairs(e);
          if (pairs == null) break;
          final rmssd = <int>[];
          for (final (k, (bpm, ms)) in pairs.indexed) {
            if (_plausibleBpm(bpm)) {
              _heldHr.add((
                e.tsDs - (pairs.length - 1 - k) * kOuraHrvWindowSec * 10,
                bpm,
              ));
            }
            if (ms >= 1 && ms <= 300) rmssd.add(ms);
          }
          if (rmssd.isNotEmpty) {
            _heldValues.add((e.tsDs, 'hrv_avg',
                rmssd.reduce((a, b) => a + b) / rmssd.length, 'ms'));
          }
        case kOuraEvtAohr:
          // A burst of readings seconds apart: one heart rate, their mean.
          final xs = [
            for (final (bpm, _) in decodeAohr(e) ?? const <(int, int)>[])
              if (_plausibleBpm(bpm)) bpm,
          ];
          if (xs.isNotEmpty) {
            _heldHr.add(
                (e.tsDs, (xs.reduce((a, b) => a + b) / xs.length).round()));
          }
        case kOuraEvtSpo2:
          final xs = decodeSpo2(e);
          if (xs == null) break;
          for (final v in xs) {
            if (v >= 70) spo2.add(v);
          }
          if (spo2.isNotEmpty) spo2Ds ??= e.tsDs;
        case kOuraEvtIbiAmplitude:
          _holdBeats(e.tsDs, decodeIbiAmplitude(e) ?? const []);
        case kOuraEvtGreenIbiQuality:
          _holdBeats(e.tsDs, [
            for (final (ibi, q) in decodeGreenIbiQuality(e) ?? const <(int, int)>[])
              q == kOuraIbiQualityGood ? ibi : 0,
          ]);
        case kOuraEvtSleepPhaseDetails:
        case kOuraEvtSleepPhaseData:
          // The ring's own staging, one page of the night's buffer. Pages 0..35
          // only; a later page with the same index replaces the earlier one.
          final hyp = decodeSleepPhases(e);
          if (hyp == null || hyp.header > 35) break;
          final page = (_period, hyp.header);
          if (_stampedPages.contains(page)) break;
          _heldStages[page] = (e.tsDs, hyp.phases);
      }
    }
    if (spo2.isNotEmpty) {
      _heldValues.add((spo2Ds!, 'spo2_avg',
          spo2.reduce((a, b) => a + b) / spo2.length, '%'));
    }
    _stampHeld(samples, stageEpochs, hypnogram, values);
    if (skipReason != null && !_syncedThisSession) {
      link.log('oura: the ring skipped the clock set (reason $skipReason).');
      yield BandNote('oura_time_sync_skipped', skipReason);
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
    if (stageRows.isNotEmpty || values.isNotEmpty) {
      yield VendorScalars([...stageRows, ...values]);
    }
    // EVERY event frame is archived, including the ones just decoded and every
    // one that was not. Steps, motion and raw PPG live in here undecoded, and
    // that is the point: the bytes are banked now so a decoder written once
    // their layout is known can be run over them (owner rulings R1-R3).
    yield SampleBatch(samples, raw: got.raw);
  }

  /// The trailing run of plausible intervals in [ibis], held to be timed
  /// back from [ds]: a beat before an implausible one (or an unclean one,
  /// passed as 0) cannot be placed.
  void _holdBeats(int ds, List<int> ibis) {
    var i = ibis.length;
    while (i > 0 && _plausibleIbi(ibis[i - 1])) {
      i--;
    }
    if (i < ibis.length) _heldBeats.add((ds, ibis.sublist(i)));
  }

  /// Stamp everything the current origin can reach: held readings and held
  /// hypnogram pages. What cannot be stamped stays held for a later batch, and
  /// is dropped at the end of the drain (or at a clock reset) rather than
  /// guessed at: a plausible wrong second is worse than a missing one, because
  /// nothing downstream can tell it apart from a measurement.
  void _stampHeld(
    List<NeutralSample> samples,
    Map<(int ms, OuraSleepPhase), int> stageEpochs,
    List<VendorEpoch> hypnogram,
    List<Observation> values,
  ) {
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
    _heldHr.removeWhere((h) {
      final unix = _anchorUnixFor(h.$1);
      if (unix == null) return false;
      samples.add(
          NeutralSample(anchor: TimeAnchor.measured, tsEpoch: unix, hr: h.$2));
      return true;
    });
    final a = _anchor;
    if (a == null) return;
    int msOf(int ds) => a.$2 * 1000 + (ds - a.$1) * 100;
    // A beat run is written as its last beat ends; each beat ends one
    // interval after the one before, so the run is timed back from there on
    // the ring's own clock.
    for (final (ds, ibis) in _heldBeats) {
      var end = msOf(ds);
      final ends = <int>[];
      for (final i in ibis.reversed) {
        ends.add(end);
        end -= i;
      }
      samples.add(NeutralSample(
        anchor: TimeAnchor.measured,
        tsEpoch: msOf(ds) ~/ 1000,
        rrMs: ibis,
        beatTsMs: ends.reversed.toList(),
      ));
    }
    _heldBeats.clear();
    for (final (ds, key, v, unit) in _heldValues) {
      values.add(Observation(
        at: DateTime.fromMillisecondsSinceEpoch(msOf(ds)),
        sourceKind: ObservationSource.vendor,
        vendorKey: key,
        value: v,
        unit: unit,
        attribution: 'Oura',
      ));
    }
    _heldValues.clear();
    // A page's stage minutes are stamped at the page's own decisecond, the
    // one stamp no batch boundary, interrupted sync or re-read can move: a
    // re-read page REPLACEs its own row. Stamped at a period's last page
    // instead, every batch or sync that saw more of the night wrote it again
    // under a later key, and the earlier rows stayed (counted twice) or sat
    // on the day before. A night that crosses midnight has rows on both days;
    // the day's served stage minutes come off the staged night itself
    // (`dayCells`), never a sum of these.
    for (final MapEntry(:key, :value) in _heldStages.entries) {
      final (ds, phases) = value;
      final ms = msOf(ds);
      for (final stage in phases) {
        stageEpochs.update((ms, stage), (m) => m + 1, ifAbsent: () => 1);
      }
      _stampedPages.add(key);
      // Each page also becomes an epoch series. A page is taken to END at its
      // own stamp; that is unverified, which is why the night is gated for
      // contiguity and for edges that agree with our own window
      // (`vendorNightRejection`) before anything reads it. A shift of one page
      // passes both. One code we have no stage for and the page is dropped —
      // the hole then fails that gate for the whole night instead of a guessed
      // stage passing it.
      final stages = [for (final p in phases) ouraStage4(p.index)];
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
}

/// The signals this ring supplies. Mirrored in `kAdapterSignals`.
const Map<InputSignal, Duration> kOuraSignals = {
  InputSignal.hrSparse: Duration(minutes: 5),
  InputSignal.rrIntervals: Duration.zero,
  InputSignal.skinTempC: Duration.zero,
  InputSignal.deviceStages: Duration.zero,
  InputSignal.deviceHrv: Duration(minutes: 5),
  InputSignal.deviceSpo2: Duration(seconds: 1),
};

/// A heart rate a heart has: anything else is a reading of nothing, or a
/// layout read wrong.
bool _plausibleBpm(int bpm) => bpm >= 25 && bpm <= 230;

/// A beat interval a heart has (30-200 bpm).
bool _plausibleIbi(int ms) => ms >= 300 && ms <= 2000;

/// One batch of history, as collected off the wire.
class _Batch {
  final List<OuraEvent> events;
  final List<Uint8List> raw;

  /// The stamp of the LAST event in delivery order, which is what the cursor
  /// follows. Not the largest: across a reboot the two differ.
  final int lastDs;
  final OuraBatchSummary summary;
  const _Batch(this.events, this.raw, this.lastDs, this.summary);
}

/// Frames off the notify characteristic, buffered so that a reply landing
/// before anyone is waiting is not dropped.
///
/// Hand-rolled rather than `package:async`'s `StreamQueue` because that would
/// mean promoting a transitive dependency to a direct one for one class, and
/// the whole of what this session needs is "the next frame, or nothing".
class _Inbox {
  // Third element is the notification bytes AS DELIVERED — `raw_archive`'s
  // copy, kept alongside the parsed frame rather than re-derived from it, and
  // only on one frame per notification. See `_collectBatch` for why
  // re-deriving loses bytes.
  final List<(int, OuraFrame, Uint8List?)> _buf = [];
  Completer<(int, OuraFrame, Uint8List?)?>? _waiter;
  bool _closed = false;

  void add(int atSec, OuraFrame f, Uint8List? raw) {
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
  Future<(int, OuraFrame, Uint8List?)?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<(int, OuraFrame, Uint8List?)?>();
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
