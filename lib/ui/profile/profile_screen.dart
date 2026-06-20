// Profile and settings — account, paired device, profile fields, and backend.
// Edits use bottom sheets; destructive actions confirm.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../today/step_goal_screen.dart';
import 'gesture_section.dart';
import 'notification_relay_section.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  // Community links. Editable here; swap any URL and rebuild — no backend needed.
  static const List<({String label, IconData icon, String url})> _socials = [
    (label: 'GitHub', icon: Ic.github, url: 'https://github.com/OpenStrap'),
    (label: 'Discord', icon: Ic.discord, url: 'https://discord.gg/dUXds5MWkd'),
    (label: 'Reddit', icon: Ic.reddit, url: 'https://reddit.com/r/openstrap'),
    (label: 'X', icon: Ic.twitter, url: 'https://x.com/OpenStrap'),
  ];

  static Future<void> _openUrl(String url) async {
    // Don't gate on canLaunchUrl — it false-negatives on Android 11+ without a
    // <queries> manifest entry. Just launch and swallow failures.
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final units = context.watch<UnitsController>();
    final user = app.user ?? const {};
    final name = (user['name'] ?? '').toString().trim();
    final email = (user['email'] ?? '').toString().trim();

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x6, Sp.screen, 0),
        children: [
          _Header(
            name: name.isEmpty ? 'Your profile' : name,
            email: email,
            onEdit: () => _editProfileSheet(context, app),
          ),
          const SizedBox(height: Sp.x8),

          // ── Your device ──────────────────────────────────────────────
          const SectionHeader('Your device'),
          _DeviceHero(app: app),

          const SizedBox(height: Sp.x7),

          // ── Profile ──────────────────────────────────────────────────
          const SectionHeader('Profile'),
          ProCard(
            padding: const EdgeInsets.symmetric(
                horizontal: Sp.x5, vertical: Sp.x2),
            child: Column(
              children: [
                DetailRow(
                  icon: Ic.profile,
                  label: 'Name',
                  value: name.isEmpty ? 'Add' : name,
                  onTap: () => _editProfileSheet(context, app),
                ),
                const _HairDivider(),
                DetailRow(
                  icon: Ic.heart,
                  label: 'Sex',
                  value: _sexLabel(user['sex']?.toString()),
                  onTap: () => _editProfileSheet(context, app),
                ),
                const _HairDivider(),
                DetailRow(
                  icon: Ic.calendar,
                  label: 'Age',
                  value: user['age'] != null ? '${user['age']}' : 'Add',
                  onTap: () => _editProfileSheet(context, app),
                ),
                const _HairDivider(),
                DetailRow(
                  icon: Ic.activity,
                  label: 'Height',
                  value: user['height_cm'] != null
                      ? units.height(user['height_cm'] as num?)
                      : 'Add',
                  onTap: () => _editProfileSheet(context, app),
                ),
                const _HairDivider(),
                DetailRow(
                  icon: Ic.fire,
                  label: 'Weight',
                  value: user['weight_kg'] != null
                      ? units.weight(user['weight_kg'] as num?)
                      : 'Add',
                  onTap: () => _editProfileSheet(context, app),
                ),
                const _HairDivider(),
                DetailRow(
                  icon: Ic.mail,
                  label: 'Email',
                  value: email.isEmpty ? '—' : email,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Sp.x2, left: Sp.x2),
            child: Text('Body metrics improve your calorie estimate.',
                style: AppText.captionMuted),
          ),

          const SizedBox(height: Sp.x7),

          // ── Goals ────────────────────────────────────────────────────
          const SectionHeader('Goals'),
          ProCard(
            padding: const EdgeInsets.symmetric(
                horizontal: Sp.x5, vertical: Sp.x2),
            child: DetailRow(
              icon: Ic.run,
              label: 'Daily step goal',
              value: user['step_goal'] != null
                  ? '${user['step_goal']} steps'
                  : 'Set',
              onTap: () => Navigator.of(context).push(
                themedRoute((_) => StepGoalScreen(
                    goal: (user['step_goal'] as num?)?.toInt(),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: Sp.x7),

          // ── Units (local display preference) ─────────────────────────
          const SectionHeader('Units'),
          ProCard(
            padding: const EdgeInsets.all(Sp.x3),
            child: Row(
              children: [
                for (final s in UnitSystem.values)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => units.setSystem(s),
                      child: Container(
                        margin: EdgeInsets.only(right: s == UnitSystem.metric ? Sp.x2 : 0),
                        padding: const EdgeInsets.symmetric(vertical: Sp.x3),
                        decoration: BoxDecoration(
                          color: units.system == s ? AppColors.coralSoft : AppColors.surfaceSunk,
                          borderRadius: BorderRadius.circular(R.chip),
                        ),
                        child: Column(
                          children: [
                            Text(s.label,
                                textAlign: TextAlign.center,
                                style: AppText.label.copyWith(
                                    color: units.system == s ? AppColors.coralInk : AppColors.inkSoft)),
                            const SizedBox(height: 2),
                            Text(s == UnitSystem.metric ? 'kg · cm' : 'lb · ft/in',
                                textAlign: TextAlign.center, style: AppText.captionMuted),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: Sp.x7),

          // ── Cycle tracking (explicit opt-in) ─────────────────────────
          const SectionHeader('Cycle tracking'),
          ProCard(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x3),
            child: Row(
              children: [
                AppIcon(Ic.calendar, size: 18, color: AppColors.coral),
                const SizedBox(width: Sp.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Track menstrual cycle', style: AppText.title),
                      const SizedBox(height: 2),
                      Text('Log periods and see phase, next period & fertile window. '
                          'Off by default — nothing is computed until you turn this on.',
                          style: AppText.captionMuted),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Switch(
                  value: user['track_cycle'] == true || user['track_cycle'] == 1,
                  onChanged: (v) async {
                    try {
                      await app.updateProfile({'track_cycle': v ? 1 : 0});
                    } catch (_) {}
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: Sp.x7),

          // ── Appearance ───────────────────────────────────────────────
          const SectionHeader('Appearance'),
          ProCard(
            child: const AppearanceSelector(labeled: true),
          ),

          const SizedBox(height: Sp.x7),

          // ── Gestures ─────────────────────────────────────────────────
          const SectionHeader('Gestures'),
          const GestureSettingsCard(),

          const SizedBox(height: Sp.x7),

          // ── Notifications (Android only — section self-hides on iOS) ──
          if (app.notificationRelay.supported) ...[
            const SectionHeader('Notifications'),
            const NotificationRelaySection(),
            const SizedBox(height: Sp.x7),
          ],

          // ── Backend ──────────────────────────────────────────────────
          const SectionHeader('Backend'),
          ProCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(Sp.x3),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(R.chip),
                    ),
                    child: AppIcon(Ic.server,
                        size: 20, color: AppColors.inkSoft),
                  ),
                  const SizedBox(width: Sp.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Self-hosted server', style: AppText.title),
                        const SizedBox(height: 2),
                        Text(app.config?.url ?? '—',
                            style: AppText.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: Sp.x3),
                Text(
                  'Your data lives on this server. It can\'t be migrated, so the '
                  'backend is fixed for this account.',
                  style: AppText.captionMuted,
                ),
              ],
            ),
          ),

          const SizedBox(height: Sp.x7),

          // ── Community ────────────────────────────────────────────────
          const SectionHeader('Community'),
          ProCard(
            child: Row(children: [
              for (final s in _socials)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(R.card),
                    onTap: () => _openUrl(s.url),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sp.x3),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                              color: AppColors.surfaceSunk, shape: BoxShape.circle),
                          child: AppIcon(s.icon, size: 20, color: AppColors.ink),
                        ),
                        const SizedBox(height: Sp.x2),
                        Text(s.label, style: AppText.caption),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Sp.x2, left: Sp.x2),
            child: Text('Join the community, report bugs, or peek at the source.',
                style: AppText.captionMuted),
          ),

          const SizedBox(height: Sp.x7),

          // ── Account ──────────────────────────────────────────────────
          const SectionHeader('Account'),
          ProCard(
            padding: const EdgeInsets.symmetric(
                horizontal: Sp.x5, vertical: Sp.x1),
            child: DetailRow(
              icon: Ic.logout,
              label: 'Sign out',
              value: '',
              onTap: () => _confirmSignOut(context, app),
              trailing: AppIcon(Ic.arrowRight,
                  size: 16, color: AppColors.coral),
            ),
          ),

          const SizedBox(height: Sp.x7),

          // ── Honesty note ─────────────────────────────────────────────
          ProCard(
            color: AppColors.surfaceAlt,
            shadow: const [],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  AppIcon(Ic.shield, size: 18, color: AppColors.inkSoft),
                  const SizedBox(width: Sp.x2),
                  Text('How your metrics are made', style: AppText.label),
                ]),
                const SizedBox(height: Sp.x3),
                Text(
                  'Metrics are computed from published algorithms over the raw '
                  'sensor data your strap uploads. We show only what this hardware '
                  'can measure — there\'s no HRV or stress score, because this '
                  'firmware doesn\'t stream the RR intervals those need.',
                  style: AppText.bodySoft,
                ),
                const SizedBox(height: Sp.x3),
                Text('OpenStrap • MIT • the analytics source is public.',
                    style: AppText.captionMuted),
              ],
            ),
          ),

          const SizedBox(height: 110),
        ],
      ),
    );
  }

  static String _sexLabel(String? s) {
    if (s == null || s.isEmpty) return 'Add';
    return s[0].toUpperCase() + s.substring(1);
  }

  // ── Profile edit sheet ────────────────────────────────────────────────
  Future<void> _editProfileSheet(BuildContext context, AppState app) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ProfileEditSheet(app: app),
    );
  }

  // ── Confirm sign out ──────────────────────────────────────────────────
  Future<void> _confirmSignOut(BuildContext context, AppState app) async {
    final ok = await _confirm(
      context,
      title: 'Sign out?',
      body: 'Your local upload queue is kept and resumes after you sign back in.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (ok == true) await app.signOut();
  }
}

// ── Confirm dialog helper ──────────────────────────────────────────────────
Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.card)),
      title: Text(title, style: AppText.h2),
      content: Text(body, style: AppText.bodySoft),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.bad)
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

// ── Header ──────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  final String name;
  final String email;
  final VoidCallback onEdit;
  const _Header(
      {required this.name, required this.email, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: AppText.h1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              if (email.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(email,
                    style: AppText.bodySoft,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
        const SizedBox(width: Sp.x2),
        RoundIconButton(Ic.edit, onTap: onEdit),
      ],
    );
  }
}

// ── Device hero ───────────────────────────────────────────────────────────
class _DeviceHero extends StatelessWidget {
  final AppState app;
  const _DeviceHero({required this.app});

  @override
  Widget build(BuildContext context) {
    if (app.paired == null) {
      return ProCard(
        child: Row(children: [
          AppIcon(Ic.watch, size: 22, color: AppColors.inkMuted),
          const SizedBox(width: Sp.x3),
          Expanded(
              child: Text('No strap paired.', style: AppText.bodySoft)),
        ]),
      );
    }

    final d = app.device;
    final conn = d.connection;
    final (dotColor, statusText) = _status(conn, app.uploading);
    final batteryPct = d.batteryPct;
    final wristOn = d.wristOn;

    return NightCard(
      onTap: () => _openDeviceSheet(context, app),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(Sp.x3),
              decoration: BoxDecoration(
                color: AppColors.nightAlt,
                borderRadius: BorderRadius.circular(R.chip),
              ),
              child: const AppIcon(Ic.watch, size: 24, color: AppColors.onNight),
            ),
            const SizedBox(width: Sp.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.strapName ?? 'OpenStrap',
                      style: AppText.h2.copyWith(color: AppColors.onNight),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: dotColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: Sp.x2),
                    Text(statusText,
                        style: AppText.caption
                            .copyWith(color: AppColors.onNightSoft)),
                  ]),
                ],
              ),
            ),
            const AppIcon(Ic.arrowRight, size: 18, color: AppColors.onNightSoft),
          ]),
          const SizedBox(height: Sp.x5),
          Wrap(
            spacing: Sp.x6,
            runSpacing: Sp.x3,
            children: [
              _Stat(
                icon: Ic.battery,
                text: batteryPct == null
                    ? '—'
                    : '${batteryPct.round()}%${d.charging == true ? ' ⚡' : ''}',
              ),
              _Stat(
                icon: Ic.pulse,
                text: wristOn == null
                    ? 'Wrist —'
                    : (wristOn ? 'On wrist' : 'Off wrist'),
              ),
              _Stat(
                icon: Ic.watch,
                text: d.serial ?? app.paired?.serial ?? 'No serial',
              ),
            ],
          ),
        ],
      ),
    );
  }

  (Color, String) _status(String conn, bool uploading) {
    if (uploading) return (AppColors.coral, 'Syncing…');
    switch (conn) {
      case 'connected':
        return (AppColors.good, 'Connected');
      case 'syncing':
        return (AppColors.coral, 'Syncing…');
      case 'connecting':
      case 'scanning':
        return (AppColors.warn, 'Connecting…');
      default:
        return (AppColors.inkMuted, 'Disconnected');
    }
  }

  Future<void> _openDeviceSheet(BuildContext context, AppState app) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DeviceSheet(app: app),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Stat({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 18, color: AppColors.onNightSoft),
          const SizedBox(width: Sp.x2),
          Text(text,
              style: AppText.title.copyWith(color: AppColors.onNight)),
        ],
      );
}

// ── Device detail sheet (rename / alarm / forget) ──────────────────────────
class _DeviceSheet extends StatelessWidget {
  final AppState app;
  const _DeviceSheet({required this.app});

  @override
  Widget build(BuildContext context) {
    // Rebuild when device state changes (alarm/name/connection).
    final live = context.watch<AppState>();
    final connected = live.isConnected;
    final alarm = live.alarmEpoch;

    return _SheetShell(
      title: live.strapName ?? 'OpenStrap',
      children: [
        if (!connected)
          _Notice(
              'Connect to your strap to rename it or change the alarm.'),
        DetailRow(
          icon: Ic.edit,
          label: 'Rename strap',
          value: live.strapName ?? 'OpenStrap',
          onTap: connected ? () => _rename(context, live) : null,
        ),
        const _HairDivider(),
        DetailRow(
          icon: Ic.clock,
          label: 'Smart alarm',
          value: alarm != null ? _fmtAlarm(alarm) : 'Off',
          onTap: connected ? () => _setAlarm(context, live) : null,
        ),
        if (connected && alarm != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: OutlinedButton.icon(
              onPressed: () async {
                try {
                  await live.clearAlarm();
                  if (context.mounted) {
                    Navigator.pop(context);
                    _snack(context, 'Alarm cleared.');
                  }
                } catch (e) {
                  if (context.mounted) _snack(context, 'Clear failed: $e');
                }
              },
              icon: const AppIcon(Ic.cancel, size: 18),
              label: const Text('Clear alarm'),
            ),
          ),
        const _HairDivider(),
        DetailRow(
          icon: Ic.info,
          label: 'Serial',
          value: live.device.serial ?? live.paired?.serial ?? '—',
        ),
        const SizedBox(height: Sp.x4),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.bad,
              side: BorderSide(
                  color: AppColors.bad.withValues(alpha: 0.5), width: 1.5),
            ),
            onPressed: () => _forget(context, live),
            icon: AppIcon(Ic.cancel, size: 18, color: AppColors.bad),
            label: const Text('Forget device'),
          ),
        ),
      ],
    );
  }

  String _fmtAlarm(int epoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m  (${dt.month}/${dt.day})';
  }

  Future<void> _rename(BuildContext context, AppState app) async {
    final ctrl = TextEditingController(text: app.strapName ?? '');
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SheetShell(
        title: 'Rename strap',
        children: [
          TextField(
            controller: ctrl,
            maxLength: 20,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Strap name'),
          ),
          const SizedBox(height: Sp.x4),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () =>
                  Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await app.renameStrap(name);
      if (context.mounted) _snack(context, 'Renamed to "$name".');
    } catch (e) {
      if (context.mounted) _snack(context, 'Rename failed: $e');
    }
  }

  Future<void> _setAlarm(BuildContext context, AppState app) async {
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (now.hour + 8) % 24, minute: 0),
    );
    if (picked == null) return;
    var when =
        DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    try {
      await app.setAlarm(when);
      if (context.mounted) {
        _snack(context, 'Alarm set for ${picked.format(context)}.');
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Set failed: $e');
    }
  }

  Future<void> _forget(BuildContext context, AppState app) async {
    final ok = await _confirm(
      context,
      title: 'Forget this device?',
      body:
          'You\'ll need to re-pair your strap to sync again. Uploaded data stays '
          'on your server.',
      confirmLabel: 'Forget',
      destructive: true,
    );
    if (ok != true) return;
    await app.unpair();
    if (context.mounted) {
      Navigator.pop(context);
      _snack(context, 'Device forgotten.');
    }
  }
}

// ── Profile edit sheet ──────────────────────────────────────────────────────
class _ProfileEditSheet extends StatefulWidget {
  final AppState app;
  const _ProfileEditSheet({required this.app});
  @override
  State<_ProfileEditSheet> createState() => _ProfileEditSheetState();
}

class _ProfileEditSheetState extends State<_ProfileEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _age;
  late final TextEditingController _height;
  late final TextEditingController _weight;
  late final UnitsController _units;
  String? _sex;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final u = widget.app.user ?? const {};
    _units = context.read<UnitsController>();
    _name = TextEditingController(text: (u['name'] ?? '').toString());
    _age = TextEditingController(
        text: u['age'] != null ? '${u['age']}' : '');
    // Pre-fill height/weight in the user's chosen units (stored as cm/kg).
    _height = TextEditingController(text: _units.heightField(u['height_cm'] as num?));
    _weight = TextEditingController(text: _units.weightField(u['weight_kg'] as num?));
    _sex = u['sex']?.toString();
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.app.updateProfile({
        'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
        'age': int.tryParse(_age.text),
        // Convert from the user's display units back to metric for storage.
        'height_cm': _units.heightToCm(_height.text),
        'weight_kg': _units.weightToKg(_weight.text),
        if (_sex != null) 'sex': _sex,
      });
      if (mounted) {
        Navigator.pop(context);
        _snack(context, 'Profile saved.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack(context, 'Save failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = (widget.app.user?['email'] ?? '').toString();
    return _SheetShell(
      title: 'Edit profile',
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: Sp.x3),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _age,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Age'),
            ),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: TextField(
              controller: _height,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _units.heightLabel),
            ),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: TextField(
              controller: _weight,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _units.weightLabel),
            ),
          ),
        ]),
        const SizedBox(height: Sp.x4),
        Text('Sex (optional)', style: AppText.label),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x2,
          children: [
            for (final opt in const ['male', 'female', 'other'])
              ChoiceChip(
                label: Text(opt[0].toUpperCase() + opt.substring(1)),
                selected: _sex == opt,
                onSelected: (_) =>
                    setState(() => _sex = _sex == opt ? null : opt),
                selectedColor: AppColors.coralSoft,
                labelStyle: AppText.label.copyWith(
                    color: _sex == opt ? AppColors.coralInk : AppColors.inkSoft),
                backgroundColor: AppColors.surfaceAlt,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(R.pill)),
                side: BorderSide.none,
              ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text('Improves your calorie estimate.', style: AppText.captionMuted),
        const SizedBox(height: Sp.x3),
        Text(
            email.isEmpty
                ? 'Email is locked to your account.'
                : 'Email ($email) is locked to your account.',
            style: AppText.captionMuted),
        const SizedBox(height: Sp.x5),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Save profile'),
          ),
        ),
      ],
    );
  }
}

// ── Shared sheet shell ──────────────────────────────────────────────────────
class _SheetShell extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SheetShell({required this.title, required this.children});
  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Sp.x6, Sp.x2, Sp.x6, Sp.x6 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.h2),
          const SizedBox(height: Sp.x5),
          ...children,
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  const _Notice(this.text);
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: Sp.x3),
        padding: const EdgeInsets.all(Sp.x3),
        decoration: BoxDecoration(
          color: AppColors.warnSoft,
          borderRadius: BorderRadius.circular(R.chip),
        ),
        child: Row(children: [
          AppIcon(Ic.info, size: 18, color: AppColors.warn),
          const SizedBox(width: Sp.x2),
          Expanded(child: Text(text, style: AppText.caption)),
        ]),
      );
}

class _HairDivider extends StatelessWidget {
  const _HairDivider();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: AppColors.divider);
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
