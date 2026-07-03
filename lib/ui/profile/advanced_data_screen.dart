import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class AdvancedDataScreen extends StatefulWidget {
  const AdvancedDataScreen({super.key});

  @override
  State<AdvancedDataScreen> createState() => _AdvancedDataScreenState();
}

class _AdvancedDataScreenState extends State<AdvancedDataScreen> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _days = const [];
  List<Map<String, dynamic>> _tableStats = const [];
  Map<String, dynamic>? _capture;
  Map<String, dynamic>? _today;
  Map<String, dynamic>? _crossday;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() => _loading = true);
    final days = await app.dataHistoryDays();
    final tableStats = await LocalDb.tableStorageStats();
    final captureRow = await LocalDb.computeFreshness('capture');
    final todayRow = await LocalDb.computeFreshness('today');
    final crossdayRow = await LocalDb.computeFreshness('crossday');
    Map<String, dynamic>? decode(Map<String, dynamic>? row) {
      final raw = row?['payload_json'];
      if (raw is! String || raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map ? decoded.cast<String, dynamic>() : null;
      } catch (_) {
        return null;
      }
    }

    if (!mounted) return;
    setState(() {
      _days = days;
      _tableStats = tableStats;
      _capture = decode(captureRow);
      _today = decode(todayRow);
      _crossday = decode(crossdayRow);
      _selected.removeWhere((d) => !_days.any((row) => row['day_id'] == d));
      _loading = false;
    });
  }

  String _fmtMs(int? ms) {
    if (ms == null || ms <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $hh:$mm';
  }

  String _fmtMb(num? mb) {
    if (mb == null || !mb.isFinite) return '—';
    if (mb >= 100) return '${mb.toStringAsFixed(0)} MB';
    if (mb >= 10) return '${mb.toStringAsFixed(1)} MB';
    return '${mb.toStringAsFixed(2)} MB';
  }

  String _fmtRows(Object? rows) {
    final n = (rows as num?)?.toInt();
    if (n == null) return '—';
    return n.toString();
  }

  Future<void> _reanalyzeSelected() async {
    if (_selected.isEmpty) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final n = await app.reanalyzeDays(_selected);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            n > 0
                ? 'Recomputed $n selected day${n == 1 ? '' : 's'}.'
                : 'No selected days were recomputed.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reanalyzeAll() async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final n = await app.reanalyzeAll();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            n > 0
                ? 'Recomputed $n day${n == 1 ? '' : 's'}.'
                : 'No raw data to analyze yet.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Sp.screen,
            Sp.x4,
            Sp.screen,
            Sp.x8,
          ),
          children: [
            Row(
              children: [
                RoundIconButton(
                  Ic.arrowLeft,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Advanced data', style: AppText.h1),
                      const SizedBox(height: 2),
                      Text(
                        'Developer tools for compute and sync',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                if (_busy || _loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: Sp.x6),
            SectionHeader(
              'Compute',
              trailing: app.reanalyzing ? app.reanalyzeProgress : null,
            ),
            ProCard(
              child: Column(
                children: [
                  DetailRow(
                    icon: Ic.history,
                    label: 'Recompute selected days',
                    value: _selected.isEmpty ? 'Select first' : 'Run',
                    onTap: _busy || _selected.isEmpty
                        ? null
                        : _reanalyzeSelected,
                  ),
                  const Divider(height: 1),
                  DetailRow(
                    icon: Ic.history,
                    label: 'Recompute all days',
                    value: _busy ? 'Working…' : 'Run',
                    onTap: _busy ? null : _reanalyzeAll,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            const SectionHeader('Status'),
            ProCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _kv(
                    'Latest data day',
                    _capture?['latest_raw_day']?.toString() ?? '—',
                  ),
                  _kv(
                    'Latest data rec_ts',
                    (_capture?['latest_raw_rec_ts'] ?? '—').toString(),
                  ),
                  _kv(
                    'Decoded 1 Hz rows',
                    (_capture?['decoded_onehz'] ?? '—').toString(),
                  ),
                  _kv(
                    'Decoded RR rows',
                    (_capture?['decoded_rr'] ?? '—').toString(),
                  ),
                  const SizedBox(height: Sp.x3),
                  _kv(
                    'Today activity',
                    _today?['activity_state']?.toString() ?? '—',
                  ),
                  _kv(
                    'Today overnight',
                    _today?['overnight_state']?.toString() ?? '—',
                  ),
                  _kv(
                    'Activity computed',
                    _fmtMs((_today?['activity_computed_at'] as num?)?.toInt()),
                  ),
                  _kv(
                    'Overnight computed',
                    _fmtMs((_today?['overnight_computed_at'] as num?)?.toInt()),
                  ),
                  const SizedBox(height: Sp.x3),
                  _kv(
                    'Cross-day baseline',
                    _crossday?['present'] == true ? 'Present' : 'Missing',
                  ),
                  _kv(
                    'Cross-day updated',
                    _fmtMs((_crossday?['updated_at'] as num?)?.toInt()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            const SectionHeader('Storage'),
            ProCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in _tableStats) ...[
                    _tableRow(row),
                    if (!identical(row, _tableStats.last))
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: Sp.x2),
                        child: Divider(height: 1),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            SectionHeader(
              'Days',
              trailing: _days.isEmpty
                  ? null
                  : (_selected.length == _days.length ? 'Clear' : 'Select all'),
              onTrailing: _days.isEmpty
                  ? null
                  : () {
                      setState(() {
                        if (_selected.length == _days.length) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(_days.map((d) => d['day_id'] as String));
                        }
                      });
                    },
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: Sp.x8),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Column(
                children: [
                  for (final row in _days) ...[
                    _dayCard(row),
                    const SizedBox(height: Sp.x3),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.x2),
    child: Row(
      children: [
        Expanded(child: Text(k, style: AppText.body)),
        const SizedBox(width: Sp.x3),
        Text(v, style: AppText.bodySoft),
      ],
    ),
  );

  Widget _tableRow(Map<String, dynamic> row) {
    final approx = row['approximate'] == true;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(row['table']?.toString() ?? '—', style: AppText.body),
        ),
        const SizedBox(width: Sp.x3),
        Text('${_fmtRows(row['rows'])} rows', style: AppText.captionMuted),
        const SizedBox(width: Sp.x3),
        Text(
          _fmtMb((row['mb'] as num?)),
          style: approx ? AppText.captionMuted : AppText.bodySoft,
        ),
      ],
    );
  }

  Widget _dayCard(Map<String, dynamic> row) {
    final dayId = row['day_id'] as String;
    final selected = _selected.contains(dayId);
    final rawCount = (row['raw_count'] as int?) ?? 0;
    final hasDerived = row['has_derived'] == true;
    final finalized = ((row['finalized'] as int?) ?? 0) == 1;
    return ProCard(
      onTap: () => setState(() {
        if (selected) {
          _selected.remove(dayId);
        } else {
          _selected.add(dayId);
        }
      }),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: (_) => setState(() {
              if (selected) {
                _selected.remove(dayId);
              } else {
                _selected.add(dayId);
              }
            }),
          ),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(dayId, style: AppText.title)),
                    Tag(
                      hasDerived
                          ? (finalized ? 'finalized' : 'derived')
                          : (rawCount > 0 ? 'raw-only' : 'empty'),
                      color: hasDerived
                          ? (finalized
                                ? AppColors.goodSoft
                                : AppColors.coralSoft)
                          : AppColors.surfaceAlt,
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x2),
                Wrap(
                  spacing: Sp.x3,
                  runSpacing: Sp.x2,
                  children: [
                    Text('Raw $rawCount', style: AppText.captionMuted),
                    Text(
                      'Derived ${hasDerived ? 'yes' : 'no'}',
                      style: AppText.captionMuted,
                    ),
                    Text(
                      'Algo ${(row['algo_version'] as num?)?.toInt() ?? '—'}',
                      style: AppText.captionMuted,
                    ),
                    Text(
                      'Metrics ${(row['metric_count'] as int?) ?? 0}',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
