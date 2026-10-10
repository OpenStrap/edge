import '../../l10n/display_text.dart';
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
//
// A SENSOR IN `kAskPickerSensors` DOES NOT SCAN AT ALL on iOS 18+. The app
// declares `NSAccessorySetupKitSupports`, so iOS never grants it standard
// Bluetooth access and a scan only ever sees accessories approved in an ASK
// picker — for such a sensor the scan returned an empty list with no error
// (#371/#372). Its "search" opens the ASK picker filtered to its own service
// instead, and the id that comes back goes to the same [onPicked] step a
// scanned row would. No scan runs first, so no `CBCentralManager` exists to
// make that picker fail either — but the pairing connect after it creates one,
// so the iOS gate's warning still shows.
//
// A notify-class sensor NOT in `kAskPickerSensors` (Polar PMD, Coros) has no
// picker and no scan on iOS 18+, so the screen says so instead of running a
// scan that returns nothing.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/accessory_setup.dart';
import '../../ble/adapters/_registry.dart';
import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ble/ble_state.dart'
    show BleUnavailableException, bandStatusFor, classifyBleBlocker;
import '../../ble/hrs_link.dart';
import '../../ble/ios_ble_restore.dart';
import '../../data/db.dart' show LocalDb;
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'profile.dart';
import 'wearable_numbers.dart' show WearableUnlocks;

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

  /// Pair with a secret the device ALREADY holds, typed by the user — for a
  /// ring, the key its own app installed, so it can be paired without a
  /// factory reset. Null hides the field. When the field is left empty the
  /// ordinary [onPicked] step runs, so this only ever adds a way in.
  final Future<String?> Function(BluetoothDevice, String key)? onPickedWithKey;

  const PairSensorScreen({
    super.key,
    required this.entry,
    this.onPicked,
    this.onPickedWithKey,
  });

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

  /// True when this sensor pairs through the iOS ASK picker instead of a scan
  /// (iOS 18+ and [kAskPickerSensors]). Decided once, in [_load].
  bool _viaPicker = false;

  /// True on iOS 18+ for a sensor NOT in [kAskPickerSensors]: no picker of
  /// its own and a scan that cannot see it, so searching says so instead.
  bool _unreachable = false;

  /// The key field's text, when [PairSensorScreen.onPickedWithKey] is set.
  final TextEditingController _key = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // Ends THIS SCREEN's scan early if it is the one running. Never a bare
    // `FlutterBluePlus.stopScan()`: the radio has one scanner and every
    // holder awaits `isScanning == false`, so a stop issued while our own
    // scan is still queued behind `withScanLock` would end the RUNNING
    // holder's scan — which then reports "found nothing" with no error to
    // say why. Hence the `owner` token: it is this `State`, so the check is
    // "mine", not "one of ours". Unawaited here, and only here: `dispose`
    // cannot await one, and nothing follows it onto the radio — unlike
    // `_pick`, where a connect does.
    unawaited(HrsLink.stopScanIfRunning(this));
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // NOT `HrsLink.pairedSensorRow()` — that is hardcoded to the heart-rate
    // strap's own adapter id, and this screen is generic over [BandEntry]
    // (a Colmi ring, an Oura ring, a strap). Looked up by `widget.entry.id`
    // directly so "already paired" renders for whichever band this screen
    // was opened for.
    Map<String, Object?>? row;
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == widget.entry.id) {
        row = r;
        break;
      }
    }
    final askOn = await AccessorySetup.isSupported();
    final viaPicker =
        kAskPickerSensors.any((e) => e.id == widget.entry.id) && askOn;
    // Kept on the picker path too: no scan runs there, but pairing the ring
    // connects through flutter_blue_plus, which creates the same central.
    final held = await HrsLink.scanHeldBackReason();
    if (!mounted) return;
    setState(() {
      _viaPicker = viaPicker;
      _unreachable = askOn && !viaPicker;
      _paired = row == null
          ? null
          : (id: row['id'] as String, label: row['label'] as String?);
      _heldBack = held;
    });
  }

  Future<void> _scan() async {
    if (_viaPicker) return _pairViaPicker();
    if (_unreachable) {
      final label = widget.entry.label;
      setState(() => _problem =
          AppLocalizations.of(context)?.pairSensorUnreachableIos(label) ??
              'This iPhone only lets the app reach sensors approved in the '
                  'system pairing sheet, and a $label cannot be offered there '
                  'yet: its advertisement does not carry the service it is '
                  'identified by. Pair it on Android for now.');
      return;
    }
    setState(() {
      _scanning = true;
      _problem = null;
      _heldBack = null;
      _found = const [];
    });
    try {
      await HrsLink.scanFor(
        widget.entry,
        owner: this,
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

  /// The iOS 18+ path for a [kAskPickerSensors] entry: the ASK picker filtered
  /// to this sensor's service, then the same pairing step a scanned row gets.
  Future<void> _pairViaPicker() async {
    setState(() {
      _scanning = true;
      _problem = null;
      _heldBack = null;
      _found = const [];
    });
    final l = AppLocalizations.of(context);
    String? id;
    String? failure;
    // The picker refuses to open while a restore central is alive, so it is
    // released first and re-created after — WITHOUT recording the ring as a
    // band (see `IosBleRestore.reacquireCentral`).
    await IosBleRestore.releaseCentralForPicker();
    try {
      id = await AccessorySetup.showSensorPicker([widget.entry.service]);
    } on PlatformException catch (e) {
      failure = l?.pairSensorCouldNotPair(e.message ?? e.code) ??
          'Could not pair that device: ${e.message ?? e.code}';
    } catch (e) {
      failure = l?.pairSensorCouldNotPair(e.toString()) ??
          'Could not pair that device: $e';
    } finally {
      await IosBleRestore.reacquireCentral();
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _problem = failure;
    });
    if (id != null) {
      await _pickDevice(BluetoothDevice.fromId(id), label: null);
    }
  }

  Future<void> _pick(BandCandidate c) => _pickDevice(c.device, label: c.label);

  Future<void> _pickDevice(BluetoothDevice device, {required String? label}) async {
    setState(() {
      _busy = device.remoteId.str;
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
    // OUR OWN SCAN, ENDED AND WAITED OUT, before anything connects. This
    // screen's 15 s window is very likely still running when a row is tapped,
    // and a connect racing a live scan is the classic Android GATT-133. Read
    // `l` above the await, because `context` after one is the lint's point.
    await HrsLink.stopScanIfRunning(this);
    String? failure;
    final typedKey = _key.text.trim();
    try {
      failure = widget.onPickedWithKey != null && typedKey.isNotEmpty
          ? await widget.onPickedWithKey!(device, typedKey)
          : widget.onPicked != null
          ? await widget.onPicked!(device)
          : await HrsLink.pairNotifySensor(
              widget.entry,
              device,
              label: label,
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
    // The key belonged to the device just paired; a second pair from this
    // screen must not silently reuse it.
    if (failure == null) _key.clear();
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
    entryLabel: uiText(c, widget.entry.label),
    adapterId: widget.entry.id,
    candidates: _found,
    scanning: _scanning,
    heldBack: _heldBack,
    problem: _problem,
    paired: _paired,
    busyRemoteId: _busy,
    keyController: widget.onPickedWithKey == null ? null : _key,
    onScan: _scan,
    onPick: _pick,
    onForget: _forget,
  );
}

/// The pure half — everything this screen draws, from values, so a test can
/// render every state without a radio.
class PairSensorView extends StatelessWidget {
  final String entryLabel;

  /// The entry's adapter, for "what this wearable unlocks"; null, or one
  /// with no column in the metric x device table, draws nothing extra.
  final String? adapterId;
  final List<BandCandidate> candidates;
  final bool scanning;

  /// The iOS gate's sentence, or null when a scan may just run.
  final String? heldBack;

  final String? problem;
  final PairedSensor? paired;
  final String? busyRemoteId;

  /// The optional "pair with the key it already holds" field. Null hides it.
  final TextEditingController? keyController;

  final VoidCallback? onScan;
  final void Function(BandCandidate)? onPick;
  final void Function(String id)? onForget;

  const PairSensorView({
    super.key,
    required this.entryLabel,
    this.adapterId,
    this.candidates = const [],
    this.scanning = false,
    this.heldBack,
    this.problem,
    this.paired,
    this.busyRemoteId,
    this.keyController,
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
                    // Worded per kind of device: a watch or ring does feed
                    // numbers (behind its flag, R6), a strap only a workout,
                    // and a Coros watch neither (no workout arms it).
                    child: Text(
                      withIosUninstallWarning(
                          c,
                      switch (categoryOf(adapterId)) {
                        _ when adapterId == kCoros.id =>
                          l?.pairSensorExplainerCoros ??
                              'A sports watch. When it syncs, it reads battery '
                                  'and a few seconds of live heart rate. No '
                                  'workout uses it, and recorded activities '
                                  'stay on the watch. Its readings are stored '
                                  'and shown; no number of ours is worked out '
                                  'from them.',
                        DeviceCategory.wearable =>
                          l?.pairSensorExplainerWearable ??
                              "A wearable's own records are stored and "
                                  'attributed to it, and its own values are '
                                  'always labelled as its. Working out our '
                                  'numbers from it (sleep, resting heart rate, '
                                  'strain) is experimental, and off until it '
                                  'has been checked against the hardware.',
                        DeviceCategory.healthMeasurement =>
                          l?.pairSensorExplainerMeasurement ??
                              "A measurement device's readings are stored and "
                                  'attributed to it. Using them in your profile '
                                  'is experimental, and off until it has been '
                                  'checked against the hardware.',
                        _ => l?.pairSensorExplainerWorkout ??
                            'A sensor gives heart rate and beat timing for '
                                'workouts. It does not replace your band. It '
                                'records while a workout runs, and a few '
                                'minutes after it ends. Its readings are '
                                'stored and shown. Scoring a workout from them '
                                'is experimental, and off until checked against '
                                'the hardware.',
                      }),
                      style: F.cap.copyWith(color: p.ink3, height: 1.5),
                    ),
                  ),
                ),
                if (adapterId != null) WearableUnlocks(adapterId!),
                if (keyController != null) ...[
                  // Before the user commits: a new key evicts the ring's own
                  // app, and there is no state in which both work.
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.pairSensorKeyReplacesTitle ??
                        "Pairing replaces the Oura app's key",
                    l?.pairSensorKeyReplacesBody ??
                        'The ring holds one key. Pairing without a key from '
                            'the Oura app gives the ring a new key of its own, '
                            'and the Oura app then stops working with this '
                            'ring until the ring is reset and set up there '
                            'again.',
                    icon: LucideIcons.triangleAlert,
                  ),
                  const SizedBox(height: S.x4),
                  _keySection(c, keyController!, busy || scanning),
                ],
                if (heldBack != null) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.pairSensorSearchWouldHideSheet ??
                        'Searching would hide the system pairing sheet',
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

  /// The key the device already holds, if the user has it. Optional, and says
  /// so: an empty field is the ordinary pairing.
  Widget _keySection(BuildContext c, TextEditingController ctl, bool locked) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Section(
      l?.pairSensorKeyTitle ?? 'Already set up elsewhere?',
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            l?.pairSensorKeyBody ??
                'If you have the key this device already uses, paste it here '
                    'and it pairs without a factory reset — nothing is written '
                    'to the device. Several keys, one per line, are tried in '
                    'turn until one is accepted, which is handy when you have '
                    'a few and do not know which belongs to this device. Leave '
                    'it empty to pair the usual way.',
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
          TextField(
            controller: ctl,
            enabled: !locked,
            autocorrect: false,
            enableSuggestions: false,
            // ONE PER LINE, so the field has to be multi-line. `maxLines` is
            // how tall it may GROW, not a cap on what can be pasted: the cap
            // lives with the code that honours it (`kOuraMaxCandidateKeys`),
            // and a limit enforced in two places is the one that drifts.
            minLines: 1,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: F.head.copyWith(color: p.ink),
            decoration: InputDecoration(
              hintText: l?.pairSensorKeyHint ??
                  '32 hex digits or base64 — one key per line',
              hintStyle: F.head.copyWith(color: p.ink3),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: S.x3),
              enabledBorder:
                  UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: p.on(C.green))),
            ),
            ),
          ],
        ),
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
              // Only a workout-armed sensor is used during workouts; a
              // wearable or a measurement device never is.
              sub: switch (categoryOf(adapterId)) {
                _ when adapterId == kCoros.id =>
                  l?.pairSensorSyncedInWindows ?? 'Synced in short windows',
                DeviceCategory.wearable =>
                  l?.pairSensorStoredOnSync ?? 'Records stored when it syncs',
                DeviceCategory.healthMeasurement =>
                  l?.pairSensorStoredOnReading ??
                      'Readings stored as it takes them',
                _ => l?.pairSensorUsedDuringWorkouts ?? 'Used during workouts',
              },
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
    final signal = cand.rssi == null
        ? (l?.devicesConnected ?? 'Connected')
        : '${cand.rssi} dBm';
    return SetRow(
      LucideIcons.heartPulse,
      C.blue,
      cand.label ?? entryLabel,
      sub: busyRemoteId == id
          ? (l?.pairSensorPairing ?? 'Pairing…')
          : cand.label == null
              ? '…$tail · $signal'
              : signal,
      chevron: !busy,
      onTap: busy || onPick == null ? null : () => onPick!(cand),
    );
  }
}
