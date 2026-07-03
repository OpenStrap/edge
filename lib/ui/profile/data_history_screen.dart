import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/db.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class DataHistoryScreen extends StatefulWidget {
  const DataHistoryScreen({super.key});

  @override
  State<DataHistoryScreen> createState() => _DataHistoryScreenState();
}

class _DataHistoryScreenState extends State<DataHistoryScreen> {
  bool _loading = true;
  bool _busy = false;
  int _dbBytes = 0;
  List<Map<String, dynamic>> _days = const [];
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
    final bytes = await app.dataFileBytes();
    if (!mounted) return;
    setState(() {
      _days = days;
      _dbBytes = bytes;
      _selected.removeWhere((d) => !_days.any((row) => row['day_id'] == d));
      _loading = false;
    });
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtTs(int? sec) {
    if (sec == null || sec <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _fmtComputed(int? ms) {
    if (ms == null || ms <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> _shareWholeDb() async {
    setState(() => _busy = true);
    try {
      final path = await LocalDb.exportCopy();
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], text: 'OpenStrap data export');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareSelected() async {
    if (_selected.isEmpty) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final path = await app.exportDaysDb(_selected);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(path)],
        text:
            'OpenStrap selected day export (${_selected.length} day${_selected.length == 1 ? '' : 's'})',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final app = context.read<AppState>();
    final count = _selected.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete selected days?'),
        content: Text(
          'This removes local raw and derived data for $count selected day${count == 1 ? '' : 's'}. Export first if you may need it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final deleted = await app.deleteDays(_selected);
      if (!mounted) return;
      _selected.clear();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted $deleted local row${deleted == 1 ? '' : 's'} across selected days.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected.length;
    final rawDays = _days
        .where((d) => ((d['raw_count'] as int?) ?? 0) > 0)
        .length;
    final derivedDays = _days.where((d) => d['has_derived'] == true).length;
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
                      Text('Data history', style: AppText.h1),
                      const SizedBox(height: 2),
                      Text('Manage your local data', style: AppText.caption),
                    ],
                  ),
                ),
                if (_loading || _busy)
                  const Padding(
                    padding: EdgeInsets.only(right: Sp.x2),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Sp.x6),
            ProCard(
              child: Row(
                children: [
                  Expanded(child: _stat('Local size', _fmtBytes(_dbBytes))),
                  const SizedBox(width: Sp.x3),
                  Expanded(child: _stat('Days with data', '$rawDays')),
                  const SizedBox(width: Sp.x3),
                  Expanded(child: _stat('Days derived', '$derivedDays')),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            SectionHeader(
              'Actions',
              trailing: selected > 0 ? '$selected selected' : 'Select days',
            ),
            ProCard(
              child: Column(
                children: [
                  DetailRow(
                    icon: Ic.cloud,
                    label: 'Export full database',
                    value: 'Share .db',
                    onTap: _busy ? null : _shareWholeDb,
                  ),
                  const Divider(height: 1),
                  DetailRow(
                    icon: Ic.history,
                    label: 'Export selected days',
                    value: selected == 0 ? 'Select first' : 'Share .db',
                    onTap: _busy || selected == 0 ? null : _shareSelected,
                  ),
                  const Divider(height: 1),
                  DetailRow(
                    icon: Ic.trash,
                    label: 'Delete selected days',
                    value: selected == 0 ? 'Select first' : 'Remove local data',
                    onTap: _busy || selected == 0 ? null : _deleteSelected,
                  ),
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
            else if (_days.isEmpty)
              ProCard(
                child: Text(
                  'No local day history yet.',
                  style: AppText.bodySoft,
                ),
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

  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: AppText.metricSm.copyWith(fontSize: 22)),
      const SizedBox(height: 2),
      Text(label, style: AppText.captionMuted),
    ],
  );

  Widget _pill(String text, Color color, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 6),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(R.chip),
    ),
    child: Text(text, style: AppText.caption.copyWith(color: fg)),
  );

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
                    if (hasDerived)
                      _pill(
                        finalized ? 'Finalized' : 'Derived',
                        finalized ? AppColors.goodSoft : AppColors.coralSoft,
                        finalized ? AppColors.good : AppColors.coralDeep,
                      )
                    else
                      _pill(
                        rawCount > 0 ? 'Raw only' : 'Empty',
                        AppColors.surfaceAlt,
                        AppColors.inkMuted,
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
                      'Span ${_fmtTs((row['min_rec_ts'] as num?)?.toInt())}–${_fmtTs((row['max_rec_ts'] as num?)?.toInt())}',
                      style: AppText.captionMuted,
                    ),
                    Text(
                      'Metrics ${(row['metric_count'] as int?) ?? 0}',
                      style: AppText.captionMuted,
                    ),
                    Text(
                      'Workouts ${(row['session_count'] as int?) ?? 0}',
                      style: AppText.captionMuted,
                    ),
                    Text(
                      'Computed ${_fmtComputed((row['computed_at'] as num?)?.toInt())}',
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
