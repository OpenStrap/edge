// Notifications — the personalized feed from /notifications, with mark-read.
// Presentation: design-system language (AppScaffold, SurfaceCard rows, domain
// accents per category, StateCard states). Feed logic untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/payloads.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

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
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() { _phase = _Phase.error; _error = 'Pair your strap first.'; });
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
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  Future<void> _markAll() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      await api.markNotificationsRead();
      await _load();
    } catch (_) {/* best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Notifications',
      subtitle: _data.unread > 0 ? '${_data.unread} unread' : 'All caught up',
      actions: [
        if (_data.unread > 0)
          TextButton(onPressed: _markAll, child: const Text('Mark all read')),
      ],
      children: [
        if (_phase == _Phase.loading)
          Skeleton.tileRow(rows: 4)
        else if (_phase == _Phase.empty)
          StateCard(
            icon: OsIcon.notifications,
            title: 'All clear',
            message:
                'Personalized nudges from your own data show up here — '
                'recovery, sleep debt, streaks and signals.',
            actionLabel: 'Refresh',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: OsIcon.notifications,
            title: "Couldn't load notifications",
            message: _error ?? 'Please try again.',
            actionLabel: 'Retry',
            onAction: _load,
          )
        else ...[
          ...dsStaggered([
            for (final n in _data.items) ...[
              NotificationTile(item: n),
              const SizedBox(height: Sp.x3),
            ],
          ]),
          const SizedBox(height: Sp.x2),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppIcon(OsIcon.shield, size: 14, color: AppColors.inkMuted),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                'Built from your own data with simple rules. '
                'Health cues are signals, not diagnoses.',
                style: AppText.captionMuted,
              ),
            ),
          ]),
        ],
      ],
    );
  }
}

/// One notification row — pure (render-testable). Category picks the domain
/// accent; priority tints it; unread carries a quiet ember dot.
class NotificationTile extends StatelessWidget {
  final NotificationItem item;
  const NotificationTile({super.key, required this.item});

  /// Illustrated category icon — read-state dims via opacity, the
  /// art is never tinted.
  OsIcon get _osIcon => switch (item.category) {
        'recovery' => OsIcon.recovery,
        'sleep' => OsIcon.sleep,
        'load' => OsIcon.bodyStrain,
        'health' => OsIcon.heart,
        'milestone' => OsIcon.calories,
        _ => OsIcon.steps,
      };

  Color get _accent {
    // Priority escalates the tone; otherwise the category's domain accent.
    if (item.priority >= 3) return AppColors.critical;
    if (item.priority == 2) return AppColors.warn;
    return switch (item.category) {
      'recovery' => DomainAccent.recovery,
      'sleep' => DomainAccent.sleep,
      'load' => DomainAccent.strain,
      'health' => DomainAccent.heart,
      'milestone' => DomainAccent.calories,
      _ => DomainAccent.steps,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = _accent;
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: c.withValues(alpha: item.read ? 0.08 : 0.14),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: OsAppIcon(_osIcon, size: 38,
                opacity: item.read ? 0.55 : 1.0),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      item.title,
                      style: AppText.title.copyWith(
                          color: item.read ? AppColors.inkSoft : AppColors.ink),
                    ),
                  ),
                  if (!item.read)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: AppColors.accent, shape: BoxShape.circle),
                    ),
                ]),
                const SizedBox(height: 4),
                Text(item.body, style: AppText.bodySoft),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
