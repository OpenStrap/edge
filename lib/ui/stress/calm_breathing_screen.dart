// Guided paced breathing — a breathing circle with a REAL cardiac-coherence
// readout, four patterns, a session that actually ends, and a strap that
// buzzes each phase change so you can shut your eyes.
//
// The circle is driven by the shared phase engine (breath_phases.dart), the
// same one behind the interval timer: both are a repeating sequence of named,
// timed phases with something to do at each boundary.
//
// The coherence score is computed on-device from live beat-to-beat RR
// (McCraty & Zayas 2014 — see openstrap_analytics's cardiacCoherence) via
// AppState.startBreathingSession/breathingResult — never fabricated. Before
// enough clean live data has accumulated, the screen honestly says so
// ("Calibrating…") instead of showing a placeholder number.
//
// Container (this file's CalmBreathingScreen) wires Provider; CalmBreathingView
// is the pure, testable presentation — the breathing-circle animation is
// local UI state (just paces the visual), the score is a prop.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../design/design.dart';
import 'breath_phases.dart';

class CalmBreathingScreen extends StatelessWidget {
  /// Auto-begin the session the moment this screen mounts — used when opened
  /// via the "start breathing" Siri/Shortcuts App Intent, where the spoken
  /// command already IS the "start" action. The normal in-app entry point
  /// (Stress screen's own button) leaves this false and shows the Ready state.
  final bool autoStart;

  const CalmBreathingScreen({super.key, this.autoStart = false});

  @override
  Widget build(BuildContext context) {
    // Was context.watch<AppState>() — select the 4 fields actually rendered
    // instead of rebuilding on all 67 notifyListeners() sources.
    context.select<AppState, (bool, bool, Map<String, dynamic>?, String?)>(
      (a) => (a.isConnected, a.breathingActive, a.breathingResult, a.breathingError),
    );
    // Also watched: a view that mounts mid-session needs the session's own
    // start and target, not the picker's defaults.
    context.select<AppState, (DateTime?, Duration?)>(
      (a) => (a.breathingStartedAt, a.breathingTarget),
    );
    final app = context.read<AppState>();
    if (autoStart && !app.breathingActive && app.isConnected) {
      // Guarded by breathingActive so this only ever fires once per mount —
      // startBreathingSession() flips breathingActive true and notifies,
      // which rebuilds this widget and short-circuits the guard.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!app.breathingActive) app.startBreathingSession();
      });
    }
    return CalmBreathingView(
      connected: app.isConnected,
      active: app.breathingActive,
      result: app.breathingResult,
      error: app.breathingError,
      pattern: app.breathingPattern,
      startedAt: app.breathingStartedAt,
      target: app.breathingTarget,
      onStart: app.startBreathingSession,
      onStop: app.stopBreathingSession,
      // Buzzing the strap is what makes this usable with your eyes closed,
      // which is the whole point of a breathing exercise you are not supposed
      // to be staring at a phone during.
      onPhaseChange: app.buzzBreathPhase,
      onBack: () {
        if (app.breathingActive) app.stopBreathingSession();
        Navigator.of(context).maybePop();
      },
    );
  }
}

/// The pure breathing board — testable with plain values, no AppState.
class CalmBreathingView extends StatefulWidget {
  final bool connected;
  final bool active;
  final Map? result;
  final String? error;

  /// The pattern being paced. Null falls back to resonance, which is what this
  /// screen has always run and the only one carrying a coherence score.
  final BreathPattern? pattern;
  final void Function({BreathPattern? pattern, Duration? target})? onStart;
  final VoidCallback? onStop;

  /// Called once per phase boundary, to buzz the strap.
  final ValueChanged<BreathPhaseKind>? onPhaseChange;

  /// When the RUNNING session began, and what it was asked to run for.
  ///
  /// Authoritative, and owned by the session rather than by this view, because
  /// the view is remounted every time someone leaves the screen and comes
  /// back. Timing from a local stopwatch restarted the pacing from zero on
  /// re-entry and reverted the length to the default, so a five-minute session
  /// re-entered at 4:00 showed 2:00 and stopped almost immediately.
  final DateTime? startedAt;
  final Duration? target;
  final VoidCallback? onBack;

  const CalmBreathingView({
    super.key,
    required this.connected,
    required this.active,
    this.result,
    this.error,
    this.pattern,
    this.onStart,
    this.onStop,
    this.onPhaseChange,
    this.startedAt,
    this.target,
    this.onBack,
  });

  @override
  State<CalmBreathingView> createState() => _CalmBreathingViewState();
}

/// Resonance, the pace this screen has always run — the table's own entry, not
/// a copy of it. A duplicate would drift on any future edit, and its empty
/// description rendered a blank line on the idle screen.
final BreathPattern _defaultPattern = kBreathPatterns.first;

/// Session lengths offered. "Open" runs until you stop it.
const _durationChoices = <int?>[2, 5, 10, null];

class _CalmBreathingViewState extends State<CalmBreathingView>
    with SingleTickerProviderStateMixin {
  /// Drives the circle. Its VALUE is ignored — the phase engine decides what
  /// is happening; this just gives us a per-frame tick.
  late AnimationController _ticker;

  /// Fallback start for a view driven without an authoritative one (the pure
  /// widget tests). The session's own start wins whenever it is known.
  DateTime? _localStart;

  /// Chosen before starting.
  BreathPattern _pattern = _defaultPattern;
  int? _minutes = 2;

  BreathPhaseKind? _lastPhase;
  int _lastCycle = -1;

  /// One-shot, because `onStop` is asynchronous. Without it every frame between
  /// the timer expiring and the parent flipping `active` false fired another
  /// stop — sixty of them a second, each one banking a session row.
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _pattern = widget.pattern ?? _defaultPattern;
    // A repeating controller used purely as a frame ticker, so the circle is
    // interpolated from real elapsed time rather than from an animation whose
    // own duration would have to be kept in sync with the pattern.
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick);
    // AFTER the ticker exists — `_begin` repeats it. Started here, not only on
    // the false→true edge in didUpdateWidget: a session survives leaving the
    // screen (swipe-back and system back never reach `onBack`, which is the
    // only thing that stops it), so re-entering mounts a fresh view with
    // `active` ALREADY true and no edge to catch. The whole session lifecycle
    // hangs off this clock, so missing it left a frozen circle, no haptics,
    // and a timed session that never ended.
    if (widget.active) _begin();
  }

  @override
  void didUpdateWidget(covariant CalmBreathingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _begin();
    } else if (!widget.active && oldWidget.active) {
      _ticker.stop();
      _localStart = null;
      setState(() {});
    }
  }

  void _begin() {
    _lastPhase = null;
    _lastCycle = -1;
    _finished = false;
    // Only when the session cannot tell us — otherwise a remount would reset
    // the clock and restart the session's timing from zero.
    _localStart ??= DateTime.now();
    _ticker.repeat();
  }

  @override
  void dispose() {
    _ticker
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  Duration get _elapsed {
    final from = widget.startedAt ?? _localStart;
    return from == null ? Duration.zero : DateTime.now().difference(from);
  }

  /// The running session's target wins over the picker, which is only a draft
  /// until Begin is pressed and reverts to its default on a remount.
  ///
  /// Keyed on [CalmBreathingView.startedAt], NOT on the target being non-null:
  /// a null target on a running session means OPEN-ENDED, and treating that as
  /// "no answer" fell through to the picker's two minutes — so an open session
  /// remounted showed a countdown it never had and stopped at 2:00.
  Duration? get _target {
    if (widget.startedAt != null) return widget.target;
    return _minutes == null ? null : Duration(minutes: _minutes!);
  }

  Duration? get _remaining {
    final t = _target;
    return t == null ? null : t - _elapsed;
  }

  void _onTick() {
    if (!widget.active || _finished) return;
    // Expiry FIRST. The Stopwatch keeps counting while the app is suspended
    // but the ticker does not, so the first tick after a resume can be long
    // past the end — buzzing on the way out would be a startling cue for a
    // session that is already over.
    final remaining = _remaining;
    if (remaining != null && remaining <= Duration.zero) {
      // The button said two minutes, so two minutes is what it runs. It used
      // to say that and run until you stopped it.
      _finished = true;
      _ticker.stop();
      widget.onStop?.call();
      return;
    }
    final at = phaseAt(_pattern, _elapsed);
    if (at != null) {
      final changed = at.phase.kind != _lastPhase || at.cycle != _lastCycle;
      if (changed) {
        _lastPhase = at.phase.kind;
        _lastCycle = at.cycle;
        widget.onPhaseChange?.call(at.phase.kind);
      }
    }
    setState(() {});
  }

  bool get _hasResult => widget.result?['ok'] == true;
  // Coherence isn't a published 0-100 scale (see cardiacCoherence's own
  // honesty note) — this threshold is a display choice, not a cited boundary.
  bool _isGood(num score) => score > 60;

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 86400);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.active ? phaseAt(_pattern, _elapsed) : null;
    final kind = at?.phase.kind;
    // A hold holds the circle where it was, rather than continuing to move and
    // silently telling you to keep breathing.
    final progress = at == null
        ? 0.0
        : (kind!.isHold ? kind.targetScale : _scaleFor(kind, at.progress));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, size: 24),
          onPressed: widget.onBack,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Sp.x6),
        child: Column(
          children: [
            Text(_pattern.label, style: AppText.h2),
            const SizedBox(height: Sp.x2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.x8),
              child: Text(
                widget.active
                    ? 'Follow the circle. Your strap buzzes each change, so '
                          'you can close your eyes.'
                    : _pattern.description,
                style: AppText.bodySoft,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: Sp.x8),
            Center(child: _circle(progress, kind)),
            const SizedBox(height: Sp.x8),
            if (widget.active) ...[
              if (_remaining != null)
                Text(
                  _fmt(_remaining!),
                  style: AppText.h2.copyWith(color: AppColors.inkSoft),
                )
              else
                Text(_fmt(_elapsed), style: AppText.h2.copyWith(
                  color: AppColors.inkSoft,
                )),
              const SizedBox(height: Sp.x5),
              if (_pattern.coherenceRated) ...[
                Text('Coherence Score', style: AppText.caption),
                const SizedBox(height: Sp.x2),
                if (_hasResult)
                  Text(
                    '${(widget.result!['score'] as num).round()}%',
                    style: AppText.h1.copyWith(
                      color: _isGood(widget.result!['score'] as num)
                          ? AppColors.good
                          : AppColors.warn,
                    ),
                  )
                else
                  // Honest: no fabricated number until enough clean live RR
                  // has accumulated (first recompute lands ~20s in).
                  Text(
                    'Calibrating…',
                    style: AppText.h2.copyWith(color: AppColors.inkMuted),
                  ),
              ] else
                // Coherence measures oscillation at the RESONANCE frequency.
                // Scoring the other patterns against it would grade them on an
                // exam they are not sitting.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.x8),
                  child: Text(
                    'No coherence score for this pattern — it only means '
                    'something for resonance breathing.',
                    style: AppText.captionMuted,
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: Sp.x8),
              OutlinedButton(
                onPressed: widget.onStop,
                child: const Text('Stop Session'),
              ),
            ] else ...[
              _patternPicker(),
              const SizedBox(height: Sp.x5),
              _durationPicker(),
              const SizedBox(height: Sp.x6),
              FilledButton(
                onPressed: widget.connected
                    ? () => widget.onStart?.call(
                        pattern: _pattern,
                        target: _target,
                      )
                    : null,
                child: Text(
                  _minutes == null
                      ? 'Begin'
                      : 'Begin $_minutes-Minute Session',
                ),
              ),
              if (!widget.connected || widget.error != null) ...[
                const SizedBox(height: Sp.x3),
                Text(
                  widget.error ?? 'Connect your band to start a session.',
                  style: AppText.captionMuted,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 0 at rest, 1 fully expanded.
  double _scaleFor(BreathPhaseKind kind, double progress) => switch (kind) {
    BreathPhaseKind.inhale || BreathPhaseKind.work => progress,
    BreathPhaseKind.exhale || BreathPhaseKind.rest => 1 - progress,
    BreathPhaseKind.holdIn => 1,
    BreathPhaseKind.holdOut => 0,
  };

  Widget _circle(double t, BreathPhaseKind? kind) {
    final scale = 1.0 + t;
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: DomainAccent.recovery.withValues(alpha: 0.2 + (t * 0.3)),
          border: Border.all(color: DomainAccent.recovery, width: 2),
        ),
        alignment: Alignment.center,
        child: Transform.scale(
          scale: 1.0 / scale, // keep the text unscaled
          child: Text(
            widget.active ? (kind?.label ?? '') : 'Ready',
            style: AppText.h2.copyWith(color: DomainAccent.recovery),
          ),
        ),
      ),
    );
  }

  Widget _patternPicker() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Sp.x5),
    child: Wrap(
      spacing: Sp.x2,
      runSpacing: Sp.x2,
      alignment: WrapAlignment.center,
      children: [
        for (final p in kBreathPatterns)
          ToggleChip(
            p.label,
            selected: _pattern.key == p.key,
            onTap: () => setState(() => _pattern = p),
          ),
      ],
    ),
  );

  Widget _durationPicker() => Wrap(
    spacing: Sp.x2,
    runSpacing: Sp.x2,
    alignment: WrapAlignment.center,
    children: [
      for (final m in _durationChoices)
        ToggleChip(
          m == null ? 'Open' : '$m min',
          selected: _minutes == m,
          onTap: () => setState(() => _minutes = m),
        ),
    ],
  );
}
