// Notification settings — what reaches the OS shade, and when it may break
// through quiet hours. The in-app feed is always kept regardless of these toggles;
// these only gate OS notifications.
//
// Decision (locked): health-critical alerts (illness, unusual physiology, fever)
// can override quiet hours; recovery + reminders stay silent during the window.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../notify/notification_center.dart';
import '../../notify/notification_prefs.dart';
import '../../notify/notification_service.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

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

  Widget _intervalChip(int min) {
    final selected = _p.waterIntervalMin == min;
    return GestureDetector(
      onTap: () =>
          _update(_p.copyWith(waterIntervalMin: min), reschedule: true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: selected ? AppColors.coral : AppColors.inkSoft.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _fmtInterval(min),
          style: AppText.caption.copyWith(
            color: selected ? Colors.white : AppColors.ink,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
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
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.only(top: Sp.x7),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              const SectionHeader('What you get'),
              ProCard(
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
                    onChanged: (v) => _update(
                        _p.copyWith(remindersEnabled: v),
                        reschedule: true),
                  ),
                ]),
              ),
              const SizedBox(height: Sp.x7),
              const SectionHeader('Hydration'),
              ProCard(
                child: Column(children: [
                  _toggle(
                    title: 'Water reminder',
                    subtitle:
                        'A gentle nudge to drink water across your waking hours, '
                        'and a buzz on your strap when it\'s connected. Stays '
                        'silent during quiet hours.',
                    value: _p.waterEnabled,
                    onChanged: (v) => _update(_p.copyWith(waterEnabled: v),
                        reschedule: true),
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
                            children: _waterPresets
                                .map((m) => _intervalChip(m))
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ]),
              ),
              const SizedBox(height: Sp.x7),
              const SectionHeader('Quiet hours'),
              ProCard(
                child: Column(children: [
                  _toggle(
                    title: 'Silence during quiet hours',
                    subtitle:
                        'Recovery and reminders stay silent in this window.',
                    value: _p.quietEnabled,
                    onChanged: (v) => _update(_p.copyWith(quietEnabled: v)),
                  ),
                  if (_p.quietEnabled) ...[
                    const _HairLine(),
                    _timeRow('From', _p.quietStartMin, () => _pickTime(true)),
                    const _HairLine(),
                    _timeRow('To', _p.quietEndMin, () => _pickTime(false)),
                    const _HairLine(),
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
              const SizedBox(height: Sp.x6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
                child: Text(
                  'Everything you see here is generated on this device from your '
                  'own data — nothing is sent to a server. Your in-app history '
                  'keeps every alert even when a category is off.',
                  style: AppText.captionMuted,
                ),
              ),
              const SizedBox(height: Sp.x8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar() => Row(children: [
        RoundIconButton(Ic.arrowLeft,
            onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Notifications', style: AppText.h1),
              Text('Alerts, recovery & reminders',
                  style: AppText.caption.copyWith(color: AppColors.inkSoft)),
            ],
          ),
        ),
      ]);

  Widget _toggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
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
              activeThumbColor: AppColors.coral,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  Widget _timeRow(String label, int min, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.x3),
          child: Row(children: [
            Expanded(child: Text(label, style: AppText.title)),
            Text(_fmt(min),
                style: AppText.title.copyWith(color: AppColors.coral)),
            const SizedBox(width: Sp.x2),
            AppIcon(Ic.arrowRight, size: 16, color: AppColors.inkSoft),
          ]),
        ),
      );
}

class _HairLine extends StatelessWidget {
  const _HairLine();
  @override
  Widget build(BuildContext context) => Divider(
      height: Sp.x4, thickness: 1, color: AppColors.inkSoft.withValues(alpha: 0.12));
}
