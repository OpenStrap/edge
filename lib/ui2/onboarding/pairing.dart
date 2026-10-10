// Pairing.
//
// The failure states are the screen. A hardware app that says "Couldn't pair"
// and offers a Retry button has told the user nothing and given them nowhere
// to go — the audit found exactly that here: a refused bond and a dismissed
// picker fell through to the same dead end. They are different problems with
// different fixes, and neither of them is the user's fault.
//
// There is also always a way out. Someone whose band is flat, or who is
// installing this before the hardware arrives, must be able to reach the app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ble/ble_state.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../ui2.dart';

/// Onboarding steps the user deliberately walked past.
///
/// [AppState.route] is derived purely from device + profile state, so a user
/// who skips pairing (band flat, hardware not arrived) or who leaves an
/// optional profile field blank would be bounced back to the same step
/// forever. The bypass is the user's answer to that, and it is theirs to
/// give — so it is recorded here rather than by weakening the conditions
/// AppState uses for everything else.
class OnboardingBypass {
  OnboardingBypass._();

  static const kPairing = 'onboard.skipped_pairing';
  static const kProfile = 'onboard.saw_profile_setup';

  /// Bumped on every skip so the gate — which selects on the AppState route,
  /// not on SharedPreferences — rebuilds.
  static final revision = ValueNotifier<int>(0);

  static bool get pairingSkipped => Prefs.getBool(kPairing, false);
  static bool get profileSeen => Prefs.getBool(kProfile, false);

  static void mark(String key) {
    Prefs.setBool(key, true);
    revision.value++;
  }

  // No `clear`. Un-skipping cannot walk the gate back to pairing: the shell
  // latches `onboarded` on its first frame and the gate sends pairing/profile
  // straight to the shell from then on. "Pair a band" pushes `RePair` instead
  // — see `profile/devices.dart`.
}

enum PairPhase {
  /// Nothing tried yet.
  idle,
  scanning,

  /// The phone's own Bluetooth stack refused us — permission, radio off, or no
  /// BLE at all. Nothing about the band is known yet, and every band-side
  /// instruction ("wake it, hold it close") is a wasted walk around the house.
  bluetoothBlocked,

  /// The scan completed and found nothing in range.
  notFound,

  /// The link came up but the band refused to bond. Distinct because the fix
  /// is in the phone's own Bluetooth settings, not in this app.
  bondRefused,

  /// The system picker was dismissed. Not an error — do not shout.
  cancelled,

  /// Anything else, with the real message attached.
  failed,
  paired,
}

/// The phone-side blocker behind a thrown pairing error, or null when the
/// failure is genuinely about the band.
///
/// [BleUnavailableException] is checked before the string matcher because it
/// carries the verdict already: its `adapterOff` case does not contain any of
/// the phrases the matcher looks for, so classifying it by text alone would
/// silently demote a radio-off to a band fault.
BleBlocker? pairBlocker(Object error) => error is BleUnavailableException
    ? error.blocker
    : classifyBleBlocker(error: error);

/// Classify a thrown pairing error. Pure — this is the whole reason the
/// distinct states exist rather than one "Couldn't pair".
PairPhase classifyPairError(Object error, {int bondRefusals = 0}) {
  // First, because this is the one failure that is not about the band at all.
  // It used to fall through to `failed` (or, via a null scan, to "No band in
  // range"), which sends someone who revoked a permission looking for hardware.
  if (pairBlocker(error) != null) return PairPhase.bluetoothBlocked;
  final s = error.toString().toLowerCase();
  if (s.contains('cancel') || s.contains('dismiss')) return PairPhase.cancelled;
  if (bondRefusals > 0 || s.contains('bond') || s.contains('encrypt')) {
    return PairPhase.bondRefused;
  }
  return PairPhase.failed;
}

class PairingScreen extends StatefulWidget {
  /// Walk past pairing and open the app anyway. Supplied by the router.
  final VoidCallback? onSkip;

  const PairingScreen({super.key, this.onSkip});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  PairPhase _phase = PairPhase.idle;
  String _detail = '';
  BleBlocker? _blocker;

  Future<void> _pair() async {
    final app = context.read<AppState>();
    setState(() {
      _phase = PairPhase.scanning;
      _detail = '';
      _blocker = null;
    });
    try {
      if (await app.accessorySetupSupported()) {
        await app.pairViaAccessorySetup();
      } else {
        final found = await app.scanForBand();
        if (found == null) {
          if (mounted) setState(() => _phase = PairPhase.notFound);
          return;
        }
        await app.pairWith(found);
      }
      if (!mounted) return;
      setState(() => _phase = PairPhase.paired);
      // Pushed from the device picker, nothing under this route reacts to
      // `isPaired` — the onboarding gate swaps `home` beneath it — and the
      // only button on "Paired" re-runs the scan. Close it, unless something
      // (RePair) already has.
      final route = ModalRoute.of(context);
      if (route != null && route.isCurrent && !route.isFirst) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _blocker = pairBlocker(e);
        _phase = classifyPairError(e, bondRefusals: app.device.bondRefusals);
        _detail = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext c) => PairingView(
        phase: _phase,
        detail: _detail,
        blocker: _blocker,
        onPair: _pair,
        onSkip: widget.onSkip,
      );
}

class PairingView extends StatelessWidget {
  final PairPhase phase;
  final String detail;
  final VoidCallback onPair;
  final VoidCallback? onSkip;

  /// Which phone-side blocker, when [phase] is `bluetoothBlocked`.
  final BleBlocker? blocker;

  const PairingView({
    super.key,
    required this.phase,
    required this.onPair,
    this.detail = '',
    this.blocker,
    this.onSkip,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final busy = phase == PairPhase.scanning;
    // The copy for this one lives in the BLE layer, so this screen and the
    // Devices screen cannot drift into two different accounts of one state.
    final blocked = phase == PairPhase.bluetoothBlocked
        ? localizedBandStatus(
            c, bandStatusFor(connection: 'disconnected', blocker: blocker))
        : null;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(S.x4, S.x8, S.x4, S.x8),
          children: [
            Icon(
                blocked == null
                    ? LucideIcons.bluetooth
                    : LucideIcons.bluetoothOff,
                size: 36,
                color: p.on(C.blue)),
            const SizedBox(height: S.x5),
            Text(_title(c, phase, blocker), style: F.t1.copyWith(color: p.ink)),
            const SizedBox(height: S.x3),
            Text(_body(c, phase, blocker), style: F.body.copyWith(color: p.ink2)),
            if (blocked?.fix != null) ...[
              const SizedBox(height: S.x3),
              Text(blocked!.fix!,
                  style: F.body.copyWith(
                      color: p.on(C.blue), fontWeight: FontWeight.w600)),
            ],
            if (busy) ...[
              const SizedBox(height: S.x8),
              Center(child: CircularProgressIndicator(color: p.on(C.blue))),
            ],
            ..._advice(c, phase, detail),
            const SizedBox(height: S.x8),
            BigButton(_cta(c, phase),
                icon: LucideIcons.radio,
                color: C.blue,
                onTap: busy ? null : onPair),
            if (onSkip != null && phase != PairPhase.paired) ...[
              const SizedBox(height: S.x3),
              // Never disabled, not even mid-scan: waiting out a scan you
              // already know will fail is exactly the trap this exists for.
              BigButton(AppLocalizations.of(c)?.pairingSkipForNow ?? 'Skip for now',
                  color: C.blue, soft: true, onTap: onSkip),
              const SizedBox(height: S.x2),
              Text(
                AppLocalizations.of(c)?.pairingSkipNote ??
                    'The app opens without a band. Nothing is measured until one '
                        'is paired.',
                style: F.cap.copyWith(color: p.ink3),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _title(BuildContext c, PairPhase phase, [BleBlocker? blocker]) {
    final l = AppLocalizations.of(c);
    return switch (phase) {
      PairPhase.bluetoothBlocked => localizedBandStatus(
          c, bandStatusFor(connection: 'disconnected', blocker: blocker))
        .title,
      PairPhase.idle => l?.pairingIdleTitle ?? 'Wake the band and hold it close',
      PairPhase.scanning => l?.pairingScanningTitle ?? 'Looking for your band',
      PairPhase.notFound => l?.pairingNotFoundTitle ?? 'No band in range',
      PairPhase.bondRefused =>
        l?.pairingBondRefusedTitle ?? 'The band refused the pairing',
      PairPhase.cancelled => l?.pairingCancelledTitle ?? 'Pairing was cancelled',
      PairPhase.failed => l?.pairingFailedTitle ?? 'Pairing did not complete',
      PairPhase.paired => l?.pairingPairedTitle ?? 'Paired',
    };
  }

  static String _body(BuildContext c, PairPhase phase, [BleBlocker? blocker]) {
    final l = AppLocalizations.of(c);
    return switch (phase) {
      PairPhase.bluetoothBlocked => localizedBandStatus(
          c, bandStatusFor(connection: 'disconnected', blocker: blocker))
        .reason,
      PairPhase.idle => l?.pairingIdleBody ??
          'Take the band off the charger, put it on your wrist and keep the '
              'phone within arm’s reach.',
      PairPhase.scanning => l?.pairingScanningBody ??
          'A band that has just come off the charger can take up to half a '
              'minute to start advertising.',
      PairPhase.notFound => l?.pairingNotFoundBody ??
          'Nothing answered the scan. The band advertises only when it is '
              'awake and not already connected to another phone.',
      PairPhase.bondRefused => l?.pairingBondRefusedBody ??
          'The band connected but refused the encryption key. That usually means an old pairing record on this phone, not a fault in the band.',
      PairPhase.cancelled => l?.pairingCancelledBody ??
          'The system picker was dismissed before a band was chosen.',
      PairPhase.failed => l?.pairingFailedBody ??
          'The band was reachable but the session did not finish.',
      PairPhase.paired => l?.pairingPairedBody ?? 'Setting up the first sync.',
    };
  }

  static String _cta(BuildContext c, PairPhase phase) {
    final l = AppLocalizations.of(c);
    return switch (phase) {
      PairPhase.idle => l?.pairingFindMyBand ?? 'Find my band',
      PairPhase.scanning => l?.pairingSearching ?? 'Searching…',
      PairPhase.cancelled => l?.pairingOpenPickerAgain ?? 'Open the picker again',
      PairPhase.paired => l?.actionContinue ?? 'Continue',
      _ => l?.pairingTryAgain ?? 'Try again',
    };
  }

  /// The fix, spelled out, for the states that have one.
  List<Widget> _advice(BuildContext c, PairPhase phase, String detail) {
    final l = AppLocalizations.of(c);
    return switch (phase) {
      PairPhase.notFound => [
          const SizedBox(height: S.x6),
          StatusCard(
            l?.pairingNotFoundAdviceTitle ??
                'Three things stop a band answering',
            l?.pairingNotFoundAdviceBody ??
                'It is still on the charger; it is out of range; or it is '
                    'still connected to another phone or to the vendor app.',
            fix: l?.pairingNotFoundAdviceFix ??
                'Force-quit the other app, then scan again',
            icon: LucideIcons.searchX,
          ),
        ],
      PairPhase.bondRefused => [
          const SizedBox(height: S.x6),
          StatusCard(
            l?.pairingBondRefusedAdviceTitle ??
                'Forget the band in Bluetooth settings first',
            l?.pairingBondRefusedAdviceBody ??
                'In the phone’s Bluetooth settings, forget the band, then scan again here. Only the system can clear the old pairing record.',
            fix: l?.pairingBondRefusedAdviceFix ?? 'Open Bluetooth settings',
            icon: LucideIcons.unlink,
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            _Detail(detail),
          ],
        ],
      PairPhase.failed => [
          const SizedBox(height: S.x6),
          StatusCard(
            l?.pairingFailedAdviceTitle ??
                'The band was found but the session did not finish',
            l?.pairingFailedAdviceBody ??
                'Scanning again from a metre away normally works.',
            icon: LucideIcons.triangleAlert,
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            _Detail(detail),
          ],
        ],
      _ => const [],
    };
  }
}

/// The raw error, kept but demoted. It is useless to most people and the only
/// thing that helps in a bug report.
class _Detail extends StatelessWidget {
  final String text;
  const _Detail(this.text);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Surface(
      elevation: 0,
      color: p.card2,
      child: Text(text, style: F.cap.copyWith(color: p.ink3)),
    );
  }
}
