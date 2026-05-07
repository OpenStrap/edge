import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/ble_service.dart';
import '../ble/live_state.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/sparkline.dart';

/// Glanceable now-screen. Big HR, status pills, sub-metrics, recent log.
class LiveScreen extends ConsumerWidget {
  const LiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(liveProvider);
    final hr = s.hr?.hr ?? 0;
    final wristStr = s.identity?.wrist.name.toUpperCase() ?? '?';
    final stateColor = _stateColor(s.state);
    final stateLabel = _stateLabel(s.state);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              StatusPill(
                  label: stateLabel,
                  color: stateColor,
                  filled: s.state == LinkState.live),
              const SizedBox(width: 8),
              if (s.batteryPct != null)
                StatusPill(
                  label: '${s.batteryPct!.toStringAsFixed(0)}%',
                  color: _batteryColor(s.batteryPct!),
                  filled: true,
                ),
              const Spacer(),
              StatusPill(
                  label: 'WRIST $wristStr',
                  color: wristStr == 'ON' ? WTheme.accent : WTheme.textMuted),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Center(
              child: Column(
                children: [
                  const Text('HEART RATE',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          letterSpacing: 2,
                          color: WTheme.textMuted)),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        hr > 0 ? '$hr' : '—',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 100,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          color: WTheme.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 18),
                        child: Text('bpm',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                color: WTheme.textDim,
                                fontSize: 14)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: SizedBox(
              height: 70,
              child: Sparkline(values: s.hrTrace, color: WTheme.accent),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2.0,
            ),
            delegate: SliverChildListDelegate([
              StatTile(
                label: 'SpO₂',
                value: s.spo2Avg > 0 ? '${s.spo2Avg}' : '—',
                unit: '%',
                icon: Icons.water_drop_outlined,
                valueColor: s.spo2Avg >= 95 ? WTheme.accent : (s.spo2Avg >= 90 ? WTheme.warn : WTheme.danger),
              ),
              StatTile(
                label: 'BATTERY',
                value: s.batteryPct != null ? s.batteryPct!.toStringAsFixed(0) : '—',
                unit: '%',
                icon: Icons.battery_full,
                valueColor: s.batteryPct != null ? _batteryColor(s.batteryPct!) : WTheme.text,
              ),
              StatTile(
                label: 'GSR',
                value: s.hr?.gsr.toString() ?? '—',
                icon: Icons.opacity,
              ),
              StatTile(
                label: 'BATCHES',
                value: '${s.ackedBatches}',
                icon: Icons.cloud_done_outlined,
              ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('IDENTITY'),
                GlassCard(
                  child: Column(
                    children: [
                      KvRow('Serial', s.identity?.serial ?? '—'),
                      KvRow('Firmware', s.identity?.firmware ?? '—'),
                      KvRow('Hardware', s.identity?.hardware ?? '—'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const SectionLabel('MOTION'),
                GlassCard(
                  child: Column(
                    children: [
                      KvRow('Accel',
                          s.hr == null ? '—' : '${s.hr!.accelX}, ${s.hr!.accelY}, ${s.hr!.accelZ}'),
                      KvRow('Gyro',
                          s.hr == null ? '—' : '${s.hr!.gyroX}, ${s.hr!.gyroY}, ${s.hr!.gyroZ}'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const SectionLabel('PPG'),
                GlassCard(
                  child: Column(
                    children: [
                      KvRow('LED drive', s.ppg?.ledDrive.toString() ?? '—'),
                      KvRow('IR / Red',
                          s.ppg == null ? '—' : '${s.ppg!.ir} / ${s.ppg!.red}'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const SectionLabel('LOG'),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: s.logs.isEmpty
                        ? [
                            const Text('—',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: WTheme.textMuted,
                                    fontSize: 11))
                          ]
                        : s.logs
                            .map((l) => Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Text(l,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          color: WTheme.textDim)),
                                ))
                            .toList(),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Color _stateColor(LinkState s) => switch (s) {
        LinkState.live => WTheme.accent,
        LinkState.handshake || LinkState.bonding => WTheme.warn,
        LinkState.disconnected || LinkState.error => WTheme.danger,
        _ => WTheme.textDim,
      };

  String _stateLabel(LinkState s) => switch (s) {
        LinkState.live => 'LIVE',
        LinkState.handshake => 'HANDSHAKE',
        LinkState.scanning => 'SCANNING',
        LinkState.connecting => 'CONNECTING',
        LinkState.bonding => 'BONDING',
        LinkState.disconnected => 'OFFLINE',
        LinkState.error => 'ERROR',
        LinkState.idle => 'IDLE',
      };

  Color _batteryColor(double pct) {
    if (pct < 15) return WTheme.danger;
    if (pct < 30) return WTheme.warn;
    return WTheme.accent;
  }
}
