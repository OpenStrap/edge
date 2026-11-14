// Band cross-check: a sensor-scan hit that is really a band must be recognised.
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/band_identity.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ui2/pairing/pair_outcome_text.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show kBandSourceTier;
import 'package:openstrap_edge/ui2/pairing/add_device_flow.dart' show addDeviceScanEntries;
import 'package:openstrap_protocol/openstrap_protocol.dart';

BandEntry? _id(List<String> svc, [String? name]) =>
    bandIdentityOf(advertisedServiceUuids: svc, name: name)?.entry;

BandIdentity? _full(List<String> svc, [String? name]) =>
    bandIdentityOf(advertisedServiceUuids: svc, name: name);

void main() {
  test('a refusal keeps a name-only WHOOP model unknown', () {
    // WHY: detecting WHOOP by name must not label it as a confirmed WHOOP 4.
    expect(pairOutcomeText(null, const PairOutcome.band(kWhoopGen4, modelCertain: false)),
        'That device is a WHOOP, a band, not a plain sensor. Nothing was saved.');
    expect(pairOutcomeText(null, const PairOutcome.band(kWhoopGen5)),
        'That device is a WHOOP 5, a band, not a plain sensor. Nothing was saved.');
  });

  _reviewEvidence();
  _gatt();
  _matching();
  _pairing();
  group('bandIdentityOf', () {
    test('0x180D + WHOOP 4 service is gen4', () {
      // WHY: the reported bug, a WHOOP 4 advertising 0x180D, filed as a strap.
      expect(_id([kHeartRateServiceUuid, kWhoopGen4.service])?.id, 'gen4');
    });

    test('0x180D + WHOOP 5 service is gen5', () {
      // WHY: same bug on the WHOOP 5.0 / MG.
      expect(_id([kHeartRateServiceUuid, kWhoopGen5.service])?.id, 'gen5');
    });

    test('service match is case-insensitive and by 32-bit prefix', () {
      // WHY: scan results carry upper/lower case and short forms; a framed band
      // is identified by servicePrefix elsewhere in the registry.
      expect(_id([kWhoopGen4.service.toUpperCase()])?.id, 'gen4');
      final sameFamily = '${kWhoopGen4.servicePrefix}-1111-2222-3333-444455556666';
      expect(_id([sameFamily])?.id, 'gen4');
    });

    test('a service match settles the model', () {
      // WHY: only a service tells gen4 from gen5; the UI may then name the model.
      expect(_full([kHeartRateServiceUuid, kWhoopGen4.service])?.modelCertain, isTrue);
      expect(_full([kHeartRateServiceUuid, kWhoopGen5.service])?.modelCertain, isTrue);
    });

    test("0x180D + \"Jordan's WHOOP\" is a WHOOP, model not certain", () {
      // WHY: the owner names the band, so the name has no serial; it proves WHOOP, not which.
      final r = _full([kHeartRateServiceUuid], "Jordan's WHOOP");
      expect(r, isNotNull);
      expect(r!.modelCertain, isFalse);
      expect({'gen4', 'gen5'}, contains(r.entry.id));
    });

    test('name match is case-insensitive, anywhere in the name', () {
      // WHY: users type any name; "whoop" can sit anywhere or in any case.
      for (final n in ["jordan's whoop 4.0", 'WHOOP', 'My Whoop Band']) {
        final r = _full([kHeartRateServiceUuid], n);
        expect(r, isNotNull, reason: n);
        expect(r!.modelCertain, isFalse, reason: n);
      }
    });

    test('a serial-style name alone does not identify a band', () {
      // WHY: "W 5AG0047521" (Discord) contains no "whoop"; do not guess from a serial shape.
      expect(_id([kHeartRateServiceUuid], 'W 5AG0047521'), isNull);
    });

    test('only 0x180D and no name is not a band', () {
      // WHY: a real chest strap must stay a sensor; never fabricate a band.
      expect(_id([kHeartRateServiceUuid]), isNull);
      expect(_id([kHeartRateServiceUuid], null), isNull);
      expect(_id(const [], null), isNull);
    });

    test('only 0x180D with an ordinary strap name is not a band', () {
      // WHY: names must be matched against band matchers only, not by guessing.
      expect(_id([kHeartRateServiceUuid], 'Polar H10 12345678'), isNull);
      expect(_id([kHeartRateServiceUuid], 'Polar H10 1234'), isNull);
    });

    test('Polar PMD service is a sensor, not a band', () {
      // WHY: sensor-role entries never trigger the "this is a band" badge.
      expect(_id([kPolarPmdService]), isNull);
      expect(_id([kHeartRateServiceUuid, kPolarPmdService], 'Polar Sense AB12'),
          isNull);
    });

    test('Coros service is the coros entry', () {
      // WHY: Coros is a band; the check covers every band, not only WHOOP.
      expect(_id([kCorosService])?.id, 'coros');
    });

    test('a band service-data UUID alone identifies it (Garmin), name not needed', () {
      // WHY: the name is user-set and may drop the brand; an entry's own
      // service-data UUID is stronger.
      final r = bandIdentityOf(
          advertisedServiceUuids: [kHeartRateServiceUuid],
          name: null,
          serviceDataUuids: [kGarminServiceDataUuids.first]);
      expect(r?.entry.id, 'garmin');
      expect(r?.modelCertain, isTrue);
    });

    test('service beats a misleading name: WHOOP 5 service, name "Polar H10"', () {
      // WHY: the name is only a hint; a service match must win.
      expect(_id([kWhoopGen5.service], 'Polar H10 1234')?.id, 'gen5');
    });

    test('a band name alone is enough (Ultrahuman "UH_" name)', () {
      // WHY: nameMatcher of ANY band entry counts, not just gen4's.
      expect(_id(const [], 'UH_ABC123')?.id, 'ultrahuman');
    });
  });

  group('HrsLink.candidateFromAd (sensor-scan per-advertisement seam)', () {
    final sensors = <BandEntry>[kBleHrs, kPolarPmd];
    BandCandidate? cand(List<String> svc, String advName) =>
        HrsLink.candidateFromAd(
          entries: sensors,
          device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:01'),
          serviceUuids: [for (final s in svc) Guid(s)],
          advName: advName,
          platformName: '',
          rssi: -55,
        );

    test('the Add a device scan covers the framed WHOOP entries: a WHOOP-only advertisement is a candidate', () {
      // WHY: a WHOOP that advertises only its own band service matched no
      // sensor entry and was dropped, so the band could never be discovered
      // from "Add a device".
      final entries = addDeviceScanEntries();
      expect(entries.map((e) => e.id), containsAll(['gen4', 'gen5', 'ble_hrs', 'oura']));
      expect(entries.map((e) => e.id).toSet().length, kBandRegistry.length);
      // (A by-name entry makes the OS filter empty: every advertisement is heard.)
      final filter = HrsLink.scanServiceFilter(entries);
      expect(filter.isEmpty || filter.contains(Guid(kWhoopGen5.service)), isTrue);
      final c = HrsLink.candidateFromAd(
        entries: entries,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:21'),
        serviceUuids: [Guid(kWhoopGen5.service)],
        advName: 'WHOOP 5A1B',
        platformName: '',
        rssi: -50,
      );
      expect(c, isNotNull);
      expect(c!.entryId, 'gen5');
      // Control: the same advertisement against the sensor list alone is dropped.
      expect(cand([kWhoopGen5.service], 'WHOOP 5A1B'), isNull);
    });

    test('a WHOOP advertising 0x180D is a ble_hrs hit flagged alsoBand=gen4', () {
      // WHY: the picker needs both facts: it matched the HR scan AND is a band.
      final c = cand([kHeartRateServiceUuid, kWhoopGen4.service], 'WHOOP 4C01');
      expect(c, isNotNull);
      expect(c!.entryId, 'ble_hrs');
      expect(c.alsoBand?.entry.id, 'gen4');
      expect(c.alsoBand?.modelCertain, isTrue);
      expect(c.rssi, -55);
    });

    test('(CR r1) a Garmin company id on a 0x180D ad is a plain strap, not the watch', () async {
      // WHY: 0x0087 names Garmin, not the watch. A Garmin heart-rate strap
      // carrying it was flagged as the Garmin watch and refused at pairing.
      final c = HrsLink.candidateFromAd(
        entries: sensors,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:02'),
        serviceUuids: [Guid(kHeartRateServiceUuid)],
        advName: 'HRM-Pro:123456',
        platformName: '',
        rssi: -60,
        manufacturerCompanyIds: [kGarminCompanyIds.first],
      );
      expect(c?.entryId, 'ble_hrs');
      expect(c?.alsoBand, isNull);
      final io = _FakeIo(() async => _strap());
      final out = await pairNotifyDevice(
          entry: kBleHrs, remoteId: 'AA:BB:CC:DD:EE:02', io: io,
          earlierBand: c?.alsoBand);
      expect(out.saved, isTrue);
      expect(io.writes, hasLength(1));
      // Control: the company id still finds a Garmin watch in a Garmin scan.
      final watch = HrsLink.candidateFromAd(
        entries: [kGarmin],
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:03'),
        serviceUuids: const [],
        advName: '',
        platformName: '',
        rssi: -60,
        manufacturerCompanyIds: [kGarminCompanyIds.first],
      );
      expect(watch?.entryId, kGarmin.id);
    });

    test('(CR r1) a framed band matched by its service prefix is a candidate', () {
      // WHY: band identity matches a framed WHOOP by its 32-bit prefix; the
      // entry match compared full UUIDs, so a WHOOP advertising a sibling
      // UUID of its family was a band with no row in an unfiltered scan.
      final sibling = '${kWhoopGen5.servicePrefix}-0000-1000-8000-00805f9b34fb';
      expect(sibling, isNot(kWhoopGen5.service));
      final c = HrsLink.candidateFromAd(
        entries: kBandRegistry,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:04'),
        serviceUuids: [Guid(sibling)],
        advName: '',
        platformName: '',
        rssi: -60,
      );
      expect(c?.entryId, 'gen5');
    });

    test('(CR r1) a name-only WHOOP keeps its model uncertain', () {
      // WHY: the name cannot tell WHOOP 4 from 5; the name-matched entry is
      // gen4, and dropping the uncertain identity made it read as a WHOOP 4.
      final c = HrsLink.candidateFromAd(
        entries: kBandRegistry,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:05'),
        serviceUuids: const [],
        advName: 'WHOOP 4C0FFEE',
        platformName: '',
        rssi: -60,
      );
      expect(c?.entryId, 'gen4');
      expect(c?.alsoBand?.entry.id, 'gen4');
      expect(c?.alsoBand?.modelCertain, isFalse);
      // Control: a service settles the model, and the band is not "also".
      final sure = HrsLink.candidateFromAd(
        entries: kBandRegistry,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:06'),
        serviceUuids: [Guid(kWhoopGen5.service)],
        advName: 'WHOOP 4C0FFEE',
        platformName: '',
        rssi: -60,
      );
      expect(sure?.entryId, 'gen5');
      expect(sure?.alsoBand, isNull);
    });

    test('(CR r1) a name that drops out keeps the row label over the OS cache', () {
      // WHY: the OS-cached platform name can be stale; the row must not
      // change under the user's finger.
      final c = HrsLink.candidateFromAd(
        entries: sensors,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:07'),
        serviceUuids: [Guid(kHeartRateServiceUuid)],
        advName: '',
        platformName: 'Old Name',
        rssi: -60,
        previousLabel: 'Polar H10 1234',
      );
      expect(c?.label, 'Polar H10 1234');
      // Control: with no earlier label the OS name is still used.
      final first = HrsLink.candidateFromAd(
        entries: sensors,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:08'),
        serviceUuids: [Guid(kHeartRateServiceUuid)],
        advName: '',
        platformName: 'Old Name',
        rssi: -60,
      );
      expect(first?.label, 'Old Name');
    });

    test('a chest strap has alsoBand null', () {
      // WHY: no false "this is a band" badge on real sensors.
      final c = cand([kHeartRateServiceUuid], 'Polar H10 12345678');
      expect(c, isNotNull);
      expect(c!.entryId, 'ble_hrs');
      expect(c.alsoBand, isNull);
    });

    test('an advertisement no scanned entry claims yields no candidate', () {
      // WHY: unrelated peripherals must not appear in the sensor list.
      expect(cand(const [], 'Random Speaker'), isNull);
    });

    test('(S2) a service-data-only advertisement identifies a Mi scale and a Garmin', () {
      // WHY: scanServiceData is registry Strings, the ad carries Guids; the
      // two must be compared as Guids or service-data-only hits vanish.
      final scale = HrsLink.candidateFromAd(
        entries: [kMiScale2],
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:11'),
        serviceUuids: const [],
        advName: '',
        platformName: '',
        rssi: -70,
        serviceDataUuids: [Guid(kMiScaleWeightService)],
      );
      expect(scale?.entryId, kMiScale2.id);
      final garmin = HrsLink.candidateFromAd(
        entries: [kGarmin],
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:12'),
        serviceUuids: const [],
        advName: '',
        platformName: '',
        rssi: -70,
        serviceDataUuids: [Guid(kGarminServiceDataUuids.first)],
      );
      expect(garmin?.entryId, kGarmin.id);
    });

    test('(S1) band evidence from an earlier advertisement survives an HR-only one', () async {
      // WHY: a WHOOP advertisement, then a bare 0x180D one for the same id.
      // The candidate must still say "band", and pairing with standard-only
      // discovery must refuse with zero writes (DT9).
      final dev = BluetoothDevice.fromId('AA:BB:CC:DD:EE:21');
      final seen = BandEvidenceLedger();
      BandCandidate? ad(List<String> svc, String name) =>
          HrsLink.candidateFromAd(
            entries: sensors,
            device: dev,
            serviceUuids: [for (final s in svc) Guid(s)],
            advName: name,
            platformName: '',
            rssi: -50,
            bandSeen: seen,
          );
      final first = ad([kHeartRateServiceUuid, kWhoopGen4.service], 'WHOOP 4C01');
      expect(first?.alsoBand?.entry.id, 'gen4');
      final second = ad([kHeartRateServiceUuid], '');
      expect(second?.alsoBand?.entry.id, 'gen4');
      // A different id must not inherit it.
      final other = HrsLink.candidateFromAd(
        entries: sensors,
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:22'),
        serviceUuids: [Guid(kHeartRateServiceUuid)],
        advName: '',
        platformName: '',
        rssi: -50,
        bandSeen: seen,
      );
      expect(other?.alsoBand, isNull);

      final io = _FakeIo(() async => _strap());
      final out = await pairNotifyDevice(
        entry: kBleHrs,
        remoteId: dev.remoteId.str,
        io: io,
        earlierBand: second!.alsoBand,
      );
      expect(out.isBand?.id, 'gen4');
      expect(io.writes, isEmpty);
    });

    test('(S1 r2) a band-only packet in an unfiltered scan still leaves evidence', () async {
      // WHY: the unified picker scans unfiltered; a WHOOP-service-only packet
      // matches no sensor entry and yields no row, but its evidence must stay
      // for the later HR-only packet, or standard-only discovery saves it.
      final dev = BluetoothDevice.fromId('AA:BB:CC:DD:EE:24');
      final seen = BandEvidenceLedger();
      BandCandidate? ad(List<String> svc) => HrsLink.candidateFromAd(
            entries: sensors,
            device: dev,
            serviceUuids: [for (final s in svc) Guid(s)],
            advName: '',
            platformName: '',
            rssi: -50,
            bandSeen: seen,
            unfilteredScan: true,
          );
      expect(ad([kWhoopGen5.service]), isNull);
      final hrOnly = ad([kHeartRateServiceUuid]);
      expect(hrOnly?.entryId, 'ble_hrs');
      expect(hrOnly?.alsoBand?.entry.id, 'gen5');

      final io = _FakeIo(() async => _strap());
      final out = await pairNotifyDevice(
        entry: kBleHrs,
        remoteId: dev.remoteId.str,
        io: io,
        earlierBand: hrOnly!.alsoBand,
      );
      expect(out.isBand?.id, 'gen5');
      expect(io.writes, isEmpty);
    });

    test('(S1) a change in band evidence alone counts as a result change', () {
      // WHY: the picker is only told about changed rows; a row that gains the
      // "band" badge with the same signal and label must be re-sent.
      final dev = BluetoothDevice.fromId('AA:BB:CC:DD:EE:23');
      final plain = (device: dev, label: 'X', rssi: -50, entryId: 'ble_hrs', alsoBand: null);
      final banded = (device: dev, label: 'X', rssi: -50, entryId: 'ble_hrs',
          alsoBand: (entry: kWhoopGen4, modelCertain: true));
      expect(HrsLink.candidateChanged(plain, banded), isTrue);
      expect(HrsLink.candidateChanged(banded, banded), isFalse);
      expect(HrsLink.candidateChanged(null, plain), isTrue);
    });
  });
}

void _gatt() {
  group('bandIdentityFromGatt (definitive, after discoverServices)', () {
    test('WHOOP 4 / WHOOP 5 service in the full list gives that entry, no name needed', () {
      // WHY: last line of defence before a band is saved as a sensor.
      expect(bandIdentityFromGatt([kHeartRateServiceUuid, kWhoopGen4.service])?.id, 'gen4');
      expect(bandIdentityFromGatt(['0000180f-0000-1000-8000-00805f9b34fb', kWhoopGen5.service])?.id, 'gen5');
    });

    test('only HR / battery / device-info services is null', () {
      // WHY: a real strap must still pair as a sensor.
      expect(
          bandIdentityFromGatt([
            kHeartRateServiceUuid,
            '0000180f-0000-1000-8000-00805f9b34fb',
            '0000180a-0000-1000-8000-00805f9b34fb',
          ]),
          isNull);
    });

    test('a sensor-role service (Polar PMD) is null', () {
      // WHY: only role==band entries count.
      expect(bandIdentityFromGatt([kPolarPmdService]), isNull);
    });
  });

  group('PairOutcome (pairNotifySensor result)', () {
    test('can carry "is a band" distinct from an error and from saved', () {
      // WHY: the UI must show the slot comparison, not an error string.
      final b = PairOutcome.band(kWhoopGen4);
      expect(b.isBand?.id, 'gen4');
      expect(b.error, isNull);
      expect(b.saved, isFalse);
      final f = PairOutcome.failed('nope');
      expect(f.error, 'nope');
      expect(f.isBand, isNull);
      expect(f.saved, isFalse);
      expect(PairOutcome.saved().saved, isTrue);
    });
  });
}

const _nus = '6e400001-b5a3-f393-e0a9-e50e24dcca9e'; // Nordic UART, NOT Coros
const _hr = '0000180d-0000-1000-8000-00805f9b34fb';
const _bat = '0000180f-0000-1000-8000-00805f9b34fb';
const _dis = '0000180a-0000-1000-8000-00805f9b34fb';

void _matching() {
  group('matching rules (S5)', () {
    test('normalizeGattUuid: case and 16/32/128-bit forms are one UUID', () {
      // WHY: scans report any form; comparing strings would miss "180D" vs the full form.
      const full = '0000180d-0000-1000-8000-00805f9b34fb';
      expect(normalizeGattUuid('180D'), full);
      expect(normalizeGattUuid('0000180D'), full);
      expect(normalizeGattUuid('0000180D-0000-1000-8000-00805F9B34FB'), full);
      expect(normalizeGattUuid(full), full);
      expect(normalizeGattUuid('FEE1'), '0000fee1-0000-1000-8000-00805f9b34fb');
    });

    test('Mi Band FEE1 matches in 16-bit, upper and 128-bit forms (advert and GATT)', () {
      // WHY: a notify-class entry is matched by the full UUID, whatever its spelling.
      for (final u in ['FEE1', 'fee1', '0000FEE1-0000-1000-8000-00805F9B34FB', kHuami234Service]) {
        expect(_id([u])?.id, 'miband234', reason: 'advert $u');
        expect(bandIdentityFromGatt([u])?.id, 'miband234', reason: 'gatt $u');
      }
    });

    test('framed entries match by 32-bit prefix at GATT discovery too', () {
      // WHY: a WHOOP family member differs after the prefix; the registry matches framed bands by servicePrefix.
      final fam = '${kWhoopGen5.servicePrefix}-1111-2222-3333-444455556666'.toUpperCase();
      expect(bandIdentityFromGatt([fam])?.id, 'gen5');
    });

    test('notify-class entries match the FULL UUID only: a near miss is no band', () {
      // WHY: a shared prefix must not claim a stranger (prefix matching for notify entries is the bug).
      final nearCoros = '${kCorosService.substring(0, kCorosService.length - 1)}1';
      final nearGarmin = '${kGarminService.substring(0, kGarminService.length - 1)}1';
      for (final u in [nearCoros, nearGarmin]) {
        expect(_id([u]), isNull, reason: 'advert $u');
        expect(bandIdentityFromGatt([u]), isNull, reason: 'gatt $u');
      }
      // positive controls: the exact UUIDs do match
      expect(bandIdentityFromGatt([kCorosService])?.id, 'coros');
      expect(bandIdentityFromGatt([kGarminService.toUpperCase()])?.id, 'garmin');
    });

    test('Nordic UART alone is not a Coros (shares the 6e400001 prefix)', () {
      // WHY: kCorosService ends ...77656c6f6f70 ("weloop"); NUS ends ...e50e24dcca9e.
      expect(kCorosService.substring(0, 8), _nus.substring(0, 8),
          reason: 'control: the prefixes really collide');
      expect(_id([_nus]), isNull);
      expect(_id([_hr, _nus]), isNull);
      expect(bandIdentityFromGatt([_nus]), isNull);
      expect(bandIdentityFromGatt([_hr, _bat, _nus]), isNull);
    });

    test('a sensor service never hides a band service in the same list', () {
      // WHY: HR + PMD + band service together is a band; the sensor match must not win.
      for (final order in [
        [_hr, kPolarPmdService, kWhoopGen4.service],
        [kWhoopGen4.service, kPolarPmdService, _hr],
      ]) {
        expect(_id(order)?.id, 'gen4');
        expect(bandIdentityFromGatt(order)?.id, 'gen4');
      }
      expect(_id([_hr, kCorosService])?.id, 'coros');
    });

    test('service evidence beats a conflicting name or service-data UUID', () {
      // WHY: names are user-set and company ids shared; a service is the strongest evidence.
      expect(_full([kCorosService], 'My WHOOP')?.entry.id, 'coros');
      expect(_full([kCorosService], 'My WHOOP')?.modelCertain, isTrue);
      expect(_id([kWhoopGen4.service], 'UH_ABC123'), isNotNull);
      expect(_id([kWhoopGen4.service], 'UH_ABC123')?.id, 'gen4');
      final r = bandIdentityOf(
          advertisedServiceUuids: [kWhoopGen5.service],
          name: 'Garmin Forerunner',
          serviceDataUuids: [kGarminServiceDataUuids.first]);
      expect(r?.entry.id, 'gen5');
    });
  });
}

DiscoveredService _svc(String uuid, [List<String> chars = const []]) =>
    DiscoveredService(uuid, chars);

/// A genuine heart-rate strap's GATT: HRS with its measurement, battery, DIS.
List<DiscoveredService> _strap() => [
      _svc(_hr, [kHeartRateMeasurementUuid]),
      _svc(_bat),
      _svc(_dis),
    ];

/// The pairing seam's fake: scripted discovery, recorded writes.
class _FakeIo implements PairingIo {
  _FakeIo(this._discover,
      {this.bondOk = true, this.persistError, this.onBond});
  final Future<List<DiscoveredService>> Function() _discover;
  final bool bondOk;
  final void Function()? onBond;
  final Object? persistError;
  final writes = <PairedDevice>[];
  var bondCalls = 0;
  var pmdReads = 0;

  @override
  Future<List<DiscoveredService>> discoverServices() => _discover();
  @override
  Future<List<int>?> readPmdFeatures() async {
    pmdReads++;
    return null;
  }

  @override
  Future<bool> triggerBond() async {
    bondCalls++;
    onBond?.call();
    return bondOk;
  }

  @override
  Future<void> persist(PairedDevice d) async {
    if (persistError != null) throw persistError!;
    writes.add(d);
  }
}

class _Pairing {
  _FakeIo? io;
  List<PairedDevice> get writes => io?.writes ?? const <PairedDevice>[];
  Future<PairOutcome> run(
    BandEntry entry,
    Future<List<DiscoveredService>> Function() discover, {
    String remoteId = 'AA:BB:CC:DD:EE:01',
    PairConfirmation? confirmation,
    BandIdentity? earlierBand,
  }) =>
      pairNotifyDevice(
        entry: entry,
        remoteId: remoteId,
        io: io = _FakeIo(discover),
        confirmation: confirmation,
        earlierBand: earlierBand,
      );
}

void _pairing() {
  group('pairNotifyDevice (the real pairing decision; injected discovery + persistence)', () {
    test('(a) a WHOOP 5 behind a 0x180D advert is a band outcome, zero writes', () async {
      // WHY (S3): the reported bug. Advertisement said only 0x180D under an
      // ordinary name; only discovery reveals the band. Nothing may be saved.
      final p = _Pairing();
      final out = await p.run(kBleHrs,
          () async => [..._strap(), _svc(kWhoopGen5.service.toUpperCase())]);
      expect(out.isBand?.id, 'gen5');
      expect(out.saved, isFalse);
      expect(out.error, isNull);
      expect(p.writes, isEmpty);
    });

    test('(a2) the same for a WHOOP 4', () async {
      // WHY: both generations, not only the one the first test happened to use.
      final p = _Pairing();
      final out = await p.run(kBleHrs, () async => [..._strap(), _svc(kWhoopGen4.service)]);
      expect(out.isBand?.id, 'gen4');
      expect(p.writes, isEmpty);
    });

    test('(b) discovery throwing is an error outcome, zero writes', () async {
      // WHY (S3): a failed discovery must never fall through to "save anyway".
      final p = _Pairing();
      final out = await p.run(kBleHrs, () async => throw StateError('gatt 133'));
      expect(out.error?.trim() ?? '', isNotEmpty);
      expect(out.isBand, isNull);
      expect(out.saved, isFalse);
      expect(p.writes, isEmpty);
    });

    test('(c) a genuine strap (180D/180F/180A only) is saved exactly once', () async {
      // WHY (S3): the safeguard must not block real sensors. Positive control for the zero-write tests.
      final p = _Pairing();
      final out = await p.run(kBleHrs, () async => _strap(), remoteId: 'AA:BB:CC:DD:EE:09');
      expect(out.saved, isTrue);
      expect(p.writes, hasLength(1));
      final w = p.writes.single;
      expect(w.adapterId, 'ble_hrs');
      expect(w.remoteId, 'AA:BB:CC:DD:EE:09');
      expect(w.id, HrsLink.mintDeviceId(kBleHrs, 'AA:BB:CC:DD:EE:09'));
      expect(w.tier, 'beatToBeat', reason: 'HrsLink.deriveTier for a declared-rr entry');
    });

    test('(S3) bond trigger and PMD read go through the interface only where they apply', () async {
      // WHY: the interface methods are always present now; the decision to call
      // them must stay with the entry (a plain strap writes nothing to the device).
      final strap = _Pairing();
      await strap.run(kBleHrs, () async => _strap());
      expect(strap.io!.bondCalls, 0);
      expect(strap.io!.pmdReads, 0);
      List<DiscoveredService> pebble() => [
            _svc(kPebbleServiceUuid, kPebble.requiredCharacteristics),
          ];
      final bonded = _Pairing();
      final ok = await bonded.run(kPebble, () async => pebble());
      expect(ok.saved, isTrue);
      expect(bonded.io!.bondCalls, 1);
      final refused = _FakeIo(() async => pebble(), bondOk: false);
      final out = await pairNotifyDevice(
          entry: kPebble, remoteId: 'AA:BB:CC:DD:EE:31', io: refused);
      expect(out.saved, isFalse);
      expect(out.error?.trim() ?? '', isNotEmpty);
      expect(refused.writes, isEmpty);
    });

    test('(CR 4500472602) a band missing the measurement characteristic is still a band outcome', () async {
      // WHY: the band cross-check needs only the discovered services. Run
      // after the characteristic check, a WHOOP without the measurement
      // characteristic got "does not expose the data" instead of the band
      // choice this flow exists to offer.
      final p = _Pairing();
      final out = await p.run(
          kBleHrs, () async => [_svc(_hr), _svc(kWhoopGen5.service)]);
      expect(out.isBand?.id, 'gen5');
      expect(out.error, isNull);
      expect(p.writes, isEmpty);
    });

    test('(CR 4500539072) a band outcome says whether its model is certain', () async {
      // WHY: the flow must not guess certainty from whether the entry changed.
      // GATT proves the model; a name match alone does not.
      final byName = (entry: kWhoopGen4, modelCertain: false);
      final proven = await _Pairing().run(kBleHrs,
          () async => [..._strap(), _svc(kWhoopGen4.service)],
          earlierBand: byName);
      expect(proven.isBand?.id, 'gen4');
      expect(proven.modelCertain, isTrue, reason: 'GATT showed the gen4 service');
      final nameOnly = await _Pairing().run(kBleHrs, () async => _strap(),
          earlierBand: byName);
      expect(nameOnly.isBand?.id, 'gen4');
      expect(nameOnly.modelCertain, isFalse, reason: 'only the name said WHOOP');
    });

    test('a strap missing its measurement characteristic fails, zero writes', () async {
      // WHY: a row pointing at a device that cannot answer is a sensor that appears paired and never beats.
      final p = _Pairing();
      final out = await p.run(kBleHrs, () async => [_svc(_hr), _svc(_bat)]);
      expect(out.error?.trim() ?? '', isNotEmpty);
      expect(out.saved, isFalse);
      expect(p.writes, isEmpty);
    });

    test('a persistence failure is an error outcome, not a saved one', () async {
      // WHY: never report success for a row that was not written.
      final out = await pairNotifyDevice(
        entry: kBleHrs,
        remoteId: 'AA:BB:CC:DD:EE:01',
        io: _FakeIo(() async => _strap(), persistError: StateError('disk full')),
      );
      expect(out.saved, isFalse);
      expect(out.error?.trim() ?? '', isNotEmpty);
    });

    test('Coros paired under kCoros, its own service discovered, saves', () async {
      // WHY (S4): the band refusal must not fire for the entry being paired.
      final p = _Pairing();
      final out = await p.run(kCoros,
          () async => [_svc(kCorosService), _svc(_bat, [kBatteryLevelUuid])]);
      expect(out.saved, isTrue);
      expect(p.writes.single.adapterId, 'coros');
    });

    test('Coros without its own service (Nordic UART only) is refused, zero writes', () async {
      // WHY (S5): a Nordic UART peripheral is not a Coros; identity is the full vendor UUID.
      final p = _Pairing();
      final out = await p.run(kCoros, () async => [_svc(_nus), _svc(_bat, [kBatteryLevelUuid])]);
      expect(out.saved, isFalse);
      expect(out.error?.trim() ?? '', isNotEmpty);
      expect(p.writes, isEmpty);
    });

    test('Garmin paired under kGarmin with its multi-link characteristics saves', () async {
      // WHY (S4): garminMlPair needs a data characteristic 6A4E2810..2819; the
      // Garmin service is a band service yet must not be refused as a band here.
      final p = _Pairing();
      final out = await p.run(kGarmin,
          () async => [_svc(kGarminService, [kGarminNotifyChar, kGarminWriteChar])]);
      expect(out.saved, isTrue);
      expect(p.writes.single.adapterId, 'garmin');
    });

    test('Garmin service without a multi-link data characteristic fails, zero writes', () async {
      // WHY: the Garmin shape check still stands behind the identity change.
      final p = _Pairing();
      final out = await p.run(kGarmin, () async => [_svc(kGarminService, const [])]);
      expect(out.saved, isFalse);
      expect(out.error?.trim() ?? '', isNotEmpty);
      expect(p.writes, isEmpty);
    });

    test('a WHOOP paired as a sensor WITH a matching confirmation saves', () async {
      // WHY (S4): option C, the user deliberately uses the WHOOP as a plain HR sensor.
      final p = _Pairing();
      final out = await p.run(
        kBleHrs,
        () async => [..._strap(), _svc(kWhoopGen5.service)],
        remoteId: 'AA:BB:CC:DD:EE:05',
        confirmation: const PairConfirmation(
            remoteId: 'AA:BB:CC:DD:EE:05', bandEntryId: 'gen5'),
      );
      expect(out.saved, isTrue);
      expect(p.writes, hasLength(1));
      expect(p.writes.single.adapterId, 'ble_hrs');
    });

    test('(CR r2) a WHOOP kept as a plain sensor is stored at the band tier, not beat-to-beat', () async {
      // WHY: deriveTier off ble_hrs's declared signals says beatToBeat, which
      // would rank a wrist optical WHOOP above the band, fill the R-peak
      // rung and win live heart rate.
      final p = _Pairing();
      await p.run(
        kBleHrs,
        () async => [..._strap(), _svc(kWhoopGen5.service)],
        remoteId: 'AA:BB:CC:DD:EE:05',
        confirmation: const PairConfirmation(
            remoteId: 'AA:BB:CC:DD:EE:05', bandEntryId: 'gen5'),
      );
      expect(p.writes.single.tier, kBandSourceTier);
      expect(kBandSourceTier, 'wristOptical');
      // Positive control: a real chest strap keeps its beat-to-beat tier.
      final strap = _Pairing();
      await strap.run(kBleHrs, () async => _strap());
      expect(strap.writes.single.tier, 'beatToBeat');
    });

    test('a confirmation for another device is still refused', () async {
      // WHY (S4): the confirmation is bound to the device id; a stale one must not unlock a different strap.
      final p = _Pairing();
      final out = await p.run(
        kBleHrs,
        () async => [..._strap(), _svc(kWhoopGen5.service)],
        remoteId: 'AA:BB:CC:DD:EE:05',
        confirmation: const PairConfirmation(
            remoteId: 'AA:BB:CC:DD:EE:99', bandEntryId: 'gen5'),
      );
      expect(out.isBand?.id, 'gen5');
      expect(p.writes, isEmpty);
    });

    test('a confirmation for another matched entry is still refused', () async {
      // WHY (S4): confirmed "WHOOP 4" does not cover a device that turns out to be a WHOOP 5 (or a Coros).
      final p = _Pairing();
      final out = await p.run(
        kBleHrs,
        () async => [..._strap(), _svc(kWhoopGen5.service)],
        remoteId: 'AA:BB:CC:DD:EE:05',
        confirmation: const PairConfirmation(
            remoteId: 'AA:BB:CC:DD:EE:05', bandEntryId: 'gen4'),
      );
      expect(out.isBand?.id, 'gen5');
      expect(p.writes, isEmpty);
    });

    test('(N1) earlier band evidence survives a standard-only GATT: refused, zero writes', () async {
      // WHY (DT9): advert/company/name said "band"; discovery shows only
      // 180D/180F/180A. Absence at GATT must not erase that evidence.
      final earlier = <String, BandIdentity>{
        'service': (entry: kWhoopGen4, modelCertain: true),
        'company id': (entry: kGarmin, modelCertain: true),
        'name hint': (entry: kWhoopGen4, modelCertain: false),
      };
      for (final e in earlier.entries) {
        final p = _Pairing();
        final out = await p.run(kBleHrs, () async => _strap(),
            remoteId: 'AA:BB:CC:DD:EE:07', earlierBand: e.value);
        expect(out.isBand?.id, e.value.entry.id, reason: e.key);
        expect(out.saved, isFalse, reason: e.key);
        expect(p.writes, isEmpty, reason: e.key);
      }
    });

    test('(N1) the same device with a matching confirmation is saved once', () async {
      // WHY (DT9): positive control; the user's explicit yes unlocks exactly that evidence.
      final p = _Pairing();
      final out = await p.run(kBleHrs, () async => _strap(),
          remoteId: 'AA:BB:CC:DD:EE:07',
          earlierBand: (entry: kWhoopGen4, modelCertain: false),
          confirmation: const PairConfirmation(
              remoteId: 'AA:BB:CC:DD:EE:07', bandEntryId: 'gen4'));
      expect(out.saved, isTrue);
      expect(p.writes, hasLength(1));
    });

    test('(N1) a confirmation for another device or entry does not unlock earlier evidence', () async {
      // WHY (DT9): the confirmation stays bound to device and entry.
      for (final c in const [
        PairConfirmation(remoteId: 'AA:BB:CC:DD:EE:99', bandEntryId: 'gen4'),
        PairConfirmation(remoteId: 'AA:BB:CC:DD:EE:07', bandEntryId: 'gen5'),
      ]) {
        final p = _Pairing();
        final out = await p.run(kBleHrs, () async => _strap(),
            remoteId: 'AA:BB:CC:DD:EE:07',
            earlierBand: (entry: kWhoopGen4, modelCertain: false),
            confirmation: c);
        expect(out.isBand?.id, 'gen4');
        expect(p.writes, isEmpty);
      }
    });

    test('(N1) a GATT-found band beats an uncertain earlier name guess', () async {
      // WHY (DT9): GATT is definitive; a name-only gen4 guess must not mislabel a WHOOP 5.
      final p = _Pairing();
      final out = await p.run(
          kBleHrs, () async => [..._strap(), _svc(kWhoopGen5.service)],
          remoteId: 'AA:BB:CC:DD:EE:07',
          earlierBand: (entry: kWhoopGen4, modelCertain: false));
      expect(out.isBand?.id, 'gen5');
      expect(p.writes, isEmpty);
    });

    test('HrsLink.pairNotifySensor delegates to pairNotifyDevice (backstop)', () {
      // WHY: the seam is worthless if production does not call it. A source
      // check, kept only as a backstop; positive control proves the matcher.
      final src = File('lib/ble/hrs_link.dart').readAsStringSync()
          .split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
      final start = src.indexOf('static Future<String?> pairNotifySensor(');
      final start2 = src.indexOf('static Future<PairOutcome> pairNotifySensor(');
      final at = start >= 0 ? start : start2;
      expect(at, greaterThanOrEqualTo(0), reason: 'pairNotifySensor not found');
      final end = src.indexOf('static ', at + 10);
      final body = src.substring(at, end);
      expect(RegExp(r'pairNotifyDevice\s*\(').hasMatch(body), isTrue);
      expect(RegExp(r'pairNotifyDevice\s*\(').hasMatch('x = pairNotifyDevice(a);'), isTrue,
          reason: 'matcher control');
    });
  });
}

void _reviewEvidence() {
  group('review regressions: evidence provenance', () {
    test('later PMD query retains HRS claim while later band query records evidence', () async {
      // WHY: an H10 can answer both queries but cannot provide PMD PPI.
      final ledger = BandEvidenceLedger();
      final confirmed = <String, String>{};
      final device = BluetoothDevice.fromId('multi-query');
      final first = HrsLink.candidateFromSystemDevice(entries: [kBleHrs, kPolarPmd],
          device: device, queriedEntry: kBleHrs, platformName: 'Polar H10',
          bandSeen: ledger, confirmed: confirmed);
      final second = HrsLink.candidateFromSystemDevice(entries: [kBleHrs, kPolarPmd],
          device: device, queriedEntry: kPolarPmd, platformName: 'Polar H10',
          bandSeen: ledger, confirmed: confirmed, previous: first);
      expect(second.entryId, kBleHrs.id);
      expect(confirmed[device.remoteId.str], kBleHrs.id);
      final io = _FakeIo(() async => _strap());
      final outcome = await pairNotifyDevice(entry: kBandRegistry.firstWhere((e) => e.id == second.entryId),
          remoteId: device.remoteId.str, io: io,
          latestBand: () => ledger.identityFor(device.remoteId.str));
      expect(outcome.saved, isTrue);
      expect(io.pmdReads, 0);
      expect(io.writes.single.adapterId, kBleHrs.id);

      // Keeping the chosen adapter must not discard later safety evidence.
      final third = HrsLink.candidateFromSystemDevice(entries: [kBleHrs, kWhoopGen5],
          device: device, queriedEntry: kWhoopGen5, platformName: 'Polar H10',
          bandSeen: ledger, confirmed: confirmed, previous: second);
      expect(third.entryId, kBleHrs.id);
      expect(third.alsoBand?.entry.id, kWhoopGen5.id);
      final bandIo = _FakeIo(() async => _strap());
      final refusal = await pairNotifyDevice(entry: kBleHrs,
          remoteId: device.remoteId.str, io: bandIo,
          latestBand: () => ledger.identityFor(device.remoteId.str));
      expect(refusal.isBand?.id, kWhoopGen5.id);
      expect(bandIo.writes, isEmpty);
    });

    test('system-device cached WHOOP name refuses a standard-only sensor save', () async {
      // WHY: iOS may return a connected WHOOP with only HRS discovery.
      final ledger = BandEvidenceLedger();
      final device = BluetoothDevice.fromId('system-whoop');
      final candidate = HrsLink.candidateFromSystemDevice(entries: [kBleHrs],
          device: device, queriedEntry: kBleHrs, platformName: 'WHOOP 5',
          bandSeen: ledger);
      expect(candidate.rssi, isNull);
      expect(candidate.alsoBand?.entry.id, kWhoopGen4.id);
      final io = _FakeIo(() async => _strap());
      final out = await pairNotifyDevice(entry: kBleHrs, remoteId: device.remoteId.str,
          io: io, latestBand: () => ledger.identityFor(device.remoteId.str));
      expect(out.isBand, isNotNull);
      expect(out.modelCertain, isFalse);
      expect(io.writes, isEmpty);
    });

    test('evidence arriving during discovery refuses persistence', () async {
      // WHY: the tapped row predates the final scan packet.
      final ledger = BandEvidenceLedger();
      final io = _FakeIo(() async {
        ledger.observe('late', advertisedServiceUuids: [kWhoopGen5.service]);
        return _strap();
      });
      final out = await pairNotifyDevice(entry: kBleHrs, remoteId: 'late', io: io,
          latestBand: () => ledger.identityFor('late'));
      expect(out.isBand?.id, kWhoopGen5.id);
      expect(io.writes, isEmpty);
    });

    test('evidence arriving during bonding is checked before saving', () async {
      // WHY: shutdown can time out while a platform lookup is still pending.
      final ledger = BandEvidenceLedger();
      const entry = BandEntry.notify(id: 'bonded_hr', label: 'Bonded sensor',
          service: kHeartRateServiceUuid, characteristics: [kHeartRateMeasurementUuid],
          timeAnchor: TimeAnchor.arrival, category: DeviceCategory.workoutSensor,
          role: DeviceRole.sensor, bondTriggerCharacteristic: kHeartRateMeasurementUuid);
      final io = _FakeIo(() async => _strap(), onBond: () {
        ledger.observe('bond', advertisedServiceUuids: [kWhoopGen5.service]);
      });
      final out = await pairNotifyDevice(entry: entry, remoteId: 'bond', io: io,
          latestBand: () => ledger.identityFor('bond'));
      expect(io.bondCalls, 1);
      expect(out.isBand?.id, kWhoopGen5.id);
      expect(io.writes, isEmpty);
    });

    test('an advertised strap name invalidates a cached WHOOP guess permanently', () async {
      // WHY: empty later packets and OS lookups must not revive stale names.
      final ledger = BandEvidenceLedger();
      final device = BluetoothDevice.fromId('renamed');
      final first = HrsLink.candidateFromSystemDevice(entries: [kBleHrs], device: device,
          queriedEntry: kBleHrs, platformName: 'WHOOP', bandSeen: ledger);
      expect(first.alsoBand, isNotNull);
      final real = HrsLink.candidateFromAd(entries: [kBleHrs], device: device,
          serviceUuids: [Guid(kHeartRateServiceUuid)], advName: 'Polar H10',
          platformName: 'WHOOP', rssi: -50, bandSeen: ledger);
      expect(real?.alsoBand, isNull);
      final last = HrsLink.candidateFromSystemDevice(entries: [kBleHrs], device: device,
          queriedEntry: kBleHrs, platformName: 'WHOOP', bandSeen: ledger, previous: real);
      expect(last.alsoBand, isNull);
      expect(last.label, 'Polar H10');
      final io = _FakeIo(() async => _strap());
      final out = await pairNotifyDevice(entry: kBleHrs, remoteId: device.remoteId.str,
          io: io, earlierBand: first.alsoBand,
          latestBand: () => ledger.identityFor(device.remoteId.str, fallback: first.alsoBand));
      expect(out.saved, isTrue);
      expect(io.writes.single.remoteId, device.remoteId.str);
    });

    for (final serviceData in [false, true]) {
      test('a model-certain name cannot replace stronger ${serviceData ? "data" : "service"} evidence', () {
        // WHY: model certainty and evidence provenance are separate dimensions.
        expect(_full([], 'COROS')?.entry.id, kCoros.id,
            reason: 'positive control: the conflicting name is recognised');
        final ledger = BandEvidenceLedger();
        ledger.observe('band', advertisedServiceUuids: serviceData ? [] : [kGarmin.service],
            serviceDataUuids: serviceData ? [kGarmin.scanServiceData.first] : []);
        final identity = ledger.observe('band', advertisedServiceUuids: [], advertisedName: 'COROS');
        expect(identity?.entry.id, kGarmin.id);
      });
    }
  });
}
