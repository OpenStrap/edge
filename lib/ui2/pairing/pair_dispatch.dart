// One place decides HOW a chosen device is paired, so the two screens that can
// pair it (the device picker and a sensor's own screen) cannot drift. A ring
// has its own pairing (`pick`: the key exchange that proves the ring before a
// row is written); everything else is the plain notify-class pairing. A plain
// connect that finds a ring retries through the screen the user is on with the
// RING's entry, and that retry must reach the ring's own pairing too, or it
// saves a ring row without the key `pick` would have written.
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;

import '../../ble/adapters/_registry.dart' show BandEntry;
import '../../ble/band_identity.dart' show BandIdentity, PairConfirmation, PairOutcome;
import '../../ble/hrs_link.dart' show HrsLink;
import '../profile/devices.dart' show kPairableSensors;

typedef PlainPair = Future<PairOutcome> Function(
  BandEntry entry,
  BluetoothDevice device, {
  String? label,
  BandIdentity? earlierBand,
  PairConfirmation? confirmation,
});

/// The entry's own registered pairing (a ring's key exchange), or null.
Future<String?> Function(BluetoothDevice)? registeredPickFor(BandEntry entry) =>
    kPairableSensors.where((s) => s.entry.id == entry.id).firstOrNull?.pick;

Future<PairOutcome> _plainPair(
  BandEntry entry,
  BluetoothDevice device, {
  String? label,
  BandIdentity? earlierBand,
  PairConfirmation? confirmation,
}) =>
    HrsLink.pairNotifySensor(entry, device,
        label: label, earlierBand: earlierBand, confirmation: confirmation);

/// Pairs [device] as [entry]: through the entry's registered `pick` when it has
/// one, otherwise the plain pairing. [pickFor] and [plain] are test seams.
Future<PairOutcome> pairRegisteredEntry(
  BandEntry entry,
  BluetoothDevice device, {
  String? label,
  BandIdentity? earlierBand,
  PairConfirmation? confirmation,
  Future<String?> Function(BluetoothDevice)? Function(BandEntry entry)? pickFor,
  PlainPair plain = _plainPair,
}) async {
  final pick = pickFor != null ? pickFor(entry) : registeredPickFor(entry);
  if (pick != null) {
    final failure = await pick(device);
    return failure == null
        ? const PairOutcome.saved()
        : PairOutcome.failed(failure);
  }
  return plain(entry, device,
      label: label, earlierBand: earlierBand, confirmation: confirmation);
}
