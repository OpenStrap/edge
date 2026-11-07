// Which main-device band (role == band) an advertisement or a GATT list belongs
// to, whatever scan found it, and what the pairing step reports. A WHOOP can
// advertise 0x180D under any name; filing it as a chest strap is the bug this
// guards against. Evidence order: a service beats a service-data UUID beats a
// name. A company id alone is no band evidence: it names the maker, not the
// product.
import 'adapters/_registry.dart';

/// [entry] is the band; [modelCertain] is false when only the NAME matched a
/// WHOOP (the name cannot tell gen4 from gen5), true when a service settled it.
typedef BandIdentity = ({BandEntry entry, bool modelCertain});

const String _sigBase = '-0000-1000-8000-00805f9b34fb';

/// A GATT UUID in canonical 128-bit lowercase form: '180D', '0000180D' and
/// '0000180d-0000-1000-8000-00805f9b34fb' all give the last one.
String normalizeGattUuid(String uuid) {
  var u = uuid.trim().toLowerCase();
  if (u.startsWith('0x')) u = u.substring(2);
  if (u.length == 4) return '0000$u$_sigBase';
  if (u.length == 8) return '$u$_sigBase';
  return u;
}

Iterable<BandEntry> get _bands =>
    kBandRegistry.where((e) => e.role == DeviceRole.band);

/// Whether service [uuid] (any form) is [e]'s. A framed band is a family:
/// matched by its 32-bit service prefix. A notify-class band is matched by its
/// full UUID, because a shared prefix is a stranger (Nordic UART shares
/// Coros's 6e400001).
bool serviceIsEntry(BandEntry e, String uuid) {
  final normalized = normalizeGattUuid(uuid);
  return e.isFramed
      ? normalized.startsWith(e.servicePrefix.toLowerCase())
      : normalized == normalizeGattUuid(e.service);
}

BandEntry? _bandForService(Iterable<String> uuids) {
  for (final e in _bands) {
    if (uuids.any((u) => serviceIsEntry(e, u))) return e;
  }
  return null;
}

/// The band an advertisement belongs to, or null. A service match settles the
/// model; so does a service-data UUID an entry names as its own. A company id
/// does not count: Garmin's 0x0087 is on every Garmin product, so a Garmin
/// heart-rate strap would be refused as the watch. A name alone only proves
/// the family, so a framed band matched by name is
/// [BandIdentity.modelCertain] false.
BandIdentity? bandIdentityOf({
  required List<String> advertisedServiceUuids,
  required String? name,
  List<String> serviceDataUuids = const <String>[],
}) {
  final bySvc = _bandForService(advertisedServiceUuids);
  if (bySvc != null) return (entry: bySvc, modelCertain: true);
  final data = {for (final u in serviceDataUuids) normalizeGattUuid(u)};
  for (final e in _bands) {
    if (e.scanServiceData.any((u) => data.contains(normalizeGattUuid(u)))) {
      return (entry: e, modelCertain: true);
    }
  }
  final lower = name?.toLowerCase() ?? '';
  if (lower.isEmpty) return null;
  for (final e in _bands) {
    if (hintedNameMatch([e], const <String>[], lower, requireHint: false) !=
        null) {
      return (entry: e, modelCertain: !e.isFramed);
    }
  }
  return null;
}

/// DEFINITIVE check after `discoverServices()`: the full GATT service list
/// against every role==band entry's service.
BandEntry? bandIdentityFromGatt(Iterable<String> discoveredServiceUuids) =>
    _bandForService(discoveredServiceUuids);

/// One discovered service and the characteristic UUIDs under it.
class DiscoveredService {
  final String uuid;
  final List<String> characteristics;
  const DiscoveredService(this.uuid, [this.characteristics = const <String>[]]);
}

/// The user's explicit "yes, pair this band as a plain sensor": bound to ONE
/// physical device ([remoteId]) and ONE matched band entry ([bandEntryId]).
class PairConfirmation {
  final String remoteId;
  final String bandEntryId;
  const PairConfirmation({required this.remoteId, required this.bandEntryId});
}

/// What the pairing operation asks its persistence callback to write: exactly
/// the arguments of `LocalDb.upsertDevice`.
typedef PairedDevice = ({
  String id,
  String adapterId,
  String remoteId,
  String? label,
  String? tier,
});

/// What `HrsLink.pairNotifySensor` reports: saved, failed (with a sentence),
/// or "this is a band" (nothing was saved).
class PairOutcome {
  /// Non-null when the device turned out to be a band (nothing was saved).
  final BandEntry? isBand;

  /// Non-null on a plain failure (nothing was saved).
  final String? error;

  /// With [isBand]: false when only the device's name said which band it is
  /// (a WHOOP name cannot tell 4 from 5); true when GATT showed it.
  final bool modelCertain;
  const PairOutcome._(this.isBand, this.error, {this.modelCertain = true});
  const PairOutcome.saved() : this._(null, null);
  const PairOutcome.failed(String message) : this._(null, message);
  const PairOutcome.band(BandEntry entry, {bool modelCertain = true})
      : this._(entry, null, modelCertain: modelCertain);
  bool get saved => isBand == null && error == null;
}

/// Everything [pairNotifyDevice] needs from the outside world once a device is
/// connected: GATT discovery, the Polar PMD feature read, the OS bond trigger
/// and persistence. One typed interface (production over BluetoothDevice and
/// LocalDb, a fake in tests) so the decision awaits plain methods.
abstract class PairingIo {
  Future<List<DiscoveredService>> discoverServices();

  /// The PMD control characteristic's feature bytes, null when unreadable.
  /// Only asked of a Polar PMD entry.
  Future<List<int>?> readPmdFeatures();

  /// Writes the entry's bond-trigger characteristic; false when refused. Only
  /// asked of an entry that names one ([BandEntry.bondTriggerCharacteristic]).
  Future<bool> triggerBond();

  Future<void> persist(PairedDevice device);
}
