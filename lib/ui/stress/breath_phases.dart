// The phase engine behind both paced breathing and the interval timer.
//
// They are the same problem: a repeating sequence of named, timed phases, with
// something to do at each boundary (change the label, buzz the strap). Keeping
// one engine means the interval timer inherits the breathing screen's haptics
// and duration handling for free, and a fix to either lands in both.
//
// Pure — no widgets, no timers, no BLE. A phase is a function of elapsed time,
// so the UI can drive it from any clock and the tests can drive it by hand.

import 'package:flutter/foundation.dart';

/// What a phase asks of you. The label is the whole instruction — a paced
/// breathing app that needs a legend has already failed.
enum BreathPhaseKind {
  inhale,
  holdIn,
  exhale,
  holdOut,

  /// Interval-timer phases.
  work,
  rest,
}

extension BreathPhaseKindLabel on BreathPhaseKind {
  String get label => switch (this) {
    BreathPhaseKind.inhale => 'Inhale',
    BreathPhaseKind.holdIn => 'Hold',
    BreathPhaseKind.exhale => 'Exhale',
    BreathPhaseKind.holdOut => 'Hold',
    BreathPhaseKind.work => 'Work',
    BreathPhaseKind.rest => 'Rest',
  };

  /// Whether the visual should be expanding, contracting, or still. Holds are
  /// still on purpose: an animation that keeps moving during a hold tells you
  /// to keep breathing.
  double get targetScale => switch (this) {
    BreathPhaseKind.inhale || BreathPhaseKind.work => 1.0,
    BreathPhaseKind.exhale || BreathPhaseKind.rest => 0.0,
    BreathPhaseKind.holdIn => 1.0,
    BreathPhaseKind.holdOut => 0.0,
  };

  bool get isHold =>
      this == BreathPhaseKind.holdIn || this == BreathPhaseKind.holdOut;
}

@immutable
class BreathPhase {
  const BreathPhase(this.kind, this.seconds);
  final BreathPhaseKind kind;
  final double seconds;
}

/// One cycle of a repeating protocol.
@immutable
class BreathPattern {
  const BreathPattern({
    required this.key,
    required this.label,
    required this.description,
    required this.phases,
    this.coherenceRated = false,
  });

  final String key;
  final String label;

  /// One line on the picker. Says what it is FOR, not what it does — the phase
  /// counts are already visible.
  final String description;
  final List<BreathPhase> phases;

  /// Whether a cardiac-coherence score is meaningful for this pattern.
  ///
  /// Only true for resonance breathing. Coherence measures how strongly heart
  /// rate oscillates AT THE PACED FREQUENCY, which is the entire point of
  /// resonance work and is not what box breathing or 4-7-8 are trying to do.
  /// Scoring them against it would grade them on someone else's exam.
  final bool coherenceRated;

  double get cycleSeconds =>
      phases.fold(0.0, (a, p) => a + p.seconds);

  /// Breaths per minute.
  double get rate => 60.0 / cycleSeconds;

  /// The paced frequency in Hz, for the coherence estimator.
  double get pacedHz => 1.0 / cycleSeconds;
}

/// Resonance breathing at ~5.5 breaths/min. The original, and the only one
/// with a coherence score attached.
const _resonance = BreathPattern(
  key: 'resonance',
  label: 'Resonance',
  description: 'Even in and out at about 5.5 breaths a minute. The one with a '
      'coherence score.',
  phases: [
    BreathPhase(BreathPhaseKind.inhale, 5.45),
    BreathPhase(BreathPhaseKind.exhale, 5.45),
  ],
  coherenceRated: true,
);

const kBreathPatterns = <BreathPattern>[
  _resonance,
  BreathPattern(
    key: 'box',
    label: 'Box',
    description: 'Four counts each way, holds included. Steadying when your '
        'head is racing.',
    phases: [
      BreathPhase(BreathPhaseKind.inhale, 4),
      BreathPhase(BreathPhaseKind.holdIn, 4),
      BreathPhase(BreathPhaseKind.exhale, 4),
      BreathPhase(BreathPhaseKind.holdOut, 4),
    ],
  ),
  BreathPattern(
    key: 'four_seven_eight',
    label: '4-7-8',
    description: 'A long hold and a longer exhale. Usually used to get to '
        'sleep.',
    phases: [
      BreathPhase(BreathPhaseKind.inhale, 4),
      BreathPhase(BreathPhaseKind.holdIn, 7),
      BreathPhase(BreathPhaseKind.exhale, 8),
    ],
  ),
  BreathPattern(
    key: 'extended_exhale',
    label: 'Long exhale',
    description: 'Out for twice as long as in. No holds, so it is easy to keep '
        'up for a while.',
    phases: [
      BreathPhase(BreathPhaseKind.inhale, 4),
      BreathPhase(BreathPhaseKind.exhale, 8),
    ],
  ),
];

final Map<String, BreathPattern> kBreathPatternsByKey = {
  for (final p in kBreathPatterns) p.key: p,
};

/// Where a repeating [pattern] is at [elapsed], and how far through that phase.
///
/// Returns null for a non-positive cycle, which would otherwise divide by zero
/// — reachable only from a malformed pattern, but this runs every frame.
({BreathPhase phase, double progress, int cycle})? phaseAt(
  BreathPattern pattern,
  Duration elapsed,
) {
  final cycle = pattern.cycleSeconds;
  if (cycle <= 0 || pattern.phases.isEmpty) return null;
  final t = elapsed.inMicroseconds / 1e6;
  if (t < 0) return null;
  final cycleIndex = (t / cycle).floor();
  var within = t - cycleIndex * cycle;
  for (final phase in pattern.phases) {
    if (within < phase.seconds) {
      return (
        phase: phase,
        progress: phase.seconds <= 0 ? 1.0 : within / phase.seconds,
        cycle: cycleIndex,
      );
    }
    within -= phase.seconds;
  }
  // Floating-point drift can land a hair past the last phase.
  return (phase: pattern.phases.last, progress: 1.0, cycle: cycleIndex);
}

/// An interval timer expressed as a [BreathPattern], so it runs on the same
/// engine — boxing rounds, HIIT, rest between sets.
BreathPattern intervalPattern({
  required Duration work,
  required Duration rest,
}) => BreathPattern(
  key: 'interval',
  label: 'Interval',
  description: 'Work and rest, buzzed at each change.',
  phases: [
    BreathPhase(BreathPhaseKind.work, work.inMilliseconds / 1000),
    if (rest > Duration.zero)
      BreathPhase(BreathPhaseKind.rest, rest.inMilliseconds / 1000),
  ],
);

/// Elapsed time at which a session of [rounds] cycles ends, or null for an
/// open-ended one.
Duration? sessionEnd(BreathPattern pattern, int? rounds) {
  if (rounds == null || rounds <= 0) return null;
  return Duration(
    microseconds: (pattern.cycleSeconds * rounds * 1e6).round(),
  );
}
