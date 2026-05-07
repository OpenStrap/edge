import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../cloud/api.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/sleep_timeline.dart';

final _sleepProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
    (ref, date) => ref.read(apiProvider).insightsSleep(date));

class SleepScreen extends ConsumerWidget {
  const SleepScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final asyncSleep = ref.watch(_sleepProvider(today));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_sleepProvider(today));
        await ref.read(_sleepProvider(today).future);
      },
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 8),
          const Text('LAST NIGHT',
              style: TextStyle(
                  fontFamily: 'monospace',
                  color: WTheme.textMuted,
                  fontSize: 11,
                  letterSpacing: 2)),
          const SizedBox(height: 16),
          asyncSleep.when(
            loading: () => const _Skel(),
            error: (e, _) => _Err(e.toString()),
            data: (data) {
              final summary = data['summary'] as Map<String, dynamic>?;
              final stages = (data['stages'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>()
                  .map((m) => (m['stage'] as int?) ?? 0)
                  .toList();
              if (summary == null) {
                return const _Empty();
              }
              final total = summary['total_sec'] as int? ?? 0;
              final deep = summary['deep_sec'] as int? ?? 0;
              final rem = summary['rem_sec'] as int? ?? 0;
              final light = summary['light_sec'] as int? ?? 0;
              final efficiency = (summary['efficiency'] as num?)?.toDouble() ?? 0;
              final awakenings = summary['awakenings'] as int? ?? 0;

              return Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_dur(total),
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 56,
                              fontWeight: FontWeight.w800,
                              color: WTheme.accent,
                              height: 1)),
                      const SizedBox(width: 8),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text('total',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                color: WTheme.textDim,
                                fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SleepTimeline(stages: stages),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 14,
                    runSpacing: 6,
                    children: [
                      _Lg(WTheme.zoneBlue, 'Deep ${(deep / total * 100).toStringAsFixed(0)}%'),
                      _Lg(WTheme.zonePurple, 'REM ${(rem / total * 100).toStringAsFixed(0)}%'),
                      _Lg(WTheme.zoneGreen, 'Light ${(light / total * 100).toStringAsFixed(0)}%'),
                      _Lg(WTheme.danger, 'Wake'),
                    ],
                  ),
                  const SizedBox(height: 24),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.9,
                    children: [
                      StatTile(
                        label: 'EFFICIENCY',
                        value: '${(efficiency * 100).toStringAsFixed(0)}',
                        unit: '%',
                        valueColor:
                            efficiency >= 0.85 ? WTheme.accent : WTheme.warn,
                      ),
                      StatTile(
                        label: 'AWAKENINGS',
                        value: '$awakenings',
                        valueColor: awakenings <= 4 ? WTheme.accent : WTheme.warn,
                      ),
                      StatTile(
                        label: 'DEEP',
                        value: _dur(deep),
                        valueColor: WTheme.zoneBlue,
                      ),
                      StatTile(
                        label: 'REM',
                        value: _dur(rem),
                        valueColor: WTheme.zonePurple,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static String _dur(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return '${h}h ${m.toString().padLeft(2, '0')}m';
  }
}

class _Lg extends StatelessWidget {
  final Color c;
  final String t;
  const _Lg(this.c, this.t);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(t,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11, color: WTheme.textDim)),
      ]);
}

class _Skel extends StatelessWidget {
  const _Skel();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator(color: WTheme.accent)),
      );
}

class _Err extends StatelessWidget {
  final String e;
  const _Err(this.e);
  @override
  Widget build(BuildContext context) => GlassCard(
        background: WTheme.danger.withValues(alpha: 0.1),
        child: Text(e,
            style:
                const TextStyle(fontFamily: 'monospace', color: WTheme.danger, fontSize: 12)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => const GlassCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No sleep computed yet.',
                style: TextStyle(
                    fontFamily: 'monospace', color: WTheme.text, fontSize: 14)),
            SizedBox(height: 6),
            Text(
                'The nightly worker runs at 06:00 UTC. After your first night '
                'of wear, your sleep stages and recovery score will appear here.',
                style: TextStyle(
                    fontFamily: 'monospace', color: WTheme.textDim, fontSize: 11)),
          ]),
        ),
      );
}
