import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../ble/ble_service.dart';
import '../config.dart';
import '../theme.dart';
import '../widgets/cards.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        const SectionLabel('ACCOUNT'),
        GlassCard(
          child: Column(
            children: [
              KvRow('Email', auth.user?['email']?.toString() ?? '—'),
              KvRow('Name', auth.user?['display_name']?.toString() ?? '—'),
              KvRow('User id', (auth.user?['id']?.toString() ?? '—').substring(0,
                  auth.user?['id']?.toString().length ?? 0)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SectionLabel('PLATFORM'),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KvRow('OS', Platform.operatingSystem),
              KvRow('Backend', Config.apiBaseUrl.replaceFirst(RegExp(r'^https?://'), '')),
              if (Platform.isIOS)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'iOS limits background usage. Continuous capture may dip while the '
                    'app is suspended; reconnects on its own when the strap notifies.',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: WTheme.textDim,
                        fontSize: 11,
                        height: 1.4),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: () async {
            await ref.read(bleServiceProvider).forgetSavedDevice();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Strap forgotten. Restart app to re-pair.')));
            }
          },
          child: const Text('Forget paired strap'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          style: FilledButton.styleFrom(foregroundColor: WTheme.danger),
          onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
          child: const Text('Sign out'),
        ),
        const SizedBox(height: 32),
        const Center(
          child: Text('whoopsie · open-source · AGPL-3.0',
              style: TextStyle(
                  fontFamily: 'monospace',
                  color: WTheme.textMuted,
                  fontSize: 11,
                  letterSpacing: 1.4)),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
