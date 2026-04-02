import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/whoop_provider.dart';
import '../../core/ble/whoop_connection.dart';
import '../../theme/app_theme.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  List<ScanResult> _results = [];
  StreamSubscription? _scanSub;
  bool _autoReconnectTried = false;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    // Start scan immediately — permissions were already granted in main()
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final manager = ref.read(whoopManagerProvider);
    final saved = manager.getLastConnectedDevice();

    if (saved != null && !_autoReconnectTried) {
      _autoReconnectTried = true;
      await _tryAutoReconnect(saved.key);
    } else {
      _startScan();
    }
  }

  Future<void> _tryAutoReconnect(String deviceKey) async {
    setState(() => _isScanning = true);
    _scanSub?.cancel();
    _results = [];

    // Scan for saved device
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) setState(() => _results = results);
      for (final r in results) {
        if (r.device.remoteId.str == deviceKey) {
          // Found it — auto-connect
          FlutterBluePlus.stopScan();
          final manager = ref.read(whoopManagerProvider);
          manager.connectToDevice(r.device, r.rssi);
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    // After timeout, fall back to showing device list
    await Future.delayed(const Duration(seconds: 11));
    if (mounted && !ref.read(whoopStateProvider).value!.isConnecting) {
      _startScan();
    }
  }

  void _startScan() {
    _scanSub?.cancel();
    setState(() {
      _results = [];
      _isScanning = true;
    });
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) setState(() => _results = results);
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 30)).then((_) {
      if (mounted) setState(() => _isScanning = false);
    });
    ref.read(whoopManagerProvider).startScan();
  }

  void _connect(ScanResult r) {
    FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    ref.read(whoopManagerProvider).connectToDevice(r.device, r.rssi);
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stateAsync = ref.watch(whoopStateProvider);

    return stateAsync.when(
      loading: () => const _DarkScaffold(child: Center(
        child: CircularProgressIndicator(color: WhoopColors.primary),
      )),
      error: (e, _) => _DarkScaffold(child: Center(
        child: Text(e.toString(),
            style: const TextStyle(color: WhoopColors.textSecondary)),
      )),
      data: (state) {
        if (state.isLive) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) context.go('/dashboard');
          });
        }

        if (state.isConnecting) return _ConnectingView(state: state);

        if (state.phase == WhoopConnectionPhase.disconnected ||
            state.phase == WhoopConnectionPhase.error) {
          // Auto-restart scan on disconnect
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isScanning) _startScan();
          });
        }

        return _ScanView(
          results: _results,
          isScanning: _isScanning,
          errorMessage: state.phase == WhoopConnectionPhase.error
              ? state.errorMessage
              : null,
          onConnect: _connect,
          onRescan: _startScan,
        );
      },
    );
  }
}

// ── Views ────────────────────────────────────────────────────────────────────

class _DarkScaffold extends StatelessWidget {
  final Widget child;
  const _DarkScaffold({required this.child});
  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: WhoopColors.background, body: child);
}

class _ConnectingView extends StatelessWidget {
  final WhoopConnectionState state;
  const _ConnectingView({required this.state});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WhoopColors.background,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _RadarAnimation(),
          const SizedBox(height: 36),
          Text(state.deviceName ?? 'WHOOP',
              style: const TextStyle(
                  color: WhoopColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          Text(state.phaseLabel.toUpperCase(),
              style: const TextStyle(
                  color: WhoopColors.textSecondary,
                  fontSize: 11,
                  letterSpacing: 3)),
          if (state.phase == WhoopConnectionPhase.syncing &&
              state.batchCount > 0) ...[
            const SizedBox(height: 16),
            Text('${state.batchCount} batches synced',
                style: const TextStyle(
                    color: WhoopColors.textDim, fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}

class _ScanView extends StatelessWidget {
  final List<ScanResult> results;
  final bool isScanning;
  final String? errorMessage;
  final void Function(ScanResult) onConnect;
  final VoidCallback onRescan;

  const _ScanView({
    required this.results,
    required this.isScanning,
    required this.onConnect,
    required this.onRescan,
    this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    // Sort: WHOOP devices first, then by RSSI
    final sorted = [...results]..sort((a, b) {
        final aIsWhoop = a.device.platformName.toLowerCase().contains('whoop') ? 1 : 0;
        final bIsWhoop = b.device.platformName.toLowerCase().contains('whoop') ? 1 : 0;
        if (aIsWhoop != bIsWhoop) return bIsWhoop - aIsWhoop;
        return b.rssi.compareTo(a.rssi);
      });
    // Only show named devices
    final visible = sorted.where((r) => r.device.platformName.isNotEmpty).toList();

    return Scaffold(
      backgroundColor: WhoopColors.background,
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 48),
          const Text('WHOOP',
              style: TextStyle(
                  color: WhoopColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 10)),
          const SizedBox(height: 6),
          const Text('CONNECT',
              style: TextStyle(
                  color: WhoopColors.textSecondary,
                  fontSize: 10,
                  letterSpacing: 5)),
          const SizedBox(height: 44),
          const _RadarAnimation(),
          const SizedBox(height: 28),
          if (errorMessage != null)
            _ErrorBanner(message: errorMessage!),
          const SizedBox(height: 16),
          Text(
            isScanning
                ? visible.isEmpty ? 'SEARCHING...' : 'SELECT YOUR DEVICE'
                : 'SCAN COMPLETE',
            style: const TextStyle(
                color: WhoopColors.textSecondary,
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: visible.isEmpty
                ? const _SearchingHint()
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _DeviceTile(
                        result: visible[i],
                        onTap: () => onConnect(visible[i])),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: _OutlineButton(label: 'RESCAN', onTap: onRescan),
          ),
        ]),
      ),
    );
  }
}

// ── Widgets ───────────────────────────────────────────────────────────────────

class _SearchingHint extends StatelessWidget {
  const _SearchingHint();
  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Text('Make sure your WHOOP is charged',
              style: TextStyle(color: WhoopColors.textDim, fontSize: 13)),
          SizedBox(height: 6),
          Text('and within Bluetooth range.',
              style: TextStyle(color: WhoopColors.textDim, fontSize: 13)),
        ],
      );
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: WhoopColors.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: WhoopColors.primary.withOpacity(0.3)),
        ),
        child: Text(message,
            style: const TextStyle(color: WhoopColors.primary, fontSize: 12),
            textAlign: TextAlign.center),
      );
}

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onTap;
  const _DeviceTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = result.device.platformName;
    final isWhoop = name.toLowerCase().contains('whoop');
    final signalBars = result.rssi > -60 ? 3 : result.rssi > -75 ? 2 : 1;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: isWhoop
              ? WhoopColors.primary.withOpacity(0.08)
              : WhoopColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isWhoop
                  ? WhoopColors.primary.withOpacity(0.4)
                  : WhoopColors.cardBorder),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (isWhoop ? WhoopColors.primary : WhoopColors.textDim)
                  .withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.watch_outlined,
                color: isWhoop ? WhoopColors.primary : WhoopColors.textDim,
                size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: TextStyle(
                        color: isWhoop
                            ? WhoopColors.textPrimary
                            : WhoopColors.textSecondary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text('${result.rssi} dBm',
                    style: const TextStyle(
                        color: WhoopColors.textDim, fontSize: 12)),
              ],
            ),
          ),
          if (isWhoop)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: WhoopColors.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('WHOOP',
                  style: TextStyle(
                      color: WhoopColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1)),
            )
          else
            Row(
              children: List.generate(3, (i) => Container(
                width: 4,
                height: 8 + i * 4.0,
                margin: const EdgeInsets.only(left: 2),
                decoration: BoxDecoration(
                  color: i < signalBars
                      ? WhoopColors.textSecondary
                      : WhoopColors.textDim,
                  borderRadius: BorderRadius.circular(2),
                ),
              )),
            ),
        ]),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _OutlineButton({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            border: Border.all(color: WhoopColors.cardBorder),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Text(label,
                style: const TextStyle(
                    color: WhoopColors.textSecondary,
                    fontSize: 12,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      );
}

// ── Radar animation ───────────────────────────────────────────────────────────

class _RadarAnimation extends StatefulWidget {
  const _RadarAnimation();
  @override
  State<_RadarAnimation> createState() => _RadarAnimationState();
}

class _RadarAnimationState extends State<_RadarAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2200))
      ..repeat();
  }
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
          size: const Size(140, 140),
          painter: _RadarPainter(_ctrl.value)));
}

class _RadarPainter extends CustomPainter {
  final double t;
  _RadarPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2;

    for (final r in [24.0, 44.0, 64.0]) {
      p.color = WhoopColors.cardBorder;
      canvas.drawCircle(c, r, p);
    }
    for (int i = 0; i < 2; i++) {
      final phase = (t + i * 0.5) % 1.0;
      p
        ..color = WhoopColors.primary.withOpacity((1 - phase) * 0.5)
        ..strokeWidth = 1.5;
      canvas.drawCircle(c, 10 + phase * 60, p);
    }
    final angle = t * 2 * pi;
    canvas.drawLine(
        c,
        Offset(c.dx + cos(angle) * 60, c.dy + sin(angle) * 60),
        Paint()
          ..color = WhoopColors.primary.withOpacity(0.6)
          ..strokeWidth = 1.5);
    canvas.drawCircle(c, 5, Paint()..color = WhoopColors.primary);
  }

  @override
  bool shouldRepaint(_RadarPainter o) => o.t != t;
}
