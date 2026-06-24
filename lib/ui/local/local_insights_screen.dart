// LocalInsightsScreen — LOCAL-mode home + on-device-compute QA surface.
// Runs the Rust core (protocol decoder + analytics) over the raw frames stored in
// the local DB and renders the derived metrics. This is the proof that the dart:ffi
// → Rust pipeline computes real numbers on the phone (no cloud, no account).
//
// Scope note: pairing/drain WITHOUT an account is the remaining "deep integration"
// (see HANDOFF). For now this computes over whatever raw is already in raw_records
// (e.g. synced during cloud use), so the on-device compute path is fully QA-able.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../local/data_source.dart';
import '../../state/app_state.dart';
import '../onboarding/switch_to_cloud_screen.dart';

class LocalInsightsScreen extends StatefulWidget {
  const LocalInsightsScreen({super.key});
  @override
  State<LocalInsightsScreen> createState() => _LocalInsightsScreenState();
}

class _LocalInsightsScreenState extends State<LocalInsightsScreen> {
  final _ds = LocalDataSource();
  bool _busy = false;
  String? _error;
  int _days = 0;
  int _rawCount = 0;
  String? _latest;
  Map<String, dynamic>? _daily;
  Map<String, dynamic>? _sleep;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
  }

  Future<void> _recompute() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final app = context.read<AppState>();
      _rawCount = (await LocalDb.counts())['raw'] ?? 0;
      _days = await app.runLocalCompute();
      final dates = (await LocalDb.derivedDates()).toList()..sort();
      _latest = dates.isEmpty ? null : dates.last;
      if (_latest != null) {
        _daily = await _ds.daily(_latest!);
        _sleep = await _ds.sleep(_latest!);
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Insights'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_outlined),
            tooltip: 'Switch to Cloud',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SwitchToCloudScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _recompute,
        icon: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh),
        label: const Text('Recompute on device'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Computed on this phone', style: t.headlineSmall),
            const SizedBox(height: 4),
            Text('Rust core (decode + analytics) via dart:ffi — no cloud.', style: t.bodySmall),
            const SizedBox(height: 16),
            Text('Raw frames stored: $_rawCount   •   Days derived: $_days', style: t.bodyMedium),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(16), child: Text('Error: $_error')),
              ),
            ],
            if (!_busy && _rawCount == 0 && _error == null) ...[
              const SizedBox(height: 24),
              Text(
                'No raw band data on this device yet. Pair + sync your band (or use Cloud mode '
                'once to populate raw frames), then return here to compute on-device.',
                style: t.bodyMedium,
              ),
            ],
            if (_latest != null) ...[
              const SizedBox(height: 24),
              Text('Latest day: $_latest', style: t.titleMedium),
              const SizedBox(height: 12),
              ..._metricCards(t),
            ],
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? _m(dynamic v) => v is Map<String, dynamic> ? v : null;
  String _n(dynamic v) => v == null ? '—' : '$v';

  List<Widget> _metricCards(TextTheme t) {
    final d = _daily ?? const {};
    final strain = _m(d['strain']);
    final hrv = _m(d['hrv']);
    final rhr = _m(d['resting_hr']);
    final zones = _m(d['zones']);
    final recovery = _m(d['recovery']);
    final readiness = _m(d['readiness']);
    final nocturnal = _m(d['nocturnal']);
    final cvhr = _m(d['cvhr']);
    final load = _m(d['load']);
    final vo2 = _m(d['vo2max']);
    // The sleep store is now a bundle {sleep, hypnogram, periods, sleep_stress, ...}.
    final sb = _m(_sleep);
    final s = _m(sb?['sleep']);
    final stages = _m(s?['stages']);
    return [
      _card('Recovery', recovery == null ? '—' : '${_n(recovery['score'])}  (z ${_n(recovery['z'])})'),
      _card('Readiness', _n(readiness?['score'])),
      _card('Strain', strain == null ? '—' : '${_n(strain['score'])}  (TRIMP ${_n(strain['trimp'])})'),
      _card('HRV (RMSSD / SDNN)',
          hrv == null ? '—' : '${_n(hrv['rmssd'])} / ${_n(hrv['sdnn'])} ms  •  ${_n(hrv['n_beats'])} beats'),
      _card('Resting HR', rhr == null ? '—' : '${_n(rhr['resting_hr'])} bpm'),
      _card('Nocturnal dip', nocturnal == null ? '—' : '${_n(nocturnal['dip_pct'])}  •  sleeping ${_n(nocturnal['sleeping_hr_avg'])} bpm'),
      _card('CVHR (1 Hz apnea screen)',
          cvhr == null ? '—' : '${_n(cvhr['fcv_per_hour'])} cyc/h  ${cvhr['high_risk'] == true ? '⚠' : ''}'),
      _card('Load (ACWR)', load == null ? '—' : '${_n(load['acwr'])}  •  ${_n(load['band'])}'),
      _card('VO₂max (est.)', _n(vo2?['vo2max'])),
      _card('HR zones (min)', zones == null
          ? '—'
          : 'Z1 ${_n(zones['zone1_min'])}  Z2 ${_n(zones['zone2_min'])}  Z3 ${_n(zones['zone3_min'])}  Z4 ${_n(zones['zone4_min'])}  Z5 ${_n(zones['zone5_min'])}'),
      _card('Sleep', s == null
          ? '—'
          : '${_n(s['duration_min'])} min  •  eff ${_n(s['efficiency'])}'
              '${stages != null ? '  •  light ${_n(stages['light_min'])} / deep ${_n(stages['deep_min'])} / rem ${_n(stages['rem_min'])}' : ''}'),
    ];
  }

  Widget _card(String label, String value) => Card(
        child: ListTile(
          title: Text(label),
          subtitle: Text(value, style: Theme.of(context).textTheme.titleMedium),
        ),
      );
}
