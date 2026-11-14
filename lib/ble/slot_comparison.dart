// What a device gives in each of the two columns the pairing screens draw:
// "Every day" (the main band, or the active wearable that fills the days the
// band left empty) and "Workouts only" (a workout-armed sensor). Capabilities
// come from the compute layer's eligibility rules, never from raw-signal
// membership.
import '../compute/inputs/canonical.dart'
    show Cell, MetricClass, capabilities, columnFor, kWorkoutArmedSensors;
import 'adapters/_registry.dart';

/// The two columns. A WHOOP fills [everyDay] as the main band; a ring or a
/// watch fills it as the active wearable (canonical.dart `activeWearable`,
/// `wearableSubstrate`); a workout-armed sensor fills [workoutsOnly].
enum DeviceSlot { everyDay, workoutsOnly }

enum DeviceCapability {
  sleep,
  recovery,
  strain,

  /// Heart rate and resting heart rate (the column's `resting_hr` row).
  heartRate,
  hrv,
  respiration,
  skinTemperature,
  steps,
  bloodOxygen,
  workoutHeartRate,
  workoutBeatToBeat,
}

/// How a capability is delivered.
/// native: this app computes it. conditional: only when [CapabilityStatus.reasonKey]
/// holds (an l10n-able key). vendorReported: the device's own number, shown as
/// the device's (never passed off as native).
enum CapabilityKind { native, conditional, vendorReported }

class CapabilityStatus {
  final CapabilityKind kind;

  /// Required (nonblank) when [kind] is conditional, else null.
  final String? reasonKey;
  const CapabilityStatus(this.kind, {this.reasonKey});
}

class SlotSide {
  final Map<DeviceCapability, CapabilityStatus> sends;

  /// The table's rows ([kTableRows]) this side does not send.
  final Set<DeviceCapability> doesNotSend;
  const SlotSide({required this.sends, required this.doesNotSend});
}

class SlotComparison {
  /// What the entry gives every day: as the main band (a WHOOP) or as the
  /// active wearable (a columned ring or watch). Empty for a chest strap.
  final SlotSide everyDay;

  /// What the entry gives during workouts as a workout-armed sensor (a WHOOP
  /// kept for workouts is read as one). Empty for a ring.
  final SlotSide workoutsOnly;

  /// The column the device goes into, or null when it fits neither (a Coros
  /// watch, a scale).
  final DeviceSlot? slot;
  const SlotComparison(
      {required this.everyDay, required this.workoutsOnly, this.slot});

  SlotSide side(DeviceSlot s) => switch (s) {
    DeviceSlot.everyDay => everyDay,
    DeviceSlot.workoutsOnly => workoutsOnly,
  };
}

/// The whole-day rows of the table, in the order they are drawn.
const List<DeviceCapability> kDayCapabilities = <DeviceCapability>[
  DeviceCapability.sleep,
  DeviceCapability.recovery,
  DeviceCapability.strain,
  DeviceCapability.heartRate,
  DeviceCapability.hrv,
  DeviceCapability.respiration,
  DeviceCapability.skinTemperature,
  DeviceCapability.steps,
];

/// Capabilities decided per workout session, not per day: the band records a
/// workout itself; a sensor only through the sensor path
/// (`kWorkoutArmedSensors`, canonical.dart; `HrsLink.deriveTier`).
const Set<DeviceCapability> kSessionCapabilities = <DeviceCapability>{
  DeviceCapability.workoutHeartRate,
  DeviceCapability.workoutBeatToBeat,
};

/// Every row the table draws: the whole-day rows, then the workout rows.
/// Blood oxygen is never one of them.
const List<DeviceCapability> kTableRows = <DeviceCapability>[
  ...kDayCapabilities,
  DeviceCapability.workoutHeartRate,
  DeviceCapability.workoutBeatToBeat,
];

/// THE mapping from a whole-day capability to its row in the compute layer's
/// metric x device columns (`columnFor`, compute/inputs/canonical.dart). A
/// capability's status for a wearable is read off `capabilities(column)[row]`.
const Map<DeviceCapability, String> kCapabilityRow = <DeviceCapability, String>{
  DeviceCapability.sleep: 'sleep_window',
  DeviceCapability.recovery: 'readiness',
  DeviceCapability.strain: 'strain',
  DeviceCapability.heartRate: 'resting_hr',
  DeviceCapability.hrv: 'hrv',
  DeviceCapability.respiration: 'respiratory_rate',
  DeviceCapability.skinTemperature: 'skin_temp',
  DeviceCapability.steps: 'steps',
};

// Blood oxygen is never claimed by a pairing comparison, for any device: the
// app refuses its own SpO2 (onehz_pipeline.dart kSpo2Refusal), and a vendor's
// reading is not a promise made at pairing. It is not in [kCapabilityRow].
// (The enum value and its label stay so the absence can be asserted.)

/// Where a claimed capability comes from: [rule] names the eligibility rule,
/// [source] is the repo file that holds it.
typedef CapabilityTrace = ({String rule, String source});

/// l10n keys (lib/l10n/app_*.arb) of the one-line captions a conditional
/// capability carries.
const String kReasonSkinTempNights = 'capReasonSkinTempNights';

// Ring settle bands use synthetic nights (oura_inputs.dart), so waiting
// for the minimum nights does not remove their provisional status.
const String kReasonSkinTempProvisional = 'capReasonSkinTempProvisional';
const String kReasonEstimated = 'capReasonEstimated';
const String kReasonEarly = 'capReasonEarly';

/// A wearable's readiness is provisional until its inputs have 14 nights of
/// baseline (oura_inputs.dart `readiness`, onehz_pipeline.dart
/// kSkinTempDevMinNights).
const String kReasonFirstNights = 'capReasonFirstNights';

/// A wearable's sleep window is ours, its stages the device's own
/// (`sleep_stages` is a device-only row).
const String kReasonOwnStagesRing = 'capReasonOwnStagesRing';
const String kReasonOwnStages = 'capReasonOwnStages';

/// WHOOP 4 has no step counter: its steps come from the strap's 100 Hz
/// pedometer over a live link only (live_step_runs.dart).
const String kReasonLiveSessions = 'capReasonLiveSessions';

/// A row that depends on whether the device sends it, where nobody has
/// confirmed it does: RR intervals are optional in the Heart Rate Service, so
/// a generic strap's (or a WHOOP read as one) beat timing is unconfirmed. A
/// device people use and send it (Polar's PPI stream) carries no caption.
const String kReasonUnconfirmed = 'capReasonUnconfirmed';

/// Pebble 2 SE has no HR sensor; only Pebble 2 can supply HR-based rows.
const String kReasonPebble2Only = 'capReasonPebble2Only';

/// [kReasonPebble2Only] on a row that is also an estimate on Pebble 2.
const String kReasonPebble2OnlyEstimated = 'capReasonPebble2OnlyEstimated';

/// l10n key of each capability's user-facing name.
const Map<DeviceCapability, String> kCapabilityLabelKey = <DeviceCapability, String>{
  DeviceCapability.sleep: 'capLabelSleep',
  DeviceCapability.recovery: 'capLabelRecovery',
  DeviceCapability.strain: 'capLabelStrain',
  DeviceCapability.heartRate: 'capLabelHeartRate',
  DeviceCapability.hrv: 'capLabelHrv',
  DeviceCapability.respiration: 'capLabelRespiration',
  DeviceCapability.skinTemperature: 'capLabelSkinTemperature',
  DeviceCapability.steps: 'capLabelSteps',
  DeviceCapability.bloodOxygen: 'capLabelBloodOxygen',
  DeviceCapability.workoutHeartRate: 'capLabelWorkoutHeartRate',
  DeviceCapability.workoutBeatToBeat: 'capLabelWorkoutBeatToBeat',
};

typedef _Claim = ({CapabilityStatus status, CapabilityTrace trace});

const String _canonical = 'lib/compute/inputs/canonical.dart';
const String _pipeline = 'lib/compute/onehz_pipeline.dart';
const String _engine = 'lib/compute/derivation_engine.dart';

const CapabilityStatus _native = CapabilityStatus(CapabilityKind.native);

CapabilityStatus _when(String reasonKey) =>
    CapabilityStatus(CapabilityKind.conditional, reasonKey: reasonKey);

bool _nativeWhoop(BandEntry e) => kWhoopGen4.id == e.id || kWhoopGen5.id == e.id;

/// The column [e] goes into, or null when it fits neither.
DeviceSlot? _slotOf(BandEntry e) {
  if (_nativeWhoop(e)) return DeviceSlot.everyDay;
  if (e.category == DeviceCategory.wearable && columnFor(e.id) != null) {
    return DeviceSlot.everyDay;
  }
  if (kWorkoutArmedSensors.contains(e.id)) return DeviceSlot.workoutsOnly;
  return null;
}

/// Every capability [e] gives in [slot], each with the rule behind it. The one
/// place claims are made, so a claim cannot exist without its trace.
Map<DeviceCapability, _Claim> _claims(BandEntry e, DeviceSlot slot,
    {bool modelKnown = true}) =>
    switch (slot) {
      DeviceSlot.everyDay => _everyDayClaims(e, modelKnown: modelKnown),
      DeviceSlot.workoutsOnly => _workoutClaims(e),
    };

Map<DeviceCapability, _Claim> _everyDayClaims(BandEntry e,
    {bool modelKnown = true}) {
  if (!_nativeWhoop(e)) {
    // The active wearable: its column's rows, behind its own switch. Coros has
    // no column (and wearableEnabled() is false for it): nothing.
    return e.category == DeviceCategory.wearable ? _columnClaims(e) : {};
  }
  // The native pipeline (onehz_pipeline.dart): sleep, rmssd, resting HR,
  // respiration, strain, readiness. Skin temperature needs a nightly mean,
  // >= 3 prior nights and a baseline spread >= 1; WHOOP 5's deg C needs 14.
  final out = <DeviceCapability, _Claim>{
    for (final c in kDayCapabilities)
      c: (
        status: c == DeviceCapability.skinTemperature
            ? _when(kReasonSkinTempNights)
            : _native,
        trace: (rule: 'native WHOOP pipeline (${c.name})', source: _pipeline),
      ),
  };
  // Steps: WHOOP 5's cumulative on-chip counter rides every synced row;
  // WHOOP 4 has none (derivation_engine.dart _stepCounterModulus), so only
  // the live link's 100 Hz pedometer counts for it.
  out[DeviceCapability.steps] = (
    status: !modelKnown
        ? _when(kReasonUnconfirmed)
        : e.id == kWhoopGen5.id ? _native : _when(kReasonLiveSessions),
    trace: (rule: 'band steps (counter or live pedometer)', source: _engine),
  );
  // The band records a workout itself.
  for (final c in kSessionCapabilities) {
    out[c] = (status: _native, trace: (rule: 'band workout session', source: _pipeline));
  }
  return out;
}

Map<DeviceCapability, _Claim> _workoutClaims(BandEntry e) {
  // Only the sensors in kWorkoutArmedSensors (ble_hrs, polar_pmd) are session
  // sources, and only with their switch on. A WHOOP kept for workouts is
  // paired under ble_hrs, so it gets ble_hrs's claims. Anything else (a ring,
  // Coros) sends nothing here.
  final slotId = _nativeWhoop(e) ? kBleHrs.id : e.id;
  if (!kWorkoutArmedSensors.contains(slotId)) return {};
  final out = <DeviceCapability, _Claim>{};
  final sig = declaredSignals(slotId).map((s) => s.name).toSet();
  const trace = (
    rule: 'workout session sensor (kWorkoutArmedSensors, flag on)',
    source: _canonical,
  );
  if (sig.contains('hr1Hz') || sig.contains('hrSparse')) {
    out[DeviceCapability.workoutHeartRate] = (status: _native, trace: trace);
  }
  if (sig.contains('rrIntervals')) {
    out[DeviceCapability.workoutBeatToBeat] = (
      status: slotId != kBleHrs.id ? _native : _when(kReasonUnconfirmed),
      trace: trace,
    );
  }
  return out;
}

/// [e]'s rows of the metric x device table, or none without a column.
Map<DeviceCapability, _Claim> _columnClaims(BandEntry e) {
  final out = <DeviceCapability, _Claim>{};
  final col = columnFor(e.id);
  if (col == null) return out; // Coros, sensors, scales: no column, no claim.
  final cls = capabilities(col);
  for (final m in kCapabilityRow.entries) {
    var status = _statusOf(cls[m.value], col[m.value]);
    if (status == null) continue;
    if (status.kind == CapabilityKind.native) {
      status = switch (m.key) {
        // Ours is the window; the stages are the device's own.
        DeviceCapability.sleep when cls['sleep_stages'] == MetricClass.device =>
          _when(e.kind == DeviceKind.ring
              ? kReasonOwnStagesRing
              : kReasonOwnStages),
        _ => status,
      };
    }
    if (status.reasonKey == kReasonEarly) {
      status = switch (m.key) {
        DeviceCapability.recovery => _when(kReasonFirstNights),
        DeviceCapability.skinTemperature => _when(kReasonSkinTempProvisional),
        _ => status,
      };
    }
    // The shared Pebble entry covers the 2 SE too. It still serves the
    // watch's reported sleep and steps without HR (dayCells), but cannot
    // derive resting HR, strain or the resting-HR recovery estimate.
    final pebbleHr = e.id == kPebble.id &&
        const {DeviceCapability.recovery, DeviceCapability.strain,
          DeviceCapability.heartRate}.contains(m.key);
    out[m.key] = (
      status: !pebbleHr
          ? status
          : _when(status.reasonKey == kReasonEstimated
              ? kReasonPebble2OnlyEstimated
              : kReasonPebble2Only),
      trace: pebbleHr
          ? (rule: 'Pebble 2 HR required for ${m.value}; SE has no HR sensor',
              source: 'lib/compute/inputs/pebble_inputs.dart')
          : (rule: 'metric x device column row ${m.value}', source: _canonical),
    );
  }
  return out;
}

CapabilityStatus? _statusOf(MetricClass? cls, Cell? cell) => switch (cls) {
  null || MetricClass.unavailable => null,
  MetricClass.device => const CapabilityStatus(CapabilityKind.vendorReported),
  MetricClass.estimated => _when(kReasonEstimated),
  MetricClass.ours => cell?.provisionalAt != null ? _when(kReasonEarly) : _native,
};

/// The rule behind [c] for [e] in [slot], or null when no eligibility rule
/// supports the claim.
CapabilityTrace? capabilityTrace(
  BandEntry e,
  DeviceCapability c, {
  required DeviceSlot slot,
  bool modelKnown = true,
}) => _claims(e, slot, modelKnown: modelKnown)[c]?.trace;

SlotSide _side(BandEntry e, DeviceSlot slot, {bool modelKnown = true}) {
  final sends = {
    for (final m in _claims(e, slot, modelKnown: modelKnown).entries) m.key: m.value.status,
  };
  return SlotSide(
    sends: sends,
    doesNotSend: kTableRows.toSet().difference(sends.keys.toSet()),
  );
}

SlotComparison slotComparisonFor(BandEntry e, {bool modelKnown = true}) => SlotComparison(
  everyDay: _side(e, DeviceSlot.everyDay, modelKnown: modelKnown),
  workoutsOnly: _side(e, DeviceSlot.workoutsOnly, modelKnown: modelKnown),
  slot: _slotOf(e),
);
