// Strava — connect/disconnect, sync, and browse pulled activities (rides incl.
// Wahoo). The OAuth hop happens in the browser; we re-check status on resume.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class StravaScreen extends StatefulWidget {
  const StravaScreen({super.key});
  @override
  State<StravaScreen> createState() => _StravaScreenState();
}

class _StravaScreenState extends State<StravaScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _busy = false;
  bool _connected = false;
  int? _athleteId;
  String? _error;
  List<Map<String, dynamic>> _activities = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the Strava authorize page in the browser → re-check status.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final api = context.read<AppState>().api;
    if (api == null) {
      setState(() {
        _loading = false;
        _error = 'Sign in first.';
      });
      return;
    }
    try {
      final st = await api.stravaStatus();
      final connected = st['connected'] == true;
      final acts = connected ? await api.stravaActivities() : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _loading = false;
        _connected = connected;
        _athleteId = (st['athlete_id'] as num?)?.toInt();
        _activities = acts;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
        final api = context.read<AppState>().api;
        final r = await api!.stravaConnect();
        final url = r['url'] as String?;
        if (url != null) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          if (mounted) _snack('Authorize in your browser, then come back.');
        }
      });

  Future<void> _sync() => _run(() async {
        final api = context.read<AppState>().api;
        final r = await api!.stravaSync();
        _snack('Synced: ${r['pulled'] ?? 0} in, ${r['pushed'] ?? 0} out.');
        await _refresh();
      });

  Future<void> _disconnect() => _run(() async {
        await context.read<AppState>().api!.stravaDisconnect();
        await _refresh();
      });

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Strava')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    Sp.screen, Sp.x6, Sp.screen, Sp.x6),
                children: [
                  ProCard(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Connection', style: AppText.title),
                              const SizedBox(height: 2),
                              Text(
                                _connected
                                    ? 'Connected${_athleteId != null ? '  ·  #$_athleteId' : ''}'
                                    : 'Not connected',
                                style: AppText.bodySoft.copyWith(
                                    color: _connected
                                        ? AppColors.good
                                        : AppColors.inkSoft),
                              ),
                            ],
                          ),
                        ),
                        if (_busy)
                          const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ),
                  ),
                  const SizedBox(height: Sp.x4),

                  if (!_connected)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _connect,
                        child: const Text('Connect Strava'),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _busy ? null : _sync,
                            child: const Text('Sync now'),
                          ),
                        ),
                        const SizedBox(width: Sp.x3),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy ? null : _disconnect,
                            child: const Text('Disconnect'),
                          ),
                        ),
                      ],
                    ),

                  if (_error != null) ...[
                    const SizedBox(height: Sp.x4),
                    Text(_error!,
                        style: AppText.caption.copyWith(color: AppColors.bad)),
                  ],

                  const SizedBox(height: Sp.x6),

                  if (!_connected)
                    Text(
                      'Bring your rides (including Wahoo) into OpenStrap, and push '
                      'your other workouts to Strava. Your bike rides are never '
                      'duplicated.',
                      style: AppText.bodySoft,
                    )
                  else ...[
                    Text('Recent activities', style: AppText.title),
                    const SizedBox(height: Sp.x3),
                    if (_activities.isEmpty)
                      Text('No activities yet — tap “Sync now”.',
                          style: AppText.bodySoft)
                    else
                      ..._activities.map(_activityTile),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _activityTile(Map<String, dynamic> a) {
    final ts = (a['start_ts'] as num?)?.toInt();
    final date =
        ts != null ? DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal() : null;
    final dateStr = date != null ? '${date.day}.${date.month}.' : '';
    final km = ((a['distance_m'] as num?)?.toDouble() ?? 0) / 1000;
    final mins = (((a['elapsed_sec'] as num?)?.toInt() ?? 0) / 60).round();
    final avgHr = (a['avg_hr'] as num?)?.round();
    final type = (a['type'] ?? 'Activity').toString();
    final name = (a['name'] ?? type).toString();

    final meta = <String>[
      if (dateStr.isNotEmpty) dateStr,
      type,
      if (km > 0.1) '${km.toStringAsFixed(1)} km',
      if (mins > 0) '$mins min',
      if (avgHr != null) 'HR $avgHr',
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: ProCard(
        child: Row(
          children: [
            AppIcon(Ic.activity, size: 22, color: AppColors.coralDeep),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: AppText.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(meta, style: AppText.bodySoft),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
