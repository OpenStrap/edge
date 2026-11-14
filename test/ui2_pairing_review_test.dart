// PR #669 review regressions: exercise the rendered sheets, recovery screens,
// table and device details, rather than just their copy helpers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/pairing/pair_help.dart';
import 'package:openstrap_edge/ui2/pairing/pair_sheets.dart';
import 'package:openstrap_edge/ui2/pairing/pair_text.dart';
import 'package:openstrap_edge/ui2/pairing/slot_comparison_view.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';

import 'support/pair_ui_support.dart';

const _ouraKey = 'Already use the Oura app? Keep the ring in that app and pair with its existing key. Skip the reset steps below. Only reset it if you want a new key.';
const _pebbleLead = 'Pebble 2 can fill your days with sleep and heart rate. Pebble 2 SE shows the watch’s own sleep and steps. It has no heart-rate sensor, so this app cannot calculate daily strain or estimate recovery from it.';
const _strapLead = 'It adds heart rate while you work out. It does not record sleep, recovery or daily strain.';

Future<void> _openBand(WidgetTester t, BandEntry entry) async {
  await pumpPair(t, Builder(builder: (c) => Scaffold(body: TextButton(
      onPressed: () => showBandFoundSheet(c, band: entry, hasMainBand: false),
      child: const Text('open')))), size: const Size(412, 2400));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void _expectKeyBeforeReset(WidgetTester t) {
  final guidance = find.text(_ouraKey);
  expect(guidance, findsOneWidget);
  final reset = find.text('Open the maker’s app and remove this device from it.');
  expect(reset, findsOneWidget, reason: 'new-key reset path stays available');
  expect(t.getTopLeft(guidance).dy, lessThan(t.getTopLeft(reset).dy));
}

void main() {
  // WHY: synthetic-night calibration stays provisional after the minimum nights.
  // catches: replacing the provisional warning with only a waiting period.
  for (final ring in [kOura, kColmi, kUltrahuman]) {
    testWidgets('${ring.id} skin temperature retains its provisional warning', (t) async {
      await _openBand(t, ring);
      final row = find.byKey(const ValueKey('slot-row-skinTemperature'));
      expect(find.descendant(of: row, matching: find.text(
          'Every day: Provisional estimate; needs a few nights')), findsOneWidget);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-skinTemperature'))).label,
          contains('Provisional estimate; needs a few nights'));
    });
  }

  // WHY: a name-only WHOOP could have either generation's step acquisition.
  // catches: using the representative's live-only or stored-counter claim.
  for (final representative in [kWhoopGen4, kWhoopGen5]) {
    testWidgets('unknown WHOOP steps stay unconfirmed (${representative.id})', (t) async {
      await pumpPair(t, Builder(builder: (c) => Scaffold(body: TextButton(
          onPressed: () => showBandFoundSheet(c, band: representative,
              hasMainBand: false, modelKnown: false),
          child: const Text('open')))), size: const Size(412, 2400));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final l = lookupAppLocalizations(const Locale('en'));
      final row = find.byKey(const ValueKey('slot-row-steps'));
      expect(find.descendant(of: row, matching: find.text(
          l.slotColumnReason(l.slotEveryDay, l.capReasonUnconfirmed))), findsOneWidget);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-everyDay-steps'))).label,
          contains(l.capReasonUnconfirmed));
      expect(find.text('WHOOP 4'), findsNothing);
      expect(find.text('WHOOP 5'), findsNothing);
    });
  }

  testWidgets('Oura sheet preserves the existing key before reset steps', (t) async {
    await _openBand(t, kOura);
    _expectKeyBeforeReset(t);
  });

  testWidgets('Oura trouble card preserves the existing key before reset steps', (t) async {
    await pumpPair(t, Scaffold(body: SingleChildScrollView(
        child: TroubleConnectingCard(entries: [kOura]))),
        size: const Size(412, 2400));
    _expectKeyBeforeReset(t);
  });

  testWidgets('Oura bond-refused screen preserves the existing key before reset steps', (t) async {
    await pumpPair(t, PairingView(phase: PairPhase.bondRefused,
        onPair: () {}, resetEntry: kOura), size: const Size(412, 2400));
    _expectKeyBeforeReset(t);
    expect(find.text('In your phone’s Bluetooth settings, find the device and choose Forget.'),
        findsOneWidget);
  });

  testWidgets('Pebble lead keeps HR for Pebble 2 and excludes it for SE', (t) async {
    await _openBand(t, kPebble);
    expect(find.text(_pebbleLead), findsOneWidget);
    expect(find.text('It can fill your days with sleep, recovery and heart rate.'), findsNothing);
  });

  testWidgets('Pebble HR captions qualify every affected row and its accessible mark', (t) async {
    await _openBand(t, kPebble);
    const only = 'Pebble 2 only. The 2 SE has no heart-rate sensor.';
    for (final (cap, reason) in [
      (DeviceCapability.recovery, 'Pebble 2 only, and an estimate, not a '
          'direct reading. The 2 SE has no heart-rate sensor.'),
      (DeviceCapability.strain, only),
      (DeviceCapability.heartRate, only),
    ]) {
      final row = find.byKey(ValueKey('slot-row-${cap.name}'));
      expect(find.descendant(of: row, matching: find.text('Every day: $reason')),
          findsOneWidget, reason: '${cap.name} must exclude SE');
      final l = lookupAppLocalizations(const Locale('en'));
      expect(t.getSemantics(find.byKey(ValueKey('slot-everyDay-${cap.name}'))).label,
          '${capabilityLabel(l, cap)}, Every day: Sends. $reason');
    }
    final sleep = find.byKey(const ValueKey('slot-row-sleep'));
    expect(find.descendant(of: sleep, matching: find.text(
        'Every day: From the device’s own sleep stages')), findsOneWidget);
    final steps = find.byKey(const ValueKey('slot-row-steps'));
    expect(find.descendant(of: steps, matching: find.text(
        'Every day: The device’s own reading')), findsOneWidget);
  });

  testWidgets('strap lead excludes daily strain precisely', (t) async {
    await pumpPair(t, Builder(builder: (c) => Scaffold(body: TextButton(
        onPressed: () => showStrapSheet(c, sensor: kBleHrs),
        child: const Text('open')))), size: const Size(412, 2400));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text(_strapLead), findsOneWidget);
  });

  test('Russian replacement says connect first and retain the old pairing on cancellation', () {
    // WHY: the old copy described forgetting first, which could strand the user.
    final l = lookupAppLocalizations(const Locale('ru'));
    expect(l.pairReplaceConfirmTitle('WHOOP').toLowerCase(), contains('после подключения'));
    expect(l.pairReplaceBand('WHOOP').toLowerCase(), contains('затем отключить'));
    expect(l.pairReplaceConfirmBody.toLowerCase(), contains('останется сопряжённым'));
    expect(l.pairReplaceConfirmBody.toLowerCase(), contains('отмените'));
  });

  test('Russian unpair explicitly removes the pairing', () {
    // WHY: disconnecting a radio link does not remove its saved pairing.
    final l = lookupAppLocalizations(const Locale('ru'));
    expect(l.pairUnpairBand.toLowerCase(), contains('сопряжени'));
    expect(l.pairUnpairBand.toLowerCase(), isNot(contains('отключ')));
  });

  test('Thai strap filter names chest straps and armbands', () {
    final l = lookupAppLocalizations(const Locale('th'));
    expect(l.pairKindStrap, contains('คาดอก'));
    expect(l.pairKindStrap, contains('ต้นแขน'));
  });

  testWidgets('WHOOP unconfirmed beat timing caption names only Workouts only', (t) async {
    await pumpPair(t, Scaffold(body: SingleChildScrollView(
        child: SlotTable(comparison: slotComparisonFor(kWhoopGen5)))),
        size: const Size(412, 2000));
    final row = find.byKey(const ValueKey('slot-row-workoutBeatToBeat'));
    expect(find.descendant(of: row, matching: find.text(
        'Workouts only: If this device sends it, not confirmed')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(
        'Every day: If this device sends it, not confirmed')), findsNothing);
  });

  testWidgets('different reasons in both columns remain associated with each column', (t) async {
    await pumpPair(t, const Scaffold(body: SingleChildScrollView(
        child: SlotTable(comparison: SlotComparison(
          everyDay: SlotSide(sends: {DeviceCapability.sleep:
              CapabilityStatus(CapabilityKind.vendorReported)}, doesNotSend: {}),
          workoutsOnly: SlotSide(sends: {DeviceCapability.sleep:
              CapabilityStatus(CapabilityKind.conditional, reasonKey: kReasonUnconfirmed)},
              doesNotSend: {}),
        )))), size: const Size(412, 2000));
    final row = find.byKey(const ValueKey('slot-row-sleep'));
    expect(find.descendant(of: row, matching: find.text(
        'Every day: The device’s own reading')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(
        'Workouts only: If this device sends it, not confirmed')), findsOneWidget);
  });

  testWidgets('each table mark announces its capability, column and status', (t) async {
    await pumpPair(t, Scaffold(body: SingleChildScrollView(
        child: SlotTable(comparison: slotComparisonFor(kWhoopGen5)))),
        size: const Size(412, 2000));
    for (final (key, label) in [
      ('slot-everyDay-sleep', 'Sleep, Every day: Sends'),
      ('slot-workoutsOnly-sleep', 'Sleep, Workouts only: Doesn’t send'),
      ('slot-everyDay-workoutBeatToBeat', 'Beat-to-beat timing during workouts, Every day: Sends'),
      ('slot-workoutsOnly-workoutBeatToBeat', 'Beat-to-beat timing during workouts, Workouts only: Sends. If this device sends it, not confirmed'),
    ]) {
      expect(t.getSemantics(find.byKey(ValueKey(key))).label, label, reason: key);
    }
  });

  for (final family in ['colmi', 'oura']) {
    testWidgets('$family detail uses its every-day description without workout-only copy', (t) async {
      final l = lookupAppLocalizations(const Locale('en'));
      await pumpPair(t, DeviceDetailView(HealthSource(name: family, kind: 'Ring',
          tier: SourceTier.beatToBeat, icon: Icons.circle, isBand: false,
          deviceId: '$family-test', family: family)), size: const Size(412, 2400));
      expect(find.text(l.pairWearableCardNote), findsOneWidget,
          reason: 'the every-day card explains its role');
      expect(find.text(l.devicesWhatItDoesBeats), findsNothing);
    });
  }

  testWidgets('workout strap detail retains the workout description', (t) async {
    final l = lookupAppLocalizations(const Locale('en'));
    await pumpPair(t, const DeviceDetailView(HealthSource(name: 'Strap', kind: 'Strap',
        tier: SourceTier.beatToBeat, icon: Icons.favorite, isBand: false,
        deviceId: 'ble_hrs-test', family: 'ble_hrs')), size: const Size(412, 2400));
    expect(find.text(l.devicesWhatItDoesBeats), findsOneWidget);
  });

  test('every Pebble locale names the SE limits and watch-reported readings', () {
    const copy = {
      'en': ('Pebble 2 only. The 2 SE has no heart-rate sensor.',
        'Pebble 2 SE shows the watch’s own sleep and steps. It has no heart-rate sensor, so this app cannot calculate daily strain or estimate recovery from it.'),
      'de': ('Nur Pebble 2. Die 2 SE hat keinen Herzfrequenzsensor.',
        'Pebble 2 SE zeigt die eigenen Schlaf- und Schrittdaten der Uhr. Sie hat keinen Herzfrequenzsensor, daher kann diese App daraus weder die tägliche Belastung berechnen noch die Erholung schätzen.'),
      'es': ('Solo Pebble 2. El 2 SE no tiene sensor de frecuencia cardiaca.',
        'Pebble 2 SE muestra el sueño y los pasos registrados por el propio reloj. No tiene sensor de frecuencia cardiaca, por lo que esta app no puede calcular la carga diaria ni estimar la recuperación a partir de sus datos.'),
      'fr': ('Pebble 2 uniquement. La 2 SE n’a pas de capteur de fréquence cardiaque.',
        'Pebble 2 SE affiche le sommeil et les pas enregistrés par la montre. Elle n’a pas de capteur de fréquence cardiaque, donc cette app ne peut pas calculer la charge quotidienne ni estimer la récupération à partir de ses données.'),
      'hi': ('केवल Pebble 2। 2 SE में हृदय गति सेंसर नहीं है।',
        'Pebble 2 SE घड़ी की अपनी नींद और कदमों की रीडिंग दिखाता है। उसमें हृदय गति सेंसर नहीं है, इसलिए यह ऐप उसके डेटा से रोज़ का शारीरिक भार नहीं निकाल सकता और न ही रिकवरी का अनुमान लगा सकता है।'),
      'ru': ('Только Pebble 2. У 2 SE нет датчика пульса.',
        'Pebble 2 SE показывает сон и шаги по данным самих часов. У него нет датчика пульса, поэтому приложение не может рассчитать дневную нагрузку или оценить восстановление по его данным.'),
      'th': ('เฉพาะ Pebble 2 รุ่น 2 SE ไม่มีเซ็นเซอร์วัดอัตราการเต้นของหัวใจ',
        'Pebble 2 SE แสดงข้อมูลการนอนและจำนวนก้าวที่นาฬิกาบันทึกเอง รุ่นนี้ไม่มีเซ็นเซอร์วัดอัตราการเต้นของหัวใจ แอปจึงคำนวณภาระร่างกายรายวันหรือประเมินการฟื้นตัวจากข้อมูลของรุ่นนี้ไม่ได้'),
      'zh': ('仅限 Pebble 2。2 SE 没有心率传感器。',
        'Pebble 2 SE 显示手表自身记录的睡眠和步数。它没有心率传感器，因此本应用无法根据它的数据计算每日身体负荷或估算恢复。'),
    };
    expect(AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
        copy.keys.toSet());
    for (final entry in copy.entries) {
      final l = lookupAppLocalizations(Locale(entry.key));
      expect(capabilityReason(l, const CapabilityStatus(CapabilityKind.conditional,
          reasonKey: 'capReasonPebble2Only')), entry.value.$1, reason: entry.key);
      expect(l.pairWearableLeadPebble, endsWith(entry.value.$2), reason: entry.key);
      // Recovery is also an estimate on Pebble 2: its caption keeps both.
      final both = capabilityReason(l, const CapabilityStatus(
          CapabilityKind.conditional, reasonKey: kReasonPebble2OnlyEstimated))!;
      expect(both.toLowerCase(), contains(l.capReasonEstimated.toLowerCase()),
          reason: entry.key);
      expect(both, contains('2 SE'), reason: entry.key);
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('Pebble conditions render and are announced in $locale at 2x text', (t) async {
      final l = lookupAppLocalizations(locale);
      String reason(String key) => capabilityReason(l,
          CapabilityStatus(CapabilityKind.conditional, reasonKey: key))!;
      await pumpPair(t, Scaffold(body: SingleChildScrollView(
          child: SlotTable(comparison: slotComparisonFor(kPebble)))),
          locale: locale, textScale: 2, size: const Size(360, 900));
      for (final (cap, key) in [
        (DeviceCapability.recovery, kReasonPebble2OnlyEstimated),
        (DeviceCapability.strain, kReasonPebble2Only),
        (DeviceCapability.heartRate, kReasonPebble2Only),
      ]) {
        final row = find.byKey(ValueKey('slot-row-${cap.name}'));
        expect(find.descendant(of: row, matching: find.text(
            l.slotColumnReason(l.slotEveryDay, reason(key)))), findsOneWidget);
        final mark = find.byKey(ValueKey('slot-everyDay-${cap.name}'));
        await t.ensureVisible(mark);
        await t.pumpAndSettle();
        expect(t.getSemantics(mark).label, contains(reason(key)));
      }
      expect(t.takeException(), isNull);
    });
  }

  test('every conditional mark in every locale has its caption', () {
    // A check whose condition has no caption would claim more than the device
    // gives. Every registry entry, both columns, every shipped locale.
    var seen = 0;
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final e in kBandRegistry) {
        final cmp = slotComparisonFor(e);
        for (final side in [cmp.everyDay, cmp.workoutsOnly]) {
          for (final MapEntry(key: cap, value: st) in side.sends.entries) {
            if (st.kind != CapabilityKind.conditional) continue;
            seen++;
            final caption = capabilityReason(l, st);
            expect(caption, isNotNull,
                reason: '${e.id} $cap ${st.reasonKey} in $locale has no caption');
            expect(caption!.trim(), isNotEmpty);
          }
        }
      }
    }
    expect(seen, greaterThan(0), reason: 'the registry has conditional marks');
  });
}
