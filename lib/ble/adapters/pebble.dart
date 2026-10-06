// The Pebble 2 / Pebble 2 SE as a [BandAdapter]: PPoGATT transport, the
// inner Pebble Protocol frames, the minimal phone handshake, and the watch's
// health data logging.
//
// THE SESSION. Every PPoGATT data packet is ACKed at the transport layer,
// then reassembled into inner frames (`protocol`'s `pebble.dart`). The watch
// asks for the phone's version (endpoint 17); the reply is sent, then the
// clock is set and data logging is asked to report its sessions. Health
// arrives as data-logging messages: per-minute records (steps, HR) under tag
// 81 and sleep / deep-sleep overlays under tag 84.
//
// COMMIT BEFORE ACK. An ACKed data-logging message is gone from the watch,
// so every ACK rides an [OffloadCheckpoint]: the host commits the batch
// (decoded HR plus the raw frame), THEN the confirm sends the ACK — the same
// invariant the WHOOP trim runs on. A message this adapter cannot read is
// NACKed (the watch re-sends it) unless it belongs to a session we do not
// decode, which is banked raw and ACKed so it cannot loop forever.
//
// STEP TOTALS CARRY FORWARD. The watch never re-sends an ACKed minute, so a
// day's total is the previous total (handed in by the link) plus every minute
// newer than the last one counted (also handed in), and the new high-water
// mark is noted back.
//
// WHAT BECOMES WHAT: HR -> sparse samples (outside derivation, ASSUMPTIONS
// R6); steps -> a daily `steps` observation; sleep overlays -> the watch's
// hypnogram (light / deep; it reports no REM or wake) plus per-night
// stage-minute vendor observations.
//
// ONLY PEBBLE 2 / PEBBLE 2 SE: older models need the phone to host a GATT
// server, which this app cannot.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../compute/vendor_sleep.dart' show VendorEpoch;
import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The lower 3 bits of a PPoGATT header byte.
const int _kPpogattCmdData = 0;
const int _kPpogattCmdAck = 1;
const int _kPpogattCmdReset = 2;

/// Shown next to every value the watch computed itself.
const String kPebbleAttribution = 'Pebble';

/// The signals this watch supplies (HR in the v7+ minute record).
const Map<InputSignal, Duration> kPebbleSignals = {
  InputSignal.hrSparse: Duration(minutes: 1),
};

class PebbleAdapter extends BandAdapter {
  final int Function() nowSeconds;

  /// Daily step totals already stored, by local midnight.
  final Map<DateTime, int> priorSteps;

  /// The newest minute already counted into [priorSteps], Unix seconds.
  final int stepsHighWater;

  PebbleAdapter({
    int Function()? nowSeconds,
    this.priorSteps = const {},
    this.stepsHighWater = 0,
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  @override
  BandEntry get entry => kPebble;

  @override
  Map<InputSignal, Duration> get signals => kPebbleSignals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final frames = PebbleFrameReassembler();
    final sessions = <int, PebbleDatalogSession>{};
    final steps = Map<DateTime, int>.of(priorSteps);
    var highWater = stepsHighWater;
    final overlays = <PebbleOverlay>[];
    var serial = 0;
    var greeted = false;

    Future<bool> send(int endpoint, List<int> payload) async {
      for (final p in pebblePpogattPackets(pebbleFrame(endpoint, payload), serial)) {
        serial = (serial + 1) & 0x1f;
        if (!await link.write(kPebblePpogattWriteUuid, p)) return false;
      }
      return true;
    }

    await for (final (_, value) in link.notify(kPebblePpogattReadUuid)) {
      if (value.isEmpty) continue;
      final header = value[0];
      final rxSerial = header >> 3;
      switch (header & 0x7) {
        case _kPpogattCmdData:
          // Transport ACK first: the watch re-sends an un-ACKed packet. An
          // unconfirmed ACK means a retransmit is coming — skip this copy.
          if (!await link.write(
              kPebblePpogattWriteUuid, <int>[(rxSerial << 3) | 1])) {
            link.log('pebble: ack write unconfirmed for serial $rxSerial');
            continue;
          }
          for (final (endpoint, p) in frames.add(value.sublist(1))) {
            final raw = [Uint8List.fromList(pebbleFrame(endpoint, p))];
            if (endpoint == kPebbleEndpointPhoneVersion &&
                p.isNotEmpty &&
                p[0] == 0x00) {
              await send(kPebbleEndpointPhoneVersion, pebblePhoneVersionReply());
              if (!greeted) {
                greeted = true;
                final now =
                    DateTime.fromMillisecondsSinceEpoch(nowSeconds() * 1000);
                await send(kPebbleEndpointTime, pebbleSetTimeUtc(now));
                await send(kPebbleEndpointDatalog, kPebbleDatalogReportSessions);
              }
              continue;
            }
            if (endpoint != kPebbleEndpointDatalog || p.length < 2) {
              yield SampleBatch(const [], raw: raw);
              continue;
            }
            final sid = p[1];
            switch (p[0]) {
              case kPebbleDatalogOpen:
                final open = parsePebbleDatalogOpen(p);
                if (open != null) sessions[sid] = open;
                await send(kPebbleEndpointDatalog,
                    open == null ? pebbleDatalogNack(sid) : pebbleDatalogAck(sid));
              case kPebbleDatalogData:
                final session = sessions[sid];
                final items = session == null
                    ? null
                    : parsePebbleDatalogItems(p, session.itemSize);
                if (session == null || items == null) {
                  await send(kPebbleEndpointDatalog, pebbleDatalogNack(sid));
                  continue;
                }
                final samples = <NeutralSample>[];
                final rows = <Observation>[];
                final hypnogram = <VendorEpoch>[];
                var readable = true;
                switch (session.tag) {
                  case kPebbleTagSteps:
                    final touched = <DateTime>{};
                    for (final item in items) {
                      final minutes = parsePebbleStepsItem(item);
                      if (minutes == null) {
                        readable = false;
                        break;
                      }
                      for (final m in minutes) {
                        if (m.tsSec > nowSeconds() + 3600) continue;
                        final hr = m.hr;
                        if (hr != null && hr >= 25 && hr <= 230) {
                          samples.add(NeutralSample(
                              anchor: TimeAnchor.measured,
                              tsEpoch: m.tsSec,
                              hr: hr));
                        }
                        if (m.tsSec <= highWater) continue;
                        highWater = m.tsSec;
                        if (m.steps == 0) continue;
                        final t =
                            DateTime.fromMillisecondsSinceEpoch(m.tsSec * 1000);
                        final day = DateTime(t.year, t.month, t.day);
                        steps[day] = (steps[day] ?? 0) + m.steps;
                        touched.add(day);
                      }
                    }
                    for (final day in touched) {
                      rows.add(_obs(day, 'steps', steps[day]!, 'steps',
                          ours: true));
                    }
                  case kPebbleTagOverlay:
                    for (final item in items) {
                      final o = parsePebbleOverlayItem(item);
                      if (o == null) {
                        readable = false;
                        break;
                      }
                      if (o.type == kPebbleOverlaySleep ||
                          o.type == kPebbleOverlayDeepSleep) {
                        overlays.add(o);
                      }
                    }
                    // A deep-sleep period belongs to the sleep period it
                    // falls inside; recomputed over everything seen this
                    // session, so the order the watch sends them in does
                    // not matter. Upserted per night (keyed on wake time).
                    for (final night in overlays
                        .where((o) => o.type == kPebbleOverlaySleep)) {
                      final end = night.startSec + night.durationSec;
                      var deep = 0;
                      for (final d in overlays) {
                        if (d.type == kPebbleOverlayDeepSleep &&
                            d.startSec >= night.startSec &&
                            d.startSec < end) {
                          deep += d.durationSec ~/ 60;
                        }
                      }
                      final at = DateTime.fromMillisecondsSinceEpoch(end * 1000);
                      rows.add(_obs(at, 'sleep_deep_min', deep, 'min'));
                      rows.add(_obs(at, 'sleep_light_min',
                          (night.durationSec ~/ 60 - deep).clamp(0, 1 << 30),
                          'min'));
                      // The night as a hypnogram: deep where a deep period
                      // lies, light (the watch's "sleep") everywhere else.
                      final deeps = overlays
                          .where((d) =>
                              d.type == kPebbleOverlayDeepSleep &&
                              d.startSec >= night.startSec &&
                              d.startSec < end)
                          .toList()
                        ..sort((a, b) => a.startSec.compareTo(b.startSec));
                      var t = night.startSec;
                      for (final d in deeps) {
                        final dEnd = math.min(d.startSec + d.durationSec, end);
                        if (d.startSec > t) {
                          hypnogram.add(VendorEpoch(t, d.startSec, 'light'));
                        }
                        if (dEnd > math.max(t, d.startSec)) {
                          hypnogram.add(VendorEpoch(
                              math.max(t, d.startSec), dEnd, 'deep'));
                        }
                        t = math.max(t, dEnd);
                      }
                      if (end > t) hypnogram.add(VendorEpoch(t, end, 'light'));
                    }
                }
                if (!readable) {
                  // A version this decoder does not know: NACK, the watch
                  // keeps it and a later build can read it.
                  await send(kPebbleEndpointDatalog, pebbleDatalogNack(sid));
                  continue;
                }
                yield SampleBatch(samples, raw: raw);
                if (rows.isNotEmpty) yield VendorScalars(rows);
                if (hypnogram.isNotEmpty) {
                  yield VendorHypnogram('pebble', hypnogram);
                }
                if (session.tag == kPebbleTagSteps) {
                  yield BandNote('pebble_steps_hw', highWater);
                }
                // Commit, THEN ACK — the watch drops what it sees ACKed.
                yield OffloadCheckpoint(() =>
                    send(kPebbleEndpointDatalog, pebbleDatalogAck(sid)));
              case kPebbleDatalogClose:
              case kPebbleDatalogTimeout:
                sessions.remove(sid);
                await send(kPebbleEndpointDatalog, pebbleDatalogAck(sid));
              default:
                yield SampleBatch(const [], raw: raw);
            }
          }
        case _kPpogattCmdAck:
          // The watch acknowledging a packet we sent.
          break;
        case _kPpogattCmdReset:
          // The transport's fixed reset reply; required to stay alive.
          await link.write(
            kPebblePpogattWriteUuid,
            value.length > 1 ? const <int>[0x03, 0x19, 0x19] : const <int>[0x03],
          );
          serial = 0;
          link.log('pebble: reset/renegotiation request (serial $rxSerial)');
        default:
          link.log('pebble: unrecognised PPoGATT command, dropped');
      }
    }
  }

  static Observation _obs(DateTime at, String name, num value, String unit,
          {bool ours = false}) =>
      Observation(
        at: at,
        sourceKind: ObservationSource.vendor,
        key: ours ? name : null,
        vendorKey: ours ? null : name,
        value: value,
        unit: unit,
        attribution: kPebbleAttribution,
      );
}

/// A session with nothing carried forward — tests and first syncs.
final PebbleAdapter kPebbleAdapter = PebbleAdapter();
