// Diagnostics — a read-only window into the on-device analysis pipeline so the
// user (and we) can SEE what's in the raw store, what got derived, and why a
// screen might be empty. Nothing here computes; it summarizes the DB.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/db.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Map<String, dynamic>? _raw;
  Map<String, dynamic>? _derived;
  Map<String, dynamic>? _cross;
  Map<String, dynamic>? _latest; // latest derived_day bundle (decoded)
  bool _loading = true;
  bool _exporting = false;

  // Inner packet-type byte → friendly label.
  static const Map<int, String> _types = {
    47: '0x2F historical (R24)',
    40: '0x28 live HR',
    43: '0x2B live R10',
    51: '0x33 IMU stream',
    48: '0x30 event',
    49: '0x31 sync marker',
    36: '0x24 cmd response',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final raw = await LocalDb.rawStats();
    final derived = await LocalDb.derivedStats();
    final cross = await LocalDb.crossDayStats();
    final latestRow = await LocalDb.latestDayResult();
    Map<String, dynamic>? latest;
    if (latestRow != null && latestRow['payload_json'] is String) {
      try {
        final d = jsonDecode(latestRow['payload_json'] as String);
        if (d is Map) latest = d.cast<String, dynamic>();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _raw = raw;
      _derived = derived;
      _cross = cross;
      _latest = latest;
      _loading = false;
    });
  }

  String _ts(Object? secOrNull, {bool ms = false}) {
    final v = (secOrNull as num?)?.toInt();
    if (v == null || v == 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms ? v : v * 1000);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _span(Object? lo, Object? hi, {bool ms = false}) {
    final a = (lo as num?)?.toInt(), b = (hi as num?)?.toInt();
    if (a == null || b == null || a == 0 || b == 0) return '—';
    var s = (b - a).toDouble();
    if (ms) s /= 1000.0;
    if (s < 3600) return '${(s / 60).toStringAsFixed(1)} min';
    if (s < 86400) return '${(s / 3600).toStringAsFixed(1)} h';
    return '${(s / 86400).toStringAsFixed(1)} days';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Diagnostics', style: AppText.h2),
        actions: [
          IconButton(
            icon: AppIcon(Ic.history, size: 20, color: AppColors.inkSoft),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Sp.screen),
              children: [
                _rawSection(),
                const SizedBox(height: Sp.x6),
                _derivedSection(),
                const SizedBox(height: Sp.x6),
                _latestSection(),
                const SizedBox(height: Sp.x6),
                _crossSection(),
                const SizedBox(height: Sp.x6),
                _reanalyze(app),
                const SizedBox(height: Sp.x3),
                _exportRow(),
                const SizedBox(height: Sp.x6),
                _logSection(app),
              ],
            ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x1),
        child: Row(children: [
          Expanded(child: Text(k, style: AppText.body)),
          Text(v, style: AppText.body.copyWith(color: AppColors.inkSoft)),
        ]),
      );

  Widget _rawSection() {
    final r = _raw ?? const {};
    final byType = (r['by_type'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Raw data'),
      ProCard(
        padding: const EdgeInsets.all(Sp.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _kv('Total events', '${r['count'] ?? 0}'),
          _kv('From (record time)', _ts(r['min_rec_ts'])),
          _kv('To (record time)', _ts(r['max_rec_ts'])),
          _kv('Span (real time)', _span(r['min_rec_ts'], r['max_rec_ts'])),
          _kv('Received span', _span(r['min_captured_ms'], r['max_captured_ms'], ms: true)),
          const Divider(height: Sp.x5),
          Text('By packet type', style: AppText.label),
          const SizedBox(height: Sp.x2),
          if (byType.isEmpty)
            Text('—', style: AppText.body.copyWith(color: AppColors.inkMuted))
          else
            ...byType.entries.map((e) {
              final t = int.tryParse(e.key) ?? -1;
              return _kv(_types[t] ?? 'type $t', '${e.value}');
            }),
          if ((byType['47'] ?? 0) == 0) ...[
            const SizedBox(height: Sp.x3),
            Text(
              'No 0x2F/R24 records — HRV, sleep, recovery need these (they carry '
              'RR + accelerometer). Live HR alone cannot drive those metrics.',
              style: AppText.caption.copyWith(color: AppColors.warn),
            ),
          ],
        ]),
      ),
    ]);
  }

  Widget _derivedSection() {
    final d = _derived ?? const {};
    final dates = (d['dates'] as List?)?.cast<String>() ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Derived days'),
      ProCard(
        padding: const EdgeInsets.all(Sp.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _kv('Days derived', '${d['count'] ?? 0}'),
          _kv('Skipped (timeout/error)', '${d['skipped'] ?? 0}'),
          _kv('Latest day', '${d['latest_date'] ?? '—'}'),
          const SizedBox(height: Sp.x2),
          if (dates.isNotEmpty)
            Text('Recent: ${dates.join(', ')}',
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        ]),
      ),
    ]);
  }

  Widget _latestSection() {
    final b = _latest;
    final cov = (b?['coverage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final scalars = (b?['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sleepWin = ((b?['sleep'] as Map?)?['window'] as Map?)?.cast<String, dynamic>();
    final skipped = b?['skipped'] == true;
    Widget present(String k) {
      final ok = scalars[k] != null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x1),
        child: Row(children: [
          AppIcon(ok ? Ic.check : Ic.cancel,
              size: 16, color: ok ? AppColors.good : AppColors.inkMuted),
          const SizedBox(width: Sp.x2),
          Text(k, style: AppText.body.copyWith(
              color: ok ? AppColors.ink : AppColors.inkMuted)),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Latest day — coverage'),
      ProCard(
        padding: const EdgeInsets.all(Sp.x4),
        child: b == null
            ? Text('No derived day yet.',
                style: AppText.body.copyWith(color: AppColors.inkMuted))
            : skipped
                ? Text('Latest day is a SKIPPED marker (derivation timed out or '
                    'errored). Today falls back to the last day with data.',
                    style: AppText.body.copyWith(color: AppColors.warn))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _kv('HR samples', '${cov['hr_samples'] ?? '—'}'),
                    _kv('HR valid (on-wrist)', '${cov['hr_valid'] ?? '—'}'),
                    _kv('RR beats', '${cov['rr_beats'] ?? '—'}'),
                    _kv('Clean NN', '${cov['nn_clean'] ?? '—'}'),
                    _kv('Clean fraction', '${cov['clean_fraction'] ?? '—'}'),
                    _kv('Accel samples', '${cov['accel_samples'] ?? '—'}'),
                    _kv('Sleep window', sleepWin?['onset_ms'] != null ? 'found' : '—'),
                    const Divider(height: Sp.x5),
                    Text('Metrics present', style: AppText.label),
                    const SizedBox(height: Sp.x2),
                    present('readiness'),
                    present('rmssd'),
                    present('rhr'),
                    present('resp_rate'),
                    present('trimp'),
                    present('dip_pct'),
                    present('odi_per_hour'),
                  ]),
      ),
    ]);
  }

  Widget _crossSection() {
    final c = _cross ?? const {'present': false};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Cross-day rollup'),
      ProCard(
        padding: const EdgeInsets.all(Sp.x4),
        child: _kv(
          'Computed',
          c['present'] == true ? 'yes (${c['n_days'] ?? '?'} days)' : 'not yet',
        ),
      ),
    ]);
  }

  Widget _reanalyze(AppState app) => ProCard(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x2),
        child: DetailRow(
          icon: Ic.history,
          label: 'Re-analyze all data',
          value: app.reanalyzing
              ? (app.reanalyzeProgress.isEmpty ? 'Working…' : app.reanalyzeProgress)
              : 'Run',
          onTap: () async {
            if (app.reanalyzing) return;
            await app.reanalyzeAll();
            await _load();
          },
        ),
      );

  Widget _exportRow() => ProCard(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x2),
        child: DetailRow(
          icon: Ic.server,
          label: 'Export data (SQLite)',
          value: _exporting ? 'Exporting…' : 'Share',
          onTap: () async {
            if (_exporting) return;
            // iOS share sheet is a popover and REQUIRES an anchor rect, or it
            // throws PlatformException(sharePositionOrigin must be set).
            // Capture it before the async gap, while layout is stable.
            final box = context.findRenderObject() as RenderBox?;
            final origin = (box != null && box.hasSize)
                ? (box.localToGlobal(Offset.zero) & box.size)
                : null;
            setState(() => _exporting = true);
            try {
              final path = await LocalDb.exportCopy();
              await Share.shareXFiles(
                [XFile(path)],
                subject: 'OpenStrap data export',
                text: 'OpenStrap local DB (raw + derived).',
                sharePositionOrigin: origin,
              );
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Export failed: $e')));
              }
            } finally {
              if (mounted) setState(() => _exporting = false);
            }
          },
        ),
      );

  Widget _logSection(AppState app) {
    final lines = app.logLines.take(40).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Recent log'),
      ProCard(
        padding: const EdgeInsets.all(Sp.x3),
        child: lines.isEmpty
            ? Text('—', style: AppText.body.copyWith(color: AppColors.inkMuted))
            : SelectableText(
                lines.join('\n'),
                style: AppText.caption.copyWith(
                    color: AppColors.inkSoft, height: 1.5, fontFamily: 'monospace'),
              ),
      ),
    ]);
  }
}
