import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import 'auth_controller.dart';

class EmailScreen extends ConsumerStatefulWidget {
  const EmailScreen({super.key});
  @override
  ConsumerState<EmailScreen> createState() => _EmailScreenState();
}

class _EmailScreenState extends ConsumerState<EmailScreen> {
  final _emailC = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _emailC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: WTheme.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Icon(Icons.favorite, color: WTheme.accent, size: 22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('whoopsie',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: WTheme.accent)),
                ],
              ),
              const SizedBox(height: 8),
              const Text("Open-source companion for WHOOP 4.0",
                  style: TextStyle(color: WTheme.textDim, fontSize: 13)),
              const SizedBox(height: 64),
              const Text("What's your email?",
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      color: WTheme.text)),
              const SizedBox(height: 8),
              const Text("We'll text a one-time code. No password to forget.",
                  style: TextStyle(color: WTheme.textDim, fontSize: 13)),
              const SizedBox(height: 24),
              TextField(
                controller: _emailC,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                style: const TextStyle(fontFamily: 'monospace', color: WTheme.text),
                decoration: const InputDecoration(hintText: 'you@example.com'),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 12),
                Text(auth.error!,
                    style: const TextStyle(color: WTheme.danger, fontSize: 12)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final email = _emailC.text.trim().toLowerCase();
                          if (!email.contains('@')) return;
                          setState(() => _busy = true);
                          await ref.read(authControllerProvider.notifier).requestOtp(email);
                          if (mounted) setState(() => _busy = false);
                        },
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Send code'),
                ),
              ),
              const Spacer(),
              const Center(
                child: Text(
                  'You stay logged in. No tracking. AGPL-3.0.',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      color: WTheme.textMuted,
                      fontSize: 11,
                      letterSpacing: 1.2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CodeScreen extends ConsumerStatefulWidget {
  const CodeScreen({super.key});
  @override
  ConsumerState<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends ConsumerState<CodeScreen> {
  final _codeC = TextEditingController();
  final _nameC = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _codeC.dispose();
    _nameC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: WTheme.text),
          onPressed: () => ref.read(authControllerProvider.notifier).resetToEmail(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Check your email',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      color: WTheme.text)),
              const SizedBox(height: 6),
              Text('Code sent to ${auth.email ?? ""}',
                  style: const TextStyle(color: WTheme.textDim, fontSize: 13)),
              const SizedBox(height: 24),
              TextField(
                controller: _codeC,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 28,
                    letterSpacing: 12,
                    color: WTheme.accent),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(hintText: '000000'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameC,
                style: const TextStyle(fontFamily: 'monospace', color: WTheme.text),
                decoration: const InputDecoration(hintText: 'Display name (optional)'),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 12),
                Text(auth.error!,
                    style: const TextStyle(color: WTheme.danger, fontSize: 12)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          if (_codeC.text.length != 6) return;
                          setState(() => _busy = true);
                          final n = _nameC.text.trim();
                          await ref.read(authControllerProvider.notifier).verifyOtp(
                              _codeC.text,
                              displayName: n.isEmpty ? null : n);
                          if (mounted) setState(() => _busy = false);
                        },
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Verify'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
