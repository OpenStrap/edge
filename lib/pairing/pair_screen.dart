import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_service.dart';
import '../cloud/api.dart';
import '../theme.dart';
import '../widgets/cards.dart';

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});
  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  bool _scanning = false;
  bool _connecting = false;
  String? _connectingId;
  List<ScanResult> _results = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _results = [];
    });
    try {
      final ble = ref.read(bleServiceProvider);
      final results = await ble.scan();
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pair(ScanResult r) async {
    setState(() {
      _connecting = true;
      _connectingId = r.device.remoteId.str;
      _error = null;
    });
    final ble = ref.read(bleServiceProvider);
    final api = ref.read(apiProvider);
    final ok = await ble.connect(r.device);
    if (!ok) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = 'Failed to connect.';
        });
      }
      return;
    }
    String serial = '';
    try {
      final id = await ble.identity.first.timeout(const Duration(seconds: 20));
      serial = id.serial;
    } catch (_) {
      serial = r.device.remoteId.str;
    }
    try {
      await api.pairDevice(
        strapSerial: serial,
        bleId: r.device.remoteId.str,
        name: r.device.platformName,
      );
      final p = await SharedPreferences.getInstance();
      await p.setBool('whoopsie_paired', true);
      if (mounted) {
        setState(() => _connecting = false);
        if (Navigator.canPop(context)) Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair your WHOOP'),
        actions: [
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: WTheme.accent))
                : const Icon(Icons.refresh, color: WTheme.text),
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: WTheme.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: WTheme.accent.withValues(alpha: 0.3)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.touch_app, color: WTheme.accent, size: 18),
                    SizedBox(width: 8),
                    Text('PAIRING MODE',
                        style: TextStyle(
                            fontFamily: 'monospace',
                            color: WTheme.accent,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w600)),
                  ]),
                  SizedBox(height: 8),
                  Text(
                    'Take the strap off your wrist, then double-tap firmly. '
                    'The light will start blinking — that means it is in pair mode. '
                    'Pick it from the list below.',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: WTheme.text,
                        fontSize: 12,
                        height: 1.5),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              GlassCard(
                background: WTheme.danger.withValues(alpha: 0.1),
                child: Text(_error!,
                    style: const TextStyle(
                        fontFamily: 'monospace', color: WTheme.danger, fontSize: 12)),
              ),
            ],
            const SizedBox(height: 16),
            const SectionLabel('NEARBY DEVICES'),
            if (_results.isEmpty)
              GlassCard(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _scanning ? 'Scanning…' : 'No devices yet. Tap refresh.',
                      style: const TextStyle(
                          fontFamily: 'monospace', color: WTheme.textDim, fontSize: 12),
                    ),
                  ),
                ),
              )
            else
              ..._results.map((r) {
                final connecting = _connecting && _connectingId == r.device.remoteId.str;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    onTap: _connecting ? null : () => _pair(r),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                              color: WTheme.accent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8)),
                          child: const Icon(Icons.bluetooth, color: WTheme.accent, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.device.platformName.isEmpty
                                      ? 'WHOOP'
                                      : r.device.platformName,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: WTheme.text,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                  '${r.device.remoteId.str.substring(0, 8)}…  •  ${r.rssi} dBm',
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: WTheme.textMuted,
                                      fontSize: 10)),
                            ],
                          ),
                        ),
                        if (connecting)
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: WTheme.accent))
                        else
                          const Icon(Icons.chevron_right, color: WTheme.textMuted),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
