// Notification settings — what reaches the OS shade, and when it may break
// through quiet hours. The in-app feed is always kept regardless of these toggles;
// these only gate OS notifications.
//
// Decision (locked): health-critical alerts (illness, unusual physiology, fever)
// can override quiet hours; recovery + reminders stay silent during the window.
// Presentation: design-system language; prefs/scheduling logic untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../notify/notification_center.dart';
import '../../notify/notification_prefs.dart';
import '../../notify/notification_service.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  NotificationPrefs _p = const NotificationPrefs();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await NotificationPrefs.load();
    if (!mounted) return;
    setState(() {
      _p = p;
      _loaded = true;
    });
    // Surface the OS permission prompt up front so the toggles actually do
    // something once granted.
    await NotificationService.instance.ensurePermission();
  }

  Future<void> _update(NotificationPrefs next,
      {bool reschedule = false}) async {
    setState(() => _p = next);
    await next.save();
    if (reschedule) {
      await NotificationCenter.instance.scheduleStandingReminders(next);
      // Re-arm the in-app strap-buzz timer to match the new schedule.
      if (mounted) await context.read<AppState>().armWaterReminder(next);
    }
  }

  String _fmt(int min) {
    final h = (min ~/ 60) % 24;
    final m = min % 60;
    final t = TimeOfDay(hour: h, minute: m);
    return t.format(context);
  }

  // Selectable hydration intervals (minutes). Modifiable — the user picks one.
  static const List<int> _waterPresets = [30, 60, 90, 120, 180, 240];

  String _fmtInterval(int min) {
    if (min < 60) return '$min min';
    final h = min / 60;
    final label = h == h.roundToDouble() ? '${h.toInt()}' : h.toString();
    return '$label hr${h == 1 ? '' : 's'}';
  }

  Future<void> _pickTime(bool start) async {
    final cur = start ? _p.quietStartMin : _p.quietEndMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (cur ~/ 60) % 24, minute: cur % 60),
    );
    if (picked == null) return;
    final mins = picked.hour * 60 + picked.minute;
    await _update(start
        ? _p.copyWith(quietStartMin: mins)
        : _p.copyWith(quietEndMin: mins));
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Notifications',
      subtitle: 'Alerts, recovery & reminders',
      actions: const [
        InfoDot(
          title: 'How notifications work',
          bullets: [
            'Everything is generated on this device from your own data — '
                'nothing is sent to a server.',
            'Your in-app history keeps every alert even when a category '
                'is off.',
            'Health alerts can break through quiet hours if you allow it.',
          ],
        ),
      ],
      children: [
        if (!_loaded)
          Skeleton.tileRow(rows: 3)
        else ...[
          const SectionHeader('What you get'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Health alerts',
                subtitle:
                    'Possible illness, unusual overnight physiology and '
                    'elevated temperature. High priority.',
                value: _p.healthEnabled,
                onChanged: (v) => _update(_p.copyWith(healthEnabled: v)),
              ),
              const _HairLine(),
              _toggle(
                title: 'Recovery',
                subtitle:
                    'Your daily recovery readiness and notable shifts in '
                    'your trends.',
                value: _p.recoveryEnabled,
                onChanged: (v) => _update(_p.copyWith(recoveryEnabled: v)),
              ),
              const _HairLine(),
              _toggle(
                title: 'Reminders',
                subtitle:
                    'Wind-down, movement nudges, step goal and the weekly '
                    'recap.',
                value: _p.remindersEnabled,
                onChanged: (v) =>
                    _update(_p.copyWith(remindersEnabled: v), reschedule: true),
              ),
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Hydration'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Water reminder',
                subtitle:
                    'A gentle nudge across your waking hours, and a buzz on '
                    'your strap when it\'s connected. Silent in quiet hours.',
                value: _p.waterEnabled,
                onChanged: (v) =>
                    _update(_p.copyWith(waterEnabled: v), reschedule: true),
              ),
              if (_p.waterEnabled) ...[
                const _HairLine(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('How often', style: AppText.title),
                      const SizedBox(height: 2),
                      Text('Every ${_fmtInterval(_p.waterIntervalMin)}.',
                          style: AppText.captionMuted),
                      const SizedBox(height: Sp.x3),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final m in _waterPresets)
                            ToggleChip(
                              _fmtInterval(m),
                              selected: _p.waterIntervalMin == m,
                              onTap: () => _update(
                                  _p.copyWith(waterIntervalMin: m),
                                  reschedule: true),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Quiet hours'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Silence during quiet hours',
                subtitle: 'Recovery and reminders stay silent in this window.',
                value: _p.quietEnabled,
                onChanged: (v) => _update(_p.copyWith(quietEnabled: v)),
              ),
              if (_p.quietEnabled) ...[
                const _HairLine(),
                ListRow(
                  title: 'From',
                  value: _fmt(_p.quietStartMin),
                  divider: true,
                  onTap: () => _pickTime(true),
                ),
                ListRow(
                  title: 'To',
                  value: _fmt(_p.quietEndMin),
                  divider: true,
                  onTap: () => _pickTime(false),
                ),
                _toggle(
                  title: 'Let health alerts through',
                  subtitle:
                      'Illness and temperature alerts can still notify you '
                      'during quiet hours.',
                  value: _p.criticalOverridesQuiet,
                  onChanged: (v) =>
                      _update(_p.copyWith(criticalOverridesQuiet: v)),
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x4),
        ],
      ],
    );
  }

  Widget _toggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.title),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.captionMuted),
                ],
              ),
            ),
            const SizedBox(width: Sp.x3),
            Switch(
              value: value,
              activeThumbColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      );
}

class _HairLine extends StatelessWidget {
  const _HairLine();
  @override
  Widget build(BuildContext context) =>
      Divider(height: Sp.x4, thickness: 1, color: AppColors.divider);
}
