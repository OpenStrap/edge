// Spot check — an on-demand ~60s live HRV reading. Enables wrist-gated optical +
// realtime records, collects beat-to-beat RR, and computes HRV on-device. Honest:
// a quick snapshot, not your nightly recovery (that's measured over a full sleep).
//
// On the design language: one recovery-green ArcGauge hero (countdown while
// scanning, the RMSSD when done), the result numbers as a bento, guidance as a
// quiet card, and the snapshot honesty behind the (i). Measurement logic lives
// in AppState — this file is presentation only.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../design/design.dart';

class SpotCheckScreen extends StatelessWidget {
  const SpotCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final active = app.spotActive;
    final remaining = app.spotRemaining;
    return SpotCheckView(
      connected: app.isConnected,
      active: active,
      remaining: remaining,
      progress: active
          ? (AppState.spotDuration - remaining) / AppState.spotDuration
          : 0.0,
      liveHr: app.device.liveHr,
      result: app.spotResult,
      error: app.spotError,
      onStart: app.startSpotCheck,
      onCancel: app.cancelSpotCheck,
      onBack: () {
        if (app.spotActive) app.cancelSpotCheck();
        Navigator.of(context).maybePop();
      },
    );
  }
}

/// The pure spot-check board — testable with plain values, no AppState.
class SpotCheckView extends StatelessWidget {
  final bool connected;
  final bool active;
  final int remaining;
  final double progress;
  final int? liveHr;
  final Map? result;
  final String? error;
  final VoidCallback? onStart;
  final VoidCallback? onCancel;
  final VoidCallback? onBack;

  const SpotCheckView({
    super.key,
    required this.connected,
    required this.active,
    this.remaining = 0,
    this.progress = 0,
    this.liveHr,
    this.result,
    this.error,
    this.onStart,
    this.onCancel,
    this.onBack,
  });

  bool get _hasResult => result?['ok'] == true;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Spot check',
      subtitle: 'A 60-second live HRV read',
      onBack: onBack,
      actions: [
        InfoDot(
          title: 'Spot check',
          body:
              'A snapshot of your current state from one minute of live '
              'beat-to-beat heart data. Your daily recovery is measured over '
              'a full night of sleep and is more reliable for trends.',
          bullets: const [
            'Sit still, band snug, breathe normally.',
            'Movement adds noise to the reading.',
          ],
          methodNote: 'RMSSD over ~60 s of live RR intervals',
        ),
      ],
      children: [
        const SizedBox(height: Sp.x5),
        Center(child: _gauge()).dsEnter(index: 0),
        const SizedBox(height: Sp.x5),
        if (active)
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Row(
              children: [
                AppIcon(OsIcon.info, size: 16, color: DomainAccent.recovery),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Text(
                    'Keep the band snug and sit still. Breathe normally — '
                    'movement adds noise to the reading.',
                    style: AppText.captionMuted,
                  ),
                ),
              ],
            ),
          ).dsEnter(index: 1)
        else if (_hasResult)
          _resultBento(result!).dsEnter(index: 1)
        else if (error != null)
          StateCard(
            icon: OsIcon.heartRate,
            title: "Couldn't get a clean read",
            message: error!,
          ).dsEnter(index: 1),
        const SizedBox(height: Sp.x5),
        if (!active)
          FilledButton.icon(
            onPressed: connected ? onStart : null,
            icon: const AppIcon(OsIcon.heartRate, size: 18, color: Colors.white),
            label: Text(result == null ? 'Start 60-second scan' : 'Scan again'),
          ).dsEnter(index: 2)
        else
          OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
        if (!connected && !active) ...[
          const SizedBox(height: Sp.x3),
          Text(
            'Connect your band to run a spot check.',
            style: AppText.captionMuted,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: Sp.x8),
      ],
    );
  }

  // ── the one ring: countdown while scanning, else the last RMSSD / a prompt ──
  Widget _gauge() {
    final color = DomainAccent.recovery;
    if (active) {
      return ArcGauge(
        value: progress.clamp(0.0, 1.0),
        color: color,
        size: 200,
        stroke: 15,
        endDot: true,
        animate: false, // scrub-driven by the countdown
        center: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$remaining', style: AppText.metric.copyWith(fontSize: 44)),
            Text('SECONDS',
                style: AppText.overline.copyWith(color: AppColors.inkMuted)),
            if (liveHr != null && liveHr! > 0) ...[
              const SizedBox(height: Sp.x1),
              Text('$liveHr bpm live', style: AppText.captionMuted),
            ],
          ],
        ),
      );
    }
    if (_hasResult) {
      return ArcGauge(
        value: 1.0,
        color: color,
        size: 200,
        stroke: 15,
        center: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${result!['rmssd']}',
                style: AppText.metric.copyWith(fontSize: 44)),
            Text('MS RMSSD',
                style: AppText.overline.copyWith(color: AppColors.inkMuted)),
          ],
        ),
      );
    }
    return ArcGauge(
      value: double.nan, // honest empty ring
      color: color,
      size: 200,
      stroke: 15,
      center: AppIcon(OsIcon.heartRate, size: 52, color: AppColors.inkMuted),
    );
  }

  // ── result numbers as a bento ────────────────────────────────────────────────
  Widget _resultBento(Map r) {
    Widget tile(String label, Object? v, String unit,
        {BentoTone tone = BentoTone.paper}) {
      return BentoTile(
        tone: tone,
        accent: DomainAccent.recovery,
        child: BigStat(
          value: v?.toString(),
          unit: unit.isEmpty ? null : unit,
          label: label,
          size: BigStatSize.md,
        ),
      );
    }

    return BentoColumns(
      entrance: false,
      left: [
        tile('RMSSD', r['rmssd'], 'ms', tone: BentoTone.soft),
        if (r['pnn50'] != null) tile('pNN50', r['pnn50'], '%'),
        if (r['n_beats'] != null) tile('Beats analysed', r['n_beats'], ''),
      ],
      right: [
        if (r['sdnn'] != null) tile('SDNN', r['sdnn'], 'ms'),
        if (r['mean_hr'] != null) tile('Mean HR', r['mean_hr'], 'bpm'),
      ],
    );
  }
}
