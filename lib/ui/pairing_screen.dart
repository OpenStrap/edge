// Pairing — put the strap in pairing mode, then scan and connect.
// Used by app.dart's gate: PairingScreen.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'kit/kit.dart';

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
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: Motion.med,
          child: _step == 0
              ? _InstructionStep(
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
// Step 1 — instruction
// ─────────────────────────────────────────────────────────────────────────────

class _InstructionStep extends StatelessWidget {
  final VoidCallback onReady;
  const _InstructionStep({super.key, required this.onReady});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x6, Sp.screen, Sp.x6),
      children: [
        const _StrapHero(),
        const SizedBox(height: Sp.x7),
        Text('Put your strap in\npairing mode.', style: AppText.display),
        const SizedBox(height: Sp.x4),
        Text(
          'Your WHOOP only talks to one phone at a time. Force-quit the official '
          'WHOOP app, then put the strap into pairing mode before continuing.',
          style: AppText.bodySoft,
        ),
        const SizedBox(height: Sp.x6),
        ProCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _Bullet(
                icon: Ic.watch,
                title: 'Wake the strap',
                body: 'Place it on its charger so it powers up and is awake.',
              ),
              SizedBox(height: Sp.x4),
              _Bullet(
                icon: Ic.bluetooth,
                title: 'Enter pairing mode',
                body:
                    'Follow the WHOOP unpair/reset steps so it advertises to a '
                    'new phone.',
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x4),
        ProCard(
          color: AppColors.warnSoft,
          shadow: const [],
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(Ic.info, size: 20, color: AppColors.warn),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Text(
                  'Pairing will likely FAIL if the strap isn\'t in pairing mode. '
                  'Make sure it is before you continue.',
                  style: AppText.caption.copyWith(color: AppColors.ink),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x7),
        FilledButton(
          onPressed: onReady,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('My strap is in pairing mode'),
              SizedBox(width: Sp.x2),
              AppIcon(Ic.arrowRight, size: 20, color: Colors.white),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _Bullet(
      {required this.icon, required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: AppColors.coralSoft,
            borderRadius: BorderRadius.circular(R.chip),
          ),
          child: AppIcon(icon, size: 20, color: AppColors.coralDeep),
        ),
        const SizedBox(width: Sp.x4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.title),
              const SizedBox(height: 2),
              Text(body, style: AppText.bodySoft),
            ],
          ),
        ),
      ],
    );
  }
}

/// Strap hero image with a graceful coral-gradient placeholder if the asset
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
        child: AppIcon(Ic.watch, size: 76, color: Colors.white),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 2 — scan / pair
// ─────────────────────────────────────────────────────────────────────────────

class _ScanStep extends StatefulWidget {
  final VoidCallback onBack;
  const _ScanStep({super.key, required this.onBack});
  @override
  State<_ScanStep> createState() => _ScanStepState();
}

enum _Phase { scanning, found, notFound, pairing, askReady }

class _ScanStepState extends State<_ScanStep> {
  _Phase _phase = _Phase.scanning;
  BluetoothDevice? _device;
  String? _error;

  @override
  void initState() {
    super.initState();
    // On iOS 18+ pairing goes through the AccessorySetupKit picker (which does its own
    // discovery + selection) so the band is provisioned for iOS-26 background relaunch.
    // On Android / iOS < 18 we use the service-filtered scan flow.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ask = await context.read<AppState>().accessorySetupSupported();
      if (!mounted) return;
      if (ask) {
        setState(() => _phase = _Phase.askReady);
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
      _phase = _Phase.pairing;
      _error = null;
    });
    try {
      await context.read<AppState>().pairViaAccessorySetup();
      // On success the gate rebuilds to the main shell.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _phase = _Phase.askReady;
      });
    }
  }

  Future<void> _scan() async {
    setState(() {
      _phase = _Phase.scanning;
      _device = null;
      _error = null;
    });
    try {
      final d = await context.read<AppState>().scanForBand();
      if (!mounted) return;
      setState(() {
        _device = d;
        _phase = d == null ? _Phase.notFound : _Phase.found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _phase = _Phase.notFound;
      });
    }
  }

  Future<void> _pair() async {
    final d = _device;
    if (d == null) return;
    setState(() {
      _phase = _Phase.pairing;
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
        _error = e.toString();
        _phase = _Phase.found;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x3, Sp.x2, Sp.screen, 0),
          child: Row(children: [
            RoundIconButton(Ic.arrowLeft, onTap: widget.onBack),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                Sp.screen, Sp.x4, Sp.screen, Sp.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  switch (_phase) {
                    _Phase.notFound => 'No strap found.',
                    _Phase.askReady => 'Pair your\nstrap.',
                    _ => 'Finding your\nstrap.',
                  },
                  style: AppText.display,
                ),
                const SizedBox(height: Sp.x4),
                Text(
                  switch (_phase) {
                    _Phase.scanning =>
                      'Scanning for a nearby WHOOP in pairing mode…',
                    _Phase.found =>
                      'Found a strap. Confirm it\'s yours, then pair.',
                    _Phase.notFound =>
                      'We couldn\'t find a strap. Make sure it\'s awake and in '
                          'pairing mode, then try again.',
                    _Phase.pairing => 'Pairing with your strap…',
                    _Phase.askReady =>
                      'Tap Pair, then choose your WHOOP in the system sheet. '
                          'This lets OpenStrap reconnect in the background.',
                  },
                  style: AppText.bodySoft,
                ),
                const Spacer(),
                Center(child: _Visual(phase: _phase, device: _device, name: _name)),
                const Spacer(),
                if (_error != null) ...[
                  Row(children: [
                    AppIcon(Ic.info, size: 18, color: AppColors.bad),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: Text(_error!,
                          style: AppText.caption
                              .copyWith(color: AppColors.bad)),
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

  Widget _actions() {
    switch (_phase) {
      case _Phase.scanning:
        return const SizedBox(height: 56);
      case _Phase.askReady:
        return FilledButton(
          onPressed: _pairViaAsk,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('Pair'),
              SizedBox(width: Sp.x2),
              AppIcon(Ic.bluetooth, size: 20, color: Colors.white),
            ],
          ),
        );
      case _Phase.found:
        return FilledButton(
          onPressed: _pair,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('Pair'),
              SizedBox(width: Sp.x2),
              AppIcon(Ic.bluetooth, size: 20, color: Colors.white),
            ],
          ),
        );
      case _Phase.pairing:
        return const FilledButton(
          onPressed: null,
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2.2, color: Colors.white),
          ),
        );
      case _Phase.notFound:
        return OutlinedButton(
          onPressed: _scan,
          child: const Text('Scan again'),
        );
    }
  }
}

/// The central animated visual: a pulsing bluetooth ring while scanning, the
/// strap name when found, a spinner while pairing, a muted watch when missing.
class _Visual extends StatefulWidget {
  final _Phase phase;
  final BluetoothDevice? device;
  final String Function(BluetoothDevice) name;
  const _Visual(
      {required this.phase, required this.device, required this.name});
  @override
  State<_Visual> createState() => _VisualState();
}

class _VisualState extends State<_Visual>
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
    if (widget.phase == _Phase.found && widget.device != null) {
      return ProCard(
        padding: const EdgeInsets.symmetric(
            horizontal: Sp.x6, vertical: Sp.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(Sp.x4),
              decoration: BoxDecoration(
                color: AppColors.coralSoft,
                borderRadius: BorderRadius.circular(R.cardSm),
              ),
              child: AppIcon(Ic.watch, size: 34, color: AppColors.coralDeep),
            ),
            const SizedBox(height: Sp.x4),
            Text(widget.name(widget.device!),
                style: AppText.h1, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (widget.phase == _Phase.notFound) {
      return Opacity(
        opacity: 0.45,
        child: Container(
          width: 132,
          height: 132,
          decoration: BoxDecoration(
              color: AppColors.surfaceAlt, shape: BoxShape.circle),
          child: AppIcon(Ic.watch, size: 56, color: AppColors.inkMuted),
        ),
      );
    }
    // scanning / pairing → pulsing rings
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value;
        return SizedBox(
          width: 180,
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (final phase in const [0.0, 0.5])
                _ring((t + phase) % 1.0),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.coral,
                  shape: BoxShape.circle,
                  boxShadow: Shadows.coral,
                ),
                child: const AppIcon(Ic.bluetooth, size: 40, color: Colors.white),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _ring(double t) {
    final size = 96 + t * 84;
    return Opacity(
      opacity: (1 - t) * 0.5,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.coral, width: 2),
        ),
      ),
    );
  }
}
