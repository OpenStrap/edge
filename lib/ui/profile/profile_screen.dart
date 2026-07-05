// Profile and settings — account, paired device, profile fields, data tools,
// health sync, notifications, AI, appearance, developer. Edits use bottom
// sheets; destructive actions confirm.
//
// Presentation: normalized onto the design system (SurfaceCard + ListRow
// sections, the ink DeviceTile, SegmentedControl units). Every action is
// preserved; only the rendering moved. [DeviceTile] is pure so render tests
// can cover it in both palettes.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/db.dart';
import '../../health/health_export.dart';
import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../../debug/debug_mode.dart';
import '../../theme/theme_switcher.dart';
import '../ai/ai_settings_screen.dart';
import '../design/design.dart';
import '../design/gallery_screen.dart';
import '../import/import_screen.dart';
import '../today/step_goal_screen.dart';
import 'advanced_data_screen.dart';
import 'data_history_screen.dart';
import 'gesture_section.dart';
import 'notification_relay_section.dart';
import 'notification_settings_screen.dart';

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

    return AppScaffold(
      titleWidget: Text(
        name.isEmpty ? 'Your profile' : name,
        style: AppText.h1,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        RoundIconButton(Ic.edit,
            osIcon: OsIcon.edit,
            onTap: () => _editProfileSheet(context, app)),
      ],
      children: [
          // ── Your device ──────────────────────────────────────────────
          const SectionHeader('Your device'),
          _deviceTile(context, app),
          // Android: battery-optimization (Doze) exemption — without it the OS
          // can freeze the background BLE session between events overnight.
          if (Platform.isAndroid) const _KeepAliveRow(),

          const SizedBox(height: Sp.x6),

          // ── Profile ──────────────────────────────────────────────────
          const SectionHeader('Profile'),
          _SettingsCard(rows: [
            ListRow(
              title: 'Name',
              value: name.isEmpty ? 'Add' : name,
              divider: true,
              onTap: () => _editProfileSheet(context, app),
            ),
            ListRow(
              title: 'Sex',
              value: _sexLabel(user['sex']?.toString()),
              divider: true,
              onTap: () => _editProfileSheet(context, app),
            ),
            ListRow(
              title: 'Age',
              value: user['age'] != null ? '${user['age']}' : 'Add',
              divider: true,
              onTap: () => _editProfileSheet(context, app),
            ),
            ListRow(
              title: 'Height',
              value: user['height_cm'] != null
                  ? units.height(user['height_cm'] as num?)
                  : 'Add',
              divider: true,
              onTap: () => _editProfileSheet(context, app),
            ),
            ListRow(
              title: 'Weight',
              value: user['weight_kg'] != null
                  ? units.weight(user['weight_kg'] as num?)
                  : 'Add',
              onTap: () => _editProfileSheet(context, app),
            ),
          ]),
          const _CardNote('Body metrics improve your calorie estimate.'),

          const SizedBox(height: Sp.x6),

          // ── Goals ────────────────────────────────────────────────────
          const SectionHeader('Goals'),
          _SettingsCard(rows: [
            ListRow(
              icon: Ic.run,
              osIcon: OsIcon.steps,
              title: 'Daily step goal',
              value: user['step_goal'] != null
                  ? '${user['step_goal']} steps'
                  : 'Set',
              onTap: () => Navigator.of(context).push(
                themedRoute(
                  (_) => StepGoalScreen(
                    goal: (user['step_goal'] as num?)?.toInt(),
                  ),
                ),
              ),
            ),
          ]),

          const SizedBox(height: Sp.x6),

          // ── Data ─────────────────────────────────────────────────────
          const SectionHeader('Data'),
          _SettingsCard(rows: [
            ListRow(
              icon: Ic.history,
              title: 'Import data',
              value: 'NOOP · Edge · WHOOP',
              divider: true,
              onTap: () => Navigator.of(
                context,
              ).push(themedRoute((_) => const ImportScreen())),
            ),
            ListRow(
              icon: Ic.cloud,
              title: 'Companion URL',
              value: app.companionConfigured
                  ? _shortUrl(app.companionUrl)
                  : 'Not set',
              divider: true,
              onTap: () => _editCompanionUrl(context, app),
            ),
            ListRow(
              icon: Ic.chart,
              title: 'Re-analyze data',
              value: app.reanalyzing
                  ? (app.reanalyzeProgress.isEmpty
                        ? 'Working…'
                        : app.reanalyzeProgress)
                  : 'Run',
              divider: true,
              onTap: () async {
                if (app.reanalyzing) return;
                final messenger = ScaffoldMessenger.of(context);
                final n = await app.reanalyzeAll();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      n > 0
                          ? 'Analyzed $n day${n == 1 ? '' : 's'} of stored data.'
                          : 'No raw data to analyze yet.',
                    ),
                  ),
                );
              },
            ),
            // Export the local SQLite store (transactionally-consistent VACUUM
            // INTO snapshot) via the share sheet — for backup, moving to a new
            // device ("Import from Edge"), or sharing for debugging.
            Builder(
              builder: (rowCtx) => ListRow(
                icon: Ic.server,
                title: 'Export data (.db)',
                value: 'Share',
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(rowCtx);
                  final box = rowCtx.findRenderObject() as RenderBox?;
                  try {
                    final path = await LocalDb.exportCopy();
                    await Share.shareXFiles(
                      [XFile(path)],
                      text: 'OpenStrap data export',
                      sharePositionOrigin: box != null
                          ? box.localToGlobal(Offset.zero) & box.size
                          : null,
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Export failed: $e')),
                    );
                  }
                },
                divider: true,
              ),
            ),
            // Per-day data manager (browse, export, delete stored days).
            ListRow(
              icon: Ic.history,
              title: 'Data history',
              value: 'Manage',
              divider: advancedDebugMode,
              onTap: () => Navigator.of(
                context,
              ).push(themedRoute((_) => const DataHistoryScreen())),
            ),
            // Debug-build-only deep inspection tools (raw stores, sync ledger).
            if (advancedDebugMode)
              ListRow(
                icon: Ic.settings,
                title: 'Advanced data',
                value: 'Debug tools',
                onTap: () => Navigator.of(
                  context,
                ).push(themedRoute((_) => const AdvancedDataScreen())),
              ),
          ]),

          const SizedBox(height: Sp.x6),

          // ── Apple Health (iOS) / Health Connect (Android) ─────────────
          SectionHeader(app.healthStoreName),
          _HealthSection(app: app),

          const SizedBox(height: Sp.x6),

          // ── Units (local display preference) ─────────────────────────
          const SectionHeader('Units'),
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedControl(
                  options: [for (final s in UnitSystem.values) s.label],
                  index: UnitSystem.values.indexOf(units.system),
                  expanded: true,
                  onChanged: (i) => units.setSystem(UnitSystem.values[i]),
                ),
                const SizedBox(height: Sp.x2),
                Center(
                  child: Text(
                    units.system == UnitSystem.metric
                        ? 'kg · cm'
                        : 'lb · ft/in',
                    style: AppText.captionMuted,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: Sp.x6),

          // ── Cycle tracking (explicit opt-in) ─────────────────────────
          const SectionHeader('Cycle tracking'),
          _ToggleCard(
            icon: Ic.calendar,
            iconColor: DomainAccent.cycle,
            title: 'Track menstrual cycle',
            subtitle:
                'Log periods and see phase, next period & fertile window. '
                'Off by default — nothing is computed until you turn this on.',
            value: user['track_cycle'] == true || user['track_cycle'] == 1,
            onChanged: (v) async {
              try {
                await app.updateProfile({'track_cycle': v ? 1 : 0});
              } catch (_) {}
            },
          ),

          const SizedBox(height: Sp.x6),

          // ── Privacy (opt-in companion data — also offered at onboarding) ──
          const SectionHeader('Privacy'),
          _ToggleCard(
            icon: Ic.info,
            title: 'Send anonymous diagnostics',
            subtitle:
                'Crash/error reports plus basic device info. No health data. '
                'On by default — switch off anytime.',
            value: app.telemetryConsent,
            onChanged: (v) => app.setTelemetryConsent(v),
          ),
          const SizedBox(height: Sp.x3),
          _ToggleCard(
            icon: Ic.activity,
            title: 'Contribute my health data',
            subtitle:
                'Periodically upload your on-device database (over Wi-Fi, '
                'while charging) to improve the algorithms. On by default — '
                'switch off anytime.',
            value: app.healthShareConsent,
            onChanged: (v) => app.setHealthShareConsent(v),
          ),

          const SizedBox(height: Sp.x6),

          // ── Appearance ───────────────────────────────────────────────
          const SectionHeader('Appearance'),
          const SurfaceCard(child: AppearanceSelector(labeled: true)),

          const SizedBox(height: Sp.x6),

          // ── Gestures ─────────────────────────────────────────────────
          const SectionHeader('Gestures'),
          const GestureSettingsCard(),

          const SizedBox(height: Sp.x6),

          // ── Notifications ────────────────────────────────────────────
          const SectionHeader('Notifications'),
          _SettingsCard(rows: [
            ListRow(
              icon: Ic.bell,
              osIcon: OsIcon.notifications,
              title: 'Alerts & reminders',
              value: 'Manage',
              onTap: () => Navigator.of(
                context,
              ).push(themedRoute((_) => const NotificationSettingsScreen())),
            ),
          ]),
          // Notification relay (Android only — self-hides on iOS).
          if (app.notificationRelay.supported) ...[
            const SizedBox(height: Sp.x3),
            const NotificationRelaySection(),
          ],
          const SizedBox(height: Sp.x6),

          // ── AI briefings & journaling (BYOK) ──────────────────────────
          const SectionHeader('AI briefings & journaling'),
          _SettingsCard(rows: [
            ListRow(
              icon: Ic.ai,
              osIcon: OsIcon.ai,
              title: 'Briefings & journal',
              value: 'Manage',
              onTap: () => Navigator.of(context)
                  .push(themedRoute((_) => const AiSettingsScreen())),
            ),
          ]),
          const SizedBox(height: Sp.x6),

          // ── Community ────────────────────────────────────────────────
          const SectionHeader('Community'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
                horizontal: Sp.x2, vertical: Sp.x2),
            child: Row(
              children: [
                for (final s in _socials)
                  Expanded(
                    child: Pressable(
                      borderRadius: BorderRadius.circular(R.cardSm),
                      onTap: () => _openUrl(s.url),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: Sp.x3),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(11),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceAlt,
                                shape: BoxShape.circle,
                              ),
                              child: AppIcon(s.icon,
                                  size: 20, color: AppColors.ink),
                            ),
                            const SizedBox(height: Sp.x2),
                            Text(s.label, style: AppText.caption),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const _CardNote(
              'Join the community, report bugs, or peek at the source.'),

          const SizedBox(height: Sp.x6),

          // ── Reset ────────────────────────────────────────────────────
          const SectionHeader('Reset'),
          _SettingsCard(rows: [
            ListRow(
              icon: Ic.logout,
              iconColor: AppColors.critical,
              title: 'Reset profile',
              onTap: () => _confirmSignOut(context, app),
            ),
          ]),

          const SizedBox(height: Sp.x6),

          // ── Developer ────────────────────────────────────────────────
          const SectionHeader('Developer'),
          _SettingsCard(rows: [
            ListRow(
              icon: Ic.edit,
              title: 'Design gallery',
              value: 'All components',
              onTap: () => Navigator.of(context)
                  .push(themedRoute((_) => const DesignGalleryScreen())),
            ),
          ]),

          const SizedBox(height: Sp.x6),

          // ── Honesty note ─────────────────────────────────────────────
          SurfaceCard(
            level: 0,
            color: AppColors.surfaceAlt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppIcon(Ic.shield, size: 18, color: AppColors.inkSoft),
                    const SizedBox(width: Sp.x2),
                    Text('How your metrics are made', style: AppText.label),
                  ],
                ),
                const SizedBox(height: Sp.x3),
                Text(
                  'Metrics are computed on this phone from published algorithms '
                  'over your strap\'s raw sensor data. We show only what the '
                  'hardware can honestly measure — estimates are labelled, and '
                  'a metric without enough data stays blank instead of guessed.',
                  style: AppText.bodySoft,
                ),
                const SizedBox(height: Sp.x3),
                Text(
                  'OpenStrap • MIT • the analytics source is public.',
                  style: AppText.captionMuted,
                ),
              ],
            ),
          ),

          const SizedBox(height: 110),
      ],
    );
  }

  // ── Device tile wiring ─────────────────────────────────────────────────
  Widget _deviceTile(BuildContext context, AppState app) {
    if (app.paired == null) {
      return SurfaceCard(
        child: Row(
          children: [
            AppIcon(Ic.watch, size: 22, color: AppColors.inkMuted),
            const SizedBox(width: Sp.x3),
            Expanded(child: Text('No strap paired.', style: AppText.bodySoft)),
          ],
        ),
      );
    }

    final d = app.device;
    final conn = d.connection;
    final (statusTone, statusText) = switch (conn) {
      // Single listening mode — no separate "syncing" state; history + live
      // records both stream over the one link.
      'connected' => (ChipTone.positive, 'Connected'),
      'connecting' || 'scanning' => (ChipTone.warn, 'Connecting…'),
      _ => (ChipTone.neutral, 'Disconnected'),
    };

    return DeviceTile(
      name: app.strapName ?? 'OpenStrap',
      statusText: statusText,
      statusTone: statusTone,
      battery: d.batteryPct == null
          ? '—'
          : '${d.batteryPct!.round()}%${d.charging == true ? ' ⚡' : ''}',
      wrist: d.wristOn == null ? '—' : (d.wristOn! ? 'On wrist' : 'Off wrist'),
      serial: d.serial ?? app.paired?.serial ?? '—',
      // Manual pull: anything the strap flashed that we don't hold yet, over
      // the CURRENT connection (no reconnect). Only offered while connected.
      onSyncNow: conn == 'connected' ? () => app.forceResync() : null,
      onTap: () => _openDeviceSheet(context, app),
    );
  }

  Future<void> _openDeviceSheet(BuildContext context, AppState app) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
      builder: (_) => _DeviceSheet(app: app),
    );
  }

  static String _sexLabel(String? s) {
    if (s == null || s.isEmpty) return 'Add';
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Compact host for the row value (drop scheme + trailing path).
  static String _shortUrl(String url) {
    var u = url.replaceFirst(RegExp(r'^https?://'), '');
    final slash = u.indexOf('/');
    if (slash > 0) u = u.substring(0, slash);
    return u;
  }

  /// Edit the companion URL — the single backend the app talks to (announcements,
  /// OTA, telemetry, and existing-user import). Blank clears the override → falls
  /// back to the build-time COMPANION_URL.
  Future<void> _editCompanionUrl(BuildContext context, AppState app) async {
    final ctrl = TextEditingController(text: app.companionUrl);
    final messenger = ScaffoldMessenger.of(context);
    final url = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(R.card),
        ),
        title: Text('Companion URL', style: AppText.h2),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The one backend the app connects to — app updates, announcements, '
              'opt-in diagnostics and existing-user import. Leave blank to use '
              'the build default.',
              style: AppText.captionMuted,
            ),
            const SizedBox(height: Sp.x3),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'https://your-worker.workers.dev',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null) return; // cancelled
    await app.setCompanionUrl(url);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          url.isEmpty
              ? 'Companion URL cleared — using the build default.'
              : 'Companion URL saved.',
        ),
      ),
    );
  }

  // ── Profile edit sheet ────────────────────────────────────────────────
  Future<void> _editProfileSheet(BuildContext context, AppState app) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
      builder: (_) => _ProfileEditSheet(app: app),
    );
  }

  // ── Confirm sign out ──────────────────────────────────────────────────
  Future<void> _confirmSignOut(BuildContext context, AppState app) async {
    final ok = await _confirm(
      context,
      title: 'Reset profile?',
      body:
          'Clears your local profile (name, age, body metrics) and forgets your '
          'strap. Your stored band data stays on this phone.',
      confirmLabel: 'Reset',
      destructive: true,
    );
    if (ok == true) await app.signOut();
  }
}

// ── Section building blocks ─────────────────────────────────────────────────

/// One SurfaceCard wrapping a stack of [ListRow]s — the settings-section idiom.
class _SettingsCard extends StatelessWidget {
  final List<Widget> rows;
  const _SettingsCard({required this.rows});
  @override
  Widget build(BuildContext context) => SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x1),
        child: Column(children: rows),
      );
}

/// A quiet caption under a card.
class _CardNote extends StatelessWidget {
  final String text;
  const _CardNote(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Sp.x2, left: Sp.x2),
        child: Text(text, style: AppText.captionMuted),
      );
}

/// A titled toggle card (icon tile + title + one-liner + Switch).
class _ToggleCard extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleCard({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = iconColor ?? AppColors.accent;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x2),
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(icon, size: 18, color: c),
          ),
          const SizedBox(width: Sp.x3),
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
}

// ── Device tile (pure) ──────────────────────────────────────────────────────

/// The paired-device card — the language's inverted ink tile: name, a status
/// chip, and the three facts that matter (battery / wrist / serial). Tap opens
/// the device sheet; an optional quiet "Sync now" action runs a manual pull.
/// No sync-cadence or data-freshness copy — the connection chip is the story.
class DeviceTile extends StatefulWidget {
  final String name;
  final String statusText;
  final ChipTone statusTone;
  final String battery;
  final String wrist;
  final String serial;
  final VoidCallback? onTap;
  final Future<void> Function()? onSyncNow;

  const DeviceTile({
    super.key,
    required this.name,
    required this.statusText,
    required this.statusTone,
    required this.battery,
    required this.wrist,
    required this.serial,
    this.onTap,
    this.onSyncNow,
  });

  @override
  State<DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<DeviceTile> {
  bool _syncing = false;

  Future<void> _sync() async {
    final run = widget.onSyncNow;
    if (run == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      await run();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BentoTile(
      tone: BentoTone.ink,
      padding: const EdgeInsets.all(Sp.x5),
      onTap: widget.onTap,
      child: Builder(builder: (context) {
        final tone = ToneScope.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(Sp.x3),
                  decoration: BoxDecoration(
                    color: AppColors.nightAlt,
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child:
                      AppIcon(Ic.watch, size: 24, color: AppColors.onNight),
                ),
                const SizedBox(width: Sp.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.name,
                        style: AppText.h2.copyWith(color: tone.fg),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: Sp.x2),
                      StatusChip(widget.statusText, tone: widget.statusTone),
                    ],
                  ),
                ),
                if (widget.onTap != null)
                  AppIcon(Ic.arrowRight, size: 18, color: tone.fgMuted),
              ],
            ),
            const SizedBox(height: Sp.x5),
            Row(
              children: [
                Expanded(
                  child: _fact(Ic.battery, 'Battery', widget.battery, tone),
                ),
                Expanded(
                  child: _fact(Ic.pulse, 'Wrist', widget.wrist, tone),
                ),
              ],
            ),
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                Expanded(
                  child: _fact(Ic.info, 'Serial', widget.serial, tone),
                ),
                if (widget.onSyncNow != null)
                  Pressable(
                    pressedScale: 0.95,
                    borderRadius: BorderRadius.circular(R.pill),
                    onTap: _syncing ? null : _sync,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Sp.x3 + 2, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.nightAlt,
                        borderRadius: BorderRadius.circular(R.pill),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_syncing) ...[
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: tone.fgMuted,
                              ),
                            ),
                            const SizedBox(width: Sp.x2),
                          ],
                          Text(
                            _syncing ? 'Syncing…' : 'Sync now',
                            style: AppText.caption.copyWith(color: tone.fg),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      }),
    );
  }

  Widget _fact(IconData icon, String label, String value, ToneColors tone) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(icon, size: 16, color: tone.fgFaint),
        const SizedBox(width: Sp.x2),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label.toUpperCase(),
                  style: AppText.overline
                      .copyWith(fontSize: 9, color: tone.fgFaint)),
              Text(
                value,
                style: AppText.title.copyWith(color: tone.fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
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
      backgroundColor: AppColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(R.card),
      ),
      title: Text(title, style: AppText.h2),
      content: Text(body, style: AppText.bodySoft),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.critical)
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

// ── Health section ──────────────────────────────────────────────────────────
/// Apple Health (iOS) / Health Connect (Android) export controls: a toggle to
/// keep pushing each day's metrics, plus state-aware CTAs (grant / install).
class _HealthSection extends StatelessWidget {
  final AppState app;
  const _HealthSection({required this.app});

  @override
  Widget build(BuildContext context) {
    final store = app.healthStoreName;
    final st = app.healthState;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(Sp.x2),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(Ic.heart, size: 18, color: AppColors.onAccentSoft),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sync to $store', style: AppText.title),
                    const SizedBox(height: 1),
                    Text(
                      'Sleep, resting HR, HRV, respiratory rate, energy & workouts.',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
              Switch(
                value: app.healthSyncEnabled,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => app.setHealthSync(v),
              ),
            ],
          ),
          if (app.healthSyncEnabled) ...[
            const SizedBox(height: Sp.x2),
            Divider(height: 1, thickness: 1, color: AppColors.divider),
            const SizedBox(height: Sp.x3),
            _statusRow(context, st, store),
          ],
        ],
      ),
    );
  }

  Widget _statusRow(BuildContext context, HealthLinkState st, String store) {
    final messenger = ScaffoldMessenger.of(context);
    // Health Connect must be installed/updated first (Android).
    if (st == HealthLinkState.notInstalled) {
      return _cta(
        '$store isn’t installed. Install it, then come back.',
        'Install',
        () => app.installHealthConnect(),
      );
    }
    if (st == HealthLinkState.needsUpdate) {
      return _cta(
        '$store needs an update before we can write to it.',
        'Update',
        () => app.installHealthConnect(),
      );
    }
    if (st == HealthLinkState.unsupported) {
      return Text(
        '$store isn’t available on this device.',
        style: AppText.captionMuted,
      );
    }

    // Available: we can't reliably read the per-type WRITE grant (the platform
    // hides it), so we just keep writing and tell the user how to allow access
    // if data isn't showing — never a stuck "Grant access" gate.
    final subtitle = app.healthIsApple
        ? 'New days are written automatically. If they don’t appear in Apple '
              'Health, tap Allow access and turn ON every category.'
        : 'New days are written automatically. If they don’t appear, open '
              'Health Connect → App permissions → OpenStrap → Allow all.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AppIcon(Ic.check, size: 16, color: AppColors.positive),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text('Syncing to $store.', style: AppText.captionMuted),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text(
          subtitle,
          style: AppText.caption.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x2,
          children: [
            FilledButton(
              onPressed: () => app.requestHealth(),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 40),
              ),
              child: const Text('Allow access'),
            ),
            if (!app.healthIsApple)
              OutlinedButton(
                onPressed: () => app.openHealthConnect(),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 40),
                ),
                child: const Text('Open Health Connect'),
              ),
            TextButton(
              onPressed: () async {
                final n = await app.healthSyncNow();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      n > 0
                          ? 'Synced $n day${n == 1 ? '' : 's'} to $store.'
                          : 'Up to date — new days sync as they’re computed.',
                    ),
                  ),
                );
              },
              child: const Text('Sync now'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _cta(String text, String label, VoidCallback onTap) => Row(
    children: [
      Expanded(child: Text(text, style: AppText.captionMuted)),
      const SizedBox(width: Sp.x2),
      FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(0, 40),
        ),
        child: Text(label),
      ),
    ],
  );
}

// ── Android "keep alive in background" (battery-optimization exemption) ────
// Shows whether OpenStrap is exempt from battery optimizations (Doze) and, if
// not, fires the system exemption dialog. Android-only (guarded at the call
// site); the check/request live in AppState → AndroidBackground.
class _KeepAliveRow extends StatefulWidget {
  const _KeepAliveRow();
  @override
  State<_KeepAliveRow> createState() => _KeepAliveRowState();
}

class _KeepAliveRowState extends State<_KeepAliveRow> {
  bool? _exempt; // null = still checking

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final v = await context.read<AppState>().isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _exempt = v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Sp.x3),
        _SettingsCard(rows: [
          ListRow(
            icon: Ic.battery,
            title: 'Keep alive in background',
            subtitle: 'So overnight tracking isn’t frozen by the OS',
            value: _exempt == null ? '…' : (_exempt! ? 'On' : 'Allow'),
            trailing: _exempt == true
                ? AppIcon(Ic.check, size: 18, color: AppColors.positive)
                : null,
            onTap: _exempt == true
                ? null
                : () async {
                    final app = context.read<AppState>();
                    await app.requestIgnoreBatteryOptimizations();
                    // The system dialog resolves out-of-band — re-check after a
                    // beat so the row reflects the user's choice on return.
                    await Future.delayed(const Duration(seconds: 1));
                    await _refresh();
                  },
          ),
        ]),
      ],
    );
  }
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
          _Notice('Connect to your strap to rename it or change the alarm.'),
        ListRow(
          icon: Ic.edit,
          osIcon: OsIcon.edit,
          title: 'Rename strap',
          value: live.strapName ?? 'OpenStrap',
          divider: true,
          onTap: connected ? () => _rename(context, live) : null,
        ),
        ListRow(
          icon: Ic.clock,
          osIcon: OsIcon.alarm,
          title: 'Smart alarm',
          value: alarm != null ? _fmtAlarm(alarm) : 'Off',
          onTap: connected ? () => _setAlarm(context, live) : null,
        ),
        // ALARM STATUS: the rich firing form (haptic waveform) is wired, and the
        // strap now CONFIRMS the alarm latched via its own event stream — so this
        // caption reflects the real confirmation state instead of a blanket
        // "experimental" warning.
        if (alarm != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Text(
              _alarmStatusText(live),
              style: AppText.captionMuted,
            ),
          ),
        if (connected && alarm != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await live.testAlarmBuzz();
                    if (context.mounted) _snack(context, 'Sent a test buzz.');
                  } catch (e) {
                    if (context.mounted) _snack(context, 'Buzz failed: $e');
                  }
                },
                icon: const AppIcon(Ic.bell, size: 18),
                label: const Text('Test buzz'),
              ),
              const SizedBox(width: Sp.x2),
              OutlinedButton.icon(
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
            ]),
          ),
        Divider(height: Sp.x4, thickness: 1, color: AppColors.divider),
        ListRow(
          icon: Ic.info,
          title: 'Serial',
          value: live.device.serial ?? live.paired?.serial ?? '—',
        ),
        const SizedBox(height: Sp.x4),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.critical,
              side: BorderSide(
                color: AppColors.critical.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
            onPressed: () => _forget(context, live),
            icon: AppIcon(Ic.cancel, size: 18, color: AppColors.critical),
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
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
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
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
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
    var when = DateTime(
      now.year,
      now.month,
      now.day,
      picked.hour,
      picked.minute,
    );
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    try {
      await app.setAlarm(when);
      if (context.mounted) {
        _snack(
          context,
          'Alarm set for ${picked.format(context)} — confirming with the strap…',
        );
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Set failed: $e');
    }
  }

  /// Live alarm caption driven by the strap's confirmation events (see AppState's
  /// alarm state machine): confirmed ✓ / pending / soft unconfirmed warning.
  String _alarmStatusText(AppState app) {
    if (app.alarmConfirmed) return 'Alarm set ✓ — confirmed by your strap.';
    if (app.alarmPending) return 'Setting alarm… waiting for the strap to confirm.';
    return 'Alarm sent, but the strap hasn\'t confirmed it yet. '
        'Tap "Test buzz" to check it fires, and keep a backup alarm.';
  }

  Future<void> _forget(BuildContext context, AppState app) async {
    final ok = await _confirm(
      context,
      title: 'Forget this device?',
      body:
          'You\'ll need to re-pair your strap to sync again. Your stored data '
          'stays on this phone.',
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
    _age = TextEditingController(text: u['age'] != null ? '${u['age']}' : '');
    // Pre-fill height/weight in the user's chosen units (stored as cm/kg).
    _height = TextEditingController(
      text: _units.heightField(u['height_cm'] as num?),
    );
    _weight = TextEditingController(
      text: _units.weightField(u['weight_kg'] as num?),
    );
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
    return _SheetShell(
      title: 'Edit profile',
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: Sp.x3),
        Row(
          children: [
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
          ],
        ),
        const SizedBox(height: Sp.x4),
        Text('SEX (OPTIONAL)',
            style: AppText.overline.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x2,
          children: [
            for (final opt in const ['male', 'female', 'other'])
              ToggleChip(
                opt[0].toUpperCase() + opt.substring(1),
                selected: _sex == opt,
                onTap: () => setState(() => _sex = _sex == opt ? null : opt),
              ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text('Improves your calorie estimate.', style: AppText.captionMuted),
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
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
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
      padding: EdgeInsets.fromLTRB(Sp.x6, Sp.x3, Sp.x6, Sp.x6 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(R.pill),
              ),
            ),
          ),
          const SizedBox(height: Sp.x4),
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
    child: Row(
      children: [
        AppIcon(Ic.info, size: 18, color: AppColors.warn),
        const SizedBox(width: Sp.x2),
        Expanded(child: Text(text, style: AppText.caption)),
      ],
    ),
  );
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
