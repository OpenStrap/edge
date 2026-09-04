// The one door into pairing.
//
// WHY THIS EXISTS. There used to be three: onboarding's `PairingScreen`
// (WHOOP-only, one "Find my band" button), `devices.dart`'s `addSensor`
// bottom sheet (a plain list of two rows), and `RePair` (a thin wrapper
// around the first). Someone with a ring or a chest strap and no WHOOP yet
// had nowhere to go from onboarding at all. This screen is the single
// front door for all three call sites — first pair, re-pair, and add a
// second sensor — so the flow, the back button and the copy cannot drift
// into three different accounts of one action again.
//
// WHAT IT DOES NOT DO. It does not invent support. The category list below
// is exactly [kBandRegistry] — three real entries, not six aspirational
// ones — because a category tile for a scale or a blood-pressure cuff this
// app cannot read from would be a promise with nothing behind it. See
// ASSUMPTIONS R6 and `sensorIcon`'s own doc for the same rule applied
// elsewhere.
//
// WHY NO BRAND LOGOS. A brand's wordmark is nominative fair use — naming a
// product to say this app works with it. A brand's LOGO GRAPHIC is someone
// else's copyrighted artwork on top of that, and a stylized mark or a
// product photo reads as an implied partnership this app does not have and
// has no license for. Every device below is a plain-text name and a
// generic Lucide glyph, never a fetched brand asset.
//
// WHY WHOOP IS A SEPARATE PUSH, NOT A ROW IN THE SAME LIST. A framed band
// pairs through `PairingScreen` — on iOS, through AccessorySetupKit's OWN
// system sheet, which this app does not render and cannot fold into a
// custom list alongside notify-class candidates. Tapping "Watches & bands"
// here pushes that screen unchanged; this file adds a front door to it, it
// does not rebuild what is already there.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ble/ble_state.dart'
    show BleUnavailableException, bandStatusFor, classifyBleBlocker;
import '../../ble/hrs_link.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../onboarding/pairing.dart' show PairingScreen;
import '../ui2.dart';
import '../profile/devices.dart' show kPairableSensors, sensorIcon;
import '../profile/pair_sensor.dart' show PairSensorScreen;
import '../profile/profile.dart' show SetRow;

class DevicePickerScreen extends StatefulWidget {
  /// Walk past pairing entirely. Non-null only at true first-run onboarding
  /// — a re-pair or add-a-sensor push always has a screen underneath to pop
  /// back to, so it needs no separate way out.
  final VoidCallback? onSkip;

  /// Whether "Watches & bands" is offered at all. False from "add a
  /// sensor": this phone already has its one primary band, and re-pairing
  /// it is a distinct, destructive-feeling action reached from `RePair`,
  /// not something to offer beside a chest strap in the same list.
  final bool includeBand;

  const DevicePickerScreen({super.key, this.onSkip, this.includeBand = true});

  @override
  State<DevicePickerScreen> createState() => _DevicePickerScreenState();
}

class _DevicePickerScreenState extends State<DevicePickerScreen> {
  final _query = TextEditingController();
  String _q = '';

  List<BandCandidate> _found = const [];
  bool _scanning = false;
  String? _heldBack;
  String? _problem;

  /// Remote id of whichever candidate — nearby row or category tile — is
  /// mid-pair, so the rest of the screen can stop accepting taps rather
  /// than starting a second pairing attempt underneath the first.
  String? _busy;

  static List<BandEntry> get _notifyEntries =>
      kBandRegistry.where((e) => !e.isFramed).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _q = _query.text));
    unawaited(_start());
  }

  @override
  void dispose() {
    _query.dispose();
    // Ends THIS screen's scan early if it is the one running — see
    // `PairSensorScreen.dispose` for why this is never a bare
    // `FlutterBluePlus.stopScan()`, and `HrsLink._scanOwner` for why the
    // token has to be this `State` rather than a flag. Unawaited here, and
    // only here: `dispose` cannot await one, and nothing follows it onto the
    // radio — unlike `_pickNearby`, where a connect does.
    unawaited(HrsLink.stopScanIfRunning(this));
    super.dispose();
  }

  Future<void> _start() async {
    final held = await HrsLink.scanHeldBackReason();
    if (!mounted) return;
    if (held != null) {
      setState(() => _heldBack = held);
      return;
    }
    await _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _problem = null;
      _heldBack = null;
      _found = const [];
    });
    try {
      await HrsLink.scanForAny(
        _notifyEntries,
        owner: this,
        onResults: (c) {
          if (mounted) setState(() => _found = c);
        },
      );
    } catch (e) {
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

  /// Pair a candidate found by the live "Nearby" scan directly — one tap,
  /// no intermediate screen, because the scan already told us which
  /// registry entry it is.
  Future<void> _pickNearby(BandCandidate cand) async {
    final sensor =
        kPairableSensors.where((s) => s.entry.id == cand.entryId).firstOrNull;
    if (sensor == null) return; // Framed entries never reach this list.
    setState(() {
      _busy = cand.device.remoteId.str;
      _problem = null;
    });
    // OUR OWN SCAN, ENDED FIRST. It runs for a 15 s window and the user has
    // tapped a row several seconds into it, so without this the radio keeps
    // scanning through the connect — and every `onResults` batch reorders the
    // list under the finger that is already committed to one row. `PairSensor`
    // does not do this because it has one entry and a shorter list; here the
    // reorder is visible.
    //
    // AWAITED, so the connect below starts on a radio that has really stopped
    // scanning rather than one still tearing the scan down. Read before the
    // await, because `context` after one is the lint's whole point.
    final l = AppLocalizations.of(context);
    await HrsLink.stopScanIfRunning(this);
    String? failure;
    try {
      failure = sensor.pick != null
          ? await sensor.pick!(cand.device)
          : await HrsLink.pairNotifySensor(sensor.entry, cand.device,
              label: cand.label);
    } catch (e) {
      failure = l?.pairSensorCouldNotPair(e.toString()) ?? 'Could not pair that device: $e';
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _problem = failure;
      if (failure == null) _found = const [];
    });
    if (failure == null) await _afterPair();
  }

  /// A category or brand row, tapped deliberately rather than found live.
  Future<void> _openEntry(BandEntry entry) async {
    if (entry.isFramed) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const PairingScreen(),
      ));
      if (mounted) await _afterPair();
      return;
    }
    // `.where(...).firstOrNull`, never `firstWhere`: the category list comes
    // from `kBandRegistry` and the pairing steps from `kPairableSensors`, two
    // lists that a new notify-class entry can leave out of step for one
    // commit. A throw here is an unhandled exception mid-tap; a sentence is a
    // screen the user can back out of.
    final sensor =
        kPairableSensors.where((s) => s.entry.id == entry.id).firstOrNull;
    if (sensor == null) {
      setState(() => _problem = AppLocalizations.of(context)
              ?.devicePickerCannotPairFromHere ??
          'That device cannot be paired from this screen.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PairSensorScreen(entry: sensor.entry, onPicked: sensor.pick),
    ));
    if (mounted) await _afterPair();
  }

  Future<void> _afterPair() async {
    // Neither sub-flow tells AppState a `device` row changed underneath it.
    if (mounted) await context.read<AppState>().refreshSensors();
    // A framed pair changes `AppState.isPaired`, which nothing here watches
    // directly — the screen that pushed us (the onboarding gate, or
    // `RePair`'s own post-frame pop) reacts to that on its own.
  }

  bool _matches(String label, String sub) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return label.toLowerCase().contains(q) || sub.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final entries = [
      if (widget.includeBand) kWhoopGen4,
      ..._notifyEntries,
    ];
    return DevicePickerView(
      query: _query,
      title: l?.devicePickerTitle ?? 'Connect your devices',
      subtitle:
          l?.devicePickerSubtitle ?? 'Bring whatever you use. You can add more anytime.',
      found: _found,
      scanning: _scanning,
      heldBack: _heldBack,
      problem: _problem,
      busyRemoteId: _busy,
      categories: [
        for (final e in entries)
          if (_matches(e.label, _categoryBlurb(c, e)))
            (
              entry: e,
              blurb: _categoryBlurb(c, e),
              icon: _categoryIcon(e),
            ),
      ],
      onScan: _scan,
      onPickNearby: _pickNearby,
      onOpenEntry: _openEntry,
      onSkip: widget.onSkip,
    );
  }

  /// Takes a [BuildContext] for the same reason [signalDisplayName] does:
  /// this is user-facing prose on a first-run screen, and the rest of the
  /// file already reads it from [AppLocalizations].
  static String _categoryBlurb(BuildContext c, BandEntry e) {
    final l = AppLocalizations.of(c);
    return switch (e.id) {
      'gen4' || 'gen5' => l?.devicePickerBlurbBand ??
          'The strap this app is built around. WHOOP 4 or 5.',
      'oura' => l?.devicePickerBlurbRing ??
          'Reads the ring directly — no Oura account or subscription.',
      'polar_pmd' => l?.devicePickerBlurbPolarPmd ??
          'A Polar Verity Sense or OH1. Beat timing measured optically, '
              'streamed during a workout, same as a chest strap.',
      _ => l?.devicePickerBlurbSensor ??
          'A chest strap or armband, for beat timing during a workout.',
    };
  }

  static IconData _categoryIcon(BandEntry e) =>
      e.isFramed ? LucideIcons.watch : sensorIcon(e.id);
}

/// The pure half — every state this screen can be in, from values, so a
/// test can render each one without a radio.
class DevicePickerView extends StatelessWidget {
  final TextEditingController query;
  final String title, subtitle;

  final List<BandCandidate> found;
  final bool scanning;
  final String? heldBack;
  final String? problem;
  final String? busyRemoteId;

  final List<({BandEntry entry, String blurb, IconData icon})> categories;

  final VoidCallback? onScan;
  final void Function(BandCandidate)? onPickNearby;
  final void Function(BandEntry)? onOpenEntry;
  final VoidCallback? onSkip;

  const DevicePickerView({
    super.key,
    required this.query,
    required this.title,
    required this.subtitle,
    this.found = const [],
    this.scanning = false,
    this.heldBack,
    this.problem,
    this.busyRemoteId,
    this.categories = const [],
    this.onScan,
    this.onPickNearby,
    this.onOpenEntry,
    this.onSkip,
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
            child: NavBar(title),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Text(subtitle, style: F.body.copyWith(color: p.ink3)),
                const SizedBox(height: S.x4),
                _SearchField(controller: query),
                const SizedBox(height: S.x5),
                if (heldBack != null)
                  StatusCard(
                    l?.pairSensorSearchWouldHideSheet ??
                        'Searching would hide the system pairing sheet',
                    heldBack!,
                    fix: l?.pairSensorSearchAnyway ?? 'Search anyway',
                    icon: LucideIcons.triangleAlert,
                    onFix: busy ? null : onScan,
                  )
                else
                  _NearbySection(
                    found: found,
                    scanning: scanning,
                    busyRemoteId: busyRemoteId,
                    onTap: onPickNearby,
                  ),
                if (problem != null) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.pairSensorThatDidNotWork ?? 'That did not work',
                    problem!,
                    icon: LucideIcons.circleAlert,
                  ),
                ],
                if (categories.isNotEmpty)
                  Section(
                    l?.devicePickerBrowseByCategory ?? 'Browse by category',
                    Surface(
                      pad: const EdgeInsets.symmetric(horizontal: S.x4),
                      child: Column(children: [
                        for (var i = 0; i < categories.length; i++) ...[
                          SetRow(
                            categories[i].icon,
                            C.blue,
                            categories[i].entry.label,
                            sub: categories[i].blurb,
                            onTap: busy
                                ? null
                                : () => onOpenEntry?.call(categories[i].entry),
                          ),
                          if (i < categories.length - 1)
                            Divider(color: p.line, height: 1),
                        ],
                      ]),
                    ),
                  ),
                const SizedBox(height: S.x5),
                Surface(
                  color: p.card2,
                  child: Row(children: [
                    Icon(LucideIcons.shieldCheck, size: 18, color: p.on(C.blue)),
                    const SizedBox(width: S.x3),
                    Expanded(
                      child: Text(
                        l?.devicePickerPrivacyNote ??
                            'Everything stays on this phone. Nothing is sent '
                                'anywhere unless you choose to export it.',
                        style: F.cap.copyWith(color: p.ink3, height: 1.4),
                      ),
                    ),
                  ]),
                ),
                if (onSkip != null) ...[
                  const SizedBox(height: S.x5),
                  BigButton(l?.pairingSkipForNow ?? 'Skip for now',
                      color: C.blue, soft: true, onTap: onSkip),
                  const SizedBox(height: S.x2),
                  Text(
                    l?.pairingSkipNote ??
                        'The app opens without a band. Nothing is measured until '
                            'one is paired.',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  const _SearchField({required this.controller});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Container(
      constraints: const BoxConstraints(minHeight: S.tap),
      padding: const EdgeInsets.symmetric(horizontal: S.x4),
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Row(children: [
        Icon(LucideIcons.search, size: 17, color: p.ink3),
        const SizedBox(width: S.x2),
        Expanded(
          child: Semantics(
            label: l?.devicePickerSearchLabel ?? 'Search devices or types',
            textField: true,
            child: TextField(
              controller: controller,
              style: F.body.copyWith(color: p.ink),
              cursorColor: p.on(C.blue),
              decoration: InputDecoration.collapsed(
                hintText: l?.devicePickerSearchHint ?? 'Search devices or types',
                hintStyle: F.body.copyWith(color: p.ink3),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _NearbySection extends StatelessWidget {
  final List<BandCandidate> found;
  final bool scanning;
  final String? busyRemoteId;
  final void Function(BandCandidate)? onTap;

  const _NearbySection({
    required this.found,
    required this.scanning,
    this.busyRemoteId,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final busy = busyRemoteId != null;
    if (found.isEmpty && !scanning) {
      return StatusCard(
        l?.devicePickerNothingNearbyTitle ?? 'Nothing found yet',
        l?.devicePickerNothingNearbyBody ??
            'A device answers only while it is awake, worn, and not already '
                'connected to another phone or app.',
        icon: LucideIcons.searchX,
      );
    }
    return Section(
      l?.devicePickerNearby ?? 'Nearby',
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          if (scanning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(children: [
                Icon(LucideIcons.bluetoothSearching, size: 18, color: p.on(C.blue)),
                const SizedBox(width: S.x3),
                Expanded(
                  child: Text(
                    l?.devicePickerScanning ?? 'Scanning for devices nearby…',
                    style: F.body.copyWith(color: p.ink),
                  ),
                ),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ]),
            ),
          for (var i = 0; i < found.length; i++) ...[
            if (scanning || i > 0) Divider(color: p.line, height: 1),
            _candidateRow(c, found[i], busy),
          ],
        ]),
      ),
    );
  }

  Widget _candidateRow(BuildContext c, BandCandidate cand, bool busy) {
    final l = AppLocalizations.of(c);
    final id = cand.device.remoteId.str;
    final tail = id.length <= 5 ? id : id.substring(id.length - 5);
    return SetRow(
      sensorIcon(cand.entryId),
      C.green,
      cand.label ?? cand.entryId,
      sub: busyRemoteId == id
          ? (l?.pairSensorPairing ?? 'Pairing…')
          : cand.label == null
              ? '…$tail · ${cand.rssi} dBm'
              : '${cand.rssi} dBm',
      chevron: !busy,
      onTap: busy || onTap == null ? null : () => onTap!(cand),
    );
  }
}
