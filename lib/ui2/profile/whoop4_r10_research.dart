import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../debug/debug_mode.dart';
import '../../debug/whoop4_r10_export.dart';
import '../../state/app_state.dart';

/// No cloud picker, clipboard, share sheet, or health export.
class Whoop4R10ResearchScreen extends StatefulWidget {
  const Whoop4R10ResearchScreen({super.key});
  @override
  State<Whoop4R10ResearchScreen> createState() => _ResearchState();
}

class _ResearchState extends State<Whoop4R10ResearchScreen> {
  bool _consent = false, _busy = false;
  String _note = '';
  final _start = TextEditingController(), _end = TextEditingController();
  final _label = TextEditingController(), _steps = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (whoop4R10ResearchEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await context.read<AppState>().r10Research.cleanupExpired();
        } catch (_) {
          if (mounted) setState(() => _note = 'Local cache cleanup failed.');
        }
      });
    }
  }

  @override
  void dispose() {
    _start.dispose(); _end.dispose(); _label.dispose(); _steps.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() { _busy = true; _note = ''; });
    try {
      await operation();
    } catch (_) {
      // Exceptions can contain private filesystem paths or payload fragments.
      if (mounted) {
        setState(() => _note =
          'Research operation failed. Check the interval, device, and local storage.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  R10StudyInterval? _interval() {
    if (_start.text.trim().isEmpty && _end.text.trim().isEmpty &&
        _steps.text.trim().isEmpty && _label.text.trim().isEmpty) {
      return null;
    }
    DateTime parse(String text) {
      if (!text.trim().endsWith('Z')) {
        throw const FormatException('UTC required');
      }
      return DateTime.parse(text.trim());
    }
    return R10StudyInterval(
      startEpochS: parse(_start.text).millisecondsSinceEpoch ~/ 1000,
      endEpochS: parse(_end.text).millisecondsSinceEpoch ~/ 1000,
      label: _label.text.isEmpty ? null : _label.text,
      countedSteps: _steps.text.trim().isEmpty ? null : int.parse(_steps.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!whoop4R10ResearchEnabled) {
      return const Scaffold(body: Center(child: Text('Research tool unavailable.')));
    }
    final app = context.read<AppState>();
    final capture = app.r10Research;
    return Scaffold(
      appBar: AppBar(title: const Text('WHOOP 4.0 R10 research')),
      body: ListenableBuilder(listenable: capture, builder: (context, _) =>
        ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Experimental capture only. No step counting.\n\n'
              'Raw records include heart data and unknown fields. Files stay in '
              'private, plaintext app cache and can be evicted by the OS. No upload '
              'or share action is provided. Retrieve deliberately using device '
              'debugging tools. Start replaces any previous research capture.\n\n'
              'Limits: 30 minutes, 20 MiB raw data; export up to 64 MiB. '
              'Reconnect in the foreground. Background/headless/pre-setup paths '
              'are excluded. Storage failure can lose research bytes after normal sync trims.'),
          CheckboxListTile(
            title: const Text('I consent to a local research capture of my band data.'),
            value: _consent,
            onChanged: _busy || capture.active ? null :
                (value) => setState(() => _consent = value ?? false),
          ),
          Text('Status: ${capture.status}\n'
              'Retained: ${capture.records} records, ${capture.bytes} bytes\n'
              'Duplicates: ${capture.duplicates}; unsupported: ${capture.unsupported}\n'
              'Incomplete: ${capture.manifest['incomplete']}'),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _busy || !_consent || capture.active ? null :
                () => _run(() async {
                  String? version;
                  try {
                    final info = await PackageInfo.fromPlatform();
                    version = '${info.version}+${info.buildNumber}';
                  } catch (_) { /* Unknown stays null. */ }
                  await app.startR10Research(consent: _consent, appVersion: version);
                }), child: const Text('Start')),
            OutlinedButton(onPressed: _busy || !capture.active ? null :
                () => _run(() => capture.stop()), child: const Text('Stop')),
            OutlinedButton(onPressed: _busy ? null :
                () => _run(() => capture.delete()), child: const Text('Delete local capture')),
          ]),
          const SizedBox(height: 20),
          const Text('Optional reference interval (UTC, for example 2026-10-13T10:00:00Z). '
              'Counted steps are your annotation, not an estimate from the band. '
              'Leave all fields empty when bounds are unknown.'),
          TextField(controller: _start, decoration:
              const InputDecoration(labelText: 'Interval start (UTC)')),
          TextField(controller: _end, decoration:
              const InputDecoration(labelText: 'Interval end (UTC)')),
          TextField(controller: _label, maxLength: 120, decoration:
              const InputDecoration(labelText: 'Activity label (avoid identifiers)')),
          TextField(controller: _steps, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Independently counted steps')),
          OutlinedButton(onPressed: _busy || capture.active || !capture.hasSession ?
              null : () => _run(() async {
                final path = await exportWhoop4R10(capture, interval: _interval());
                if (mounted) {
                  setState(() => _note =
                    'Local export saved at:\n$path\nCache may be evicted. Nothing was sent.');
                }
              }), child: const Text('Export to local cache')),
          if (_note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 16),
              child: SelectableText(_note)),
        ]),
      ),
    );
  }
}
