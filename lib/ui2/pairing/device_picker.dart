import '../../l10n/display_text.dart';
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
// is exactly [kBandRegistry] — real entries, not aspirational ones —
// because a category tile for a scale or a blood-pressure cuff this
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
import '../../ble/band_identity.dart' show PairConfirmation, PairOutcome;
import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ble/ble_state.dart'
    show
        BleUnavailableException,
        bandStatusFor,
        classifyBleBlocker,
        kMaxConcurrentSecondaryLinks;
import '../../ble/hrs_link.dart';
import '../../ble/oura_link.dart' show pairOuraRingWithTypedKey;
import '../../data/db.dart' show LocalDb;
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../onboarding/pairing.dart' show PairingScreen;
import '../ui2.dart';
import 'add_device_flow.dart';
import 'pair_band_view.dart';
import 'category_filter_pills.dart';
import 'pair_dispatch.dart';
import 'pair_text.dart'
    show PairFilter, pairFilterOf, pairL10n, slotPill;
import 'whoop_firmware_warning.dart';
import '../../ble/slot_comparison.dart' show slotComparisonFor;
import '../profile/devices.dart'
    show
        kPairableSensors,
        refuseIfSensorCapReached,
        sensorCapReached,
        sensorIcon;
import '../profile/pair_sensor.dart' show PairSensorScreen;
import '../profile/profile.dart' show SetRow;

/// Refreshes the sensor list once a pairing has been SAVED. The pairing is
/// already durable here, so a failing refresh must not surface as "could not
/// pair" (the caller's catch would say exactly that). The list reloads on its
/// next load. Returns whether the refresh worked.
@visibleForTesting
Future<bool> refreshAfterPair(Future<void> Function() refresh) async {
  try {
    await refresh();
    return true;
  } catch (e) {
    debugPrint('[pair] sensor list refresh failed after a saved pairing: $e');
    return false;
  }
}

class DevicePickerScreen extends StatefulWidget {
  /// Walk past pairing entirely. Non-null only at true first-run onboarding
  /// — a re-pair or add-a-sensor push always has a screen underneath to pop
  /// back to, so it needs no separate way out.
  final VoidCallback? onSkip;

  /// Where the back chevron goes when there is no route underneath to pop.
  /// Set only at first-run onboarding, where the picker is the gate's root
  /// page; null keeps the default `Navigator.maybePop`.
  final VoidCallback? onBack;

  /// Whether "Watches & bands" is offered at all. False from "add a
  /// sensor": this phone already has its one primary band, and re-pairing
  /// it is a distinct, destructive-feeling action reached from `RePair`,
  /// not something to offer beside a chest strap in the same list.
  final bool includeBand;

  @visibleForTesting
  final Future<String?> Function()? debugScanHeldBackReason;

  const DevicePickerScreen(
      {super.key,
      this.onSkip,
      this.onBack,
      this.includeBand = true,
      this.debugScanHeldBackReason});

  @override
  State<DevicePickerScreen> createState() => _DevicePickerScreenState();
}

class _DevicePickerScreenState extends State<DevicePickerScreen>
    implements AddDeviceIo, PairBandHost {
  final _query = TextEditingController();
  String _q = '';

  List<BandCandidate> _found = const [];
  bool _scanning = false;
  String? _heldBack;
  String? _problem;

  /// The filter pill chosen over the results (null = All) and the good-news
  /// line shown after a secondary sensor paired.
  final _kind = ValueNotifier<PairFilter?>(null);
  String? _notice;

  /// Remote id of whichever candidate — nearby row or category tile — is
  /// mid-pair, so the rest of the screen can stop accepting taps rather
  /// than starting a second pairing attempt underneath the first.
  /// The one flow every tap goes through, so a second tap mid-flow is
  /// refused ([AddDeviceFlow.running]).
  late final AddDeviceFlow _flow = AddDeviceFlow(this);

  /// True while [_flow] runs; disables the list (see [DevicePickerView.locked]).
  bool _locked = false;

  String? _busy;

  static List<BandEntry> get _notifyEntries =>
      kBandRegistry.where((e) => !e.isFramed).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _q = _query.text));
    _kind.addListener(() => setState(() {}));
    // The first-run band list does not scan: on iOS a scan creates the central
    // that keeps the system pairing sheet from opening.
    if (!widget.includeBand) unawaited(_start());
  }

  @override
  void dispose() {
    _query.dispose();
    _kind.dispose();
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
    if (_locked || _scanning) return;
    final held = await (widget.debugScanHeldBackReason?.call() ??
        HrsLink.scanHeldBackReason());
    if (!mounted || _locked || _scanning) return;
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
        addDeviceScanEntries(),
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

  /// A device found by the live scan was tapped. [AddDeviceFlow] decides what
  /// it is (a band or a sensor), asks the user where that matters, and calls
  /// back here to do the pairing.
  Future<void> _pickNearby(BandCandidate cand) => _runTap(cand);

  Future<void> _replaceBand() => _runTap(null);

  Future<void> _runTap(BandCandidate? cand) async {
    // One flow at a time: a second tap while a sheet, a confirm or the
    // unpair of the old band is still running starts nothing.
    if (_locked || _flow.running) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _problem = null;
      _notice = null;
      _locked = true;
    });
    final AddDeviceResult result;
    try {
      result = cand == null
          ? await _flow.replaceMainBand(context)
          : await _flow.onTap(context, cand);
    } finally {
      if (mounted) setState(() => _locked = false);
    }
    if (!mounted) return;
    switch (result.outcome) {
      case AddDeviceOutcome.pairedSecondary:
      case AddDeviceOutcome.pairedOther:
        setState(() {
          _found = const [];
          if (result.outcome == AddDeviceOutcome.pairedSecondary) {
            _notice = l?.pairSecondaryPaired ?? 'You paired a secondary sensor.';
          }
        });
        await _afterPair();
      case AddDeviceOutcome.failed:
        setState(() => _problem = result.message);
      case AddDeviceOutcome.bandFlowHeldBack:
        // The same restart guidance a held-back scan shows.
        setState(() => _heldBack = result.message);
      case AddDeviceOutcome.cancelled:
      case AddDeviceOutcome.openedBandFlow:
        break;
    }
  }

  @override
  bool get hasMainBand => context.read<AppState>().isPaired;

  @override
  String? get mainBandRemoteId => context.read<AppState>().paired?.remoteId;

  @override
  String? get mainBandName => context.read<AppState>().strapName;

  @override
  Future<BandFlowResult> openBandFlow(BandEntry band,
          {required String? remoteId, bool modelKnown = true, bool replacing = false}) =>
      _openEntry(band, remoteId: remoteId, modelKnown: modelKnown, replacing: replacing, returnOnPair: true);

  @override
  Future<void> stopScan() => HrsLink.stopScanIfRunning(this);

  @override
  Future<String?> mainBandBlockedReason() => HrsLink.scanHeldBackReason();

  /// A category tile, tapped deliberately: the same confirmation a nearby row
  /// gets (a workout sensor and no band asks first), then the entry's own
  /// screen, whose connect-time band refusals go through the same flow.
  Future<void> _browseEntry(BandEntry entry,
      {bool modelKnown = false, bool confirmed = false}) async {
    if (_locked || _flow.running) return;
    setState(() => _locked = true);
    final l = AppLocalizations.of(context);
    try {
      if (!confirmed && !await _flow.confirmBrowse(context, entry)) return;
      if (!mounted) return;
      await _openEntry(entry, modelKnown: modelKnown);
    } catch (e) {
      if (mounted) {
        setState(() => _problem = l?.pairSensorCouldNotPair(e.toString()) ??
            'Could not pair that device: $e');
      }
    } finally {
      if (mounted) setState(() => _locked = false);
    }
  }

  @override
  void pickBand(BandEntry entry) => unawaited(_browseEntry(entry, modelKnown: true));

  @override
  void strapOnlyConfirmed() => unawaited(_browseEntry(kBleHrs, confirmed: true));

  /// The pairing operation itself, for [AddDeviceFlow].
  @override
  Future<PairOutcome> pair(
      BandCandidate cand, BandEntry entry, PairConfirmation? confirmation) async {
    final sensor =
        kPairableSensors.where((s) => s.entry.id == entry.id).firstOrNull;
    final l = AppLocalizations.of(context);
    if (sensor == null) {
      return PairOutcome.failed(l?.devicePickerCannotPairFromHere ??
          'That device cannot be paired from this screen.');
    }
    // Re-checked on every pair: this screen stays open after one for the
    // next, so `addSensor`'s check at the door does not bound a visit.
    // The minted id is the row only `pairNotifySensor` writes; a `pick`
    // callback mints its own, so it is checked by adapter alone. The reason
    // shows as this pair's failure, like any other.
    if (sensorCapReached(await LocalDb.deviceRows(),
        repairingId: sensor.pick == null
            ? HrsLink.mintDeviceId(sensor.entry, cand.device.remoteId.str)
            : null,
        adapterId: sensor.entry.id)) {
      return PairOutcome.failed(
          l?.devicesSensorLimit(kMaxConcurrentSecondaryLinks) ??
              'This phone will pair at most $kMaxConcurrentSecondaryLinks '
                  'sensors alongside your band. Remove one to add another.');
    }
    if (!mounted) return const PairOutcome.failed('');
    setState(() => _busy = cand.device.remoteId.str);
    // OUR OWN SCAN, ENDED FIRST. It runs for a 15 s window and the user has
    // tapped a row several seconds into it, so without this the radio keeps
    // scanning through the connect — and every `onResults` batch reorders the
    // list under the finger that is already committed to one row. AWAITED, so
    // the connect below starts on a radio that has really stopped scanning.
    await HrsLink.stopScanIfRunning(this);
    PairOutcome outcome;
    try {
      outcome = await pairRegisteredEntry(sensor.entry, cand.device,
          label: cand.label,
          earlierBand: cand.alsoBand,
          confirmation: confirmation);
    } catch (e) {
      outcome = PairOutcome.failed(
          l?.pairSensorCouldNotPair(e.toString()) ?? 'Could not pair that device: $e');
    }
    if (mounted) setState(() => _busy = null);
    return outcome;
  }

  /// A category or brand row, tapped deliberately rather than found live; or
  /// a scanned band handed over by [AddDeviceFlow] ([remoteId], [modelKnown]
  /// as [AddDeviceIo.openBandFlow]).
  Future<BandFlowResult> _openEntry(BandEntry entry,
      {String? remoteId, bool modelKnown = true, bool replacing = false, bool returnOnPair = false}) async {
    // A handoff from AddDeviceFlow awaits the scan shutdown first; the user may
    // have left meanwhile, and neither branch below may touch a disposed context.
    if (!mounted) return BandFlowResult.closed;
    if (entry.isFramed) {
      // The pushed screen covers this one without disposing it, so this
      // screen's 15 s scan would keep the scan lock — and "Find my band"
      // would sit queued behind the rest of it, spinner already running,
      // before its own scan even starts. Nothing here can show its results.
      await HrsLink.stopScanIfRunning(this);
      if (!mounted) return BandFlowResult.closed;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PairingScreen(
            entry: entry, modelKnown: modelKnown, remoteId: remoteId, replacing: replacing),
      ));
      if (mounted) await _afterPair();
      return BandFlowResult.closed;
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
      return BandFlowResult.closed;
    }
    // Re-checked on every tap: this screen stays open after a pair, and the
    // onboarding and re-pair routes reach it without `addSensor`'s check.
    // Soft — a sensor that already has a row still opens its own screen, for
    // its forget / re-pair section. That screen checks each pair exactly.
    if (await refuseIfSensorCapReached(context,
            adapterId: sensor.entry.id, anyOfAdapter: true) ||
        !mounted) {
      return BandFlowResult.closed;
    }
    // Same as the framed branch: the sensor's own scan queues behind ours.
    await HrsLink.stopScanIfRunning(this);
    if (!mounted) return BandFlowResult.closed;
    final result = await Navigator.of(context).push(MaterialPageRoute<BandFlowResult>(
      builder: (_) => PairSensorScreen(
        entry: sensor.entry,
        returnOnPair: returnOnPair,
        onPicked: sensor.pick,
        // The ring alone can be paired with the key its own app installed —
        // see `pairOuraRingWithKey`.
        onPickedWithKey:
            sensor.entry.id == kOura.id ? pairOuraRingWithTypedKey : null,
        ),
      ),
    );
    if (mounted) await _afterPair();
    return result ?? BandFlowResult.closed;
  }

  Future<void> _afterPair() async {
    // Neither sub-flow tells AppState a `device` row changed underneath it.
    if (mounted) await refreshAfterPair(context.read<AppState>().refreshSensors);
    // A framed pair changes `AppState.isPaired`, which nothing here watches
    // directly — the pushed `PairingScreen` closes itself on success, and the
    // gate (or `RePair`) reacts to the flag underneath.
  }

  bool _matches(String label, String sub) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return label.toLowerCase().contains(q) || sub.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    if (widget.includeBand) {
      return PairBandView(
        entries: firstRunBandEntries(), host: this, onSkip: widget.onSkip,
        onBack: widget.onBack, problem: _problem,
      );
    }
    final entries = _notifyEntries;
    return DevicePickerView(
      query: _query,
      title: l?.pairAddDevice ?? 'Add a device',
      subtitle: l?.pairAddDeviceSubtitle ??
          'Scan once. After the scan we tell you whether a device is a band or a sensor.',
      found: _found,
      showWhoopWarning: widget.includeBand,
      scanning: _scanning,
      heldBack: _heldBack,
      problem: _problem,
      busyRemoteId: _busy,
      locked: _locked,
      categories: [
        for (final e in entries)
          if ((_matches(
                uiText(c, e.label),
                uiText(c, deviceCategoryBlurb(l, e)),
              ) ||
              _matches(e.label, deviceCategoryBlurb(null, e)) ||
              // The one framed row stands for every WHOOP this app pairs, but
              // its label is gen4's, so "whoop 5" or "mg" matched nothing and
              // the only way to pair the band vanished from the list.
              (e.isFramed &&
                  _matches('${kWhoopGen5.label} WHOOP MG', 'WHOOP5 WHOOPMG'))))
            (
              entry: e,
              blurb: deviceCategoryBlurb(l, e),
              icon: _categoryIcon(e),
            ),
      ],
      onScan: _heldBack == null ? _start : _scan,
      onPickNearby: _pickNearby,
      onReplaceBand: hasMainBand ? _replaceBand : null,
      onOpenEntry: _browseEntry,
      kindSelection: _kind,
      notice: _notice,
      onSkip: widget.onSkip,
      onBack: widget.onBack,
    );
  }

  static IconData _categoryIcon(BandEntry e) =>
      e.isFramed ? LucideIcons.watch : sensorIcon(e.id);
}

/// The pure half — every state this screen can be in, from values, so a
/// test can render each one without a radio.
class DevicePickerView extends StatelessWidget {
  final bool showWhoopWarning;
  final TextEditingController query;
  final String title, subtitle;

  final List<BandCandidate> found;
  final bool scanning;
  final String? heldBack;
  final String? problem;
  final String? busyRemoteId;

  final List<({BandEntry entry, String blurb, IconData icon})> categories;

  final VoidCallback? onScan;
  final VoidCallback? onReplaceBand;
  final void Function(BandCandidate)? onPickNearby;
  final void Function(BandEntry)? onOpenEntry;
  final VoidCallback? onSkip;
  final VoidCallback? onBack;

  /// The filter pills over the results: the chosen kind (null = All) and
  /// its setter. Null [kindSelection] draws no pills. The owner listens and
  /// rebuilds this view when it changes.
  final ValueNotifier<PairFilter?>? kindSelection;

  /// A good-news line shown above the results, e.g. after a sensor paired.
  final String? notice;

  /// A pairing flow is running (a sheet, a confirm, the old band's unpair):
  /// every row and the scan button wait for it.
  final bool locked;

  const DevicePickerView({
    super.key,
    required this.query,
    required this.title,
    required this.subtitle,
    this.showWhoopWarning = true,
    this.found = const [],
    this.scanning = false,
    this.heldBack,
    this.problem,
    this.busyRemoteId,
    this.categories = const [],
    this.onScan,
    this.onReplaceBand,
    this.onPickNearby,
    this.onOpenEntry,
    this.onSkip,
    this.onBack,
    this.kindSelection,
    this.notice,
    this.locked = false,
  });

  static DeviceKind? _kindOf(String entryId) =>
      kBandRegistry.where((e) => e.id == entryId).firstOrNull?.kind;

  /// What a found device physically is: the band it turned out to be when
  /// it passed itself off as a heart-rate sensor, else its own entry's kind.
  static DeviceKind? _foundKind(BandCandidate f) =>
      f.alsoBand?.entry.kind ?? _kindOf(f.entryId);

  static PairFilter? _groupOf(BandCandidate f) {
    final k = _foundKind(f);
    return k == null ? null : pairFilterOf(k);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final busy = busyRemoteId != null || locked;
    // The pills read the whole list; the filter narrows what is drawn.
    final kinds = [
      for (final f in found) ?_foundKind(f),
      for (final e in this.categories) e.entry.kind,
    ];
    // A kind the search has emptied out is no filter: the pills hide when
    // one kind is left, and a hidden selection would hide every row.
    final groups = {for (final k in kinds) ?pairFilterOf(k)};
    final selected = kindSelection?.value;
    final group = groups.length > 1 && groups.contains(selected) ? selected : null;
    final shownFound = group == null
        ? found
        : [for (final f in found) if (_groupOf(f) == group) f];
    // Shadows the field on purpose: the rows below keep their original text.
    final categories = group == null
        ? this.categories
        : [
            for (final e in this.categories)
              if (pairFilterOf(e.entry.kind) == group) e,
          ];
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(title, onBack: onBack),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (showWhoopWarning) ...[
                  const WhoopFirmwareWarning(),
                  const SizedBox(height: S.x4),
                ],
                Text(subtitle, style: F.body.copyWith(color: p.ink3)),
                const SizedBox(height: S.x4),
                if (onReplaceBand != null) ...[
                  BigButton(l?.pairReplaceMyBand ?? 'Replace my band',
                      key: const ValueKey('device-picker-replace-band'),
                      soft: true, onTap: busy ? null : onReplaceBand),
                  const SizedBox(height: S.x4),
                ],
                _SearchField(controller: query),
                if (kindSelection != null && groups.length > 1) ...[
                  const SizedBox(height: S.x3),
                  CategoryFilterPills(
                      kinds: kinds, selection: kindSelection!),
                ],
                const SizedBox(height: S.x5),
                if (notice != null) ...[
                  StatusCard(notice!, '',
                      icon: LucideIcons.circleCheck),
                  const SizedBox(height: S.x4),
                ],
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
                    found: shownFound,
                    scanning: scanning,
                    busyRemoteId: busyRemoteId,
                    onTap: locked ? null : onPickNearby,
                  ),
                if (heldBack == null && onScan != null) ...[
                  const SizedBox(height: S.x3),
                  BigButton(l?.pairSearchDevices ?? 'Search for devices',
                      key: const ValueKey('device-picker-scan'),
                      icon: LucideIcons.search,
                      soft: true,
                      onTap: busy || scanning ? null : onScan),
                ],
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
                        child: Column(
                          children: [
                            for (var i = 0; i < categories.length; i++) ...[
                              SetRow(
                                categories[i].icon,
                                C.blue,
                                uiText(c, categories[i].entry.label),
                                sub: uiText(c, categories[i].blurb),
                            onTap: busy
                                ? null
                                : () => onOpenEntry?.call(categories[i].entry),
                          ),
                          ?_slotChip(c, categories[i].entry),
                          if (i < categories.length - 1)
                            Divider(color: p.line, height: 1),
                            ],
                          ],
                        ),
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
          ],
        ),
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
    final signal = cand.rssi == null
        ? (l?.devicesConnected ?? 'Connected')
        : '${cand.rssi} dBm';
    final idle = cand.label == null ? '…$tail · $signal' : signal;
    // Where it fits, read off the band it turned out to be when it passed
    // itself off as a heart-rate sensor.
    final row = SetRow(
      sensorIcon(cand.entryId),
      C.green,
      cand.label ?? cand.entryId,
      sub: busyRemoteId == id
          // A Mi Band 2/3 may wait up to 30 s for a tap on the band, and this
          // path opens no screen of its own to say so.
          ? (cand.entryId == kMiBand234.id
              ? (l?.pairSensorPairingMiband234 ??
                  'Pairing… If the band buzzes, tap it to confirm.')
              : (l?.pairSensorPairing ?? 'Pairing…'))
          // One tap pairs a Mi Band 2/3, so its unpair-first step shows on
          // the row before that tap, not only on the category list.
          : cand.entryId == kMiBand234.id
              ? '$idle\n${deviceCategoryBlurb(AppLocalizations.of(c), kMiBand234)}'
              : idle,
      chevron: !busy,
      onTap: busy || onTap == null ? null : () => onTap!(cand),
    );
    final entry = cand.alsoBand?.entry ??
        kBandRegistry.where((e) => e.id == cand.entryId).firstOrNull;
    final chip = entry == null ? null : _slotChip(c, entry);
    if (chip == null) return row;
    return Column(children: [row, chip]);
  }
}

/// The "Every day" / "Workouts only" chip under a device row, or null when
/// the device fits neither column.

Widget? _slotChip(BuildContext c, BandEntry e) {
  final slot = slotComparisonFor(e).slot;
  if (slot == null) return null;
  return Align(
    key: ValueKey('row-slot-${e.id}'),
    alignment: AlignmentDirectional.centerStart,
    child: Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: slotPill(pairL10n(c), slot),
    ),
  );
}

/// The one-line description under each device in the picker, localised.
String deviceCategoryBlurb(AppLocalizations? l, BandEntry e) {
  return localizedText(l, switch (e.id) {
      'gen4' || 'gen5' => l?.devicePickerBlurbBand ??
          'The strap this app is built around. WHOOP 4 or 5.',
      'oura' => l?.devicePickerBlurbRing ??
          'Reads the ring directly — no Oura account or subscription.',
      'polar_pmd' => l?.devicePickerBlurbPolarPmd ??
          'A Polar Verity Sense or OH1. Beat timing measured optically, '
              'streamed during a workout, same as a chest strap.',
      'coros' => l?.devicePickerBlurbCoros ??
          'A sports watch. Reads battery and live heart rate — recorded '
              'activities stay on the watch.',
      'ultrahuman' => l?.devicePickerBlurbUltrahuman ??
          'Reads the ring directly — no account, no key exchange.',
      'miband234' => l?.devicePickerBlurbMiband234 ??
          'Mi Band 2 or 3: heart rate, steps and sleep. Unpair it from Mi '
              'Fit or Zepp first, or reset it. Tap the band if it buzzes. Mi '
              'Band 4 isn’t supported.',
      'pebble' => l?.devicePickerBlurbPebble ??
          'Pebble 2 or Pebble 2 SE only. Syncs steps and sleep, and heart '
              'rate on a Pebble 2 (the SE has no heart-rate sensor).',
      'thermometer' => l?.devicePickerBlurbThermometer ??
          'Saves each reading as a body temperature.',
      'miscale_bc' => l?.devicePickerBlurbMiscaleBc ??
          'Saves each settled weight and bio-impedance, including stored ones.',
      'miscale2' => l?.devicePickerBlurbMiscale2 ??
          'Saves each settled weight, including stored ones.',
      'colmi' => l?.devicePickerBlurbColmi ??
          'A Colmi ring. Syncs heart rate, sleep stages, steps, SpO2, HRV '
              "and stress; values the ring computes itself are labelled as "
              "Colmi's. Experimental.",
      _ => l?.devicePickerBlurbSensor ??
          'A chest strap or armband, for beat timing during a workout.',
  });
}

/// Test seam for the category blurbs: each one localised.
@visibleForTesting
String debugCategoryBlurb(BuildContext c, BandEntry e) =>
    deviceCategoryBlurb(AppLocalizations.of(c), e);
