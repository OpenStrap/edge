// Spot check — an on-demand ~60s live HRV reading. Enables wrist-gated optical +
// realtime records, collects beat-to-beat RR, and computes HRV server-side. Honest:
// a quick snapshot, not your nightly recovery (that's measured over a full sleep).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class SpotCheckScreen extends StatelessWidget {
  const SpotCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.isConnected;
    final active = app.spotActive;
    final result = app.spotResult;
    final err = app.spotError;
    final remaining = app.spotRemaining;
    final progress = active
        ? (AppState.spotDuration - remaining) / AppState.spotDuration
        : 0.0;
    final liveHr = app.device.liveHr;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            Row(children: [
              RoundIconButton(Ic.arrowLeft, onTap: () {
                if (active) app.cancelSpotCheck();
                Navigator.of(context).pop();
              }),
              const SizedBox(width: Sp.x3),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Spot check', style: AppText.h1),
                const SizedBox(height: 4),
                Text('A quick live HRV reading', style: AppText.caption),
              ])),
            ]),
            const SizedBox(height: Sp.x8),

            // The ring: countdown while scanning, else the last RMSSD or a prompt.
            Center(child: RingStat(
              t: active ? progress.clamp(0.0, 1.0) : (result?['ok'] == true ? 1.0 : 0.0),
              color: AppColors.good, size: 200, stroke: 16,
              center: active
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('$remaining', style: AppText.display),
                      Text('seconds', style: AppText.caption),
                      if (liveHr != null && liveHr > 0) ...[
                        const SizedBox(height: 4),
                        Text('♥ $liveHr bpm', style: AppText.captionMuted),
                      ],
                    ])
                  : (result?['ok'] == true
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('${result!['rmssd']}', style: AppText.display),
                          Text('ms RMSSD', style: AppText.caption),
                        ])
                      : AppIcon(Ic.pulse, size: 56, color: AppColors.inkMuted)),
            )),
            const SizedBox(height: Sp.x8),

            if (active)
              ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Row(children: [
                AppIcon(Ic.info, size: 16, color: AppColors.coralDeep),
                const SizedBox(width: Sp.x3),
                Expanded(child: Text('Keep the band snug and sit still. Breathe normally — '
                    'movement adds noise to the reading.', style: AppText.captionMuted)),
              ])))
            else if (result?['ok'] == true) ...[
              _resultCard(result!),
            ] else if (err != null)
              ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Text(err, style: AppText.captionMuted))),

            const SizedBox(height: Sp.x6),

            if (!active)
              FilledButton.icon(
                onPressed: connected ? app.startSpotCheck : null,
                icon: const AppIcon(Ic.pulse, size: 18, color: Colors.white),
                label: Text(result == null ? 'Start 60-second scan' : 'Scan again'),
              )
            else
              OutlinedButton(onPressed: app.cancelSpotCheck, child: const Text('Cancel')),

            if (!connected && !active) ...[
              const SizedBox(height: Sp.x3),
              Text('Connect your band to run a spot check.',
                  style: AppText.captionMuted, textAlign: TextAlign.center),
            ],

            const SizedBox(height: Sp.x6),
            Text('A spot check is a snapshot of your current state. Your daily recovery '
                'is measured over a full night of sleep and is more reliable for trends.',
                style: AppText.captionMuted),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(Map r) => ProCard(child: Column(children: [
        _row('RMSSD', '${r['rmssd'] ?? '—'}', 'ms'),
        if (r['sdnn'] != null) _row('SDNN', '${r['sdnn']}', 'ms'),
        if (r['pnn50'] != null) _row('pNN50', '${r['pnn50']}', '%'),
        if (r['mean_hr'] != null) _row('Mean HR', '${r['mean_hr']}', 'bpm'),
        if (r['n_beats'] != null) _row('Beats analysed', '${r['n_beats']}', ''),
      ]));

  Widget _row(String label, String value, String unit) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: Sp.x2), child: Row(children: [
        Expanded(child: Text(label, style: AppText.body)),
        Text(unit.isEmpty ? value : '$value $unit', style: AppText.label),
      ]));
}
