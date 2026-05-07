import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/api.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/score_ring.dart';

final _todayProvider = FutureProvider.autoDispose((ref) =>
    ref.read(apiProvider).insightsToday());

class RecoveryScreen extends ConsumerWidget {
  const RecoveryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(_todayProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_todayProvider);
        await ref.read(_todayProvider.future);
      },
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          today.when(
            loading: () => const _Skeleton(),
            error: (e, _) => _ErrBox(e.toString()),
            data: (data) {
              final recovery = data['recovery'] as Map<String, dynamic>?;
              final score = recovery?['score'] != null
                  ? (recovery!['score'] as num).toDouble()
                  : null;
              final hrv = recovery?['hrv'] != null
                  ? (recovery!['hrv'] as num).toDouble()
                  : null;
              final resp = recovery?['resp_rate'] != null
                  ? (recovery!['resp_rate'] as num).toDouble()
                  : null;

              return Column(
                children: [
                  const SizedBox(height: 12),
                  const Text('TODAY',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          color: WTheme.textMuted,
                          fontSize: 11,
                          letterSpacing: 2)),
                  const SizedBox(height: 16),
                  Center(
                    child: ScoreRing(
                      value: score ?? 0,
                      label: score != null ? (score * 100).toStringAsFixed(0) : '—',
                      unit: score != null ? '%' : '',
                      caption: 'RECOVERY',
                      size: 240,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    score == null
                        ? 'Awaiting nightly worker · runs 06:00 UTC'
                        : _commentaryFor(score),
                    style: const TextStyle(
                        fontFamily: 'monospace', color: WTheme.textDim, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.7,
                    children: [
                      StatTile(
                        label: 'HRV (rMSSD)',
                        value: hrv != null ? hrv.toStringAsFixed(0) : '—',
                        unit: 'ms',
                        icon: Icons.show_chart,
                        valueColor: hrv != null && hrv >= 30 ? WTheme.accent : WTheme.warn,
                      ),
                      StatTile(
                        label: 'RESP RATE',
                        value: resp != null ? resp.toStringAsFixed(1) : '—',
                        unit: 'br/min',
                        icon: Icons.air,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const SectionLabel('HOW THIS IS COMPUTED'),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text('recovery = 0.5·sleep + 0.3·hrv + 0.2·rhr',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                color: WTheme.accent,
                                fontSize: 12)),
                        SizedBox(height: 12),
                        Text(
                          'Sleep — efficiency × duration vs 8 h target.\n'
                          'HRV — rMSSD during sleep, capped at 60 ms.\n'
                          'RHR — resting HR vs 50-bpm baseline.\n'
                          'Updated nightly at 06:00 UTC. Open-source. Tunable in src/scheduled/nightly.ts.',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              color: WTheme.textDim,
                              fontSize: 11,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _commentaryFor(double score) {
    if (score >= 0.7) return 'Primed. Push hard if you want.';
    if (score >= 0.5) return 'Solid. Train normally.';
    if (score >= 0.3) return 'Yellow. Easy day or active recovery.';
    return 'Low. Rest, hydrate, sleep early.';
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 320,
        child: Center(child: CircularProgressIndicator(color: WTheme.accent)),
      );
}

class _ErrBox extends StatelessWidget {
  final String e;
  const _ErrBox(this.e);
  @override
  Widget build(BuildContext context) => GlassCard(
        background: WTheme.danger.withValues(alpha: 0.1),
        child: Text(e,
            style: const TextStyle(
                fontFamily: 'monospace', color: WTheme.danger, fontSize: 12)),
      );
}
