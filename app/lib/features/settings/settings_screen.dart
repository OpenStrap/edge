import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/providers/whoop_provider.dart';
import '../../theme/app_theme.dart';

// Persisted list of app package names for which haptics are enabled
final hapticAppsProvider =
    StateNotifierProvider<HapticAppsNotifier, List<String>>(
  (ref) => HapticAppsNotifier(),
);

class HapticAppsNotifier extends StateNotifier<List<String>> {
  static const _key = 'haptic_apps';
  static const _ch = MethodChannel('com.whoopconnect.whoop_connect/service');

  HapticAppsNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key) ?? [];
    state = saved;
    _syncToAndroid(saved);
  }

  Future<void> toggle(String packageName) async {
    final next = state.contains(packageName)
        ? state.where((p) => p != packageName).toList()
        : [...state, packageName];
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next);
    _syncToAndroid(next);
  }

  void _syncToAndroid(List<String> packages) {
    _ch.invokeMethod('setHapticApps', {'packages': packages}).catchError((_) {});
  }

  bool isEnabled(String packageName) => state.contains(packageName);
}

// Provider for notification access grant status — refreshed each time settings opens
final notificationAccessProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  try {
    const ch = MethodChannel('com.whoopconnect.whoop_connect/service');
    final result = await ch.invokeMethod<bool>('isNotificationAccessGranted');
    return result ?? false;
  } catch (_) {
    return false;
  }
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _channel =
      MethodChannel('com.whoopconnect.whoop_connect/service');

  static const _popularApps = [
    ('WhatsApp', 'com.whatsapp'),
    ('Messages', 'com.google.android.apps.messaging'),
    ('Gmail', 'com.google.android.gm'),
    ('Slack', 'com.Slack'),
    ('Instagram', 'com.instagram.android'),
    ('Telegram', 'org.telegram.messenger'),
    ('Signal', 'org.thoughtcrime.securesms'),
    ('Phone', 'com.google.android.dialer'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hapticApps = ref.watch(hapticAppsProvider);
    final stateAsync = ref.watch(whoopStateProvider);
    final notifAccessAsync = ref.watch(notificationAccessProvider);
    final notifGranted = notifAccessAsync.value ?? false;

    return Scaffold(
      backgroundColor: WhoopColors.background,
      appBar: AppBar(
        backgroundColor: WhoopColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios,
              color: WhoopColors.textPrimary, size: 18),
          onPressed: () => context.pop(),
        ),
        title: const Text(
          'SETTINGS',
          style: TextStyle(
            color: WhoopColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 4,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          // Device section
          stateAsync
                  .whenData((state) => _Section(
                        title: 'DEVICE',
                        children: [
                          _InfoRow(label: 'Status', value: state.phaseLabel),
                          _InfoRow(
                              label: 'Device',
                              value: state.deviceName ?? '—'),
                          _InfoRow(
                              label: 'Serial', value: state.serial ?? '—'),
                          if (state.batteryPct != null)
                            _InfoRow(
                                label: 'Battery',
                                value:
                                    '${state.batteryPct!.toStringAsFixed(0)}%'),
                        ],
                      ))
                  .value ??
              const SizedBox.shrink(),

          const SizedBox(height: 28),

          // Haptic notifications section
          _Section(
            title: 'HAPTIC NOTIFICATIONS',
            subtitle:
                'WHOOP vibrates when these apps send notifications.',
            children: [
              // Notification access status row
              _AccessStatusRow(
                label: 'Notification Access',
                granted: notifGranted,
                onGrant: () => _openNotificationSettings(context, ref),
              ),
              const Divider(height: 1, color: WhoopColors.divider, indent: 18),
              ..._popularApps.map((entry) {
                final (name, pkg) = entry;
                final enabled = hapticApps.contains(pkg);
                return _ToggleRow(
                  label: name,
                  value: enabled,
                  onChanged: notifGranted
                      ? (_) =>
                          ref.read(hapticAppsProvider.notifier).toggle(pkg)
                      : null,
                );
              }),
            ],
          ),

          const SizedBox(height: 28),

          // Call control section
          _Section(
            title: 'CALL CONTROL',
            subtitle: 'Control calls with WHOOP gestures.',
            children: [
              const _InfoRow(label: 'Double tap', value: 'Answer / hang up'),
              const _InfoRow(label: 'Single tap', value: 'Answer incoming'),
            ],
          ),

          const SizedBox(height: 28),

          // Haptic test section
          _Section(
            title: 'HAPTICS',
            children: [
              _ActionRow(
                label: 'Test Haptic',
                onTap: () {
                  stateAsync.whenData((state) {
                    if (state.isConnected) {
                      ref.read(whoopManagerProvider).sendHaptic();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Not connected to WHOOP'),
                          backgroundColor: WhoopColors.card,
                        ),
                      );
                    }
                  });
                },
              ),
            ],
          ),

          const SizedBox(height: 28),

          // About
          const _Section(
            title: 'ABOUT',
            children: [
              _InfoRow(label: 'Version', value: '1.0.0'),
              _InfoRow(label: 'Protocol', value: 'WHOOP Gen4 BLE'),
              _InfoRow(label: 'Build', value: 'Production'),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openNotificationSettings(
      BuildContext context, WidgetRef ref) async {
    try {
      await _channel.invokeMethod('openNotificationSettings');
      // Refresh the access status when the user comes back
      ref.invalidate(notificationAccessProvider);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Open: Settings > Apps > Special app access > Notification access'),
            backgroundColor: WhoopColors.card,
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }
}

// ── Settings sub-widgets ──────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _Section(
      {required this.title, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: WhoopColors.textSecondary,
            fontSize: 10,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(color: WhoopColors.textDim, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: WhoopColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: WhoopColors.cardBorder),
          ),
          child: Column(
            children: children.indexed.map((entry) {
              final (i, child) = entry;
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 4),
                    child: child,
                  ),
                  if (i < children.length - 1)
                    const Divider(
                        height: 1, color: WhoopColors.divider, indent: 18),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _AccessStatusRow extends StatelessWidget {
  final String label;
  final bool granted;
  final VoidCallback onGrant;

  const _AccessStatusRow({
    required this.label,
    required this.granted,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  color: WhoopColors.textPrimary, fontSize: 14)),
          const Spacer(),
          if (granted)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: WhoopColors.green),
                ),
                const SizedBox(width: 6),
                const Text('Granted',
                    style: TextStyle(
                        color: WhoopColors.green,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
              ],
            )
          else
            GestureDetector(
              onTap: onGrant,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: WhoopColors.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: WhoopColors.primary.withOpacity(0.4)),
                ),
                child: const Text(
                  'Enable',
                  style: TextStyle(
                      color: WhoopColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  color: WhoopColors.textPrimary, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  color: WhoopColors.textSecondary, fontSize: 14)),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _ToggleRow(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  color: onChanged != null
                      ? WhoopColors.textPrimary
                      : WhoopColors.textDim,
                  fontSize: 14)),
          const Spacer(),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: WhoopColors.primary,
            activeTrackColor: WhoopColors.primary.withOpacity(0.3),
            inactiveThumbColor: WhoopColors.textDim,
            inactiveTrackColor: WhoopColors.cardBorder,
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ActionRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Text(label,
                style: const TextStyle(
                    color: WhoopColors.primary, fontSize: 14)),
            const Spacer(),
            const Icon(Icons.chevron_right,
                color: WhoopColors.textDim, size: 18),
          ],
        ),
      ),
    );
  }
}
