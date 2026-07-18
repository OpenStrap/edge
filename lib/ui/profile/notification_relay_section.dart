// Notification-relay settings — pick which phone apps buzz the strap. ANDROID ONLY:
// both the card and the screen render nothing unless NotificationRelay.supported, so
// the feature simply doesn't exist on iOS (no "unavailable" copy, no trace).
// Presentation: design-system language; relay logic untouched.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:provider/provider.dart';

import '../../notify/call_buzzer.dart';
import '../../notify/notification_relay.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';

/// The Profile card. Returns an empty box on unsupported platforms (iOS) so the
/// caller can place it unconditionally and it stays invisible there.
class NotificationRelaySection extends StatelessWidget {
  const NotificationRelaySection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final relay = app.notificationRelay;
    final calls = app.callBuzzer;
    if (!relay.supported) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([relay, calls]),
      builder: (context, _) {
        final String subtitle;
        if (relay.enabled && !relay.permissionGranted) {
          subtitle = 'Needs notification access';
        } else if (calls.enabled && !calls.permissionGranted) {
          // Calls are switched on but can't work yet — surface the actionable
          // state instead of reporting 'Off' / silently omitting calls.
          subtitle = 'Needs phone permission';
        } else if (!relay.enabled) {
          subtitle = calls.active ? 'On · calls only' : 'Off';
        } else {
          final apps = relay.appCount == 0
              ? 'no apps selected'
              : '${relay.appCount} app${relay.appCount == 1 ? '' : 's'}';
          subtitle = 'On · $apps${calls.active ? ' · calls' : ''}';
        }
        return SurfaceCard(
          padding:
              const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
          onTap: () => Navigator.of(context).push(themedRoute(
              (_) => const NotificationRelayScreen(),
              name: 'NotificationRelayScreen')),
          child: ListRow(
            icon: OsIcon.notifications,
            iconColor: AppColors.accent,
            title: 'Buzz on app notifications',
            subtitle: subtitle,
            trailing: AppIcon(OsIcon.arrowRight,
                size: 16, color: AppColors.onSurfaceFaint),
          ),
        );
      },
    );
  }
}

/// Full settings screen: master toggle → grant access → per-app allow-list.
class NotificationRelayScreen extends StatefulWidget {
  const NotificationRelayScreen({super.key});
  @override
  State<NotificationRelayScreen> createState() => _NotificationRelayScreenState();
}

class _NotificationRelayScreenState extends State<NotificationRelayScreen>
    with WidgetsBindingObserver {
  late Future<List<AppInfo>> _apps;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _apps = InstalledApps.getInstalledApps(
        excludeSystemApps: true, withIcon: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the system Settings page → re-check the grant.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppState>().notificationRelay.refreshPermission();
      context.read<AppState>().callBuzzer.refreshPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.read<AppState>().notificationRelay;
    final calls = context.read<AppState>().callBuzzer;
    return AppScaffold(
      title: 'Band notifications',
      subtitle: 'Buzz the strap when an app notifies',
      body: AnimatedBuilder(
        animation: Listenable.merge([relay, calls]),
        builder: (context, _) {
          final showApps = relay.enabled && relay.permissionGranted;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(Sp.screen, 0, Sp.screen, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MasterToggle(relay: relay),
                    if (relay.enabled && !relay.permissionGranted) ...[
                      const SizedBox(height: Sp.x3),
                      _GrantCard(relay: relay),
                    ],
                    const SizedBox(height: Sp.x3),
                    _CallBuzzCard(calls: calls),
                    if (showApps) ...[
                      const SizedBox(height: Sp.x5),
                      Text('APPS',
                          style: AppText.overline
                              .copyWith(color: AppColors.inkMuted)),
                      const SizedBox(height: Sp.x3),
                      _SearchField(
                          onChanged: (q) => setState(() => _query = q)),
                      const SizedBox(height: Sp.x3),
                    ],
                  ],
                ),
              ),
              if (showApps)
                Expanded(
                    child:
                        _AppList(relay: relay, future: _apps, query: _query))
              else
                const SizedBox.shrink(),
            ],
          );
        },
      ),
    );
  }
}

class _MasterToggle extends StatelessWidget {
  final NotificationRelay relay;
  const _MasterToggle({required this.relay});
  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: Row(
        children: [
          Container(
            // Art carries its own padding: 2 + 30 ≈ the old 8 + 18 chip.
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: const OsAppIcon(OsIcon.notifications, size: 30),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(child: Text('Relay notifications', style: AppText.title)),
          Switch.adaptive(
            value: relay.enabled,
            activeTrackColor: AppColors.accent,
            onChanged: (v) => relay.setEnabled(v),
          ),
        ],
      ),
    );
  }
}

class _GrantCard extends StatelessWidget {
  final NotificationRelay relay;
  const _GrantCard({required this.relay});
  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Notification access needed', style: AppText.title),
          const SizedBox(height: 4),
          Text(
            'Android needs your permission to read which app posted a notification. '
            'We only use it to decide whether to buzz the band — nothing leaves your phone.',
            style: AppText.captionMuted,
          ),
          const SizedBox(height: Sp.x4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () => relay.requestPermission(),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 44),
              ),
              child: const Text('Grant access'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Incoming-call buzz — independent of the app relay above: ringing is not an
/// observable notification (dialers post it ONGOING, which the relay skips, and
/// the dialer is a hidden system app), so it rides READ_PHONE_STATE + a native
/// telephony bridge instead and works even with "Relay notifications" off.
class _CallBuzzCard extends StatelessWidget {
  final CallBuzzer calls;
  const _CallBuzzCard({required this.calls});
  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: const OsAppIcon(OsIcon.notifications, size: 30),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                  child: Text('Buzz on incoming calls', style: AppText.title)),
              Switch.adaptive(
                value: calls.enabled,
                activeTrackColor: AppColors.accent,
                onChanged: (v) async {
                  await calls.setEnabled(v);
                  // Ask for the (state-only) phone permission the moment the
                  // feature is switched on, not at some later surprise point.
                  if (v && !calls.permissionGranted) {
                    await calls.requestPermission();
                  }
                },
              ),
            ],
          ),
          if (calls.enabled && !calls.permissionGranted) ...[
            const SizedBox(height: Sp.x2),
            Text(
              'Android needs the phone permission to know when the phone is '
              'ringing. Only the ringing state is read — never numbers or calls.',
              style: AppText.captionMuted,
            ),
            const SizedBox(height: Sp.x3),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: () => calls.requestPermission(),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 44),
                ),
                child: const Text('Grant permission'),
              ),
            ),
            const SizedBox(height: Sp.x2),
          ],
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchField({required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      style: AppText.body,
      decoration: InputDecoration(
        hintText: 'Search apps',
        hintStyle: AppText.bodySoft.copyWith(color: AppColors.inkMuted),
        filled: true,
        fillColor: AppColors.surfaceAlt,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(R.pill),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _AppList extends StatelessWidget {
  final NotificationRelay relay;
  final Future<List<AppInfo>> future;
  final String query;
  const _AppList({required this.relay, required this.future, required this.query});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AppInfo>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            child: SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accent)),
          );
        }
        final all = snap.data ?? const <AppInfo>[];
        final q = query.trim().toLowerCase();
        final apps = (q.isEmpty
            ? all
            : all.where((a) => a.name.toLowerCase().contains(q)).toList())
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        if (apps.isEmpty) {
          return Center(child: Text('No apps found', style: AppText.captionMuted));
        }
        return ListView.separated(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(Sp.screen, 0, Sp.screen, Sp.x8),
          itemCount: apps.length,
          separatorBuilder: (_, _) => const SizedBox(height: Sp.x2),
          itemBuilder: (context, i) {
            final a = apps[i];
            return _AppRow(relay: relay, app: a);
          },
        );
      },
    );
  }
}

class _AppRow extends StatelessWidget {
  final NotificationRelay relay;
  final AppInfo app;
  const _AppRow({required this.relay, required this.app});
  @override
  Widget build(BuildContext context) {
    final Uint8List? icon = app.icon;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: icon != null && icon.isNotEmpty
                ? Image.memory(icon, width: 34, height: 34, gaplessPlayback: true)
                : Container(
                    width: 34, height: 34, color: AppColors.surfaceAlt,
                    child: AppIcon(OsIcon.notifications, size: 18, color: AppColors.inkMuted)),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Text(app.name, style: AppText.body, maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Switch.adaptive(
            value: relay.isAppEnabled(app.packageName),
            activeTrackColor: AppColors.accent,
            onChanged: (v) => relay.setAppEnabled(app.packageName, v),
          ),
        ],
      ),
    );
  }
}
