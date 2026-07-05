// AiSettingsScreen — "AI briefings & journaling". Enable/disable the morning
// briefing, evening recap and pre-sleep journal prompt, set their times, and
// reach the BYOK key entry (the coach's existing CoachSettingsScreen — linked,
// not duplicated). Honest state when no key is set.
//
// On the design language: AppScaffold chrome, SurfaceCard sections with toggle
// + time rows, hairlines. Changing a pref re-asserts the OS schedule via
// AppState.refreshAiReminders (which routes through NotificationCenter).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/ai_prefs.dart';
import '../../coach/coach_config.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../coach/coach_settings_screen.dart';
import '../design/design.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  AiPrefs _p = const AiPrefs();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await AiPrefs.load();
    if (!mounted) return;
    setState(() {
      _p = p;
      _loaded = true;
    });
  }

  Future<void> _update(AiPrefs next) async {
    setState(() => _p = next);
    await next.save();
    if (mounted) await context.read<AppState>().refreshAiReminders();
  }

  String _fmt(int min) =>
      TimeOfDay(hour: (min ~/ 60) % 24, minute: min % 60).format(context);

  Future<void> _pickTime(int current, ValueChanged<int> apply) async {
    final picked = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: (current ~/ 60) % 24, minute: current % 60),
    );
    if (picked == null) return;
    apply(picked.hour * 60 + picked.minute);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<CoachConfig>();
    return AppScaffold(
      title: 'AI briefings',
      subtitle: 'Daily summaries & journaling',
      children: [
        if (!_loaded)
          Skeleton.tileRow(rows: 2)
        else ...[
          _keyCard(cfg).dsEnter(index: 0),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Daily briefings'),
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
                child: Column(children: [
                  _toggle(
                    title: 'Morning briefing',
                    subtitle:
                        'A short read on last night\'s sleep, recovery and what '
                        'it means for the day ahead.',
                    value: _p.morningEnabled,
                    onChanged: (v) =>
                        _update(_p.copyWith(morningEnabled: v)),
                  ),
                  if (_p.morningEnabled) ...[
                    const _HairLine(),
                    _timeRow('Time', _p.morningMin,
                        () => _pickTime(_p.morningMin,
                            (m) => _update(_p.copyWith(morningMin: m)))),
                  ],
                  const _HairLine(),
                  _toggle(
                    title: 'Evening recap',
                    subtitle:
                        'How the day landed — strain, movement and stress, in a '
                        'few glanceable lines.',
                    value: _p.eveningEnabled,
                    onChanged: (v) =>
                        _update(_p.copyWith(eveningEnabled: v)),
                  ),
                  if (_p.eveningEnabled) ...[
                    const _HairLine(),
                    _timeRow('Time', _p.eveningMin,
                        () => _pickTime(_p.eveningMin,
                            (m) => _update(_p.copyWith(eveningMin: m)))),
                  ],
                ]),
              ),
              const SizedBox(height: Sp.x6),
              const SectionHeader('Pre-sleep journaling'),
              SurfaceCard(
                padding: const EdgeInsets.all(Sp.x4),
                child: Column(children: [
                  _toggle(
                    title: 'Bedtime journal prompt',
                    subtitle:
                        'A nudge near your bedtime to log the day — by hand or '
                        'by chatting with your AI. Fires once a night.',
                    value: _p.journalEnabled,
                    onChanged: (v) =>
                        _update(_p.copyWith(journalEnabled: v)),
                  ),
                  if (_p.journalEnabled) ...[
                    const _HairLine(),
                    _timeRow(
                      'Time',
                      _p.journalMin >= 0
                          ? _p.journalMin
                          : AiPrefs.journalFallbackMin,
                      () => _pickTime(
                          _p.journalMin >= 0
                              ? _p.journalMin
                              : AiPrefs.journalFallbackMin,
                          (m) => _update(_p.copyWith(journalMin: m))),
                      valueOverride:
                          _p.journalMin < 0 ? 'Around bedtime' : null,
                    ),
                    if (_p.journalMin >= 0) ...[
                      const _HairLine(),
                      InkWell(
                        onTap: () =>
                            _update(_p.copyWith(journalMin: AiPrefs.journalAuto)),
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: Sp.x3),
                          child: Row(children: [
                            Expanded(
                                child: Text('Use my bedtime',
                                    style: AppText.title)),
                            AppIcon(Ic.clock,
                                size: 16, color: AppColors.inkSoft),
                          ]),
                        ),
                      ),
                    ],
                  ],
                ]),
              ),
          const SizedBox(height: Sp.x5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
            child: Text(
              'Briefings are written from your own on-device data by your '
              'own AI provider, using your own key. The only network call '
              'is to that provider — nothing goes to an OpenStrap server.',
              style: AppText.captionMuted,
            ),
          ),
          const SizedBox(height: Sp.x8),
        ],
      ],
    );
  }

  /// BYOK key state — links to the SAME CoachSettingsScreen the AI coach uses.
  Widget _keyCard(CoachConfig cfg) {
    final ok = cfg.configured;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      onTap: () => Navigator.of(context)
          .push(themedRoute((_) => const CoachSettingsScreen())),
      child: ListRow(
        icon: ok ? Ic.check : Ic.ai,
        // Spark art only in the "add a key" state — the connected state keeps
        // its green check.
        osIcon: ok ? null : OsIcon.ai,
        iconColor: ok ? AppColors.positive : AppColors.inkSoft,
        title: ok ? 'AI key connected' : 'Add your AI key',
        subtitle: ok
            ? 'Using ${cfg.model.isEmpty ? 'your provider' : cfg.model}. Tap to change.'
            : 'Briefings and journal chat need your own AI key. Tap to add one.',
        trailing:
            AppIcon(Ic.arrowRight, size: 16, color: AppColors.inkMuted),
      ),
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
              activeThumbColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  Widget _timeRow(String label, int min, VoidCallback onTap,
          {String? valueOverride}) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.x3),
          child: Row(children: [
            Expanded(child: Text(label, style: AppText.title)),
            Text(valueOverride ?? _fmt(min),
                style: AppText.title.copyWith(color: AppColors.accent)),
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
      height: Sp.x4,
      thickness: 1,
      color: AppColors.inkSoft.withValues(alpha: 0.12));
}
