// A non-WHOOP wearable's numbers, served cell by cell off its column of the
// metric x device table (lib/compute/inputs/canonical.dart, PLAN §7).
//
// TWO PRESENTATIONS, one setting, so the UX call can be made on real screens:
// "one number" draws the primary value by Ours > Device > Estimated > Not
// available with a quiet source line, and a tap opens the device's own value;
// "side by side" draws ours and the device's together. Nothing here decides a
// class: the cell arrives with it, and this file only words it.
//
// The device's proprietary scores never get one of our cards. They have no
// slot of ours ([kDeviceValueSlot]) and are drawn only in [WearableDayView]'s
// own-scores section, which is that device's page.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart'
    show DeviceCategory, categoryOf, kBandRegistry, kThermometer;
import '../../ble/session_link.dart' show SessionLink;
import '../../compute/inputs/canonical.dart';
import '../../compute/inputs/validation_bands.dart' show kTruthBandRows;
import '../../data/day_label.dart' show todayLabel;
import '../../data/db.dart' show LocalDb;
import '../../l10n/app_localizations.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'profile.dart';

/// The two presentation settings, read synchronously off [Prefs] and
/// broadcast so an open screen redraws when Settings flips one.
class WearableDisplay extends ChangeNotifier {
  WearableDisplay._();
  static final WearableDisplay instance = WearableDisplay._();

  bool get sideBySide => Prefs.getBool(Prefs.wearableSideBySide, false);
  bool get showEstimates => Prefs.getBool(Prefs.wearableShowEstimates, true);

  void setSideBySide(bool on) {
    Prefs.setBool(Prefs.wearableSideBySide, on);
    notifyListeners();
  }

  void setShowEstimates(bool on) {
    Prefs.setBool(Prefs.wearableShowEstimates, on);
    notifyListeners();
  }

  /// Paired wearables, workout sensors and health-measurement devices with
  /// their rule-R6 flag, for the developer toggles. Empty until [loadDevices] has run.
  /// A workout sensor no workout arms (a Coros watch) is left out: its flag
  /// feeds no number, so a toggle for it would do nothing.
  List<({String id, String adapter, String label, bool on, bool active})>
      devices = const [];

  Future<void> loadDevices() async {
    final active = await activeWearableId();
    devices = [
      for (final r in await LocalDb.deviceRows())
        if (r['adapter_id'] case final String adapter
            when r['id'] != LocalDb.kPrimaryDeviceId &&
                (isWearableRow(r) ||
                    kWorkoutArmedSensors.contains(adapter) ||
                    categoryOf(adapter) == DeviceCategory.healthMeasurement))
          (
            id: r['id'] as String,
            adapter: adapter,
            label: (r['label'] as String?) ?? wearableName(adapter),
            on: await wearableEnabled(adapter),
            active: r['id'] == active,
          ),
    ];
    notifyListeners();
  }

  /// True while a toggle's re-derive runs; the toggles ignore taps then.
  bool busy = false;

  /// Taps one device's toggle and re-derives what that moves. A wearable
  /// that is not the active one is made active (flag on); only the active
  /// wearable turns off. A workout sensor or a scale flips its flag. The flag is per
  /// adapter, so two paired devices of one adapter share it.
  Future<void> toggleDevice(String id, String adapter, bool on, bool active)
      async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      final wearable = categoryOf(adapter) == DeviceCategory.wearable;
      await useDevice(id, adapter, wearable ? !(on && active) : !on);
      // A scale turned on hands its newest weighing to the profile now;
      // turned off, takes back the one it handed over (rule R6).
      if (categoryOf(adapter) == DeviceCategory.healthMeasurement) {
        await SessionLink.onSessionDone?.call();
      }
      await loadDevices();
    } catch (e) {
      // The tap does not await this, so a throw would go unreported and the
      // row would keep the state it had before the tap.
      debugPrint('[devices] toggle $adapter failed: $e');
      try {
        await loadDevices();
      } catch (_) {/* the row keeps its last state */}
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

/// Strings for a widget that may be pumped with no localizations above it:
/// the generated English, never a second copy of it typed here.
AppLocalizations _l(BuildContext c) =>
    AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));

/// The wearable's name as a sentence uses it ("From your Garmin watch").
String wearableName(String adapterId) {
  for (final e in kBandRegistry) {
    if (e.id == adapterId) return e.label;
  }
  return adapterId;
}

/// Skin temperature in centi-°C, our method tags for it.
bool _skinTempMethod(String? method) =>
    method != null && method.startsWith('skin_temp_c_');

/// A row of the table, worded. [method] names what the row holds where a
/// device fills it differently: a ring with no decoded HR keeps its skin
/// temperature baseline in the baselines row.
String rowLabel(AppLocalizations l, String row, {String? method}) =>
    switch (row) {
  'baselines_load_illness' when _skinTempMethod(method) =>
    l.wearableRowSkinTempBaseline,
  'sleep_window' => l.wearableRowSleepWindow,
  'efficiency_awakenings' => l.wearableRowEfficiency,
  'sleep_stages' => l.wearableRowSleepStages,
  'naps' => l.wearableRowNaps,
  'sleep_debt_need_sri' => l.wearableRowSleepDebt,
  'resting_hr' => l.wearableRowRestingHr,
  'nadir_dip' => l.wearableRowNadir,
  'hrv' => l.wearableRowHrv,
  'respiratory_rate' => l.wearableRowRespiratoryRate,
  'spo2' => l.wearableRowSpo2,
  'stress' => l.wearableRowStress,
  'skin_temp' => l.wearableRowSkinTemp,
  'readiness' => l.wearableRowReadiness,
  'irregular_rhythm' => l.wearableRowIrregularRhythm,
  'steps' => l.wearableRowSteps,
  'strain' => l.wearableRowStrain,
  'calories' => l.wearableRowCalories,
  'movement' => l.wearableRowMovement,
  'auto_workouts' => l.wearableRowAutoWorkouts,
  'hrr' => l.wearableRowHrr,
  'workouts_with_strap' => l.wearableRowStrapWorkouts,
  'baselines_load_illness' => l.wearableRowBaselines,
  'circadian' => l.wearableRowCircadian,
  _ => row,
};

/// A device's own score key, worded for its page. A key with no wording
/// yet reads as its own words ("fitness_age" is "Fitness age"), never as the
/// raw key.
String deviceScoreLabel(AppLocalizations l, String key) => switch (key) {
  'sleep_score' => l.wearableScoreSleep,
  'readiness_score' => l.wearableScoreReadiness,
  'body_battery' => l.wearableScoreBodyBattery,
  'impedance' => l.wearableScoreImpedance,
  _ => observationTitle(key),
};

/// A stored device value's name as words ('spo2_avg' is 'Spo2 avg'); a name
/// with no underscore reads verbatim ('BioCharge').
String observationTitle(String name) {
  if (!name.contains('_')) return name;
  final w = name.replaceAll('_', ' ').trim();
  return w.isEmpty ? name : '${w[0].toUpperCase()}${w.substring(1)}';
}

/// A cell's method tag, worded for the source line; null for a tag with no
/// words yet, and the line then names the device alone.
String? methodText(AppLocalizations l, String? method) => switch (method) {
  'hr_1min' => l.wearableMethodHr1min,
  'hr_1hz' => l.wearableMethodStrap,
  'rr_strap' => l.wearableMethodStrapBeats,
  'rr_ring' => l.wearableMethodRingBeats,
  'hr_5min' || 'hr_5min_stager' => l.wearableMethodHr5min,
  'device_stages' => l.wearableMethodDeviceStages,
  'skin_temp_c_5min' ||
  'skin_temp_c_slot' ||
  'skin_temp_c_event' => l.wearableMethodSkinTemp,
  'hr_5min_rest' => l.wearableMethodRest,
  'rhr_only_partial' => l.wearableMethodRhrOnly,
  kPartialReadinessMethod => l.wearableMethodPartialComposite,
  kStrapReadinessMethod => l.wearableMethodRhrStrapComposite,
  'hr_1min_zone_minutes' => l.wearableMethodZoneMinutes,
  'steps_5min' => l.wearableMethodActivity,
  _ => null,
};

/// An unavailable cell's [Why] code, worded with the device's name. An
/// unknown code says only that the value is not available.
String whyText(AppLocalizations l, String? reason, String device) =>
    switch (Why.values.asNameMap()[reason]) {
      null => l.wearableNotAvailable,
      Why.noNight => l.wearableWhyNoNight,
      Why.noStagedNight => l.wearableWhyNoStagedNight(device),
      Why.noMovementData => l.wearableWhyNoMovementData(device),
      Why.needsThreeNights => l.wearableWhyNeedsThreeNights,
      Why.noNightHr => l.wearableWhyNoNightHr,
      Why.noDeviceHrv => l.wearableWhyNoDeviceHrv(device),
      Why.noDeviceResp => l.wearableWhyNoDeviceResp(device),
      Why.noDeviceSpo2 => l.wearableWhyNoDeviceSpo2(device),
      Why.noDeviceStress => l.wearableWhyNoDeviceStress(device),
      Why.skinTempNotDecoded => l.wearableWhySkinTempNotDecoded,
      Why.readinessRhrOnly => l.wearableWhyReadinessRhrOnly(device),
      Why.needsBeats => l.wearableWhyNeedsBeats,
      Why.noDeviceSteps => l.wearableWhyNoDeviceSteps(device),
      Why.noWakeHr => l.wearableWhyNoWakeHr,
      Why.noWakeHrOrProfile => l.wearableWhyNoWakeHrOrProfile,
      Why.needsStrap => l.wearableWhyNeedsStrap,
      Why.needsHistory => l.wearableWhyNeedsHistory,
      Why.needsThreeDaysHr => l.wearableWhyNeedsThreeDaysHr,
      Why.noWake => l.wearableWhyNoWake(device),
      Why.neverBeats => l.wearableWhyNeverBeats(device),
      Why.neverResp => l.wearableWhyNeverResp(device),
      Why.neverSpo2 => l.wearableWhyNeverSpo2(device),
      Why.neverStress => l.wearableWhyNeverStress(device),
      Why.neverSkinTemp => l.wearableWhyNeverSkinTemp(device),
      Why.needsRhrBaseline => l.wearableWhyNeedsRhrBaseline,
      Why.noMovementRecord => l.wearableWhyNoMovementRecord(device),
      Why.noHrDip => l.wearableWhyNoHrDip,
      Why.noNightForNaps => l.wearableWhyNoNightForNaps,
      Why.needsThreeNightsTemp => l.wearableWhyNeedsThreeNightsTemp,
      Why.tooSparseForWorkouts => l.wearableWhyTooSparseForWorkouts,
      Why.noDeviceNap => l.wearableWhyNoDeviceNap(device),
      Why.notDecoded => l.wearableWhyNotDecoded(device),
      Why.beatsNotSeparated => l.wearableWhyBeatsNotSeparated(device),
      Why.noNightReading => l.wearableWhyNoNightReading(device),
    };

/// [v] in [row]'s unit, as (number, unit). [device] marks the device's own
/// value where its unit differs from ours: skin temperature is ours as a
/// deviation and the device's in °C.
(String, String) formatCell(
  AppLocalizations l,
  String row,
  num v, {
  String? method,
  bool device = false,
}) {
  String int0(num x) => x.round().toString();
  String fixed1(num x) => x.toStringAsFixed(1);
  return switch (row) {
    'sleep_window' || 'sleep_stages' || 'naps' => (axisHm(v.toDouble()), ''),
    'efficiency_awakenings' || 'spo2' => (int0(v), l.wearableUnitPct),
    'sleep_debt_need_sri' => (fixed1(v), l.wearableUnitHours),
    'baselines_load_illness' when _skinTempMethod(method) => (
        fixed1(v / 100),
        l.wearableUnitCelsius,
      ),
    'resting_hr' ||
    'nadir_dip' ||
    'hrr' ||
    'baselines_load_illness' => (int0(v), l.wearableUnitBpm),
    'hrv' => (int0(v), l.wearableUnitMs),
    'respiratory_rate' => (fixed1(v), l.wearableUnitBrMin),
    'skin_temp' => device
        ? (fixed1(v), l.wearableUnitCelsius)
        : ('${v > 0 ? '+' : ''}${fixed1(v)}', l.wearableUnitSd),
    'strain' => (fixed1(v), ''),
    'calories' => (int0(v), l.wearableUnitKcal),
    // A ring's movement is the share of the night's records with steps in
    // them; a watch's is minutes in a heart-rate zone.
    'movement' => method == 'steps_5min'
        ? (int0(v * 100), l.wearableUnitPct)
        : (int0(v), l.wearableUnitMin),
    // Hours after midnight, as a clock time.
    'circadian' => () {
      final m = (v * 60).round() % (24 * 60);
      return ('${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}', '');
    }(),
    _ => (int0(v), ''),
  };
}

/// The confidence line for a cell whose method has a measured [band]
/// (`validation_bands.dart`), in the row's unit; null with none.
String? bandText(AppLocalizations l, String row, num? band) {
  if (band == null) return null;
  final (n, unit) = formatCell(l, row, band);
  final text = unit.isEmpty ? n : '$n $unit';
  // Readiness is banded only as the partial score, against the same partial
  // score at 1 Hz, never against the full composite.
  return row == 'readiness'
      ? l.wearableBandPartial(text)
      : kTruthBandRows.contains(row)
      ? l.wearableBandTruth(text)
      : l.wearableBand(text);
}

/// The quiet line under a value: whose number it is and what it came from.
String sourceLine(AppLocalizations l, MetricClass cls, String? method,
    String device) {
  final how = methodText(l, method);
  return switch (cls) {
    // A strap measured it, not the wearable: the strap gets the credit.
    MetricClass.ours when how != null &&
            (method == 'hr_1hz' || method == 'rr_strap') =>
        l.wearableSourceStrap(how),
    MetricClass.ours => how == null
        ? l.wearableSourceOursPlain(device)
        : l.wearableSourceOurs(device, how),
    MetricClass.device => l.wearableSourceDevice(device),
    MetricClass.estimated => how == null
        ? l.wearableSourceEstimatedPlain(device)
        : l.wearableSourceEstimated(device, how),
    MetricClass.unavailable => l.wearableNotAvailable,
  };
}

MetricClass _classOf(Map<String, Object?> cell) =>
    MetricClass.values.asNameMap()[cell['class']] ?? MetricClass.unavailable;

/// One row of the table for one day, in either presentation. [cell] is a
/// value of `dayCells`: `class`, `value`, `method`, and `device_value` /
/// `reason` where they apply.
class WearableCell extends StatelessWidget {
  final String row;
  final Map<String, Object?> cell;

  /// The wearable's name, as [wearableName] gives it.
  final String device;
  final bool sideBySide, showEstimates;

  const WearableCell(
    this.row,
    this.cell, {
    super.key,
    required this.device,
    this.sideBySide = false,
    this.showEstimates = true,
  });

  @override
  Widget build(BuildContext c) {
    final l = _l(c);
    final cls = _classOf(cell);
    final method = cell['method'] as String?;
    final label = rowLabel(l, row, method: method);
    // An estimate the person chose not to see is still not a measurement:
    // it says so, rather than vanishing as if the row did not exist.
    if (cls == MetricClass.estimated && !showEstimates) {
      return StatusCard(label, l.wearableWhyEstimateHidden);
    }
    if (cls == MetricClass.unavailable) {
      return StatusCard(label, whyText(l, cell['reason'] as String?, device));
    }
    final value = cell['value'] as num;
    // The device's own number: beside ours, or the primary when it is all
    // there is.
    final devValue = cls == MetricClass.device
        ? value
        : cell['device_value'] as num?;
    return sideBySide
        ? _SideBySide(
            label: label,
            ours: cls == MetricClass.device
                ? null
                : formatCell(l, row, value, method: method),
            estimated: cls == MetricClass.estimated,
            provisional: cell['provisional'] == true,
            deviceValue: devValue == null
                ? null
                : formatCell(l, row, devValue, device: true),
            device: device,
            // How ours was made (its source line and band) is on the detail.
            onTap: () => showWearableDetail(c,
                row: row, cell: cell, device: device),
          )
        : _OneNumber(
            label: label,
            value: formatCell(l, row, value,
                method: method, device: cls == MetricClass.device),
            estimated: cls == MetricClass.estimated,
            provisional: cell['provisional'] == true,
            source: sourceLine(l, cls, method, device),
            onTap: () => showWearableDetail(c,
                row: row, cell: cell, device: device),
          );
  }
}

class _OneNumber extends StatelessWidget {
  final String label, source;
  final (String, String) value;
  final bool estimated;

  /// Ours, resting on a calibration not yet measured on real nights.
  final bool provisional;
  final VoidCallback onTap;

  const _OneNumber({
    required this.label,
    required this.value,
    required this.estimated,
    this.provisional = false,
    required this.source,
    required this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = _l(c);
    return Surface(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(label, style: F.cap.copyWith(color: p.ink2))),
          if (estimated) Pill(l.wearableEstimated, C.orange),
          if (provisional) Pill(l.wearableProvisional, C.orange),
        ]),
        const SizedBox(height: S.x1),
        _Value(value),
        const SizedBox(height: S.x1),
        Text(source, style: F.cap.copyWith(color: p.ink3)),
      ]),
    );
  }
}

class _SideBySide extends StatelessWidget {
  final String label, device;
  final (String, String)? ours, deviceValue;
  final bool estimated, provisional;
  final VoidCallback onTap;

  const _SideBySide({
    required this.label,
    required this.ours,
    required this.estimated,
    this.provisional = false,
    required this.deviceValue,
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = _l(c);
    Widget side(String who, (String, String)? v) => Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(who, style: F.cap.copyWith(color: p.ink3)),
                const SizedBox(height: S.x1),
                v == null
                    ? Text(l.wearableNotAvailable,
                        style: F.body.copyWith(color: p.ink3))
                    : _Value(v),
              ]),
        );
    return Surface(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(label, style: F.cap.copyWith(color: p.ink2))),
          if (estimated) Pill(l.wearableEstimated, C.orange),
          if (provisional) Pill(l.wearableProvisional, C.orange),
        ]),
        const SizedBox(height: S.x2),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          side(l.wearableOurs, ours),
          const SizedBox(width: S.x4),
          side(device, deviceValue),
        ]),
      ]),
    );
  }
}

class _Value extends StatelessWidget {
  final (String, String) v;
  const _Value(this.v);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final (n, unit) = v;
    return Text.rich(TextSpan(children: [
      TextSpan(text: n, style: F.n24.copyWith(color: p.ink)),
      if (unit.isNotEmpty)
        TextSpan(text: ' $unit', style: F.cap.copyWith(color: p.ink3)),
    ]));
  }
}

/// The detail behind a "one number" card: ours (or whatever served the
/// slot) with its source line, then the device's own value, or a line that
/// it gave none.
Future<void> showWearableDetail(
  BuildContext c, {
  required String row,
  required Map<String, Object?> cell,
  required String device,
}) =>
    showModalBottomSheet<void>(
      context: c,
      backgroundColor: P.of(c).card,
      builder: (c) => WearableDetail(row: row, cell: cell, device: device),
    );

class WearableDetail extends StatelessWidget {
  final String row, device;
  final Map<String, Object?> cell;

  const WearableDetail({
    super.key,
    required this.row,
    required this.cell,
    required this.device,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = _l(c);
    final cls = _classOf(cell);
    final method = cell['method'] as String?;
    final value = cell['value'] as num?;
    final devValue =
        cls == MetricClass.device ? value : cell['device_value'] as num?;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(S.x5),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rowLabel(l, row, method: method),
                  style: F.head.copyWith(color: p.ink)),
              if (value != null && cls != MetricClass.device) ...[
                const SizedBox(height: S.x4),
                _Value(formatCell(l, row, value, method: method)),
                const SizedBox(height: S.x1),
                Text(sourceLine(l, cls, method, device),
                    style: F.cap.copyWith(color: p.ink3)),
                if (bandText(l, row, cell['band'] as num?) case final b?) ...[
                  const SizedBox(height: S.x1),
                  Text(b, style: F.cap.copyWith(color: p.ink3)),
                ],
              ],
              const SizedBox(height: S.x5),
              Text(l.wearableDetailDeviceSays(device),
                  style: F.cap.copyWith(color: p.ink2)),
              const SizedBox(height: S.x1),
              devValue == null
                  ? Text(l.wearableDetailNoDeviceValue(device),
                      style: F.body.copyWith(color: p.ink3))
                  : _Value(formatCell(l, row, devValue, device: true)),
            ]),
      ),
    );
  }
}

/// What a wearable unlocks, before pairing: its column's best class per row
/// ([capabilities]), grouped. Read off the table, so a row that moves class
/// there moves here with no copy to edit. Nothing for a device with no
/// column, nor outside developer mode: every wearable is behind its flag
/// (R6) until a real-hardware sync, and only a developer can turn one on.
///
/// [always] shows it outside developer mode too: under a paired device's
/// own "use this device" switch, where anyone can now turn it on.
class WearableUnlocks extends StatelessWidget {
  final String adapterId;
  final bool always;
  const WearableUnlocks(this.adapterId, {super.key, this.always = false});

  @override
  Widget build(BuildContext c) {
    final column = columnFor(adapterId);
    if (column == null || !(always || Prefs.getBool(Prefs.devMode, false))) {
      return const SizedBox.shrink();
    }
    final p = P.of(c);
    final l = _l(c);
    final caps = capabilities(column);
    // A row the wearable alone cannot serve but a strap session does (§3b:
    // ours, strap only) is its own group, not "not available".
    bool withStrap(String row) =>
        caps[row] == MetricClass.unavailable &&
        column[row]!.reason == Why.needsStrap;
    final groups = [
      (l.wearableUnlocksOurs, C.green, (String r) => caps[r] == MetricClass.ours),
      (l.wearableUnlocksStrap, C.green, withStrap),
      (l.wearableUnlocksDevice, C.blue,
          (String r) => caps[r] == MetricClass.device),
      (l.wearableUnlocksEstimated, C.orange,
          (String r) => caps[r] == MetricClass.estimated),
      (l.wearableUnlocksNone, C.n500,
          (String r) => caps[r] == MetricClass.unavailable && !withStrap(r)),
    ];
    return Section(
      l.wearableUnlocksTitle,
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (title, color, inGroup) in groups)
            if (caps.keys.any(inGroup)) ...[
              Text(title, style: F.cap.copyWith(color: p.on(color))),
              const SizedBox(height: S.x1),
              Text(
                [
                  for (final row in caps.keys)
                    if (inGroup(row))
                      rowLabel(l, row, method: column[row]!.ourMethod),
                ]
                    .join(', '),
                style: F.body.copyWith(color: p.ink),
              ),
              const SizedBox(height: S.x3),
            ],
        ]),
      ),
    );
  }
}

/// The rows a Home card and the Health tab draw off the active wearable.
const List<String> kHomeWearableRows = [
  'readiness',
  'sleep_window',
  'strain',
  'resting_hr',
  'steps',
  'calories',
];
const List<String> kHealthWearableRows = [
  'resting_hr',
  'nadir_dip',
  'hrv',
  'respiratory_rate',
  'spo2',
  'skin_temp',
  'stress',
  'irregular_rhythm',
];

/// The active wearable's [rows] for [date] (today when null), as a card on
/// Home or the Health tab. Nothing on an install with no active wearable,
/// which is every WHOOP-only one, so those screens do not change there.
class WearableCells extends StatefulWidget {
  final List<String> rows;
  final String? date;
  const WearableCells(this.rows, {super.key, this.date});

  @override
  State<WearableCells> createState() => _WearableCellsState();
}

class _WearableCellsState extends State<WearableCells> with RevisionReload {
  String? _device;
  Map<String, Map<String, Object?>> _cells = const {};

  @override
  void initState() {
    super.initState();
    // A developer toggle can switch or turn off the wearable without a
    // derive (none of its days are its own), so a toggle re-reads too.
    WearableDisplay.instance.addListener(reload);
    reload();
  }

  @override
  void dispose() {
    WearableDisplay.instance.removeListener(reload);
    super.dispose();
  }

  @override
  void didUpdateWidget(WearableCells old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date) reload();
  }

  @override
  Future<void> reload() async {
    final t = beginRead(#cells);
    try {
      final w = await activeWearable();
      final cells =
          w == null ? null : await dayCells(widget.date ?? todayLabel());
      if (stillNewest(#cells, t)) {
        setState(() => (
              _device = w == null ? null : wearableName(w.$2),
              _cells = cells ?? const {},
            ));
      }
    } catch (_) {
      // A read that fails draws nothing extra; the screen around it stands.
      if (stillNewest(#cells, t)) {
        setState(() => (_device = null, _cells = const {}));
      }
    }
  }

  @override
  Widget build(BuildContext c) => _device == null
      ? const SizedBox.shrink()
      : ListenableBuilder(
          listenable: WearableDisplay.instance,
          builder: (c, _) => WearableCellsCard(
            device: _device!,
            rows: widget.rows,
            cells: _cells,
            sideBySide: WearableDisplay.instance.sideBySide,
            showEstimates: WearableDisplay.instance.showEstimates,
          ),
        );
}

/// The pure half of [WearableCells]: [rows] of [cells], in that order, under
/// the wearable's name. A row the column does not have is skipped.
class WearableCellsCard extends StatelessWidget {
  final String device;
  final List<String> rows;
  final Map<String, Map<String, Object?>> cells;
  final bool sideBySide, showEstimates;

  const WearableCellsCard({
    super.key,
    required this.device,
    required this.rows,
    required this.cells,
    this.sideBySide = false,
    this.showEstimates = true,
  });

  @override
  Widget build(BuildContext c) {
    final shown = [for (final r in rows) if (cells[r] != null) r];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Section(
      device,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final r in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: S.x3),
            child: WearableCell(r, cells[r]!,
                device: device,
                sideBySide: sideBySide,
                showEstimates: showEstimates),
          ),
      ]),
    );
  }
}

/// The two presentation settings as a settings group.
Widget wearableSettingsGroup(BuildContext c) => ListenableBuilder(
      listenable: WearableDisplay.instance,
      builder: (c, _) {
        final l = _l(c);
        final d = WearableDisplay.instance;
        return settingsGroup(c, l.wearableSettingsGroup, [
          SetRow(LucideIcons.columns2, C.indigo, l.wearablePresentationRowTitle,
              sub: l.wearablePresentationRowSub,
              value: d.sideBySide
                  ? l.wearablePresentationSideBySide
                  : l.wearablePresentationOneNumber,
              chevron: false,
              onTap: () => d.setSideBySide(!d.sideBySide)),
          SetRow(LucideIcons.sparkles, C.orange, l.wearableEstimatesRowTitle,
              sub: l.wearableEstimatesRowSub,
              value: d.showEstimates ? l.stateOn : l.stateOff,
              chevron: false,
              onTap: () => d.setShowEstimates(!d.showEstimates)),
          // Rule R6: each wearable/sensor is off until a developer turns it
          // on here. On a wearable this also makes it the active one.
          for (final w in d.devices)
            SetRow(LucideIcons.watch, C.green, w.label,
                sub: l.wearableFlagRowSub,
                value: w.active && w.on
                    ? l.wearableFlagActive
                    : (w.on ? l.stateOn : l.stateOff),
                chevron: false,
                onTap: d.busy
                    ? null
                    : () => d.toggleDevice(w.id, w.adapter, w.on, w.active)),
        ]);
      },
    );

/// The user-facing beta switch on a paired device's page: the same rule-R6
/// flag the developer toggles flip ([WearableDisplay.toggleDevice]), so the
/// two stay in step. A wearable with a column scores; a workout-armed sensor
/// is used during workouts; a scale's weighings feed the profile. Nothing for
/// anything else (a WHOOP band, a thermometer, a Coros watch): its flag feeds
/// no number.
class DeviceUseSwitch extends StatefulWidget {
  final String deviceId, adapterId;
  const DeviceUseSwitch(
      {super.key, required this.deviceId, required this.adapterId});

  @override
  State<DeviceUseSwitch> createState() => _DeviceUseSwitchState();
}

class _DeviceUseSwitchState extends State<DeviceUseSwitch> {
  @override
  void initState() {
    super.initState();
    WearableDisplay.instance.loadDevices().catchError((Object _) {});
  }

  String? _title(AppLocalizations l) {
    final a = widget.adapterId;
    if (categoryOf(a) == DeviceCategory.wearable) {
      return columnFor(a) == null ? null : l.deviceUseScoresTitle;
    }
    if (kWorkoutArmedSensors.contains(a)) return l.deviceUseWorkoutsTitle;
    if (categoryOf(a) == DeviceCategory.healthMeasurement &&
        a != kThermometer.id) {
      return l.deviceUseReadingsTitle;
    }
    return null;
  }

  Future<void> _set(bool on) async {
    final d = WearableDisplay.instance;
    final w = d.devices.where((w) => w.id == widget.deviceId).firstOrNull;
    if (w == null || d.busy) return;
    final wearable = categoryOf(w.adapter) == DeviceCategory.wearable;
    if (on && wearable) {
      final other = d.devices
          .where((o) => o.active && o.on && o.id != w.id)
          .firstOrNull;
      if (!await _confirmUse(context, w.label, other?.label)) return;
    }
    await d.toggleDevice(w.id, w.adapter, w.on, w.active);
  }

  @override
  Widget build(BuildContext c) {
    final l = _l(c);
    final title = _title(l);
    if (title == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: WearableDisplay.instance,
      builder: (c, _) {
        final p = P.of(c);
        final d = WearableDisplay.instance;
        final w = d.devices.where((w) => w.id == widget.deviceId).firstOrNull;
        if (w == null) return const SizedBox.shrink();
        final wearable = categoryOf(w.adapter) == DeviceCategory.wearable;
        final on = wearable ? w.on && w.active : w.on;
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
          Surface(
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Wrap(
                      spacing: S.x2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: F.body.copyWith(color: p.ink)),
                        Pill(l.deviceUseBeta, C.orange),
                      ]),
                  const SizedBox(height: S.x1),
                  Text(d.busy ? l.deviceUseWorking : l.deviceUseBetaSub,
                      style: F.over.copyWith(color: p.ink3)),
                ]),
              ),
              const SizedBox(width: S.x3),
              d.busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Switch(value: on, onChanged: _set),
            ]),
          ),
          if (wearable) ...[
            const SizedBox(height: S.x5),
            WearableUnlocks(w.adapter, always: true),
          ],
        ]),
        );
      },
    );
  }
}

/// The confirm before a wearable starts scoring: what changes, that [other]
/// (the wearable scoring now, if any) stops, and that it can be undone.
Future<bool> _confirmUse(BuildContext c, String device, String? other) async {
  final l = _l(c);
  final ok = await showModalBottomSheet<bool>(
    context: c,
    sheetAnimationStyle: sheetMotion(c),
    // Scrolls rather than overflows: three paragraphs at a large text size
    // outgrow the default half-height sheet.
    isScrollControlled: true,
    backgroundColor: P.of(c).card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
    ),
    builder: (s) {
      final p = P.of(s);
      final body = F.cap.copyWith(color: p.ink2, height: 1.5);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(S.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.deviceUseSheetTitle(device),
                  style: F.head.copyWith(color: p.ink)),
              const SizedBox(height: S.x2),
              Text(l.deviceUseSheetWhat, style: body),
              if (other != null) ...[
                const SizedBox(height: S.x2),
                Text(l.deviceUseSheetSwitch(other), style: body),
              ],
              const SizedBox(height: S.x2),
              Text(l.deviceUseSheetOff, style: body),
              const SizedBox(height: S.x5),
              BigButton(l.deviceUseSheetConfirm,
                  onTap: () => Navigator.of(s).pop(true)),
              const SizedBox(height: S.x3),
              BigButton(l.deviceUseSheetCancel,
                  soft: true, onTap: () => Navigator.of(s).pop(false)),
            ],
          ),
        ),
      );
    },
  );
  return ok == true;
}

/// One wearable's numbers for today, reached from its device page. Only the
/// ACTIVE wearable serves cells (`dayCells`); any other says so.
class WearableDayScreen extends StatefulWidget {
  final String deviceId, adapterId;
  const WearableDayScreen(
      {super.key, required this.deviceId, required this.adapterId});

  @override
  State<WearableDayScreen> createState() => _WearableDayScreenState();
}

class _WearableDayScreenState extends State<WearableDayScreen> {
  bool _loaded = false, _active = false, _hasDay = false, _bandDay = false;
  Map<String, Map<String, Object?>> _cells = const {};
  Map<String, ({num value, String? unit})> _scores = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final date = todayLabel();
    final active = (await activeWearable())?.$1 == widget.deviceId;
    final cells = active ? await dayCells(date) : null;
    // A day the band covered is stored, but not this wearable's: no cells,
    // so it reads as no day from this wearable rather than a blank page. A
    // watch with no HR sensor derives no day, but its own values still serve.
    final hasDay = cells != null &&
        (await LocalDb.dayResult(date) != null ||
            cells.values.any((c) => c['value'] != null));
    // The band's day never becomes this wearable's: say so, not "yet".
    final bandDay = active && cells == null && await bandHasDay(date);
    final scores = await deviceOwnScores(widget.deviceId, date);
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _active = active;
      _hasDay = hasDay;
      _bandDay = bandDay;
      _cells = cells ?? const {};
      _scores = scores;
    });
  }

  /// Developer only: make this the active wearable with its flag on (rule
  /// R6 keeps it off for everyone else until a real-hardware sync).
  Future<void> _use() async {
    await useDevice(widget.deviceId, widget.adapterId, true);
    await WearableDisplay.instance.loadDevices();
    await _load();
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: WearableDisplay.instance,
        builder: (c, _) => WearableDayView(
          device: wearableName(widget.adapterId),
          loaded: _loaded,
          active: _active,
          hasDay: _hasDay,
          bandDay: _bandDay,
          cells: _cells,
          scores: _scores,
          sideBySide: WearableDisplay.instance.sideBySide,
          showEstimates: WearableDisplay.instance.showEstimates,
          onUse: Prefs.getBool(Prefs.devMode, false) ? _use : null,
        ),
      );
}

/// The pure half of [WearableDayScreen].
class WearableDayView extends StatelessWidget {
  final String device;
  final bool loaded, active, hasDay, sideBySide, showEstimates;

  /// The band has this day ([bandHasDay]), so no day from this wearable
  /// is coming for it.
  final bool bandDay;
  final Map<String, Map<String, Object?>> cells;

  /// The device's own scores, which have no slot of ours: drawn here, on
  /// its page, and nowhere else.
  final Map<String, ({num value, String? unit})> scores;
  final VoidCallback? onUse;

  const WearableDayView({
    super.key,
    required this.device,
    this.loaded = true,
    this.active = true,
    this.hasDay = true,
    this.bandDay = false,
    this.cells = const {},
    this.scores = const {},
    this.sideBySide = false,
    this.showEstimates = true,
    this.onUse,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = _l(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l.wearableDayTitle, sub: device),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (!loaded)
                  const SizedBox.shrink()
                else if (!active)
                  StatusCard(l.wearableNotActiveTitle, l.wearableNotActiveWhy,
                      fix: onUse == null ? '' : l.wearableUseThis,
                      onFix: onUse)
                else if (!hasDay && bandDay)
                  StatusCard(l.wearableBandDayTitle, l.wearableBandDayWhy)
                else if (!hasDay)
                  StatusCard(l.wearableNoDayTitle, l.wearableNoDayWhy)
                else
                  for (final MapEntry(key: row, value: cell) in cells.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: S.x3),
                      child: WearableCell(row, cell,
                          device: device,
                          sideBySide: sideBySide,
                          showEstimates: showEstimates),
                    ),
                if (scores.isNotEmpty)
                  Section(
                    l.wearableScoresTitle(device),
                    Surface(
                      child: Column(children: [
                        for (final MapEntry(key: k, value: v)
                            in scores.entries)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: S.x1),
                            child: Row(children: [
                              // The device's own number, under its own
                              // name, worded ([deviceScoreLabel]).
                              Expanded(
                                  child: Text(deviceScoreLabel(l, k),
                                      style:
                                          F.body.copyWith(color: p.ink2))),
                              _Value((
                                v.value is int
                                    ? '${v.value}'
                                    : v.value.toStringAsFixed(1),
                                v.unit ?? '',
                              )),
                            ]),
                          ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
