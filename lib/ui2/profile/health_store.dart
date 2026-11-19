// APPLE HEALTH / HEALTH CONNECT — the sub-screen behind the Data-group row in
// Settings. Top: the on/off switch for writing. Below it, only while on: the
// per-type WRITE authorization the store currently reports, plus the two ways
// to change it.
//
// WHY THIS SCREEN EXISTS: on iOS a write grant can be revoked in OS Settings
// at any moment, and an ungranted HealthKit write silently no-ops — the old
// row only noticed on a failed export. The status is read natively
// (`openstrap/health_auth`, because HealthKit answers authorizationStatus for
// the share side while the `health` plugin cannot see it) on every resume and
// every open of this screen, and anything unreadable shows as "Unknown", never
// as a guessed grant.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../health/health_permission_status.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'profile.dart' show SetRow, settingsGroup;
import 'settings.dart' show healthSyncSub, toggleHealthSync;

/// The route behind the "Apple Health" / "Health Connect" row in Settings → Data.
class HealthStoreScreen extends StatefulWidget {
  const HealthStoreScreen({super.key});

  @override
  State<HealthStoreScreen> createState() => _HealthStoreScreenState();
}

class _HealthStoreScreenState extends State<HealthStoreScreen>
    with WidgetsBindingObserver {
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
    // Back from the HealthKit grant sheet or OS Settings: re-read the status.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    final app = context.read<AppState>();
    if (app.healthSyncEnabled) unawaited(app.refreshHealthPermissions());
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final store = app.healthStoreName;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(store),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                settingsGroup(c, l?.settingsGroupWrite ?? 'Write', [
                  SetRow(LucideIcons.heartPulse, C.red,
                      l?.settingsWriteToHealthStoreRowTitle(store) ??
                          'Write to $store',
                      sub: healthSyncSub(
                          c, app.healthSyncEnabled, app.healthState, store),
                      trailing: Switch(
                          value: app.healthSyncEnabled,
                          onChanged: (_) => unawaited(toggleHealthSync(app))),
                      chevron: false,
                      onTap: () => unawaited(toggleHealthSync(app))),
                ]),
                if (app.healthSyncEnabled) ...[
                  if (app.healthIsApple)
                    settingsGroup(
                        c, l?.settingsGroupPermissions ?? 'Permissions', [
                      for (final t in app.healthPermTypes)
                        _permRow(c, l, t, app.healthPermissions[t.key]),
                    ])
                  else
                    settingsGroup(
                        c, l?.settingsGroupPermissions ?? 'Permissions', [
                      SetRow(LucideIcons.externalLink, C.blue,
                          l?.settingsHealthManageStoreRowTitle(store) ??
                              'Manage in $store',
                          sub: l?.settingsHealthManageStoreRowSub(store) ??
                              'Permissions are granted per app in the $store app',
                          onTap: () => app.openHealthConnect()),
                    ]),
                  if (app.healthIsApple)
                    settingsGroup(c, l?.settingsGroupManage ?? 'Manage', [
                      SetRow(LucideIcons.sliders, C.blue,
                          l?.settingsHealthRequestPermsTitle ??
                              'Manage permissions',
                          sub: l?.settingsHealthRequestPermsSub(store) ??
                              'Opens the $store sheet where each data type can be switched on or off',
                          onTap: () async {
                        await app.requestHealth();
                        if (!c.mounted) return;
                        await app.refreshHealthPermissions();
                      }),
                      SetRow(LucideIcons.settings, C.blue,
                          l?.settingsHealthOpenSystemTitle ??
                              'Open in system settings',
                          sub: l?.settingsHealthOpenSystemSub(store) ??
                              '$store data access for this app lives in the system settings under Health',
                          onTap: () => launchUrl(Uri.parse('app-settings:'),
                              mode: LaunchMode.externalApplication)),
                    ]),
                  if (app.healthIsApple)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, 0),
                      child: Text(
                          l?.settingsHealthFootnote(store) ??
                              '$store reports the write status of each data type. '
                              'Changes made in the system settings are picked up the next time the app is opened.',
                          style: F.over.copyWith(color: p.ink3)),
                    ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// One data type: icon + localized name + a status chip. The chip is the
  /// honest answer — denied is red, "not asked" and unreadable are distinct
  /// and never shown as granted.
  Widget _permRow(
      BuildContext c, AppLocalizations? l, HealthPermType t, HealthWriteAuth? s) {
    final a = s ?? HealthWriteAuth.unknown;
    final (color, icon, label) = switch (a) {
      HealthWriteAuth.authorized => (
          C.green,
          LucideIcons.check,
          l?.healthPermAuthorized ?? 'Allowed'
        ),
      HealthWriteAuth.denied => (
          C.red,
          LucideIcons.x,
          l?.healthPermDenied ?? 'Denied'
        ),
      HealthWriteAuth.notDetermined => (
          C.orange,
          LucideIcons.circle,
          l?.healthPermNotDetermined ?? 'Not asked'
        ),
      HealthWriteAuth.unknown => (
          C.orange,
          LucideIcons.circleHelp,
          l?.healthPermUnknown ?? 'Unknown'
        ),
    };
    final p = P.of(c);
    return SetRow(_typeIcon(t), _typeColor(t), _typeLabel(l, t),
        trailing: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1 / 2),
          decoration:
              BoxDecoration(color: p.wash(color), borderRadius: R.rSm),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 12, color: p.on(color)),
            const SizedBox(width: S.x1),
            Text(label,
                style: F.cap
                    .copyWith(color: p.on(color), fontWeight: FontWeight.w600)),
          ]),
        ),
        chevron: false);
  }

  static IconData _typeIcon(HealthPermType t) => switch (t) {
        HealthPermType.sleep => LucideIcons.moonStar,
        HealthPermType.restingHr => LucideIcons.heartPulse,
        HealthPermType.hrv => LucideIcons.waves,
        HealthPermType.respRate => LucideIcons.wind,
        HealthPermType.heartRate => LucideIcons.gauge,
        HealthPermType.activeEnergy => LucideIcons.flame,
        HealthPermType.basalEnergy => LucideIcons.flame,
        HealthPermType.steps => LucideIcons.footprints,
        HealthPermType.workout => LucideIcons.medal,
        HealthPermType.weight => LucideIcons.scale,
      };

  static Color _typeColor(HealthPermType t) => switch (t) {
        HealthPermType.sleep => C.indigo,
        HealthPermType.restingHr => C.red,
        HealthPermType.hrv => C.blue,
        HealthPermType.respRate => C.teal,
        HealthPermType.heartRate => C.red,
        HealthPermType.activeEnergy => C.orange,
        HealthPermType.basalEnergy => C.yellow,
        HealthPermType.steps => C.teal,
        HealthPermType.workout => C.purple,
        HealthPermType.weight => C.sky,
      };

  static String _typeLabel(AppLocalizations? l, HealthPermType t) =>
      switch (t) {
        HealthPermType.sleep => l?.healthTypeSleep ?? 'Sleep',
        HealthPermType.restingHr => l?.healthTypeRestingHr ?? 'Resting heart rate',
        HealthPermType.hrv => l?.healthTypeHrv ?? 'HRV',
        HealthPermType.respRate => l?.healthTypeRespRate ?? 'Respiratory rate',
        HealthPermType.heartRate => l?.healthTypeHeartRate ?? 'Heart rate',
        HealthPermType.activeEnergy =>
          l?.healthTypeActiveEnergy ?? 'Active energy',
        HealthPermType.basalEnergy => l?.healthTypeBasalEnergy ?? 'Basal energy',
        HealthPermType.steps => l?.healthTypeSteps ?? 'Steps',
        HealthPermType.workout => l?.healthTypeWorkout ?? 'Workouts',
        HealthPermType.weight => l?.healthTypeWeight ?? 'Weight',
      };
}
