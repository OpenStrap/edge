import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../cloud/api.dart';
import '../config.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/trend_chart.dart';

final _trendProvider =
    FutureProvider.autoDispose.family<List<dynamic>, ({String metric, int days})>(
        (ref, q) async {
  final token = await ref.read(apiProvider).getToken();
  final uri = Uri.parse('${Config.apiBaseUrl}/insights/trend?metric=${q.metric}&days=${q.days}');
  final r = await http.get(uri, headers: {'authorization': 'Bearer ${token ?? ''}'});
  if (r.statusCode >= 400) throw Exception('${r.statusCode}: ${r.body}');
  final data = jsonDecode(r.body) as Map<String, dynamic>;
  return (data['points'] as List<dynamic>?) ?? [];
});

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recovery = ref.watch(_trendProvider((metric: 'recovery', days: 30)));
    final hrv = ref.watch(_trendProvider((metric: 'hrv', days: 30)));
    final sleep = ref.watch(_trendProvider((metric: 'sleep_total', days: 30)));
    final hr = ref.watch(_trendProvider((metric: 'hr', days: 14)));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_trendProvider);
        await Future.wait([
          ref.read(_trendProvider((metric: 'recovery', days: 30)).future),
          ref.read(_trendProvider((metric: 'hrv', days: 30)).future),
          ref.read(_trendProvider((metric: 'sleep_total', days: 30)).future),
          ref.read(_trendProvider((metric: 'hr', days: 14)).future),
        ]);
      },
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'RECOVERY · 30d',
            color: WTheme.accent,
            asyncPoints: recovery,
            valueKey: 'score',
            scaleX100: true,
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'HRV (rMSSD) · 30d',
            color: WTheme.zonePurple,
            asyncPoints: hrv,
            valueKey: 'hrv',
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'SLEEP (h) · 30d',
            color: WTheme.zoneBlue,
            asyncPoints: sleep,
            valueKey: 'total_sec',
            scaleDivide: 3600,
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'AVG HEART RATE · 14d',
            color: WTheme.danger,
            asyncPoints: hr,
            valueKey: 'avg',
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Color color;
  final AsyncValue<List<dynamic>> asyncPoints;
  final String valueKey;
  final bool scaleX100;
  final double? scaleDivide;

  const _Section({
    required this.title,
    required this.color,
    required this.asyncPoints,
    required this.valueKey,
    this.scaleX100 = false,
    this.scaleDivide,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title),
        GlassCard(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
          child: asyncPoints.when(
            loading: () => const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator(color: WTheme.accent))),
            error: (e, _) => SizedBox(
                height: 80,
                child: Center(
                    child: Text(e.toString(),
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            color: WTheme.danger,
                            fontSize: 11)))),
            data: (points) {
              final values = points
                  .map((p) {
                    final v = (p as Map<String, dynamic>)[valueKey];
                    if (v == null) return null;
                    var d = (v as num).toDouble();
                    if (scaleX100) d *= 100;
                    if (scaleDivide != null) d /= scaleDivide!;
                    return d;
                  })
                  .whereType<double>()
                  .toList();
              final labels = points
                  .map((p) {
                    final d = (p as Map<String, dynamic>)['date']?.toString();
                    return d?.substring(5) ?? '';
                  })
                  .toList();
              return TrendChart(values: values, xLabels: labels, color: color);
            },
          ),
        ),
      ],
    );
  }
}
