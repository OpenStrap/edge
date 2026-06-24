// First-run mode selection (LOCAL_FIRST_DESIGN §3.1). Local → info screen WITHOUT
// email → pairing. Cloud → info WITH email → OTP → pairing. UI identical after.
import 'package:flutter/material.dart';
import '../../local/app_mode.dart';

class ModeSelectScreen extends StatelessWidget {
  final void Function(AppMode mode) onSelected;
  const ModeSelectScreen({super.key, required this.onSelected});

  Future<void> _pick(AppMode mode) async {
    await AppModeStore.save(mode);
    onSelected(mode);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('How do you want to use OpenStrap?', style: t.headlineSmall),
              const SizedBox(height: 24),
              _Card(
                title: 'Local',
                subtitle: 'Your data stays on your device. More accurate (1 Hz, on-device) — '
                    'computation runs on your phone; may be slower on older devices.',
                onTap: () => _pick(AppMode.local),
              ),
              const SizedBox(height: 16),
              _Card(
                title: 'Cloud',
                subtitle: 'Standard accuracy, synced across your devices and the web. '
                    'Needs an email account.',
                onTap: () => _pick(AppMode.cloud),
              ),
              const SizedBox(height: 24),
              Text('You can change this anytime — your numbers stay the same.',
                  style: t.bodySmall, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _Card({required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.titleLarge),
              const SizedBox(height: 8),
              Text(subtitle, style: t.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
