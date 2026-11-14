// What happens when the user taps a device found by the "Add a device" scan.
// One scan covers sensors and bands; which it is gets decided here, after the
// scan, and the user confirms before anything is saved. The pairing operation
// and the main-band flow are injected, so this runs without a radio.
import 'package:flutter/widgets.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/band_identity.dart';
import '../../ble/hrs_link.dart' show BandCandidate;
import '../../l10n/app_localizations.dart';
import 'pair_sheets.dart';
import 'pair_text.dart' show pairL10n;

/// Closing a route alone never proves that an authenticated wearable paired.
enum BandFlowResult { closed, pairedWearable }

enum AddDeviceOutcome {
  /// The user backed out; nothing was saved.
  cancelled,

  /// Saved as a secondary sensor ("You paired a secondary sensor.").
  pairedSecondary,

  /// Saved, and not a secondary sensor (a scale, a thermometer).
  pairedOther,

  /// Handed to the main-band flow; nothing was saved here.
  openedBandFlow,

  /// Pairing failed; [AddDeviceResult.message] says why.
  failed,

  /// The main-band flow cannot open right now (iOS, no provisioned band, so
  /// the system pairing sheet would fail until a restart);
  /// [AddDeviceResult.message] is the restart guidance. Nothing was saved.
  bandFlowHeldBack,
}

typedef AddDeviceResult = ({AddDeviceOutcome outcome, String? message});

AddDeviceResult _r(AddDeviceOutcome o, [String? message]) =>
    (outcome: o, message: message);

/// Entries that cannot be paired from a list tap: their pairing installs a key
/// on their own screen (the Oura ring asks for it, a Mi Band gets one), so
/// every choice for them ends in the band flow. A plain save would leave a row
/// sync cannot use. ui2_pair_sheets_test checks every keyed sensor is here.
const Set<String> _ownScreen = {'oura', 'miband234'};

/// What the "Add a device" scan listens for: every registry entry, the framed
/// WHOOP bands included, so a WHOOP that advertises only its own band service
/// still turns up and goes to the band-choice flow.
List<BandEntry> addDeviceScanEntries() => List.unmodifiable(kBandRegistry);

/// What the flow needs from the screen and the radio.
abstract interface class AddDeviceIo {
  /// Whether a main band is paired right now (read at tap time).
  bool get hasMainBand;

  /// The primary peripheral must never also acquire a secondary connection.
  String? get mainBandRemoteId;

  /// The paired band's name, shown when choosing its replacement; null
  /// when it has none (the sheet then says "your band").
  String? get mainBandName;

  /// The pairing operation for [cand] under registry [entry]; the real one is
  /// `HrsLink.pairNotifySensor`, tests pass a fake.
  Future<PairOutcome> pair(
      BandCandidate cand, BandEntry entry, PairConfirmation? confirmation);

  /// Ends this screen's own scan (awaited), so the next screen starts on a
  /// radio that is not scanning.
  Future<void> stopScan();

  /// Why the main-band flow cannot open right now, as restart guidance
  /// (`HrsLink.scanHeldBackReason`); null when it can.
  Future<String?> mainBandBlockedReason();

  /// Opens the main-band pairing for [band], bound to the tapped device
  /// [remoteId], or selected by the system picker when null. [modelKnown]
  /// false forbids assuming [band]'s generation. Authenticated wearable screens
  /// return [BandFlowResult.pairedWearable] only after a successful pair.
  Future<BandFlowResult> openBandFlow(BandEntry band,
      {required String? remoteId, bool modelKnown = true, bool replacing = false});
}

class AddDeviceFlow {
  final AddDeviceIo io;
  AddDeviceFlow(this.io);

  bool _running = false;

  /// A tap's flow is under way (a sheet, a confirm, an unpair, a pairing).
  /// [onTap] refuses a second one until it ends.
  bool get running => _running;

  static BandEntry? _entry(String id) =>
      kBandRegistry.where((e) => e.id == id).firstOrNull;

  /// Capture [c]'s navigator and localizations before the first await; the
  /// sheets use it again after each one, so the caller must keep it mounted.
  Future<AddDeviceResult> onTap(BuildContext c, BandCandidate cand) async {
    if (_running) return _r(AddDeviceOutcome.cancelled);
    _running = true;
    final l = AppLocalizations.of(c);
    try {
      return await _onTap(c, cand);
    } catch (e) {
      return _r(AddDeviceOutcome.failed,
          l?.pairSensorCouldNotPair(e.toString()) ?? 'Could not pair that device: $e');
    } finally {
      _running = false;
    }
  }

  /// An unapproved iOS replacement cannot appear in a CoreBluetooth scan.
  /// The platform picker (or Android's band scan) selects it after confirmation.
  Future<AddDeviceResult> replaceMainBand(BuildContext c) async {
    if (_running || !io.hasMainBand) return _r(AddDeviceOutcome.cancelled);
    _running = true;
    final l = AppLocalizations.of(c);
    try {
      return await _replace(c, kWhoopGen4, null, modelKnown: false);
    } catch (e) {
      return _r(AddDeviceOutcome.failed,
          l?.pairSensorCouldNotPair(e.toString()) ?? 'Could not pair that device: $e');
    } finally {
      _running = false;
    }
  }

  Future<AddDeviceResult> _onTap(BuildContext c, BandCandidate cand) async {
    final refusal = _primaryRefusal(c, cand);
    if (refusal != null) return refusal;
    final entry = _entry(cand.entryId);
    if (entry == null) return _r(AddDeviceOutcome.cancelled);
    // A band in its own right, or a sensor-looking device that is also a band.
    final band = entry.role == DeviceRole.band ? entry : cand.alsoBand?.entry;
    if (band != null) {
      // A WHOOP heard by name only: the name cannot tell WHOOP 4 from 5.
      final modelKnown = cand.alsoBand?.modelCertain != false;
      final choice = await showBandFoundSheet(c,
          band: band,
          hasMainBand: io.hasMainBand,
          mainBandName: io.mainBandName,
          modelKnown: modelKnown,
          deviceName: cand.label);
      if (choice == null) return _r(AddDeviceOutcome.cancelled);
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      if (choice == BandSheetChoice.replaceBand) {
        return _replace(c, band, cand, modelKnown: modelKnown);
      }
      // The band's own entry decides: a ring heard as a heart-rate strap
      // still pairs only on its own (authenticated) screen.
      if (choice == BandSheetChoice.asBand || _ownScreen.contains(band.id)) {
        return _handoff(band, cand, modelKnown: modelKnown);
      }
      // A WHOOP kept as a secondary sensor is paired as a heart-rate sensor;
      // a ring or a watch pairs under its own entry.
      final pairAs = band.canBeMainDevice ? kBleHrs : band;
      return _pair(c, cand, pairAs,
          confirmation: PairConfirmation(
              remoteId: cand.device.remoteId.str, bandEntryId: band.id));
    }
    if (!await confirmBrowse(c, entry, deviceName: cand.label) ||
        !c.mounted) {
      return _r(AddDeviceOutcome.cancelled);
    }
    return _pair(c, cand, entry);
  }

  /// The confirmation owed before pairing [entry]: a workout sensor and no
  /// band shows the strap sheet (everything every day is a cross) before it
  /// is saved as all there is. False when the user went back. A device paired
  /// as its own entry (Colmi as Colmi) needs none.
  Future<bool> confirmBrowse(BuildContext c, BandEntry entry,
      {String? deviceName}) async {
    if (!_isSecondarySensor(entry) || io.hasMainBand) return true;
    return showStrapSheet(c, sensor: entry, deviceName: deviceName);
  }

  /// Confirm replacement, then verify the new band while the current one
  /// remains paired. The pairing owner commits the switch only after READY.
  Future<AddDeviceResult> _replace(
      BuildContext c, BandEntry band, BandCandidate? cand,
      {bool modelKnown = true}) async {
    if (!await showReplaceBandConfirm(c, mainBandName: io.mainBandName)) {
      return _r(AddDeviceOutcome.cancelled);
    }
    if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
    return _handoff(band, cand, modelKnown: modelKnown, replacing: true);
  }

  /// Hands over to the main-band flow: the scan ends first, and where the
  /// system pairing sheet cannot open the user gets restart guidance instead.
  Future<AddDeviceResult> _handoff(BandEntry band, BandCandidate? cand,
      {bool modelKnown = true, bool replacing = false}) async {
    await io.stopScan();
    if (band.isFramed) {
      final held = await io.mainBandBlockedReason();
      if (held != null) return _r(AddDeviceOutcome.bandFlowHeldBack, held);
    }
    final result = await io.openBandFlow(band,
        remoteId: cand?.device.remoteId.str, modelKnown: modelKnown, replacing: replacing);
    if (!band.isFramed) {
      return _r(result == BandFlowResult.pairedWearable
          ? AddDeviceOutcome.pairedOther : AddDeviceOutcome.cancelled);
    }
    return _r(AddDeviceOutcome.openedBandFlow);
  }

  static bool _isSecondarySensor(BandEntry e) =>
      e.role == DeviceRole.sensor && e.category == DeviceCategory.workoutSensor;

  AddDeviceResult? _primaryRefusal(BuildContext c, BandCandidate cand) =>
      cand.device.remoteId.str == io.mainBandRemoteId
          ? _r(AddDeviceOutcome.failed, pairL10n(c).pairPrimaryCannotBeSensor)
          : null;

  Future<AddDeviceResult> _pair(BuildContext c, BandCandidate cand,
      BandEntry entry,
      {PairConfirmation? confirmation}) async {
    final refusal = _primaryRefusal(c, cand);
    if (refusal != null) return refusal;
    final outcome = await io.pair(cand, entry, confirmation);
    // afterConnect checks `c.mounted` before it touches the context.
    // ignore: use_build_context_synchronously
    return afterConnect(c, cand, entry, outcome, confirmation: confirmation);
  }

  /// What happens after a connect that returned [outcome] for [cand] under
  /// [entry]: a band found asks again (nothing was saved) and re-runs only on
  /// an explicit yes. Shared by the nearby list and the category screen.
  Future<AddDeviceResult> afterConnect(
      BuildContext c, BandCandidate cand, BandEntry entry, PairOutcome outcome,
      {PairConfirmation? confirmation}) async {
    final found = outcome.isBand;
    if (found != null) {
      // The connect showed it is a band. Nothing was saved; ask again with
      // that in hand, and re-run only on an explicit yes.
      // A WHOOP named only by its name keeps the name's uncertain model.
      final modelKnown = outcome.modelCertain;
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      final choice = await showBandFoundSheet(c,
          band: found,
          hasMainBand: io.hasMainBand,
          mainBandName: io.mainBandName,
          afterConnect: true,
          modelKnown: modelKnown,
          deviceName: cand.label);
      if (choice == null) return _r(AddDeviceOutcome.cancelled);
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      if (choice == BandSheetChoice.replaceBand) {
        return _replace(c, found, cand, modelKnown: modelKnown);
      }
      if (choice == BandSheetChoice.asBand || _ownScreen.contains(found.id)) {
        return _handoff(found, cand, modelKnown: modelKnown);
      }
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      // A ring or a watch pairs under its own entry, never as a plain sensor.
      return _pair(c, cand, found.canBeMainDevice ? kBleHrs : found,
          confirmation: PairConfirmation(
              remoteId: cand.device.remoteId.str, bandEntryId: found.id));
    }
    final error = outcome.error;
    if (error != null) return _r(AddDeviceOutcome.failed, error);
    return _r(_isSecondarySensor(entry)
        ? AddDeviceOutcome.pairedSecondary
        : AddDeviceOutcome.pairedOther);
  }
}
