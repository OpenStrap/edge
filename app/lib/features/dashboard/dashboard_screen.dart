import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/whoop_provider.dart';
import '../../core/ble/whoop_connection.dart';
import '../../theme/app_theme.dart';
import 'widgets/hr_ring.dart';
import 'widgets/metric_tile.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(whoopStateProvider);

    return stateAsync.when(
      loading: () => const Scaffold(
        backgroundColor: WhoopColors.background,
        body: Center(child: CircularProgressIndicator(color: WhoopColors.primary)),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: WhoopColors.background,
        body: Center(
          child: Text(e.toString(),
              style: const TextStyle(color: WhoopColors.textSecondary)),
        ),
      ),
      data: (state) {
        if (!state.isConnected && !state.isLive) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) context.go('/scan');
          });
        }

        return Scaffold(
          backgroundColor: WhoopColors.background,
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                _buildAppBar(context, ref, state),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      Center(child: HrRing(heartRate: state.heartRate)),
                      const SizedBox(height: 32),

                      _buildMetricsGrid(state),
                      const SizedBox(height: 16),

                      _buildStatusRow(state),
                      const SizedBox(height: 28),

                      // Backend insights section
                      if (state.insights != null || state.backendOnline) ...[
                        _SectionLabel(
                          label: 'INSIGHTS',
                          trailing: _BackendDot(online: state.backendOnline),
                        ),
                        const SizedBox(height: 12),
                        _InsightsCard(
                          insights: state.insights,
                          backendOnline: state.backendOnline,
                        ),
                        const SizedBox(height: 28),
                      ],

                      // HR history chart
                      if (state.hrHistory.length >= 4) ...[
                        const _SectionLabel(label: 'HEART RATE HISTORY'),
                        const SizedBox(height: 12),
                        _HrChart(history: state.hrHistory),
                        const SizedBox(height: 28),
                      ],

                      // PPG optical section
                      if (state.lastR21 != null) ...[
                        const _SectionLabel(label: 'PPG OPTICAL'),
                        const SizedBox(height: 12),
                        _buildOpticalRow(state),
                        const SizedBox(height: 28),
                      ],

                      // Device info
                      const _SectionLabel(label: 'DEVICE'),
                      const SizedBox(height: 12),
                      _buildDeviceInfo(state),
                      const SizedBox(height: 16),

                      _buildActions(context, ref, state),
                      const SizedBox(height: 24),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  SliverAppBar _buildAppBar(
      BuildContext context, WidgetRef ref, WhoopConnectionState state) {
    return SliverAppBar(
      backgroundColor: WhoopColors.background,
      floating: true,
      elevation: 0,
      titleSpacing: 20,
      title: Row(
        children: [
          const Text(
            'WHOOP',
            style: TextStyle(
              color: WhoopColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: state.isLive ? WhoopColors.green : WhoopColors.textDim,
              boxShadow: state.isLive
                  ? [BoxShadow(color: WhoopColors.green.withOpacity(0.6), blurRadius: 6)]
                  : null,
            ),
          ),
        ],
      ),
      actions: [
        if (state.batteryPct != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _BatteryIndicator(
                pct: state.batteryPct!, charging: state.charging == true),
          ),
        IconButton(
          icon: const Icon(Icons.tune, color: WhoopColors.textSecondary, size: 22),
          onPressed: () => context.push('/settings'),
        ),
      ],
    );
  }

  Widget _buildMetricsGrid(WhoopConnectionState state) {
    // Prefer backend insights values when available
    final insights = state.insights;
    final recoveryFromBackend = insights != null
        ? (insights['recovery_score'] as num?)?.toDouble()
        : null;
    final displayRecovery = recoveryFromBackend ?? state.recoveryScore;
    final strainScore = insights != null
        ? (insights['strain_score'] as num?)?.toDouble()
        : null;

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.5,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        MetricTile(
          label: 'HRV',
          value: state.hrv != null ? state.hrv!.toStringAsFixed(1) : '--',
          unit: 'ms',
          icon: Icons.favorite_border,
          isLoading: state.hrHistory.length < 4,
          subLabel: state.hrv != null ? _hrvLabel(state.hrv!) : 'building...',
        ),
        MetricTile(
          label: 'SpO2',
          value: state.spo2 != null ? state.spo2!.toStringAsFixed(1) : '--',
          unit: '%',
          icon: Icons.water_drop_outlined,
          isLoading: state.lastR21?.channelC == null,
          valueColor: state.spo2 != null && state.spo2! < 95
              ? WhoopColors.accent
              : null,
        ),
        MetricTile(
          label: strainScore != null ? 'Strain' : 'Temperature',
          value: strainScore != null
              ? strainScore.toStringAsFixed(1)
              : (state.tempC != null ? state.tempC!.toStringAsFixed(1) : '--'),
          unit: strainScore != null ? '/ 21' : '°C',
          icon: strainScore != null ? Icons.local_fire_department_outlined : Icons.thermostat_outlined,
          valueColor: strainScore != null ? _strainColor(strainScore) : null,
        ),
        MetricTile(
          label: 'Recovery',
          value: displayRecovery != null
              ? displayRecovery.toStringAsFixed(0)
              : '--',
          unit: '%',
          icon: Icons.bolt_outlined,
          valueColor: displayRecovery != null
              ? _recoveryColor(displayRecovery)
              : null,
        ),
      ],
    );
  }

  Widget _buildStatusRow(WhoopConnectionState state) {
    return Row(
      children: [
        Expanded(
          child: StatusTile(
            label: 'Wrist',
            isActive: state.wristOn,
            activeText: 'On Wrist',
            inactiveText: 'Off Wrist',
            activeIcon: Icons.watch_outlined,
            inactiveIcon: Icons.watch_off_outlined,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: StatusTile(
            label: 'Charging',
            isActive: state.charging,
            activeText: 'Charging',
            inactiveText: 'On Battery',
            activeIcon: Icons.bolt,
            inactiveIcon: Icons.battery_std_outlined,
          ),
        ),
      ],
    );
  }

  Widget _buildOpticalRow(WhoopConnectionState state) {
    final r21 = state.lastR21!;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: WhoopColors.green),
            ),
            const SizedBox(width: 8),
            const Text('Optical Locked',
                style: TextStyle(color: WhoopColors.green, fontSize: 13)),
            const Spacer(),
            Text('LED ${r21.ledDrive}',
                style: const TextStyle(color: WhoopColors.textDim, fontSize: 11)),
          ]),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ChannelDot(color: const Color(0xFF4CAF50), label: 'GREEN 1',
                  count: r21.channelA?.length ?? 0),
              _ChannelDot(color: const Color(0xFF66BB6A), label: 'GREEN 2',
                  count: r21.channelB?.length ?? 0),
              _ChannelDot(color: const Color(0xFF7E57C2), label: 'IR',
                  count: r21.channelC?.length ?? 0),
              _ChannelDot(color: const Color(0xFFEF5350), label: 'RED',
                  count: r21.channelF?.length ?? 0),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceInfo(WhoopConnectionState state) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.cardBorder),
      ),
      child: Column(
        children: [
          _InfoRow(label: 'Device', value: state.deviceName ?? '—'),
          _InfoRow(label: 'Serial', value: state.serial ?? '—'),
          _InfoRow(label: 'Batches synced', value: '${state.batchCount}'),
          _InfoRow(
              label: 'Signal',
              value: state.rssi != null ? '${state.rssi} dBm' : '—'),
        ],
      ),
    );
  }

  Widget _buildActions(
      BuildContext context, WidgetRef ref, WhoopConnectionState state) {
    final manager = ref.read(whoopManagerProvider);
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            label: 'HAPTIC',
            icon: Icons.vibration,
            onTap: () => manager.sendHaptic(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionButton(
            label: 'DISCONNECT',
            icon: Icons.bluetooth_disabled,
            onTap: () {
              manager.disconnect();
              context.go('/scan');
            },
            danger: true,
          ),
        ),
      ],
    );
  }

  String _hrvLabel(double hrv) {
    if (hrv > 60) return 'excellent';
    if (hrv > 40) return 'good';
    if (hrv > 20) return 'moderate';
    return 'low';
  }

  Color _recoveryColor(double score) {
    if (score >= 67) return WhoopColors.green;
    if (score >= 34) return WhoopColors.accent;
    return WhoopColors.primary;
  }

  Color _strainColor(double score) {
    if (score >= 14) return WhoopColors.primary;
    if (score >= 7) return WhoopColors.accent;
    return WhoopColors.green;
  }
}

// ── Insights card ──────────────────────────────────────────────────────────────

class _InsightsCard extends StatelessWidget {
  final Map<String, dynamic>? insights;
  final bool backendOnline;

  const _InsightsCard({this.insights, required this.backendOnline});

  @override
  Widget build(BuildContext context) {
    if (!backendOnline) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: WhoopColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: WhoopColors.cardBorder),
        ),
        child: const Center(
          child: Text('Backend offline — insights unavailable',
              style: TextStyle(color: WhoopColors.textDim, fontSize: 12)),
        ),
      );
    }

    if (insights == null) {
      return Container(
        height: 64,
        decoration: BoxDecoration(
          color: WhoopColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: WhoopColors.cardBorder),
        ),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: WhoopColors.textDim,
            ),
          ),
        ),
      );
    }

    final recoveryScore = (insights!['recovery_score'] as num?)?.toDouble();
    final strainScore = (insights!['strain_score'] as num?)?.toDouble();
    final avgHr = (insights!['avg_hr'] as num?)?.toDouble();
    final hrvAvg = (insights!['hrv_avg'] as num?)?.toDouble();
    final hrvTrend = insights!['hrv_trend'] as String?;
    final restingHr = (insights!['resting_hr'] as num?)?.toDouble();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.cardBorder),
      ),
      child: Column(
        children: [
          if (recoveryScore != null)
            _InsightRow(
              label: 'Recovery Score',
              value: '${recoveryScore.toStringAsFixed(0)}%',
              valueColor: _recoveryColor(recoveryScore),
            ),
          if (strainScore != null)
            _InsightRow(
              label: 'Strain Score',
              value: '${strainScore.toStringAsFixed(1)} / 21',
            ),
          if (restingHr != null)
            _InsightRow(
              label: 'Resting HR',
              value: '${restingHr.toStringAsFixed(0)} bpm',
            ),
          if (avgHr != null)
            _InsightRow(
              label: 'Avg HR (session)',
              value: '${avgHr.toStringAsFixed(0)} bpm',
            ),
          if (hrvAvg != null)
            _InsightRow(
              label: 'HRV Average',
              value: '${hrvAvg.toStringAsFixed(1)} ms',
            ),
          if (hrvTrend != null)
            _InsightRow(
              label: 'HRV Trend',
              value: hrvTrend,
              valueColor: _trendColor(hrvTrend),
            ),
        ],
      ),
    );
  }

  Color _recoveryColor(double score) {
    if (score >= 67) return WhoopColors.green;
    if (score >= 34) return WhoopColors.accent;
    return WhoopColors.primary;
  }

  Color _trendColor(String trend) {
    if (trend == 'improving') return WhoopColors.green;
    if (trend == 'declining') return WhoopColors.primary;
    return WhoopColors.textSecondary;
  }
}

class _InsightRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InsightRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(color: WhoopColors.textSecondary, fontSize: 13)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  color: valueColor ?? WhoopColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Section label with optional trailing widget ────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  final Widget? trailing;

  const _SectionLabel({required this.label, this.trailing});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: WhoopColors.textSecondary,
              fontSize: 10,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      );
}

class _BackendDot extends StatelessWidget {
  final bool online;
  const _BackendDot({required this.online});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? WhoopColors.green : WhoopColors.textDim,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            online ? 'LIVE' : 'OFFLINE',
            style: TextStyle(
              color: online ? WhoopColors.green : WhoopColors.textDim,
              fontSize: 9,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}

// ── Dashboard sub-widgets ──────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  color: WhoopColors.textSecondary, fontSize: 13)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  color: WhoopColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _ChannelDot extends StatelessWidget {
  final Color color;
  final String label;
  final int count;
  const _ChannelDot(
      {required this.color, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: const TextStyle(
                color: WhoopColors.textDim,
                fontSize: 9,
                letterSpacing: 0.5)),
        Text('$count',
            style: const TextStyle(
                color: WhoopColors.textSecondary, fontSize: 11)),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? WhoopColors.primary : WhoopColors.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: danger
              ? WhoopColors.primary.withOpacity(0.08)
              : WhoopColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: danger
                ? WhoopColors.primary.withOpacity(0.3)
                : WhoopColors.cardBorder,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatteryIndicator extends StatelessWidget {
  final double pct;
  final bool charging;
  const _BatteryIndicator({required this.pct, required this.charging});

  @override
  Widget build(BuildContext context) {
    final color = pct > 50
        ? WhoopColors.green
        : pct > 20
            ? WhoopColors.accent
            : WhoopColors.primary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (charging)
          const Icon(Icons.bolt, color: WhoopColors.accent, size: 14),
        Text(
          '${pct.toStringAsFixed(0)}%',
          style: TextStyle(
              color: color, fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _HrChart extends StatelessWidget {
  final List<double> history;
  const _HrChart({required this.history});

  @override
  Widget build(BuildContext context) {
    final spots = history.asMap().entries
        .map((e) => FlSpot(e.key.toDouble(), e.value))
        .toList();
    final minY =
        (history.reduce((a, b) => a < b ? a : b) - 5).clamp(40.0, 200.0);
    final maxY =
        (history.reduce((a, b) => a > b ? a : b) + 5).clamp(40.0, 220.0);

    return Container(
      height: 120,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.35,
              color: WhoopColors.primary,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    WhoopColors.primary.withOpacity(0.2),
                    WhoopColors.primary.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
