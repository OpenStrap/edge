// Pair a second sensor: scan, pick one, write the `device` row.
//
// WHY THIS EXISTS. The whole decode-and-store path for a standard Bluetooth
// heart-rate sensor shipped, tested, and unreachable: `HrsLink.arm()` reads a
// `device` row and nothing ever created one, so every call returned false and
// the feature was a library with no door. This is the door.
//
// WHY IT IS GENERIC OVER A [BandEntry] AND NOT ABOUT STRAPS. The scan filter,
// the candidate list, the picking, the characteristic check and the `device`
// row are the same work for every notify-class band; the only part that
// differs is what happens between "user tapped a row" and "the row is
// written" — for a strap, nothing, and for a ring, a key exchange against a
// factory-reset device. So that step is the ONE injected parameter
// ([onPicked]) and everything else is shared. A second copy of this screen per
// band is how the copy, the honesty rules and the iOS gate below drift apart.
//
// WHAT IT DELIBERATELY DOES NOT DO.
//  * Not a background scan. It scans while it is on screen and stops.
//  * Not a connection owner. The pairing connect is dropped as soon as the row
//    is written; `HrsLink.arm` opens the real session when a workout starts.
//  * Not a promise that anything derives from the sensor. `kDerivableSources`
//    is empty (ASSUMPTIONS R6): a paired sensor CAPTURES, and its seconds bank
//    and sync and appear in diagnostics while producing no metric at all. The
//    copy on this screen says so rather than implying a recovery score.
//
// THE iOS GATE is the part worth reading twice — see
// `HrsLink.scanHeldBackReason`, which carries the evidence. Starting a scan on
// an iPhone whose WHOOP is not yet paired creates a `CBCentralManager`, and
// AccessorySetupKit's picker refuses to open while one exists. That is
// recoverable by restarting the app and by nothing else, so the screen says it
// out loud BEFORE scanning and lets the user decide, rather than discovering it
// later as a WHOOP that cannot be paired for no visible reason.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ble/ble_state.dart'
    show BleUnavailableException, bandStatusFor, classifyBleBlocker;
import '../../ble/hrs_link.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'profile.dart';

/// A sensor this phone already has a `device` row for.
typedef PairedSensor = ({String id, String? label});

class PairSensorScreen extends StatefulWidget {
  /// Which band to look for. Its `service` is the scan filter and its
  /// `requiredCharacteristics` are what a candidate has to actually expose.
  final BandEntry entry;

  /// Called with the picked peripheral. Returns null on success, or a
  /// user-facing reason on failure. This is where a band that needs a key
  /// exchange does it.
  ///
  /// NULL means the plain notify-class pairing — connect, discover, check the
  /// required characteristics, write the row — which is the whole of what a
  /// heart-rate strap needs. Making it the default is what keeps the common
  /// case out of every caller.
  final Future<String?> Function(BluetoothDevice)? onPicked;

  const PairSensorScreen({super.key, required this.entry, this.onPicked});

  @override
  State<PairSensorScreen> createState() => _PairSensorScreenState();
}

class _PairSensorScreenState extends State<PairSensorScreen> {
  List<BandCandidate> _found = const [];
  bool _scanning = false;

  /// Why a scan should not start yet (the iOS gate), or null. Cleared — not
  /// re-checked — once the user has chosen to scan anyway: it is their call to
  /// make once, not a question to re-ask every time the list refreshes.
  String? _heldBack;

  /// The last failure, in a sentence. Never "Something went wrong".
  String? _problem;

  /// Remote id of the peripheral being paired, so its row can say so and the
  /// rest of the list can stop accepting taps.
  String? _busy;

  PairedSensor? _paired;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // Ends THIS file's scan early if it is the one running. Never a bare
    // `FlutterBluePlus.stopScan()`: the radio has one scanner and every
    // holder awaits `isScanning == false`, so a stop issued while our own
    // scan is still queued behind `withScanLock` would end the RUNNING
    // holder's scan — which then reports "found nothing" with no error to
    // say why.
    HrsLink.stopScanIfRunning();
    super.dispose();
  }

  Future<void> _load() async {
    final row = await HrsLink.pairedSensorRow();
    final held = await HrsLink.scanHeldBackReason();
    if (!mounted) return;
    setState(() {
      _paired = row == null
          ? null
          : (id: row['id'] as String, label: row['label'] as String?);
      _heldBack = held;
    });
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _problem = null;
      _heldBack = null;
      _found = const [];
    });
    try {
      await HrsLink.scanFor(
        widget.entry,
        onResults: (c) {
          if (mounted) setState(() => _found = c);
        },
      );
    } catch (e) {
      // A phone-level blocker has copy of its own, written once and shared by
      // every surface that shows the link — home, devices, pairing, and now
      // this. Anything else is reported as itself.
      final blocker =
          e is BleUnavailableException ? e.blocker : classifyBleBlocker(error: e);
      if (!mounted) return;
      setState(() => _problem = blocker != null
          ? localizedBandStatus(context,
                  bandStatusFor(connection: 'disconnected', blocker: blocker))
              .reason
          : (AppLocalizations.of(context)?.pairSensorScanDidNotRun(e.toString()) ??
              'The scan did not run: $e'));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pick(BandCandidate c) async {
    setState(() {
      _busy = c.device.remoteId.str;
      _problem = null;
    });
    // The injected callback (a ring's key exchange) is not this file's code
    // and can throw — a `BluetoothDevice.connect` timeout, a keychain error,
    // anything the callback itself does not already turn into a returned
    // sentence. An uncaught throw here skips the `setState` below entirely,
    // which leaves `_busy` set and every row permanently un-tappable until
    // the screen is torn down and rebuilt — the same "stuck busy" failure
    // mode a returned failure string already has a real answer for.
    final l = AppLocalizations.of(context);
    String? failure;
    try {
      failure = widget.onPicked != null
          ? await widget.onPicked!(c.device)
          : await HrsLink.pairNotifySensor(
              widget.entry,
              c.device,
              label: c.label,
            );
    } catch (e) {
      failure = l?.pairSensorCouldNotPair(e.toString()) ??
          'Could not pair that device: $e';
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _problem = failure;
      // On success the list has done its job; keeping it would invite a second
      // pair of a device that is now the paired one.
      if (failure == null) _found = const [];
    });
    if (failure == null) await _load();
  }

  Future<void> _forget(String id) async {
    await HrsLink.forgetDevice(id);
    if (!mounted) return;
    // `_load()` refreshes only THIS screen's own `_paired` field.
    // `AppState.sensors` is a separate, shared copy of the same device rows
    // — `devices.dart` reads it directly — and nothing else refreshes it on
    // this path, so a forget from here would leave that other screen showing
    // a sensor that no longer exists until something unrelated happened to
    // reload it.
    await context.read<AppState>().refreshSensors();
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext c) => PairSensorView(
        entryLabel: widget.entry.label,
        candidates: _found,
        scanning: _scanning,
        heldBack: _heldBack,
        problem: _problem,
        paired: _paired,
        busyRemoteId: _busy,
        onScan: _scan,
        onPick: _pick,
        onForget: _forget,
      );
}

/// The pure half — everything this screen draws, from values, so a test can
/// render every state without a radio.
class PairSensorView extends StatelessWidget {
  final String entryLabel;
  final List<BandCandidate> candidates;
  final bool scanning;

  /// The iOS gate's sentence, or null when a scan may just run.
  final String? heldBack;

  final String? problem;
  final PairedSensor? paired;
  final String? busyRemoteId;

  final VoidCallback? onScan;
  final void Function(BandCandidate)? onPick;
  final void Function(String id)? onForget;

  const PairSensorView({
    super.key,
    required this.entryLabel,
    this.candidates = const [],
    this.scanning = false,
    this.heldBack,
    this.problem,
    this.paired,
    this.busyRemoteId,
    this.onScan,
    this.onPick,
    this.onForget,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final busy = busyRemoteId != null;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.pairSensorAddASensor ?? 'Add a sensor',
                sub: entryLabel),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (paired != null) ..._pairedSection(c, paired!),
                Section(
                  paired == null
                      ? (l?.pairSensorWhatThisAdds ?? 'What this adds')
                      : (l?.pairSensorPairAnother ?? 'Pair another'),
                  Surface(
                    child: Text(
                      l?.pairSensorExplainer ??
                          'A sensor is used only while a workout is running, and '
                              'only for heart rate and beat timing. It does not '
                              'replace your band, it is never used overnight, and '
                              'nothing it records feeds a score yet — its readings are '
                              'stored and shown, and that is all.',
                      style: F.cap.copyWith(color: p.ink3, height: 1.5),
                    ),
                  ),
                ),
                if (heldBack != null) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.pairSensorSearchWouldHideSheet ??
                        'Searching would hide the WHOOP pairing sheet',
                    heldBack!,
                    fix: l?.pairSensorSearchAnyway ?? 'Search anyway',
                    icon: LucideIcons.triangleAlert,
                    onFix: busy ? null : onScan,
                  ),
                ] else ...[
                  const SizedBox(height: S.x6),
                  BigButton(
                    scanning
                        ? (l?.pairSensorSearching ?? 'Searching…')
                        : (l?.pairSensorSearchForSensors ?? 'Search for sensors'),
                    icon: LucideIcons.bluetooth,
                    color: C.blue,
                    onTap: scanning || busy ? null : onScan,
                  ),
                ],
                if (problem != null) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.pairSensorThatDidNotWork ?? 'That did not work',
                    problem!,
                    icon: LucideIcons.circleAlert,
                  ),
                ],
                if (candidates.isNotEmpty)
                  Section(
                    l?.pairSensorInRange ?? 'In range',
                    Surface(
                      pad: const EdgeInsets.symmetric(horizontal: S.x4),
                      child: Column(children: [
                        for (var i = 0; i < candidates.length; i++) ...[
                          _candidateRow(c, candidates[i], busy),
                          if (i < candidates.length - 1)
                            Divider(color: p.line, height: 1),
                        ],
                      ]),
                    ),
                  )
                else if (scanning)
                  Padding(
                    padding: const EdgeInsets.only(top: S.x6),
                    child: Center(
                      child: NoData(
                          message: l?.pairSensorListeningForSensors ??
                              'Listening for sensors…'),
                    ),
                  )
                else if (heldBack == null && problem == null)
                  Padding(
                    padding: const EdgeInsets.only(top: S.x6),
                    child: StatusCard(
                      l?.pairSensorNothingFoundYet ?? 'Nothing found yet',
                      l?.pairSensorNothingFoundBody ??
                          'A sensor answers a search only while it is awake, worn '
                              'or damp, and not already connected to another phone '
                              'or app.',
                      icon: LucideIcons.searchX,
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _pairedSection(BuildContext c, PairedSensor s) {
    final l = AppLocalizations.of(c);
    return [
      Section(
        l?.pairSensorPaired ?? 'Paired',
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            SetRow(
              LucideIcons.heartPulse,
              C.green,
              // A sensor that advertised no name is shown as what it is, not
              // as an invented one.
              s.label ?? entryLabel,
              sub: l?.pairSensorUsedDuringWorkouts ?? 'Used during workouts',
              chevron: false,
              onTap: null,
            ),
            SetRow(
              LucideIcons.trash2,
              C.red,
              l?.pairSensorForgetThisSensor ?? 'Forget this sensor',
              sub: l?.pairSensorForgetThisSensorSub ??
                  'Removes the source. The readings it already took stay.',
              danger: true,
              chevron: false,
              onTap: onForget == null ? null : () => onForget!(s.id),
            ),
          ]),
        ),
      ),
    ];
  }

  Widget _candidateRow(BuildContext c, BandCandidate cand, bool busy) {
    final l = AppLocalizations.of(c);
    final id = cand.device.remoteId.str;
    // The signal strength as the radio reported it, in its own unit. Not a bar
    // count: three bars is a judgement about distance nobody measured.
    //
    // An UNNAMED sensor also gets the tail of its remote id, because without a
    // name two of them are the same row twice and the user has no way to say
    // which one they meant. A named one does not — the id is machine plumbing
    // and putting it on every row is noise.
    final tail = id.length <= 5 ? id : id.substring(id.length - 5);
    return SetRow(
      LucideIcons.heartPulse,
      C.blue,
      cand.label ?? entryLabel,
      sub: busyRemoteId == id
          ? (l?.pairSensorPairing ?? 'Pairing…')
          : cand.label == null
              ? '…$tail · ${cand.rssi} dBm'
              : '${cand.rssi} dBm',
      chevron: !busy,
      onTap: busy || onPick == null ? null : () => onPick!(cand),
    );
  }
}
