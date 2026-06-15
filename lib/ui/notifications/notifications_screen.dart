// Notifications — the personalized feed from /notifications, with mark-read.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/payloads.dart';
import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

enum _Phase { loading, ready, empty, error }

class _NotificationsScreenState extends State<NotificationsScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  NotificationsData _data = const NotificationsData(0, []);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) {
      setState(() { _phase = _Phase.error; _error = 'Not signed in.'; });
      return;
    }
    setState(() { _phase = _Phase.loading; _error = null; });
    try {
      final res = await api.getNotifications();
      if (!mounted) return;
      final d = NotificationsData.fromJson(res);
      setState(() { _data = d; _phase = d.isEmpty ? _Phase.empty : _Phase.ready; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is ApiException ? e.body : e.toString();
      });
    }
  }

  Future<void> _markAll() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      await api.markNotificationsRead();
      await _load();
    } catch (_) {/* best-effort */}
  }

  // ── category → icon / color ──────────────────────────────────────────────────
  IconData _icon(String cat) {
    switch (cat) {
      case 'recovery': return Ic.recovery;
      case 'sleep': return Ic.moon;
      case 'load': return Ic.strain;
      case 'health': return Ic.heart;
      case 'milestone': return Ic.fire;
      default: return Ic.run;
    }
  }

  Color _color(int priority) {
    switch (priority) {
      case 3: return AppColors.bad;
      case 2: return AppColors.warn;
      case 1: return AppColors.coral;
      default: return AppColors.inkMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(),
            const SizedBox(height: Sp.x6),
            if (_phase == _Phase.loading)
              _loading()
            else if (_phase == _Phase.empty)
              _stateCard(Ic.check, 'All clear',
                  'No notifications right now. Personalized nudges from your own '
                  'data show up here — recovery, sleep debt, streaks and signals.')
            else if (_phase == _Phase.error)
              _stateCard(Ic.cloud, "Couldn't load notifications", _error ?? 'Please try again.')
            else ...[
              for (final n in _data.items) ...[
                _tile(n),
                const SizedBox(height: Sp.x3),
              ],
              const SizedBox(height: Sp.x4),
              _honesty(),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _topBar() => Row(children: [
        RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Notifications', style: AppText.h1),
            const SizedBox(height: 2),
            Text(_data.unread > 0 ? '${_data.unread} unread' : 'All caught up',
                style: AppText.caption),
          ],
        )),
        if (_data.unread > 0)
          TextButton(onPressed: _markAll, child: const Text('Mark all read')),
      ]);

  Widget _tile(NotificationItem n) {
    final c = _color(n.priority);
    return ProCard(
      color: n.read ? AppColors.surface : AppColors.surface,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
              color: c.withValues(alpha: n.read ? 0.08 : 0.16),
              borderRadius: BorderRadius.circular(R.chip)),
          child: AppIcon(_icon(n.category), size: 20,
              color: n.read ? AppColors.inkMuted : c),
        ),
        const SizedBox(width: Sp.x4),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(child: Text(n.title,
                  style: AppText.title.copyWith(
                      color: n.read ? AppColors.inkSoft : AppColors.ink))),
              if (!n.read)
                Container(width: 8, height: 8, decoration: BoxDecoration(
                    color: AppColors.coral, shape: BoxShape.circle)),
            ]),
            const SizedBox(height: 4),
            Text(n.body, style: AppText.bodySoft),
          ],
        )),
      ]),
    );
  }

  Widget _honesty() => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(Ic.shield, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x2),
        Expanded(child: Text(
          'Built from your own data with simple rules. '
          'Health cues are signals, not diagnoses.',
          style: AppText.captionMuted,
        )),
      ]);

  Widget _loading() => ProCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: SizedBox(height: 280,
            child: Center(child: CircularProgressIndicator(color: AppColors.coral))),
      );

  Widget _stateCard(IconData icon, String title, String message) => ProCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(color: AppColors.coralSoft, shape: BoxShape.circle),
            child: AppIcon(icon, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x5),
          OutlinedButton(onPressed: _load, child: const Text('Refresh')),
        ]),
      );
}
