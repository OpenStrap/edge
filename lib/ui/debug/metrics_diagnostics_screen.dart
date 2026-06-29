import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../compute/derivation_engine.dart';
import '../../data/db.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class MetricsDiagnosticsScreen extends StatefulWidget {
  const MetricsDiagnosticsScreen({super.key});

  @override
  State<MetricsDiagnosticsScreen> createState() =>
      _MetricsDiagnosticsScreenState();
}

class _MetricsDiagnosticsScreenState extends State<MetricsDiagnosticsScreen> {
  bool _loading = true;
  Map<String, dynamic>? _raw;
  Map<String, dynamic>? _latestDay;
  Map<String, dynamic>? _cross;
  Map<String, dynamic>? _rolling;
  Map<String, dynamic>? _captureFreshness;
  Map<String, dynamic>? _todayFreshness;
  Map<String, dynamic>? _bandSignals;
  Map<String, dynamic>? _sleepCandidate;
  Map<String, dynamic>? _wakeFeatures;
  Map<String, dynamic>? _rollingArtifact;
  Map<String, dynamic>? _crossdayInput;
  List<Map<String, dynamic>> _recentDays = const [];
  List<Map<String, dynamic>> _jobs = const [];
  Map<String, int> _seriesCounts = const {};

  static const List<String> _baselineKeys = [
    'ln_rmssd',
    'rhr',
    'resp_rate',
    'skin_temp_adc',
    'readiness',
    'strain',
    'tst_min',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final raw = await LocalDb.rawStats();
    final latestDay = await LocalDb.latestDayResult();
    final cross = await LocalDb.crossDayStats();
    final rolling = await LocalDb.baseline('rolling');
    final rollingArtifact = await LocalDb.baseline('rolling_artifact');
    final crossdayInput = await LocalDb.baseline('crossday_input');
    final captureFreshness = await LocalDb.computeFreshness('capture');
    final todayFreshness = await LocalDb.computeFreshness('today');
    final bandSignals = await LocalDb.bandSignalsStats();
    final todayKey = LocalDb.localDayLabelNow();
    final sleepCandidate = await LocalDb.sleepSessionCandidate(
      todayKey,
      kAlgoVersion,
    );
    final wakeFeatures = await LocalDb.wakeDayFeatures(todayKey, kAlgoVersion);
    final recentDays = await LocalDb.recentDayDiagnostics(10);
    final jobs = await LocalDb.computeJobs(limit: 10);
    final seriesCounts = await LocalDb.metricSeriesCounts(_baselineKeys);
    Map<String, dynamic>? decodeFresh(Map<String, dynamic>? row) {
      final raw = row?['payload_json'];
      if (raw is! String || raw.isEmpty) return null;
      try {
        final d = jsonDecode(raw);
        return d is Map ? d.cast<String, dynamic>() : null;
      } catch (_) {
        return null;
      }
    }
    if (!mounted) return;
    setState(() {
      _raw = raw;
      _latestDay = latestDay;
      _cross = cross;
      _rolling = rolling;
      _rollingArtifact = decodeFresh(rollingArtifact);
      _crossdayInput = decodeFresh(crossdayInput);
      _captureFreshness = decodeFresh(captureFreshness);
      _todayFreshness = decodeFresh(todayFreshness);
      _bandSignals = bandSignals;
      _sleepCandidate = decodeFresh(sleepCandidate);
      _wakeFeatures = decodeFresh(wakeFeatures);
      _recentDays = recentDays;
      _jobs = jobs;
      _seriesCounts = seriesCounts;
      _loading = false;
    });
  }

  String _ts(Object? secOrMs, {bool ms = false}) {
    final v = (secOrMs as num?)?.toInt();
    if (v == null || v <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms ? v : v * 1000);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _dayLabelFromSec(Object? sec) {
    final v = (sec as num?)?.toInt();
    if (v == null || v <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(v * 1000);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  String _ageMs(Object? msOrNull) {
    final v = (msOrNull as num?)?.toInt();
    if (v == null || v <= 0) return '—';
    final sec = ((DateTime.now().millisecondsSinceEpoch - v) / 1000).round();
    if (sec < 60) return '${sec}s ago';
    if (sec < 3600) return '${(sec / 60).floor()}m ago';
    if (sec < 86400) return '${(sec / 3600).floor()}h ago';
    return '${(sec / 86400).floor()}d ago';
  }

  String _secsSpan(Object? a, Object? b) {
    final lo = (a as num?)?.toInt();
    final hi = (b as num?)?.toInt();
    if (lo == null || hi == null || hi < lo) return '—';
    final sec = hi - lo;
    if (sec < 3600) return '${(sec / 60).toStringAsFixed(1)} min';
    if (sec < 86400) return '${(sec / 3600).toStringAsFixed(1)} h';
    return '${(sec / 86400).toStringAsFixed(1)} d';
  }

  Widget _kv(String k, String v, {Color? valueColor}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Sp.x1),
    child: Row(
      children: [
        Expanded(child: Text(k, style: AppText.body)),
        Text(
          v,
          style: AppText.body.copyWith(color: valueColor ?? AppColors.inkSoft),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final derive =
        (((app.pipelineStatus['derive'] as Map?)?['engine'] as Map?) ??
                const {})
            .cast<String, dynamic>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Metrics diagnostics', style: AppText.h2),
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
                _freshnessSection(),
                const SizedBox(height: Sp.x6),
                _jobsSection(),
                const SizedBox(height: Sp.x6),
                _deriveSection(app, derive),
                const SizedBox(height: Sp.x6),
                _recentDaysSection(),
                const SizedBox(height: Sp.x6),
                _baselinesSection(),
              ],
            ),
    );
  }

  Widget _freshnessSection() {
    final raw = _raw ?? const {};
    final latest = _latestDay;
    final cross = _cross ?? const {};
    final crossRow = _rolling;
    final capture = _captureFreshness ?? const {};
    final today = _todayFreshness ?? const {};
    final sleepCandidate = _sleepCandidate ?? const {};
    final wakeFeatures = _wakeFeatures ?? const {};
    final rollingArtifact = _rollingArtifact ?? const {};
    final crossdayInput = _crossdayInput ?? const {};
    final latestDayId = latest?['day_id']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Freshness'),
        ProCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Latest raw edge', _ts(raw['max_rec_ts'])),
              _kv('Latest raw day', _dayLabelFromSec(raw['max_rec_ts'])),
              _kv(
                'Freshness raw edge',
                _ts(capture['latest_raw_rec_ts']),
              ),
              _kv(
                'Freshness raw day',
                '${capture['latest_raw_day'] ?? '—'}',
              ),
              _kv('Decoded 1 Hz rows', '${raw['decoded_onehz'] ?? 0}'),
              _kv('Decoded RR beats', '${raw['decoded_rr'] ?? 0}'),
              _kv(
                'Structured band events',
                '${_bandSignals?['event_count'] ?? 0}',
              ),
              _kv('Battery samples', '${_bandSignals?['battery_count'] ?? 0}'),
              _kv('Latest derived day', latestDayId ?? '—'),
              _kv('Latest derived compute', _ageMs(latest?['computed_at'])),
              _kv('Today key', '${today['today_day'] ?? '—'}'),
              _kv('Today activity state', '${today['activity_state'] ?? '—'}'),
              _kv('Today overnight state', '${today['overnight_state'] ?? '—'}'),
              _kv('Overnight source day', '${today['overnight_day'] ?? '—'}'),
              _kv(
                'Sleep candidate',
                sleepCandidate.isEmpty
                    ? 'missing'
                    : (sleepCandidate['sleep_offset_sec'] == null ||
                            (sleepCandidate['sleep_offset_sec'] as num?) == 0)
                        ? 'present (no sleep)'
                        : 'present',
              ),
              _kv(
                'Wake features',
                wakeFeatures.isEmpty ? 'missing' : 'present',
              ),
              _kv(
                'Rolling artifact',
                rollingArtifact.isEmpty ? 'missing' : 'present',
              ),
              _kv(
                'Cross-day input',
                crossdayInput.isEmpty
                    ? 'missing'
                    : '${((crossdayInput['days'] as List?) ?? const []).length} day(s)',
              ),
              _kv(
                'Cross-day rollup',
                cross['present'] == true ? 'present' : 'missing',
                valueColor: cross['present'] == true
                    ? AppColors.good
                    : AppColors.warn,
              ),
              _kv('Rolling baseline update', _ageMs(crossRow?['updated_at'])),
              _kv('Raw span', _secsSpan(raw['min_rec_ts'], raw['max_rec_ts'])),
            ],
          ),
        ),
      ],
    );
  }

  Widget _jobsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Durable Queue'),
        ProCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Queued jobs', '${_jobs.length}'),
              if (_jobs.isEmpty)
                Text(
                  'No persisted compute jobs yet.',
                  style: AppText.captionMuted,
                )
              else
                ..._jobs.map((job) {
                  final id = (job['id'] ?? '—').toString();
                  final type = (job['type'] ?? '—').toString();
                  final state = (job['state'] ?? '—').toString();
                  final scope = (job['scope'] ?? '—').toString();
                  return Padding(
                    padding: const EdgeInsets.only(top: Sp.x2),
                    child: Text(
                      '$state • $type • $scope • $id',
                      style: AppText.captionMuted,
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _deriveSection(AppState app, Map<String, dynamic> derive) {
    final scheduler =
        (app.pipelineStatus['derive'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final err = derive['last_error']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Compute run'),
        ProCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(
                'Scheduler running',
                scheduler['running'] == true ? 'yes' : 'no',
              ),
              _kv(
                'Capture blocked',
                scheduler['offload_active'] == true ? 'yes' : 'no',
              ),
              _kv(
                'Pending light',
                scheduler['pending_light'] == true ? 'yes' : 'no',
              ),
              _kv(
                'Pending heavy',
                scheduler['pending_heavy'] == true ? 'yes' : 'no',
              ),
              const Divider(height: Sp.x5),
              _kv('Engine running', derive['running'] == true ? 'yes' : 'no'),
              _kv('Stage', '${derive['stage'] ?? '—'}'),
              _kv('Mode', '${derive['mode'] ?? '—'}'),
              _kv('Force', derive['force'] == true ? 'yes' : 'no'),
              _kv('Started', _ageMs(derive['started_at'])),
              _kv(
                'Duration',
                derive['duration_ms'] == null
                    ? '—'
                    : '${((derive['duration_ms'] as num).toInt() / 1000).toStringAsFixed(1)}s',
              ),
              _kv('Raw pages', '${derive['raw_pages'] ?? 0}'),
              _kv('Raw rows', '${derive['raw_rows'] ?? 0}'),
              _kv('This day pages', '${derive['day_raw_pages'] ?? 0}'),
              _kv('This day rows', '${derive['day_raw_rows'] ?? 0}'),
              _kv('Max day pages', '${derive['max_day_raw_pages'] ?? 0}'),
              _kv('Max day rows', '${derive['max_day_raw_rows'] ?? 0}'),
              _kv('Per-day row cap', '500000'),
              _kv('Per-day page cap', '300'),
              _kv('Scope days', '${derive['scope_days'] ?? 0}'),
              _kv('Scope reason', '${derive['scope_reason'] ?? '—'}'),
              _kv('Scope from', _ts(derive['range_from_rec_ts'])),
              _kv('Scope to', _ts(derive['range_to_rec_ts'])),
              _kv('Prepared days', '${derive['prepared_days'] ?? 0}'),
              _kv('Todo days', '${derive['todo_days'] ?? 0}'),
              _kv('Done days', '${derive['done_days'] ?? 0}'),
              _kv('Skipped days', '${derive['skipped_days'] ?? 0}'),
              _kv('Active day', '${derive['active_day'] ?? '—'}'),
              if (app.reanalyzing)
                _kv(
                  'Re-analyze',
                  app.reanalyzeProgress.isEmpty
                      ? 'Working…'
                      : app.reanalyzeProgress,
                ),
              if (err != null && err.isNotEmpty) ...[
                const Divider(height: Sp.x5),
                Text('Last error', style: AppText.label),
                const SizedBox(height: Sp.x2),
                Text(
                  err,
                  style: AppText.caption.copyWith(
                    color: AppColors.warn,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _recentDaysSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Recent derived days'),
        ProCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: _recentDays.isEmpty
              ? Text(
                  'No derived day rows yet.',
                  style: AppText.body.copyWith(color: AppColors.inkMuted),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final day in _recentDays) ...[
                      Text(
                        day['day_id']?.toString() ?? '—',
                        style: AppText.label,
                      ),
                      const SizedBox(height: Sp.x1),
                      _kv('Raw max', _ts(day['raw_max_rec_ts'])),
                      _kv('Computed', _ageMs(day['computed_at'])),
                      _kv(
                        'State',
                        day['skipped'] == true
                            ? 'skipped'
                            : ((day['finalized'] as num?)?.toInt() == 1
                                  ? 'finalized'
                                  : 'open'),
                        valueColor: day['skipped'] == true
                            ? AppColors.warn
                            : AppColors.inkSoft,
                      ),
                      _kv('Readiness', '${day['readiness'] ?? '—'}'),
                      _kv('RMSSD', '${day['rmssd'] ?? '—'}'),
                      _kv('RHR', '${day['rhr'] ?? '—'}'),
                      _kv('Strain', '${day['strain'] ?? '—'}'),
                      _kv('Sleep min', '${day['tst_min'] ?? '—'}'),
                      if ((day['skip_reason'] ?? '').toString().isNotEmpty)
                        _kv('Skip reason', '${day['skip_reason']}'),
                      if (day != _recentDays.last)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Sp.x2),
                          child: Divider(height: 1),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _baselinesSection() {
    Map<String, dynamic> rolling = const {};
    final raw = _rolling?['payload_json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) rolling = d.cast<String, dynamic>();
      } catch (_) {
        /* ignore */
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Baseline inputs'),
        ProCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Rolling n', '${rolling['n'] ?? '—'}'),
              _kv('Rolling RHR', '${rolling['rhr'] ?? '—'}'),
              _kv('Rolling RMSSD', '${rolling['rmssd'] ?? '—'}'),
              _kv('Rolling readiness', '${rolling['readiness'] ?? '—'}'),
              const Divider(height: Sp.x5),
              for (final key in _baselineKeys)
                _kv('$key series', '${_seriesCounts[key] ?? 0} points'),
            ],
          ),
        ),
      ],
    );
  }
}
