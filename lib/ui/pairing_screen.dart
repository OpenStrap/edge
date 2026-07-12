// Pairing — put the strap in pairing mode, then scan and connect.
// Used by app.dart's gate: PairingScreen.
//
// Presentation: design-system language. The BLE flow (scan → found → pair, or
// the iOS 18+ AccessorySetupKit picker) is UNTOUCHED — only the rendering moved
// onto SurfaceCard/BentoTile/StatusChip. Pure widgets (PairingInstructionContent
// and PairingStateView, keyed by the public [PairPhase]) are extracted so render
// tests can cover every state in both palettes without BLE.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'design/design.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  int _step = 0; // 0 = instruction, 1 = scan/pair
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: Motion.med,
          switchInCurve: Motion.curve,
          child: _step == 0
              ? PairingInstructionContent(
                  key: const ValueKey('step0'),
                  onReady: () => setState(() => _step = 1),
                )
              : _ScanStep(
                  key: const ValueKey('step1'),
                  onBack: () => setState(() => _step = 0),
                ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 1 — instruction (pure)
// ─────────────────────────────────────────────────────────────────────────────

class PairingInstructionContent extends StatelessWidget {
  final VoidCallback onReady;
  const PairingInstructionContent({super.key, required this.onReady});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x6, Sp.screen, Sp.x6),
      physics: const BouncingScrollPhysics(),
      children: dsStaggered([
        const _StrapHero(),
        const SizedBox(height: Sp.x6),
        Text('Put your strap in\npairing mode.', style: AppText.display),
        const SizedBox(height: Sp.x3),
        Text(
          'Your WHOOP only talks to one phone at a time. Force-quit the '
          'official app first.',
          style: AppText.bodySoft,
        ),
        const SizedBox(height: Sp.x5),
        SurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
          child: Column(
            children: const [
              ListRow(
                icon: OsIcon.wear,
                title: 'Wake the strap',
                subtitle: 'Place it on its charger so it powers up.',
                divider: true,
              ),
              ListRow(
                icon: OsIcon.bluetooth,
                title: 'Enter pairing mode',
                subtitle:
                    'Follow the WHOOP unpair/reset steps so it advertises to a '
                    'new phone.',
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x3),
        SurfaceCard(
          level: 0,
          color: AppColors.warnSoft,
          padding: const EdgeInsets.all(Sp.x4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(OsIcon.info, size: 18, color: AppColors.warn),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Text(
                  'Pairing will likely fail unless the strap is in pairing mode.',
                  style: AppText.caption.copyWith(color: AppColors.ink),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),
        FilledButton(
          onPressed: onReady,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('My strap is in pairing mode'),
              SizedBox(width: Sp.x2),
              AppIcon(OsIcon.arrowRight, size: 20, color: Colors.white),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Strap hero image with a graceful ember-gradient placeholder if the asset
/// hasn't been added yet.
class _StrapHero extends StatelessWidget {
  const _StrapHero();
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(R.card),
      child: SizedBox(
        height: 220,
        width: double.infinity,
        child: Image.asset(
          'assets/images/strap_hero.png',
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _StrapPlaceholder(),
        ),
      ),
    );
  }
}

class _StrapPlaceholder extends StatelessWidget {
  const _StrapPlaceholder();
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.glow1, AppColors.glow2],
        ),
      ),
      child: const Center(
        child: AppIcon(OsIcon.wear, size: 76, color: Colors.white),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 2 — scan / pair
// ─────────────────────────────────────────────────────────────────────────────

/// Public so the pure [PairingStateView] can be rendered per-state in tests.
enum PairPhase { scanning, found, notFound, pairing, askReady, bluetoothOff }

/// Turns whatever a BLE plugin throws into something a normal person can act
/// on. flutter_blue_plus/AccessorySetupKit exceptions come through as raw
/// PlatformException text — nobody should ever see that on screen.
String humanizePairError(Object e) {
  final msg = e.toString().toLowerCase();
  if (msg.contains('permission') ||
      msg.contains('denied') ||
      msg.contains('unauthorized')) {
    return "OpenStrap needs Bluetooth permission to find your strap. Check "
        "your phone's settings and try again.";
  }
  if (msg.contains('timeout') || msg.contains('timed out')) {
    return "That took too long. Make sure the strap is nearby, awake, and "
        "in pairing mode, then try again.";
  }
  return "Couldn't pair with your strap. Make sure it's awake and nearby, "
      "then try again.";
}

class _ScanStep extends StatefulWidget {
  final VoidCallback onBack;
  const _ScanStep({super.key, required this.onBack});
  @override
  State<_ScanStep> createState() => _ScanStepState();
}

class _ScanStepState extends State<_ScanStep> {
  PairPhase _phase = PairPhase.scanning;
  BluetoothDevice? _device;
  String? _error;

  @override
  void initState() {
    super.initState();
    // On iOS 18+ pairing goes through the AccessorySetupKit picker (which does its own
    // discovery + selection) so the band is provisioned for iOS-26 background relaunch.
    // On Android / iOS < 18 we use the service-filtered scan flow.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!await context.read<AppState>().bluetoothReady()) {
        if (!mounted) return;
        setState(() => _phase = PairPhase.bluetoothOff);
        return;
      }
      if (!mounted) return;
      final ask = await context.read<AppState>().accessorySetupSupported();
      if (!mounted) return;
      if (ask) {
        setState(() => _phase = PairPhase.askReady);
      } else {
        _scan();
      }
    });
  }

  String _name(BluetoothDevice d) =>
      d.platformName.isNotEmpty ? d.platformName : 'WHOOP band';

  /// iOS 18+ pairing: open the ASK system picker; on selection the band is provisioned
  /// and the gate rebuilds to the main shell.
  Future<void> _pairViaAsk() async {
    setState(() {
      _phase = PairPhase.pairing;
      _error = null;
    });
    try {
      await context.read<AppState>().pairViaAccessorySetup();
      // On success the gate rebuilds to the main shell.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = humanizePairError(e);
        _phase = PairPhase.askReady;
      });
    }
  }

  Future<void> _scan() async {
    final app = context.read<AppState>(); // capture before async gaps
    // Bluetooth being off is the #1 reason a scan silently finds nothing —
    // check it explicitly instead of letting a swallowed platform error
    // through as a misleading "no strap found."
    if (!await app.bluetoothReady()) {
      if (!mounted) return;
      setState(() {
        _phase = PairPhase.bluetoothOff;
        _error = null;
      });
      return;
    }
    setState(() {
      _phase = PairPhase.scanning;
      _device = null;
      _error = null;
    });
    try {
      final d = await app.scanForBand();
      if (!mounted) return;
      setState(() {
        _device = d;
        _phase = d == null ? PairPhase.notFound : PairPhase.found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = humanizePairError(e);
        _phase = PairPhase.notFound;
      });
    }
  }

  Future<void> _pair() async {
    final d = _device;
    if (d == null) return;
    setState(() {
      _phase = PairPhase.pairing;
      _error = null;
    });
    try {
      // Provisional label from the advertised name; the real serial arrives from
      // the HELLO body (fixed offset) once connected and overwrites it.
      await context.read<AppState>().pairWith(d, serial: _name(d));
      // On success the gate rebuilds to the main shell.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = humanizePairError(e);
        _phase = PairPhase.found;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PairingStateView(
      phase: _phase,
      deviceName: _device == null ? null : _name(_device!),
      error: _error,
      onBack: widget.onBack,
      onPair: _phase == PairPhase.askReady ? _pairViaAsk : _pair,
      onRetry: _scan,
    );
  }
}

/// Pure per-state pairing view: scanning rings, found device tile, pairing
/// spinner, not-found retry — one primary action per state.
class PairingStateView extends StatelessWidget {
  final PairPhase phase;
  final String? deviceName;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onPair;
  final VoidCallback onRetry;

  const PairingStateView({
    super.key,
    required this.phase,
    this.deviceName,
    this.error,
    required this.onBack,
    required this.onPair,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x3, Sp.screen, 0),
          child: Row(children: [AppBackButton(onBack: onBack)]),
        ),
        Expanded(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(Sp.screen, Sp.x4, Sp.screen, Sp.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  switch (phase) {
                    PairPhase.notFound => 'No strap found.',
                    PairPhase.askReady => 'Pair your\nstrap.',
                    PairPhase.found => 'Strap found.',
                    PairPhase.bluetoothOff => 'Bluetooth is off.',
                    _ => 'Finding your\nstrap.',
                  },
                  style: AppText.display,
                ),
                const SizedBox(height: Sp.x3),
                Text(
                  switch (phase) {
                    PairPhase.scanning =>
                      'Scanning for a nearby WHOOP in pairing mode…',
                    PairPhase.found => 'Confirm it\'s yours, then pair.',
                    PairPhase.notFound =>
                      'Make sure it\'s awake and in pairing mode, then try again.',
                    PairPhase.pairing => 'Pairing with your strap…',
                    PairPhase.askReady =>
                      'Tap Pair, then choose your WHOOP in the system sheet. '
                          'This lets OpenStrap reconnect in the background.',
                    PairPhase.bluetoothOff =>
                      'Turn on Bluetooth in Settings or Control Center, then '
                          'try again.',
                  },
                  style: AppText.bodySoft,
                ),
                const Spacer(),
                Center(child: _visual()),
                const Spacer(),
                if (error != null) ...[
                  Row(children: [
                    AppIcon(OsIcon.info, size: 18, color: AppColors.critical),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: Text(error!,
                          style: AppText.caption
                              .copyWith(color: AppColors.critical)),
                    ),
                  ]),
                  const SizedBox(height: Sp.x4),
                ],
                _actions(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _visual() {
    switch (phase) {
      case PairPhase.found:
        return _FoundDeviceTile(name: deviceName ?? 'WHOOP band').dsPop();
      case PairPhase.notFound:
        return Opacity(
          opacity: 0.45,
          child: Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
                color: AppColors.surfaceAlt, shape: BoxShape.circle),
            child: AppIcon(OsIcon.wear, size: 56, color: AppColors.inkMuted),
          ),
        );
      case PairPhase.bluetoothOff:
        return Opacity(
          opacity: 0.45,
          child: Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
                color: AppColors.surfaceAlt, shape: BoxShape.circle),
            child:
                AppIcon(OsIcon.bluetooth, size: 56, color: AppColors.inkMuted),
          ),
        );
      case PairPhase.scanning:
      case PairPhase.pairing:
      case PairPhase.askReady:
        return const _PulseRings();
    }
  }

  Widget _actions() {
    switch (phase) {
      case PairPhase.scanning:
        return const SizedBox(height: 56);
      case PairPhase.askReady:
      case PairPhase.found:
        return FilledButton(
          onPressed: onPair,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('Pair'),
              SizedBox(width: Sp.x2),
              AppIcon(OsIcon.bluetooth, size: 20, color: Colors.white),
            ],
          ),
        );
      case PairPhase.pairing:
        return const FilledButton(
          onPressed: null,
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2.2, color: Colors.white),
          ),
        );
      case PairPhase.notFound:
        return OutlinedButton(
          onPressed: onRetry,
          child: const Text('Scan again'),
        );
      case PairPhase.bluetoothOff:
        return OutlinedButton(
          onPressed: onRetry,
          child: const Text('Check again'),
        );
    }
  }
}

/// The found-device card — the language's inverted ink device tile.
class _FoundDeviceTile extends StatelessWidget {
  final String name;
  const _FoundDeviceTile({required this.name});

  @override
  Widget build(BuildContext context) {
    return BentoTile(
      tone: BentoTone.ink,
      padding: const EdgeInsets.symmetric(horizontal: Sp.x6, vertical: Sp.x6),
      child: Builder(builder: (context) {
        final tone = ToneScope.of(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(Sp.x4),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(R.cardSm),
              ),
              child: const AppIcon(OsIcon.wear, size: 30, color: Colors.white),
            ),
            const SizedBox(height: Sp.x4),
            Text(
              name,
              style: AppText.h1.copyWith(color: tone.fg),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Sp.x3),
            const StatusChip('Ready to pair',
                icon: OsIcon.activity, tone: ChipTone.positive),
          ],
        );
      }),
    );
  }
}

/// The scanning/pairing visual: two eased expanding rings around a steady
/// ember core. Painter isolated behind a RepaintBoundary; one ticker.
class _PulseRings extends StatefulWidget {
  const _PulseRings();
  @override
  State<_PulseRings> createState() => _PulseRingsState();
}

class _PulseRingsState extends State<_PulseRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = _c.value;
          return SizedBox(
            width: 180,
            height: 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (final phase in const [0.0, 0.5]) _ring((t + phase) % 1.0),
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                    boxShadow: AppColors.isDark ? const [] : Shadows.coral,
                  ),
                  child:
                      const AppIcon(OsIcon.bluetooth, size: 40, color: Colors.white),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _ring(double t) {
    final size = 96 + Curves.easeOut.transform(t) * 84;
    return Opacity(
      opacity: (1 - t) * 0.45,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.accent, width: 2),
        ),
      ),
    );
  }
}
