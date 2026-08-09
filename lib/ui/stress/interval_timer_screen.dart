// Interval timer — boxing rounds, HIIT, rest between sets.
//
// Runs on the same phase engine as paced breathing (breath_phases.dart),
// because they are the same problem: a repeating sequence of named, timed
// phases with something to do at each boundary. The strap buzzing at each
// change is the entire reason this belongs in this app rather than being any
// of the hundred timer apps — you do not have to look at the phone.
//
// Deliberately NOT a workout. It records nothing and starts no session: an
// auto-detected effort or a manually started workout already covers that, and
// a timer that quietly created sessions would double-count every round.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../design/design.dart';
import '../../gps/screen_wake.dart';
import 'breath_phases.dart';

/// Work-interval choices, in seconds.
const _workChoices = <int>[20, 30, 45, 60, 120, 180];

/// Rest choices. Zero means continuous rounds with a buzz at each boundary.
const _restChoices = <int>[0, 10, 15, 30, 60];

/// Round counts. Null runs until stopped.
const _roundChoices = <int?>[3, 5, 8, 12, null];

class IntervalTimerScreen extends StatefulWidget {
  const IntervalTimerScreen({super.key});

  @override
  State<IntervalTimerScreen> createState() => _IntervalTimerScreenState();
}

class _IntervalTimerScreenState extends State<IntervalTimerScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final _clock = Stopwatch();

  int _work = 180;
  int _rest = 60;
  int? _rounds = 3;
  bool _running = false;

  BreathPhaseKind? _lastPhase;
  int _lastCycle = -1;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick);
  }

  @override
  void dispose() {
    // Releasing here as well as in _stop: popping the screen mid-round never
    // called _stop, so the wake lock leaked and the phone stayed awake until
    // something else happened to release it.
    if (_running) ScreenWake.release();
    _ticker
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  BreathPattern get _pattern => intervalPattern(
    work: Duration(seconds: _work),
    rest: Duration(seconds: _rest),
  );

  Duration? get _sessionEnd => sessionEnd(_pattern, _rounds);

  void _start() {
    setState(() {
      _running = true;
      _lastPhase = null;
      _lastCycle = -1;
    });
    _clock
      ..reset()
      ..start();
    _ticker.repeat();
    // The keep-awake is the difference between a timer you can use and one
    // that dies mid-round because the screen locked.
    ScreenWake.enable();
  }

  void _stop() {
    _ticker.stop();
    _clock.stop();
    ScreenWake.release();
    if (mounted) setState(() => _running = false);
  }

  void _onTick() {
    if (!_running) return;
    final elapsed = _clock.elapsed;
    final end = _sessionEnd;
    if (end != null && elapsed >= end) {
      // A DISTINCT pattern, not three of the ordinary one. Three identical
      // haptic frames land back-to-back at GATT speed and re-trigger the
      // firmware mid-playback, so they are felt as a single buzz —
      // indistinguishable from the phase cue they were meant to be different
      // from.
      context.read<AppState>().buzzSessionComplete();
      _stop();
      return;
    }
    final at = phaseAt(_pattern, elapsed);
    if (at != null &&
        (at.phase.kind != _lastPhase || at.cycle != _lastCycle)) {
      _lastPhase = at.phase.kind;
      _lastCycle = at.cycle;
      context.read<AppState>().buzzBreathPhase(at.phase.kind);
    }
    setState(() {});
  }

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 86400);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final connected = context.select<AppState, bool>((a) => a.isConnected);
    final elapsed = _clock.elapsed;
    final at = _running ? phaseAt(_pattern, elapsed) : null;
    final kind = at?.phase.kind;
    final phaseLeft = at == null
        ? null
        : Duration(
            milliseconds:
                ((at.phase.seconds * (1 - at.progress)) * 1000).round(),
          );

    return AppScaffold(
      title: 'Interval timer',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          Sp.screen,
          Sp.x4,
          Sp.screen,
          dsBottomGutter(context),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_running) ...[
              Center(
                child: Text(
                  kind?.label ?? '',
                  style: AppText.h2.copyWith(
                    color: kind == BreathPhaseKind.rest
                        ? AppColors.inkSoft
                        : AppColors.accent,
                  ),
                ),
              ),
              const SizedBox(height: Sp.x3),
              Center(
                child: Text(
                  _fmt(phaseLeft ?? Duration.zero),
                  style: AppText.h1.copyWith(fontSize: 72),
                ),
              ),
              const SizedBox(height: Sp.x3),
              Center(
                child: Text(
                  _rounds == null
                      ? 'Round ${(at?.cycle ?? 0) + 1}'
                      : 'Round ${(at?.cycle ?? 0) + 1} of $_rounds',
                  style: AppText.bodySoft,
                ),
              ),
              const SizedBox(height: Sp.x8),
              OutlinedButton(onPressed: _stop, child: const Text('Stop')),
            ] else ...[
              _label('Work'),
              _chips(
                _workChoices.map((s) => (s, _durLabel(s))).toList(),
                _work,
                (v) => setState(() => _work = v),
              ),
              const SizedBox(height: Sp.x4),
              _label('Rest'),
              _chips(
                _restChoices
                    .map((s) => (s, s == 0 ? 'None' : _durLabel(s)))
                    .toList(),
                _rest,
                (v) => setState(() => _rest = v),
              ),
              const SizedBox(height: Sp.x4),
              _label('Rounds'),
              _chips(
                _roundChoices.map((r) => (r, r?.toString() ?? 'Open')).toList(),
                _rounds,
                (v) => setState(() => _rounds = v),
              ),
              const SizedBox(height: Sp.x6),
              FilledButton(
                onPressed: connected ? _start : null,
                child: const Text('Start'),
              ),
              const SizedBox(height: Sp.x3),
              Text(
                connected
                    ? 'Your strap buzzes at every change, so you can leave the '
                          'phone alone. Nothing is recorded — start a workout '
                          'if you want the session logged.'
                    : 'Connect your band — the buzz is the point.',
                style: AppText.captionMuted,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _durLabel(int seconds) => seconds < 60
      ? '${seconds}s'
      : (seconds % 60 == 0 ? '${seconds ~/ 60}m' : '${seconds ~/ 60}m ${seconds % 60}s');

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.x2),
    child: Text(text, style: AppText.label.copyWith(color: AppColors.inkSoft)),
  );

  Widget _chips<T>(
    List<(T, String)> options,
    T selected,
    ValueChanged<T> onPick,
  ) => Wrap(
    spacing: Sp.x2,
    runSpacing: Sp.x2,
    children: [
      for (final o in options)
        ToggleChip(
          o.$2,
          selected: selected == o.$1,
          onTap: () => onPick(o.$1),
        ),
    ],
  );
}
