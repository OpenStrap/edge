// Guided resonance breathing — a paced-breathing circle (5.5 breaths/min,
// the classic HRV-resonance pace) with a REAL cardiac-coherence readout.
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

class CalmBreathingScreen extends StatelessWidget {
  const CalmBreathingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return CalmBreathingView(
      connected: app.isConnected,
      active: app.breathingActive,
      result: app.breathingResult,
      error: app.breathingError,
      onStart: app.startBreathingSession,
      onStop: app.stopBreathingSession,
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
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onBack;

  const CalmBreathingView({
    super.key,
    required this.connected,
    required this.active,
    this.result,
    this.error,
    this.onStart,
    this.onStop,
    this.onBack,
  });

  @override
  State<CalmBreathingView> createState() => _CalmBreathingViewState();
}

class _CalmBreathingViewState extends State<CalmBreathingView>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  String _phaseText = "Inhale";

  @override
  void initState() {
    super.initState();
    // A standard resonance frequency is ~5.5 breaths per minute.
    // 5.5 breaths/min = ~10.9 seconds per breath cycle.
    // So 5.45 seconds inhale, 5.45 seconds exhale.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5450),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _phaseText = "Exhale");
        _controller.reverse();
      } else if (status == AnimationStatus.dismissed) {
        setState(() => _phaseText = "Inhale");
        _controller.forward();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CalmBreathingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _controller.forward();
    } else if (!widget.active && oldWidget.active) {
      _controller.stop();
      _controller.value = 0.0;
      setState(() => _phaseText = "Inhale");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasResult => widget.result?['ok'] == true;
  // Coherence isn't a published 0-100 scale (see cardiacCoherence's own
  // honesty note) — this threshold is a display choice, not a cited boundary.
  bool _isGood(num score) => score > 60;

  @override
  Widget build(BuildContext context) {
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
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Resonance Breathing',
            style: AppText.h2,
          ),
          const SizedBox(height: Sp.x2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x8),
            child: Text(
              'Sync your breath with the circle to maximize your HRV and lower sympathetic stress.',
              style: AppText.bodySoft,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 64),
          Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // Scale from 1.0 to 2.0
                final scale = 1.0 + (_controller.value * 1.0);
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: DomainAccent.recovery.withValues(alpha: 0.2 + (_controller.value * 0.3)),
                      border: Border.all(
                        color: DomainAccent.recovery,
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Transform.scale(
                      scale: 1.0 / scale, // keep text unscaled
                      child: Text(
                        widget.active ? _phaseText : "Ready",
                        style: AppText.h2.copyWith(
                          color: DomainAccent.recovery,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 64),
          if (widget.active) ...[
            Text(
              'Coherence Score',
              style: AppText.caption,
            ),
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
              // Honest: no fabricated number until enough clean live RR has
              // accumulated (first recompute lands ~20s in — see AppState's
              // _breathingRecomputeInterval).
              Text(
                'Calibrating…',
                style: AppText.h2.copyWith(color: AppColors.inkMuted),
              ),
            const SizedBox(height: Sp.x8),
            OutlinedButton(
              onPressed: widget.onStop,
              child: const Text('Stop Session'),
            ),
          ] else ...[
            FilledButton(
              onPressed: widget.connected ? widget.onStart : null,
              child: const Text('Begin 2-Minute Session'),
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
    );
  }
}
