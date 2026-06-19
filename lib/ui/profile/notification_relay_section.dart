// Notification-relay settings — pick which phone apps buzz the strap. ANDROID ONLY:
// both the card and the screen render nothing unless NotificationRelay.supported, so
// the feature simply doesn't exist on iOS (no "unavailable" copy, no trace).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:provider/provider.dart';

import '../../notify/notification_relay.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

/// The Profile card. Returns an empty box on unsupported platforms (iOS) so the
/// caller can place it unconditionally and it stays invisible there.
class NotificationRelaySection extends StatelessWidget {
  const NotificationRelaySection({super.key});

  @override
  Widget build(BuildContext context) {
    final relay = context.read<AppState>().notificationRelay;
    if (!relay.supported) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: relay,
      builder: (context, _) {
        final subtitle = !relay.enabled
            ? 'Off'
            : !relay.permissionGranted
                ? 'Needs notification access'
                : relay.appCount == 0
                    ? 'On · no apps selected'
                    : 'On · ${relay.appCount} app${relay.appCount == 1 ? '' : 's'}';
        return ProCard(
          onTap: () => Navigator.of(context).push(
              themedRoute((_) => const NotificationRelayScreen())),
          child: Row(
            children: [
              Icon(Ic.bell, size: 22, color: AppColors.coral),
              const SizedBox(width: Sp.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Buzz on app notifications', style: AppText.title),
                    const SizedBox(height: 2),
                    Text(subtitle, style: AppText.bodySoft),
                  ],
                ),
              ),
              Icon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
            ],
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.read<AppState>().notificationRelay;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: relay,
          builder: (context, _) {
            final showApps = relay.enabled && relay.permissionGranted;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x4, Sp.screen, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        RoundIconButton(Ic.arrowLeft,
                            onTap: () => Navigator.of(context).maybePop()),
                        const SizedBox(width: Sp.x3),
                        Expanded(child: Text('Band notifications', style: AppText.h1)),
                      ]),
                      const SizedBox(height: Sp.x4),
                      Text(
                        'When an app below posts a notification, your strap gives a '
                        'short buzz. Your phone must be connected to the band.',
                        style: AppText.bodySoft,
                      ),
                      const SizedBox(height: Sp.x5),
                      _MasterToggle(relay: relay),
                      if (relay.enabled && !relay.permissionGranted) ...[
                        const SizedBox(height: Sp.x4),
                        _GrantCard(relay: relay),
                      ],
                      const SizedBox(height: Sp.x5),
                      if (showApps) ...[
                        Text('APPS', style: AppText.overline),
                        const SizedBox(height: Sp.x3),
                        _SearchField(onChanged: (q) => setState(() => _query = q)),
                        const SizedBox(height: Sp.x3),
                      ],
                    ],
                  ),
                ),
                if (showApps)
                  Expanded(child: _AppList(relay: relay, future: _apps, query: _query))
                else
                  const SizedBox.shrink(),
                const SizedBox(height: Sp.x4),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MasterToggle extends StatelessWidget {
  final NotificationRelay relay;
  const _MasterToggle({required this.relay});
  @override
  Widget build(BuildContext context) {
    return ProCard(
      child: Row(
        children: [
          Icon(Ic.bell, size: 22, color: AppColors.coral),
          const SizedBox(width: Sp.x4),
          Expanded(child: Text('Relay notifications', style: AppText.title)),
          Switch.adaptive(
            value: relay.enabled,
            activeTrackColor: AppColors.coral,
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
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Notification access needed', style: AppText.title),
          const SizedBox(height: 4),
          Text(
            'Android needs your permission to read which app posted a notification. '
            'We only use it to decide whether to buzz the band — nothing leaves your phone.',
            style: AppText.caption,
          ),
          const SizedBox(height: Sp.x4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () => relay.requestPermission(),
              child: const Text('Grant access'),
            ),
          ),
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
        hintStyle: AppText.bodySoft,
        filled: true,
        fillColor: AppColors.surfaceAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(R.chip),
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
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.coral)),
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
    return ProCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: icon != null && icon.isNotEmpty
                ? Image.memory(icon, width: 34, height: 34, gaplessPlayback: true)
                : Container(
                    width: 34, height: 34, color: AppColors.surfaceAlt,
                    child: Icon(Ic.bell, size: 18, color: AppColors.inkMuted)),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Text(app.name, style: AppText.body, maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Switch.adaptive(
            value: relay.isAppEnabled(app.packageName),
            activeTrackColor: AppColors.coral,
            onChanged: (v) => relay.setAppEnabled(app.packageName, v),
          ),
        ],
      ),
    );
  }
}
