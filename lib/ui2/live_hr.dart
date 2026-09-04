// The heart rate arriving RIGHT NOW.
//
// Live HR is not a workout-only quantity, but the stream is not free either:
// the screen hosting this card owns the realtime-HR stream while it is mounted
// (`AppState.retainLiveHrView` / `releaseLiveHrView`, discussion #287), so a
// beat is a second old while someone is looking at it and the band goes quiet
// again when they leave. It was simply never surfaced outside the workout
// screen.
//
// THE RULES THIS FILE HOLDS:
//
//   · It OWNS NO TIME. The first version ran a `Timer.periodic` and a heart
//     that pulsed at the measured rate off a repeating controller — which the
//     design-system tests correctly rejected: an endless loop cannot be stopped
//     by the reduced-motion gate, and raw `Duration`s bypass `motion()`. The
//     deeper problem was architectural: the trace also died every time the
//     screen closed. The buffer lives on [AppState] now and this is a pure
//     renderer.
//   · The trace is READINGS, not seconds, and says so. Samples arrive when the
//     band delivers them, so calling it "the last 90 seconds" would be a claim
//     about spacing nothing here guarantees.
//   · Absence states its reason and never a number. `AppState.liveHr` returns
//     null past [AppState.liveHrMaxAge], so an unworn band, a dropped link and
//     a backgrounded HR-only downgrade all arrive as null — and each gets the
//     sentence that is true for it.
//   · It repaints ALONE. A 1 Hz stream hung off a `watch` in a parent would
//     rebuild that whole tree once a second for the life of the connection.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'ui2.dart';

/// The live reading as a card: the number, and the recent readings behind it.
class LiveHrCard extends StatelessWidget {
  /// The real one: reads the live stream off [AppState].
  const LiveHrCard({super.key})
      : _hr = null,
        _trace = null,
        _preview = false;

  /// A fixed reading, for the gallery. The gallery has no band, no stream and
  /// no Provider above it, and a card that reached for one would either throw
  /// there or force every caller to thread state through. This is the same
  /// widget with its inputs handed to it.
  const LiveHrCard.preview({super.key, required int hr, required List<int> trace})
      : _hr = hr,
        _trace = trace,
        _preview = true;

  final int? _hr;
  final List<int>? _trace;
  final bool _preview;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final hr = _preview ? _hr : c.select<AppState, int?>((a) => a.liveHr);
    if (hr == null) {
      if (_preview) return _absent(paired: true, connected: true);
      // SELECTED, not read: with no reading the only thing this widget watched
      // was `liveHr`, which stays null through both pairing and connecting — so
      // the card went on saying "No band is paired" after the band was paired
      // and connected. These are what change in that state.
      return _absent(
        paired: c.select<AppState, bool>((a) => a.isPaired),
        connected: c.select<AppState, bool>((a) => a.isConnected),
      );
    }

    // A REVISION, not the length. Length is pinned at the cap once the buffer
    // is full, so watching it drew the first 90 readings and then froze.
    final List<int> trace;
    if (_preview) {
      trace = _trace ?? const [];
    } else {
      c.select<AppState, int>((a) => a.liveHrTraceRev);
      trace = c.read<AppState>().liveHrTrace;
    }

    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // At 3.1x text an n48 number plus a pill does not fit a phone width, so
        // the number is allowed to scale down inside the space that is left
        // rather than the row overflowing. The pill keeps its size: it is two
        // short words and shrinking it is how a label becomes unreadable.
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Icon(LucideIcons.heart, size: 26, color: p.on(C.red)),
          const SizedBox(width: S.x3),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$hr', style: F.n48.copyWith(color: p.ink)),
                  const SizedBox(width: S.x2),
                  Text('bpm', style: F.body.copyWith(color: p.ink3)),
                ],
              ),
            ),
          ),
          const SizedBox(width: S.x2),
          const Pill('LIVE', C.red, icon: LucideIcons.radio),
        ]),
        if (trace.length > 2) ...[
          const SizedBox(height: S.x3),
          SizedBox(
            height: 56,
            child: CustomPaint(
              painter: LineChart(
                [for (final v in trace) v.toDouble()],
                C.red,
                fill: false,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: S.x2),
          Text(
            'The last ${trace.length} readings — ${trace.reduce(math.min)}'
            '–${trace.reduce(math.max)} bpm. Not stored; this is '
            'the live stream, not a record of your day.',
            style: F.over.copyWith(color: p.ink3),
          ),
        ],
      ]),
    );
  }

  /// No live reading. Three different facts, and only the one the app can
  /// actually see is stated.
  Widget _absent({required bool paired, required bool connected}) {
    final (String why, String fix) = !paired
        ? ('No band is paired.', 'Pair one from Profile to read live beats.')
        : !connected
            ? (
                'Your band is not connected.',
                'Live beats need an open link — the app connects when you open '
                    'it with the band in range.'
              )
            : (
                'No beat in the last ${AppState.liveHrMaxAge.inSeconds} '
                    'seconds.',
                'The band streams while it is on your wrist and the app is '
                    'open.'
              );
    return StatusCard('No live reading', why,
        fix: fix, icon: LucideIcons.heartOff);
  }
}
