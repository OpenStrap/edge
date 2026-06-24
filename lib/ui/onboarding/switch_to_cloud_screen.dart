// Switch LOCAL → CLOUD. Reached from the Profile / Local home "Switch to Cloud"
// button. Flow: enter email → we send a 6-digit code → enter code → a clear note
// ("this uploads & syncs ALL your on-device data to the cloud") → Proceed flips the
// mode and starts the uploader. After this, raw is deleted on upload (cloud retention)
// instead of being kept on-device for 14 days.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../net/api_client.dart';
import '../../state/app_state.dart';

class SwitchToCloudScreen extends StatefulWidget {
  const SwitchToCloudScreen({super.key});
  @override
  State<SwitchToCloudScreen> createState() => _SwitchToCloudScreenState();
}

enum _Step { email, code }

class _SwitchToCloudScreenState extends State<SwitchToCloudScreen> {
  _Step _step = _Step.email;
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _devCode;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resp = await context.read<AppState>().beginCloudSwitch(email);
      _devCode = resp['dev_code'] as String?;
      if (_devCode != null) _code.text = _devCode!;
      setState(() => _step = _Step.code);
    } on ApiException catch (e) {
      setState(() => _error = e.body);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _proceed() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().completeCloudSwitch(
            _email.text.trim().toLowerCase(),
            _code.text.trim(),
          );
      // Mode flipped → the root gate rebuilds into the cloud shell.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      setState(() => _error = e.body);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Switch to Cloud')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: _step == _Step.email ? _emailStep(t) : _codeStep(t),
        ),
      ),
    );
  }

  List<Widget> _emailStep(TextTheme t) => [
        Text('Move to the cloud', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Cloud mode adds an email account so your data syncs across your devices '
          'and the web. We\'ll send a 6-digit code to confirm it\'s you.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Email', hintText: 'you@example.com'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _sendCode,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send code'),
        ),
      ];

  List<Widget> _codeStep(TextTheme t) => [
        Text('Enter your code', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text('We sent a 6-digit code to ${_email.text.trim()}.', style: t.bodyMedium),
        const SizedBox(height: 24),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: t.headlineMedium?.copyWith(letterSpacing: 10),
          decoration: const InputDecoration(counterText: ''),
        ),
        const SizedBox(height: 16),
        // The note the user asked for — explicit about what Proceed does.
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.cloud_upload_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This syncs all your data with the cloud. Your on-device raw history '
                    'will be uploaded, and from now on it\'s removed from this device once '
                    'it\'s safely on the server. Proceed?',
                    style: t.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _proceed,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Proceed — sync to cloud'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _step = _Step.email),
          child: const Text('Use a different email'),
        ),
      ];
}
