// Sources, not "devices".
//
// This is where the band-agnostic thesis has to be legible, because this is
// where someone goes to ask "which of my things is this number coming from?".
//
// The answer is a quality ladder, and the ordering rule is the inverse of the
// platform health stores: Apple Health and Health Connect rank by whatever
// wrote last (with a manual priority list bolted on top), so a phone's step
// estimate can quietly outrank a chest strap. Here the better sensor wins and
// recency only breaks a tie within a tier.
//
// RULING (supersedes the "no user preference" clause this paragraph used to
// carry). The default order for every signal is derived from physics, computed
// from `BandAdapter.signals`; `rankSources`' tier ladder stays as the source of
// that default. A user may reorder WITHIN ONE SIGNAL, and when they do the row
// is marked `user_set = 1` with a one-tap reset. Recency never enters a
// cross-device comparison. The screen no longer claims a preference it cannot
// set, because now it can.
//
// PER SIGNAL, never per metric, and never an N×M grid in Settings. "Priority
// for readiness" has no meaning — readiness has four inputs. Only a handful of
// declared signals ever contend, so `contendedSignals` is usually empty and
// `SignalPriorityScreen`'s entry row is then absent entirely.
//
// TWO BUCKETS AND ONLY TWO: what is measuring, and what is NOT YET — the
// second with a reason and a PERMANENCE beside it. "Not yet" without a
// permanence becomes a lie by slow motion: "no, an iPhone has no ANT radio" is
// a different statement from "not yet, a few weeks". There is deliberately no
// third "imported" tier; bringing a history in is data adoption, not device
// support, and it never appears on a compatibility list.
//
// A tier rung is drawn when something in it exists. Tier 1 is now reachable —
// a standard Bluetooth heart-rate sensor can be paired from this screen — so it
// is no longer named in the NOT YET list. What it CANNOT do is stated on the
// sensor's own row instead: it captures beats during a workout and nothing
// derives from it yet, because no one on this project has held one
// (ASSUMPTIONS R6).

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothDevice;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/adapters/_registry.dart'
    show
        BandEntry,
        kBandRegistry,
        kBleHrs,
        kColmi,
        kJyou,
        kHPlus,
        kLefun,
        kOura,
        kCasio,
        kPineTime,
        kQHybrid,
        declaredSignals;
import '../../ble/adapters/signals.dart' show InputSignal;
import '../../ble/casio_link.dart' show CasioLink;
import '../../ble/colmi_link.dart' show ColmiLink;
import '../../ble/hrs_link.dart' show HrsLink, HrsReading;
import '../../ble/jyou_link.dart' show JyouLink;
import '../../ble/oura_link.dart' show OuraLink, pairOuraRing;
import '../../ble/hplus_link.dart' show HPlusLink;
import '../../ble/pinetime_link.dart' show PineTimeLink;
import '../../ble/qhybrid_link.dart' show QHybridLink, pairQHybrid;
import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ble/ble_state.dart' show BandStatus, kMaxConcurrentSecondaryLinks;
import '../../data/db.dart' show LocalDb;
import '../../l10n/app_localizations.dart';
import '../../notify/battery_forecast.dart';
import '../../state/prefs.dart' show Prefs;
import '../../sync/paired_device.dart' show cleanDeviceLabel;
import '../../state/app_state.dart';
import '../pairing/device_picker.dart' show DevicePickerScreen;
import '../onboarding/profile_setup.dart' show formatDay;
import '../ui2.dart';
import 'profile.dart';
import 'settings.dart' show backToRoot;

/// Measurement quality, which is the ONLY thing that decides precedence.
enum SourceTier {
  /// An electrical beat detector: R-peaks, so genuine beat-to-beat intervals.
  beatToBeat(
    1,
    'Beat-to-beat intervals',
    'Electrical R-peak detection.',
    C.green,
  ),

  /// Optical pulse at the wrist. Everything this app ships today.
  wristOptical(
    2,
    'Wrist optical pulse',
    'Continuous 24/7 pulse, sleep and temperature. Beat timing is inferred '
        'from a pulse wave, so HRV here is PRV.',
    C.blue,
  ),

  /// The phone in a pocket.
  phone(
    3,
    'Steps only',
    'The phone’s own motion coprocessor. Steps and nothing else.',
    C.orange,
  );

  const SourceTier(this.rank, this.label, this.detail, this.accent);

  final int rank;
  final String label;
  final String detail;
  final Color accent;
}

/// Localized label/detail for a [SourceTier]. The enum's own `.label`/
/// `.detail` stay English-only (a const enum constructor can't take a
/// BuildContext) — this is the wrapper every render call site should use
/// instead, same split as `sourceState`/`_localizedSourceState` below.
String sourceTierLabel(BuildContext c, SourceTier t) {
  final l = AppLocalizations.of(c);
  switch (t) {
    case SourceTier.beatToBeat:
      return l?.devicesTierBeatToBeatLabel ?? t.label;
    case SourceTier.wristOptical:
      return l?.devicesTierWristOpticalLabel ?? t.label;
    case SourceTier.phone:
      return l?.devicesTierPhoneLabel ?? t.label;
  }
}

String sourceTierDetail(BuildContext c, SourceTier t) {
  final l = AppLocalizations.of(c);
  switch (t) {
    case SourceTier.beatToBeat:
      return l?.devicesTierBeatToBeatDetail ?? t.detail;
    case SourceTier.wristOptical:
      return l?.devicesTierWristOpticalDetail ?? t.detail;
    case SourceTier.phone:
      return l?.devicesTierPhoneDetail ?? t.detail;
  }
}

/// This band's name, from the registry entry that decodes it — never asserted.
///
/// The two call sites here and in `day_steps.dart` both used to be
/// `generation == 'gen5' ? 'WHOOP 5' : 'WHOOP 4'`, which does not name a band,
/// it ASSERTS one: every future adapter, every imported day and every row
/// banked before the family stamp existed was published as a WHOOP 4. Null is
/// the honest answer for all of those, and every caller has a word for it.
String? bandLabelFor(String? adapterId) {
  if (adapterId == null || adapterId.isEmpty) return null;
  for (final e in kBandRegistry) {
    if (e.id == adapterId) return e.label;
  }
  return null;
}

/// One row in a metric screen's device filter (final-plan §6.3).
///
/// THREE STATES, and the third is why this is a type rather than a
/// `List<String>`: a device that cannot supply the metric is SHOWN, disabled,
/// with the reason. An unexplained absent option is the thing users file bugs
/// about, and an unexplained empty chart is worse.
typedef DeviceOption = ({
  /// `device.id`. `''` is the primary band, permanently (ASSUMPTIONS A1).
  String deviceId,

  /// What the pill says — the user's own label for the device.
  String label,

  /// False when the device does not declare every signal the metric needs.
  /// The pill is drawn and untappable.
  bool selectable,

  /// Non-null ONLY when the option is worth explaining: the missing-signal
  /// reason for a non-selectable one, or the empty-window reason for a
  /// selectable one with no coverage. Null on the ordinary case.
  String? reason,
});

/// The metric-screen device filter: one pill per candidate, plus the reason
/// under it when there is one.
///
/// ABSENT, not empty, when [options] has fewer than two entries — the widget
/// returns `SizedBox.shrink()` so a single-device screen has no row, no
/// padding, and no layout shift. That is the assertion the single-device
/// goldens make (final-plan §6.5).
class DeviceFilter extends StatelessWidget {
  const DeviceFilter({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.color = C.blue,
  });

  final List<DeviceOption> options;

  /// Null is "All devices" — the merged view, and the default.
  final String? selected;

  /// Null argument means All devices.
  final ValueChanged<String?> onSelect;
  final Color color;

  @override
  Widget build(BuildContext c) {
    if (options.length < 2) return const SizedBox.shrink();
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final all = l?.deviceFilterAllDevices ?? 'All devices';
    final labels = [all, for (final o in options) o.label];
    final index = selected == null
        ? 0
        : options.indexWhere((o) => o.deviceId == selected) + 1;
    // Index 0 is All devices and is always tappable, so every disabled index
    // is shifted by one — the off-by-one that would otherwise grey the wrong
    // pill.
    final disabled = <int>{
      for (var i = 0; i < options.length; i++)
        if (!options[i].selectable) i + 1,
    };
    final shown = index <= 0 ? null : options[index - 1];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SubTabs(
        labels,
        index < 0 ? 0 : index,
        (i) => onSelect(i == 0 ? null : options[i - 1].deviceId),
        color: color,
        disabled: disabled,
      ),
      // THE REASON, for the selected pill and for any disabled one. Never an
      // unexplained empty chart and never an unexplained dead option.
      if (shown?.reason case final r?) ...[
        const SizedBox(height: S.x2),
        Text('${shown!.label} · $r', style: F.over.copyWith(color: p.ink3)),
      ] else if (disabled.isNotEmpty) ...[
        const SizedBox(height: S.x2),
        Text(
          [
            // `reason` is documented as non-null for a non-selectable option
            // but the type does not enforce it, and an unguarded
            // interpolation renders the literal text "null" beside the label.
            for (final o in options)
              if (!o.selectable)
                o.reason == null ? o.label : '${o.label} · ${o.reason}',
          ].join('   '),
          style: F.over.copyWith(color: p.ink3),
        ),
      ],
    ]);
  }
}

/// The global per-signal priority editor: one drag-reorder list per contended
/// signal, reached from `MyDevicesView`'s "Which source wins" row. Only
/// contended signals get a list — a signal only one paired device declares
/// has nothing to order (final-plan §4.5).
class SignalPriorityScreen extends StatefulWidget {
  const SignalPriorityScreen({super.key});

  @override
  State<SignalPriorityScreen> createState() => _SignalPriorityScreenState();
}

class _SignalPriorityScreenState extends State<SignalPriorityScreen> {
  bool _loading = true;
  List<InputSignal> _signals = const [];
  Map<InputSignal, List<String>> _order = const {};
  Map<String, String> _labels = const {};
  Set<String> _userSet = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final sources = liveSources(app);
    final signals = contendedSignalsOf(sources);
    final labels = <String, String>{
      // The phone has no `device` row, so no id. Coalesced to `''` its null
      // collapsed onto the PRIMARY BAND's key, and a map literal keeps
      // insertion order with last-write-wins — so a phone iterated after the
      // band renamed the band's row in the reorder list. The user then drags
      // a row labelled "Your phone" that actually moves the band, in the one
      // editor that decides which device wins a signal.
      for (final s in sources) ?deviceIdOf(s): s.name,
    };
    final priorities = await LocalDb.signalPriorities();
    final order = <InputSignal, List<String>>{};
    for (final sig in signals) {
      final declaring = declaringDeviceIds(sources, sig);
      final stored = priorities[sig.name];
      order[sig] = stored != null && stored.isNotEmpty
          ? [
              for (final id in stored) if (declaring.contains(id)) id,
              for (final id in declaring) if (!stored.contains(id)) id,
            ]
          : declaring;
    }
    final userSet = await LocalDb.userSetSignals();
    if (!mounted) return;
    setState(() {
      _signals = signals;
      _labels = labels;
      _order = order;
      _userSet = userSet;
      _loading = false;
    });
  }

  /// A write that did not land must never look like one that did — the list
  /// snapping back with no sentence anywhere is how a user believes they set
  /// a preference they did not.
  Future<void> _sayNotSaved() => showReasonSheet(
        context,
        AppLocalizations.of(context)?.devicesOrderNotSaved ??
            'That order could not be saved. Nothing changed.',
      );

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.devicesWhichSourceWins ?? 'Which source wins'),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  for (final sig in _signals) ...[
                    Section(
                      signalDisplayName(c, sig),
                      Column(children: [
                        ReorderableListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          onReorder: (from, to) async {
                            final ids = [...?_order[sig]];
                            // ReorderableListView's `to` is the index BEFORE removal.
                            ids.insert(
                                to > from ? to - 1 : to, ids.removeAt(from));
                            try {
                              await LocalDb.setSignalPriority(sig, ids);
                            } catch (_) {
                              // The stored order is unchanged, so leave the
                              // list where it was rather than showing an order
                              // nothing persisted. Same shape as `_saveRpe`.
                              if (mounted) await _sayNotSaved();
                              return;
                            }
                            if (!mounted) return;
                            setState(() {
                              _order = {..._order, sig: ids};
                              _userSet = {..._userSet, sig.name};
                            });
                          },
                          children: [
                            for (final id in _order[sig] ?? const <String>[])
                              ListTile(
                                key: ValueKey(id),
                                title: Text(_labels[id] ?? id),
                              ),
                          ],
                        ),
                        if (_userSet.contains(sig.name))
                          Pressable(
                            onTap: () async {
                              try {
                                await LocalDb.clearSignalPriority(sig);
                              } catch (_) {
                                if (mounted) await _sayNotSaved();
                                return;
                              }
                              await _load();
                            },
                            semanticLabel: 'Reset ${signalDisplayName(c, sig)} '
                                'to the default order',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: S.x2),
                              child: Text(
                                l?.devicesResetToDefault ??
                                    'Back to the default order',
                                style: F.cap.copyWith(color: p.on(C.blue)),
                              ),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(height: S.x4),
                  ],
                  Text(
                    l?.metricDetailHistoryKeepsSource ??
                        'Days already finished keep the source they were '
                            'calculated with.',
                    style: F.over.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}

/// The HUMAN name for a signal, for a heading or a screen reader.
///
/// `InputSignal.name` is a Dart identifier — `hr1Hz`, `rrIntervals`,
/// `skinTempRaw` — and it was reaching a settings screen as a section title
/// and as a semantic label. An exhaustive `switch` with no `default` makes a
/// future [InputSignal] member a COMPILE ERROR here rather than a leaked
/// identifier, the same protection `sourceTierLabel` gives.
String signalDisplayName(BuildContext c, InputSignal s) {
  final l = AppLocalizations.of(c);
  return switch (s) {
    InputSignal.rrIntervals =>
      l?.signalRrIntervals ?? 'Beat-to-beat intervals',
    InputSignal.hr1Hz => l?.signalHr1Hz ?? 'Continuous heart rate',
    InputSignal.hrSparse => l?.signalHrSparse ?? 'Heart rate',
    InputSignal.accel1Hz => l?.signalAccel1Hz ?? 'Movement',
    InputSignal.accelHighRate =>
      l?.signalAccelHighRate ?? 'High-rate movement',
    InputSignal.ppgGreen => l?.signalPpgGreen ?? 'Green PPG',
    InputSignal.ppgRedIr => l?.signalPpgRedIr ?? 'Red/infrared PPG',
    InputSignal.skinTempRaw => l?.signalSkinTempRaw ?? 'Skin temperature',
    InputSignal.vendorScalars =>
      l?.signalVendorScalars ?? 'The device’s own numbers',
  };
}

/// Why this device cannot serve a metric, from the signals it does NOT declare.
///
/// Generated, never written per device per metric: it stays true when an
/// adapter's declarations change and it costs nothing at the fortieth device.
/// One phrase per [InputSignal] — the physical absence, not the metric.
///
/// Takes a [BuildContext] for the same reason [signalDisplayName] does: this
/// is rendered to the user, as a disabled pill's sub-label, so it is translated
/// like every other sentence on the screen. And NOT by reusing
/// [signalDisplayName]: "no accelerometer" and "no temperature sensor" name the
/// hardware, where the display names ("Movement", "Skin temperature") name what
/// the user reads off it — the distinction this doc comment's last line is
/// about. A `switch` with no `default` for the same reason as well: a new
/// [InputSignal] member is a compile error here rather than a device silently
/// explaining itself as "cannot supply this".
String missingSignalReason(BuildContext c, Set<InputSignal> missing) {
  final l = AppLocalizations.of(c);
  String words(InputSignal s) => switch (s) {
        InputSignal.rrIntervals =>
          l?.missingSignalRrIntervals ?? 'no beat-to-beat intervals',
        InputSignal.hr1Hz =>
          l?.missingSignalHr1Hz ?? 'no continuous heart rate',
        InputSignal.hrSparse => l?.missingSignalHrSparse ?? 'no heart rate',
        InputSignal.accel1Hz => l?.missingSignalAccel1Hz ?? 'no accelerometer',
        InputSignal.accelHighRate =>
          l?.missingSignalAccelHighRate ?? 'no high-rate accelerometer',
        InputSignal.ppgGreen => l?.missingSignalPpgGreen ?? 'no green PPG',
        InputSignal.ppgRedIr =>
          l?.missingSignalPpgRedIr ?? 'no red/infrared PPG',
        InputSignal.skinTempRaw =>
          l?.missingSignalSkinTempRaw ?? 'no temperature sensor',
        InputSignal.vendorScalars =>
          l?.missingSignalVendorScalars ?? 'reports nothing of its own',
      };
  // Ordered by the enum so two devices missing the same pair read identically.
  final parts = [for (final s in InputSignal.values) if (missing.contains(s)) s];
  return parts.isEmpty
      ? (l?.missingSignalUnknown ?? 'cannot supply this')
      : words(parts.first);
}

/// The devices that could serve [requires], newest-facts-only: a registry
/// declaration compared against a `device` row. NO QUERY, which is what makes
/// the visibility gate in §6.5 free.
///
/// SUPERSET test. A device qualifies only when its adapter declares every one
/// of [requires] — see `MetricSpec.requires`.
///
/// [c] is only ever used to translate a rejected device's `reason` — see
/// [missingSignalReason]. Nothing about WHICH devices qualify depends on it.
List<DeviceOption> signalCandidates(
  BuildContext c,
  AppState app, {
  required Set<InputSignal> requires,
}) =>
    candidatesFromSources(c, rankSources(liveSources(app)), requires: requires);

/// The STORAGE device id for [s], or null when it has none.
///
/// `HealthSource.deviceId` is null for BOTH the primary band (whose stored id
/// is `LocalDb.kPrimaryDeviceId`, `''`) and the phone (which has no `device`
/// row at all), so the two need different answers from the same field. One
/// helper rather than the ternary repeated at every consumer: coalescing the
/// phone's null to `''` silently maps it ONTO the band, and force-unwrapping
/// it throws the first time a phone source reaches a new path.
String? deviceIdOf(HealthSource s) =>
    s.isBand ? LocalDb.kPrimaryDeviceId : s.deviceId;

/// The pure half of [signalCandidates] — split out so a test can hand-build
/// [HealthSource]s (as `device_sources_test.dart` already does) instead of a
/// live `AppState`. [c] is passed straight through to [missingSignalReason]
/// and has no say in which sources qualify.
List<DeviceOption> candidatesFromSources(
  BuildContext c,
  List<HealthSource> sources, {
  required Set<InputSignal> requires,
}) {
  if (requires.isEmpty) return const [];
  final out = <DeviceOption>[];
  for (final s in sources) {
    // The phone has no `device` row and no adapter. It is a step counter, and
    // steps are the one metric with no `requires` at all (§4.6), so it can
    // never be a candidate here.
    final id = deviceIdOf(s);
    if (id == null) continue;
    final declared = declaredSignals(s.family);
    // A device declaring NOTHING is not a candidate for anything — never
    // shown, not even disabled. `OuraAdapter.signals == const {}` is exactly
    // this case (§0): the ring is not "missing everything", it is out of
    // scope for every metric, and a permanent disabled pill on every screen
    // would be the noise §0 promises a WHOOP + ring user never sees.
    if (declared.isEmpty) continue;
    final missing = requires.difference(declared);
    out.add((
      deviceId: id,
      label: s.name,
      selectable: missing.isEmpty,
      reason: missing.isEmpty ? null : missingSignalReason(c, missing),
    ));
  }
  return out;
}

/// The devices that DECLARE [sig], in the physics ladder's order.
///
/// The one correct basis for a `signal_priority` write. `setSignalPriority`
/// replaces every row of a signal, and `signalPriority`'s rows are ALSO the
/// resolver's candidate list — so an order built from anything narrower than
/// "declares this signal" (a metric's selectable pills, say) silently deletes
/// a device from a signal it really does declare, and takes it out of every
/// OTHER metric that shares that signal. Per signal, never per metric.
List<String> declaringDeviceIds(List<HealthSource> sources, InputSignal sig) => [
      for (final s in rankSources(sources))
        // Skipped, never force-unwrapped: an id-less source (the phone) has
        // nothing to rank, and `!` here would throw the day one declares a
        // contended signal.
        if (deviceIdOf(s) case final id?)
          if (declaredSignals(s.family).contains(sig)) id,
    ];

/// Who currently wins each of [requires] — `{signal: deviceId}`, in
/// [requires]' own order, from the stored `signal_priority` orders in
/// [stored] (`LocalDb.signalPriorities()`'s shape, keyed by `signal.name`).
///
/// PER SIGNAL, because per signal is the only shape the table has. A metric's
/// "preferred device" is a question about SEVERAL signals: readiness needs
/// four, and nothing stops a user putting a chest strap first for beat timing
/// and the band first for continuous heart rate. Reading `requires.first`
/// alone and calling its winner the metric's preferred device asserts an
/// agreement that may not exist — see [unanimousWinner], which is the test
/// for whether it does.
///
/// A stored id is skipped unless the device still DECLARES that signal, the
/// same filter [SignalPriorityScreen] applies when it renders an order: a row
/// left behind by a forgotten device has no adapter to serve the window, and
/// the resolver passes over it too (it has no coverage to own). [fallback]
/// answers a signal with no usable row — the ladder's choice, which the
/// caller already has in hand.
Map<InputSignal, String?> signalWinners(
  List<HealthSource> sources, {
  required Set<InputSignal> requires,
  required Map<String, List<String>> stored,
  String? fallback,
}) {
  final out = <InputSignal, String?>{};
  for (final sig in requires) {
    final declaring = declaringDeviceIds(sources, sig);
    String? winner;
    for (final id in stored[sig.name] ?? const <String>[]) {
      if (declaring.contains(id)) {
        winner = id;
        break;
      }
    }
    out[sig] = winner ?? fallback;
  }
  return out;
}

/// The device winning EVERY signal in [winners], or null when they disagree —
/// and null for an empty map, which is "nothing resolved", not agreement.
///
/// Null is therefore not "no preference": a caller showing one device's name
/// must ALSO know whether the winners were split, or it labels a split
/// configuration with whatever its no-preference placeholder happens to say.
String? unanimousWinner(Map<InputSignal, String?> winners) {
  final distinct = winners.values.toSet();
  return distinct.length == 1 ? distinct.first : null;
}

/// Signals TWO OR MORE paired devices declare. The whole content of the
/// priority editor, and the reason it is usually empty: only a handful of the
/// declared signals ever contend, so the table is tens of rows forever
/// (final-plan §4.5).
List<InputSignal> contendedSignals(AppState app) =>
    contendedSignalsOf(liveSources(app));

/// The pure half of [contendedSignals] — see [candidatesFromSources].
List<InputSignal> contendedSignalsOf(List<HealthSource> sources) {
  final n = <InputSignal, int>{};
  for (final s in sources) {
    final id = deviceIdOf(s);
    if (id == null) continue;
    for (final sig in declaredSignals(s.family)) {
      n[sig] = (n[sig] ?? 0) + 1;
    }
  }
  return [for (final s in InputSignal.values) if ((n[s] ?? 0) >= 2) s];
}

/// Bands the owner has personally held and cross-confirmed. Everything else is
/// publicly EXPERIMENTAL, however well its fixtures pass — a fixture proves
/// determinism and physiological sanity, never correctness, and a decoder with
/// a 2× scale error reads a resting 50 bpm as 100 and passes every generic
/// bound. Hardware in his hands is the only promotion path.
///
/// ponytail: a const set here until the CODEOWNERS-gated `_verified.dart`
/// exists (ASSUMPTIONS E5). Move it there and delete this — it must never
/// become a CI rule, which would hand the key to the PR author.
const Set<String> kOwnerConfirmedBandIds = {'gen4', 'gen5'};
// gen5 promoted 2026-08-23: WHOOP 5 worn by the owner, paired, connected,
// live HR streaming, and a full historical drain completed (the trim token
// reached `sync_cursor`, so the band was told it may release that flash).
// 249,596 decoded seconds and 151,595 beats stamped `device_family='gen5'`
// on his own export. That is the promotion path in ASSUMPTIONS E5 — hardware
// in his hands — not a fixture passing.

/// A device family this app does NOT speak today, and why.
///
/// [permanence] is the load-bearing half. It is a plain phrase, never a date —
/// "being built" and "not a matter of time" are different promises and a user
/// is owed the difference.
class NotYet {
  final String name, reason, permanence;
  final IconData icon;
  const NotYet(this.name, this.reason, this.permanence, this.icon);
}

/// The honest other half of this screen.
///
/// Short on purpose: a list gets checked, and every row on it is a claim
/// someone can hold us to. These three are the ones already decided.
const List<NotYet> kNotYet = [
  NotYet(
    'Polar 360 and Loop',
    'Screenless, no subscription, worn around the clock, with beat-to-beat '
        'intervals the vendor documents. Nobody has written the driver.',
    'Planned',
    LucideIcons.watch,
  ),
  NotYet(
    'Fitbit, Withings, Xiaomi and Zepp bands',
    'Their pairing key is issued by the vendor’s own server. A driver would '
        'work only while their app stayed installed and signed in, and would '
        'stop the day they changed it — so the band would be ours to support '
        'and theirs to switch off.',
    'Not a matter of time',
    LucideIcons.cloudOff,
  ),
];

/// One thing that can produce measurements.
class HealthSource {
  final String name, kind;

  /// Where this source sits on the quality ladder, or NULL when it has no
  /// place on it.
  ///
  /// Null is not "unknown", it is "none". The Oura ring is the case: it holds
  /// a pairing key, drains history and banks every frame it is sent, and it
  /// supplies no decoded signal at all (`OuraAdapter.signals` is `const {}`),
  /// so there is no measurement quality to rank. Filing it under the phone's
  /// rung would have told someone their ring was reporting steps.
  final SourceTier? tier;
  final IconData icon;
  final bool connected;

  /// Records are landing right now. Narrower than [connected] — an idle link
  /// is not a sync, and a multi-minute offload used to look identical to one.
  final bool syncing;
  final double? batteryPct;
  final bool charging;
  final DateTime? lastData;

  /// True for the PRIMARY band — the only source the offload engine drives,
  /// and the only one with band controls (rename, find, battery forecast).
  ///
  /// FALSE for a paired sensor, deliberately. A chest strap is a better beat
  /// detector than the band and a worse everything-else: it measures nothing
  /// while a workout is not running. Letting one satisfy `hasBand` would take
  /// the "No band is paired" card off a screen belonging to someone whose
  /// sleep, recovery and temperature are all still abstaining.
  final bool isBand;

  /// The `device` row this source is, for a paired sensor. Null for the
  /// primary band (whose row is `LocalDb.kPrimaryDeviceId`, `''`) and for the
  /// phone. It is the `device_id` every measurement this source wrote carries,
  /// which is what makes forgetting it possible without touching the data.
  final String? deviceId;

  /// The ingest-stamped sensor family (`'gen4'` / `'gen5'`), or null when the
  /// link has not said yet. Not cosmetic: it is the key every sensor-dependent
  /// metric looks its own constants up under, and null is a refusal.
  final String? family;

  /// Publicly EXPERIMENTAL — this band is decoded but the owner has never held
  /// one (see [kOwnerConfirmedBandIds]). Not a quality tier and not a
  /// confidence: it says who has checked, not how good the numbers are.
  /// NOT gated on [isBand]. A paired sensor is the case this exists for — it
  /// is the one nobody here has held — and requiring `isBand` would have hidden
  /// the label on exactly those rows while showing it on the band the owner
  /// wears daily.
  bool get experimental =>
      family != null && !kOwnerConfirmedBandIds.contains(family);

  const HealthSource({
    required this.name,
    required this.kind,
    required this.tier,
    required this.icon,
    this.connected = false,
    this.syncing = false,
    this.batteryPct,
    this.charging = false,
    this.lastData,
    this.isBand = false,
    this.deviceId,
    this.family,
  });
}

/// The one-row device disclosure (MT-12 / CV-04a).
///
/// Metrics whose correct behaviour depends on the sensor carry their own
/// per-family constants, so a gen4 strap and a gen5 strap can land on different
/// tiers for identical physiology. If that asymmetry is nowhere on screen the
/// tier stops meaning anything — so it lives on the band's own page, as one
/// row, next to the battery.
///
/// Returns null for a non-band source: the phone reports steps and nothing that
/// is calibrated per sensor.
(String value, String sub)? calibrationDisclosure(HealthSource s) {
  if (!s.isBand) return null;
  final label = bandLabelFor(s.family);
  if (label != null) {
    return (
      label,
      'Metrics that depend on the sensor use this band’s own constants, so two '
          'different bands can land on different tiers for the same physiology.'
    );
  }
  // Null is the honest majority case, not an error: every row banked before
  // the stamp existed, every import and every raw replay carries no family,
  // and those metrics abstain rather than borrow gen4's numbers. A family this
  // build has no registry entry for lands here too — an unknown band is not a
  // WHOOP 4.
  return (
    'Not stated yet',
    'This band has not said which generation it is, and imported or older '
        'days never will. Metrics that depend on the sensor abstain rather '
        'than borrow another band’s numbers.'
  );
}

/// The glyph for a paired sensor. A ring is not a chest strap and the row is
/// the only place a user can tell two paired sensors apart at a glance.
IconData sensorIcon(String? adapterId) => switch (adapterId) {
      'oura' || 'lefun' || 'colmi' => LucideIcons.circleDot,
      'hplus' || 'pinetime' || 'qhybrid' || 'casio' || 'jyou' =>
        LucideIcons.watch,
      _ => LucideIcons.heartPulse,
    };

/// The tier named by a `device.tier` column, or null when the column is blank
/// or holds a name this build does not have.
///
/// Null is a refusal, the same way a null `adapter_id` is: a row written by a
/// future version naming a rung this build cannot draw must not be quietly
/// filed under the nearest one it knows.
SourceTier? tierNamed(Object? name) {
  for (final t in SourceTier.values) {
    if (t.name == name) return t;
  }
  return null;
}

/// The sources that actually exist right now. Nothing is listed that cannot
/// produce a number today — everything else is in [kNotYet], with its reason.
///
/// [sensorLive] is whether a paired sensor's link is up THIS INSTANT. It is
/// passed in rather than read off `HrsLink` here because it changes on every
/// beat: routing it through [AppState] would notify every listener in the app
/// at 1 Hz for the duration of a workout, which is the rebuild storm this
/// screen has already been fixed for once.
List<HealthSource> liveSources(AppState app, {bool sensorLive = false}) => [
      if (app.isPaired)
        HealthSource(
          name: app.strapName ?? 'Your band',
          // The registry's own word for this band, or just what it is when the
          // link has not said. Never an assertion that an unnamed band is a
          // WHOOP 4.
          kind: [
            ?bandLabelFor(app.device.generation),
            'wrist optical',
          ].join(' · '),
          tier: SourceTier.wristOptical,
          icon: LucideIcons.watch,
          connected: app.isConnected,
          syncing: app.syncingNow,
          batteryPct: app.device.batteryPct,
          charging: app.device.charging ?? false,
          lastData: app.lastRecordAt,
          isBand: true,
          family: app.device.generation,
        ),
      // Sensors paired alongside the band. One row each, ranked by their own
      // tier like everything else — a beat-to-beat strap sorts ABOVE the wrist
      // band, which is the whole point of the ladder being quality-first.
      for (final r in app.sensors)
        HealthSource(
          // The advertised name the user picked, then the registry's word for
          // what it is. Never a placeholder — `cleanDeviceLabel` already
          // refused anything junk at pairing.
          name: (r['label'] as String?) ??
              bandLabelFor(r['adapter_id'] as String?) ??
              'Paired sensor',
          kind: bandLabelFor(r['adapter_id'] as String?) ?? 'Unknown sensor',
          // Null when the column is blank (a source with nothing to rank) or
          // names a rung this build does not have. Either way it is a refusal,
          // never the nearest rung we happen to know.
          tier: tierNamed(r['tier']),
          icon: sensorIcon(r['adapter_id'] as String?),
          // `sensorLive` reflects HrsLink.reading ONLY — a live HRS session
          // must not mark an unrelated paired Oura row as connected just
          // because some sensor happens to be live right now.
          connected: sensorLive && r['adapter_id'] == kBleHrs.id,
          isBand: false,
          deviceId: r['id'] as String?,
          family: r['adapter_id'] as String?,
        ),
      if (app.phoneStepsEnabled)
        HealthSource(
          name: 'This phone',
          kind: 'Motion coprocessor',
          tier: SourceTier.phone,
          icon: LucideIcons.smartphone,
          // NOT the toggle. On iOS `requestAuthorization` reports success even
          // when the user denied READ, so the toggle sits on while every read
          // comes back empty — this row used to hardcode `true` and claim a
          // source that was measuring nothing. Steps actually banked is the
          // only evidence the phone is a source.
          connected: app.phoneStepsLastSyncedDays != null &&
              (app.phoneStepsLastTotal ?? 0) > 0,
        ),
    ];

/// Quality first, then recency, then the name. The inverse of last-writer-wins.
///
/// THE DEFAULT ORDER, and only that. There was a `preferred` list here that no
/// caller ever passed and no screen could set — the card above it told the user
/// their own preference was "the last word", which was a mechanism that did not
/// exist. That is what died, and the reason it died was last-writer-wins plus a
/// preference nothing could write. Neither has come back.
///
/// What HAS come back is a user order, and it does not live here: it lives in
/// `signal_priority`, per SIGNAL, written from `SignalPriorityScreen` and from
/// the metric screen's own "Prefer this device" row. This function is
/// precedence rule 3 of three — consulted only where that table is silent, and
/// it is silent for every install with one device.
List<HealthSource> rankSources(List<HealthSource> sources) {
  final out = [...sources];
  out.sort((a, b) {
    // An unranked source sorts BELOW every ranked one — it is not competing
    // for precedence, because it supplies nothing to compete with.
    final byTier = (a.tier?.rank ?? 99).compareTo(b.tier?.rank ?? 99);
    if (byTier != 0) return byTier;
    final at = a.lastData, bt = b.lastData;
    if (at != null && bt != null && at != bt) return bt.compareTo(at);
    if (at != null) return -1;
    if (bt != null) return 1;
    return a.name.compareTo(b.name);
  });
  return out;
}

// ══════════════════ MY DEVICES ══════════════════

class MyDevices extends StatelessWidget {
  const MyDevices({super.key});

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    // The live reading is subscribed HERE and nowhere higher. It moves on every
    // beat, so a listener on AppState would rebuild the whole app at 1 Hz for
    // the length of a workout; this rebuilds one screen.
    return ValueListenableBuilder<HrsReading?>(
      valueListenable: HrsLink.instance.reading,
      builder: (c, reading, _) => _build(c, app, reading != null),
    );
  }

  Widget _build(BuildContext c, AppState app, bool sensorLive) {
    return MyDevicesView(
      sources: rankSources(liveSources(app, sensorLive: sensorLive)),
      // The band row's dot says connected or not. That covers six different
      // problems with six different fixes, and a user cannot fix a problem the
      // app will not name — so the engine's own verdict rides alongside it.
      status: app.isPaired ? app.engine.bandStatus : null,
      // This used to clear a preference and nothing else — the gate that
      // renders the pairing step is MaterialApp.home, underneath this pushed
      // screen, so the button appeared completely inert. And the gate is no
      // longer an option regardless: an onboarded user is never routed back
      // into first-run pairing (that was the bug where forgetting a band threw
      // months of data behind an onboarding screen), which makes this the only
      // way back to pairing. So push it.
      onPair: () => goto(c, const RePair()),
      onAddSensor: () => addSensor(c),
      contendedSignals: contendedSignals(app),
      onSignalPriority: () => goto(c, const SignalPriorityScreen()),
    );
  }
}

/// Every sensor that can be paired from this screen — a second device
/// alongside the band, never a replacement for it.
///
/// Data, not a switch statement, because the ONLY thing that differs between
/// them is which entry the picker filters on and what has to happen once the
/// user taps one. `PairSensorScreen` is generic over exactly that.
final List<({BandEntry entry, String blurb, Future<String?> Function(BluetoothDevice)? pick})>
    kPairableSensors = [
  (
    entry: kBleHrs,
    blurb: 'A chest strap or armband. Beat timing measured electrically, '
        'which a wrist pulse cannot match. Runs during a workout.',
    // Null means the plain notify-class pairing, which is the whole of what a
    // heart-rate sensor needs.
    pick: null,
  ),
  (
    entry: kOura,
    blurb: 'Reads the ring directly, with no Oura account and no subscription. '
        'The ring must be factory reset FIRST — one that is already set up in '
        'the Oura app cannot be re-keyed. Reset it from the Oura app (remove/'
        'unpair the ring), then close that app before pairing here.',
    pick: pairOuraRing,
  ),
  (
    entry: kLefun,
    blurb: 'A generic Bluetooth ring or band from the family sold under many '
        'storefront names. Pairs and connects, but reports nothing yet — '
        'nobody on this project has held one to verify what its numbers mean.',
    // No key, no handshake — plain notify-class pairing, with no measurement
    // tier: this device declares no signal at all (`LefunAdapter.signals` is
    // `const {}`), so there is no quality to rank it against another source.
    pick: (device) => HrsLink.pairNotifySensor(
      kLefun,
      device,
      label: cleanDeviceLabel(device.platformName),
      tier: null,
    ),
  ),
  (
    entry: kHPlus,
    blurb: 'A generic HPlus-family HR band (HPlus, Makibes F68, Zeblaze and '
        'similar). No account, no handshake — it pairs and banks what it '
        'sends, but nothing is decoded into a number yet.',
    // Null: no auth step, so the plain notify-class pairing is the whole of
    // what this band needs — same as [kBleHrs].
    pick: null,
  ),
  (
    entry: kPineTime,
    blurb: 'Pairs and banks its raw data in the background, but does not '
        'derive anything from it yet — nobody on this project owns one to '
        'verify its numbers against.',
    // Null means the plain notify-class pairing, which is the whole of what
    // this watch needs — no auth, no key.
    pick: null,
  ),
  (
    entry: kQHybrid,
    blurb: 'The original Fossil/Skagen hybrid smartwatch line, not the newer '
        'Hybrid HR. Pairs and connects; nothing derives from it yet.',
    // NOT plain notify-class pairing (`pick: null`): unlike a heart-rate
    // strap, which a workout arms, this band has no workout role, so
    // `pairQHybrid` is what runs its first real session — the adapter's own
    // battery-probe confirms it is this protocol, not the encrypted Hybrid HR
    // sibling, and whatever it answers in the bounded window right after is
    // what gets archived. The same session is re-runnable afterward — see
    // `qhybrid_link.dart` and this screen's own sync affordance.
    pick: pairQHybrid,
  ),
  (
    entry: kColmi,
    blurb: 'A Colmi ring. No account, no handshake — it pairs and banks its '
        'history, but nothing is decoded into a number yet.',
    // Null: no auth step, so the plain notify-class pairing is the whole of
    // what this ring needs — same as [kBleHrs].
    pick: null,
  ),
  (
    entry: kCasio,
    blurb: 'GBX100, GW-B5600, GMW-B5000, ECB-S100 and current Casio '
        'smartwatches. Pairs and connects; nothing derives from it yet.',
    // Null means the plain notify-class pairing — standard BLE bonding is
    // the whole of what this watch needs.
    pick: null,
  ),
  (
    entry: kJyou,
    blurb: 'Pairs and banks its raw data, but does not derive anything from '
        'it yet — nobody on this project owns one to verify its numbers '
        'against.',
    // Null means the plain notify-class pairing, same as the heart-rate
    // sensor above.
    pick: null,
  ),
];

/// Choose which kind of sensor to pair, then hand off to the pairing screen.
Future<void> addSensor(BuildContext c) async {
  // Count paired secondary devices (the `device` table minus the primary row).
  //
  // PAIRED ROWS, NOT LIVE SLOTS, and deliberately: admission here is a
  // question about the sensors this phone manages, not about who holds a GATT
  // link in this instant. Live slot state is transient — `OuraLink` holds one
  // only from connect through `stop()`, `HrsLink` only for a workout — so
  // reading it would admit or refuse the same pairing depending on the second
  // it was tapped, and a slot freed a moment later cannot un-refuse anything.
  // The same constant bounds both because the number is the same number; the
  // sentence below states the PAIRING rule, which is the one enforced here.
  final secondaryCount = (await LocalDb.deviceRows())
      .where((r) => r['id'] != LocalDb.kPrimaryDeviceId)
      .length;
  if (secondaryCount >= kMaxConcurrentSecondaryLinks) {
    if (!c.mounted) return;
    // DERIVED FROM THE CONSTANT the check above uses. Hardcoded, the sentence
    // states a different rule from the one enforced the moment the cap moves.
    await showReasonSheet(
        c,
        AppLocalizations.of(c)
                ?.devicesSensorLimit(kMaxConcurrentSecondaryLinks) ??
            'This phone will pair at most $kMaxConcurrentSecondaryLinks '
                'sensors alongside your band. Remove one to add another.');
    return;
  }
  if (!c.mounted) return;
  // `includeBand: false` — this phone already has its one primary band;
  // re-pairing it is `RePair`'s job, not a row beside a chest strap here.
  await goto(c, const DevicePickerScreen(includeBand: false));
  // The picker's own sub-screens write a `device` row; nothing tells
  // AppState that happened.
  if (c.mounted) await c.read<AppState>().refreshSensors();
}

/// Ask for a SECOND framed band. iOS cannot show the system pairing sheet while a
/// CBCentralManager exists in the process, and on an already-paired install
/// flutter_blue_plus creates one during start-up and never releases it — so the
/// sheet can only be shown on the next launch, before start-up touches the radio.
/// This writes the request; `AppState._initSteps` performs it.
///
/// NOT surfaced from any visible button in M4 — no second framed band exists yet
/// to provision against (see MULTIDEVICE_PROGRESS.md's M4 notes). This wires the
/// plumbing and its test only.
Future<void> addFramedBand(BuildContext c) async {
  // ACKED, not fire-and-forget. `Prefs.setBool` updates the cache
  // OPTIMISTICALLY and never rolls it back (see prefs.dart), and this flag's
  // whole purpose is to survive the restart the sheet below asks for — a
  // write that did not land would leave the user following correct
  // instructions to no effect.
  final saved = await Prefs.setBoolAcked(Prefs.kAskAddPendingKey, true);
  if (!c.mounted) return;
  if (!saved) {
    await showReasonSheet(
        c,
        AppLocalizations.of(c)?.devicesRequestNotSaved ??
            'That request could not be saved. Please try again.');
    return;
  }
  await showRestartRequiredSheet(c);
}

/// One-sentence sheet: the ASK ordering constraint, stated where the user is.
Future<void> showRestartRequiredSheet(BuildContext c) async {
  final p = P.of(c);
  await showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
        child: Text(
          'iOS can only show the system pairing sheet before the app has used '
          'Bluetooth. Close OpenStrap completely, then reopen it — the sheet '
          'appears on its own.',
          style: F.body.copyWith(color: p.ink),
        ),
      ),
    ),
  );
}

/// One-sentence sheet giving a reason a requested action was refused.
Future<void> showReasonSheet(BuildContext c, String reason) async {
  final p = P.of(c);
  await showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
        child: Text(reason, style: F.body.copyWith(color: p.ink)),
      ),
    ),
  );
}

/// Pairing, pushed rather than gated.
///
/// The onboarding gate is what used to take the pairing screen away once a
/// band answered. A pushed copy has no gate under it, so it closes itself —
/// otherwise it sits there on "Paired · Continue", whose button re-runs the
/// scan.
class RePair extends StatelessWidget {
  const RePair({super.key});

  @override
  Widget build(BuildContext c) {
    if (c.watch<AppState>().isPaired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (c.mounted) Navigator.of(c).maybePop();
      });
    }
    // NO `onSkip`. That argument is first-run onboarding's "Skip for now",
    // and its note says the app opens without a band and nothing is measured
    // — a sentence about a decision this user made long ago. A re-pair backs
    // out through `NavBar`'s own back button, exactly as `addSensor` does.
    return const DevicePickerScreen();
  }
}

class MyDevicesView extends StatelessWidget {
  final List<HealthSource> sources;
  final VoidCallback? onPair, onAddSensor;

  /// The band's own state, from `bandStatusFor`. Null when nothing is paired.
  final BandStatus? status;

  /// Signals two or more paired devices declare — from `contendedSignals`.
  /// Empty on every single-device install, which keeps the priority-editor
  /// entry row absent by default (final-plan §4.5).
  final List<InputSignal> contendedSignals;
  final VoidCallback? onSignalPriority;

  const MyDevicesView({
    super.key,
    this.sources = const [],
    this.onPair,
    this.onAddSensor,
    this.status,
    this.contendedSignals = const [],
    this.onSignalPriority,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final localizedStatus =
        status == null ? null : localizedBandStatus(c, status!);
    final fault = localizedStatus?.isFault == true ? localizedStatus : null;
    // A BAND, not "a source". The phone is a source and it is not a substitute
    // for one: gating this on `sources.isEmpty` meant a phone counting steps
    // hid the only route back to pairing, and forgetting a band left the user
    // stranded with a steps row and no way to add another.
    final hasBand = sources.any((s) => s.isBand);

    // THE PHONE ROW IS LISTED WHENEVER THE TOGGLE IS ON, connected or not —
    // `connected` there is "steps have actually been banked", because on iOS
    // the toggle sits on while a denied READ permission returns nothing. So
    // "a source exists" was the wrong test for this card: it told a user
    // whose phone was measuring nothing that "the phone counts steps".
    final phoneCounting = sources.any((s) => !s.isBand && s.connected);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.devicesMySources ?? 'My sources'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                // FIRST, in the tier-2 slot the missing band would occupy —
                // not appended under the phone. Someone who has just forgotten
                // a band is here to add one, and the row they can see is not
                // the one they came for.
                if (!hasBand) ...[
                  StatusCard(
                    phoneCounting
                        ? (l?.devicesNoBandPaired ?? 'No band is paired')
                        : (l?.devicesNothingMeasuringYet ??
                            'Nothing is measuring yet'),
                    phoneCounting
                        ? (l?.devicesPhoneCountingBody ??
                            'The phone counts steps and nothing else. Heart '
                                'rate, sleep, recovery and temperature all abstain '
                                'until a band is paired.')
                        : (l?.devicesNothingMeasuringBody ??
                            'No band is paired and no phone steps are arriving, '
                                'so every metric in the app will abstain rather '
                                'than estimate.'),
                    fix: l?.devicesPairABand ?? 'Pair a band',
                    icon: LucideIcons.watch,
                    onFix: onPair,
                  ),
                  if (sources.isNotEmpty) const SizedBox(height: S.x3),
                ],
                // LIVE — the first of the two buckets. Only drawn when there is
                // something in it: a heading over nothing is the empty rung
                // problem again, one level up.
                if (sources.isNotEmpty) ...[
                  Text(l?.devicesLive ?? 'LIVE', style: F.over.copyWith(color: p.ink3)),
                  const SizedBox(height: S.x3),
                ],
                for (final s in sources) ...[
                  SourceRow(s, onTap: () => goto(c, DeviceDetail(s))),
                  if (s.isBand && fault != null) ...[
                    const SizedBox(height: S.x2),
                    StatusCard(fault.title, fault.reason,
                        fix: fault.fix ?? '',
                        icon: LucideIcons.bluetoothOff),
                  ],
                  const SizedBox(height: S.x3),
                ],
                // At the foot of LIVE, because that is what it adds to. Not
                // gated on having a band: a sensor is a second source, and
                // someone with no band at all is exactly who benefits most
                // from being able to pair one.
                if (onAddSensor != null)
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: SetRow(LucideIcons.plus, C.green,
                        l?.devicesAddASensor ?? 'Add a sensor',
                        sub: l?.devicesAddASensorSub ??
                            'A heart-rate strap or a ring, alongside the band',
                        onTap: onAddSensor),
                  ),
                // ONLY when something can actually contend. A reorder screen
                // over one device is a control with nothing to order, which is
                // the empty-rung problem this screen already refuses (§6.5).
                if (contendedSignals.isNotEmpty && onSignalPriority != null) ...[
                  const SizedBox(height: S.x3),
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: SetRow(LucideIcons.arrowUpDown, C.blue,
                        l?.devicesWhichSourceWins ?? 'Which source wins',
                        sub: l?.devicesWhichSourceWinsSub ??
                            'When two of your devices measure the same thing',
                        onTap: onSignalPriority),
                  ),
                ],
                // NOT YET — removed from this screen per product decision
                // (owner's call, live review). `kNotYet`/`NotYet` still hold
                // the reasons and permanences below; only the render is gone.
                const SizedBox(height: S.x5),
                Text(l?.devicesQualityLadder ?? 'THE QUALITY LADDER',
                    style: F.over.copyWith(color: p.ink3)),
                const SizedBox(height: S.x3),
                for (final t in SourceTier.values)
                  // Every rung is drawn now, filled or not. The tier-1 rung
                  // used to be hidden because nothing could reach it and an
                  // unreachable empty rung is just something to go hunting
                  // for; "Add a sensor" above is how it is reached, so an
                  // empty one is now a genuine invitation rather than a dead
                  // end.
                  ...[
                    TierRow(t, filled: sources.any((s) => s.tier == t)),
                    const SizedBox(height: S.x3),
                  ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// The one line under a source's name.
///
/// "Not connected" is a statement about a radio link, and the phone has none:
/// it is either handing steps over or it is not, which is exactly the failure
/// the row used to hide behind a hardcoded "Connected".
// Kept context-free and directly tested (see ui2_router_test.dart,
// device_sources_test.dart) — this is the tier/connection LOGIC, not just
// copy. `_localizedSourceState` below is what the UI actually renders.
String sourceState(HealthSource s) {
  // A PAIRED SENSOR IS TESTED FOR FIRST, before the tier is consulted at all.
  // It is armed by a workout and only by a workout, so "not connected" is its
  // resting state and not a fault — and a sensor whose tier could not be named
  // falls back to the phone's rung, where this function would otherwise have
  // told the user their chest strap was reporting steps.
  if (s.deviceId != null) {
    if (s.connected) return 'Streaming beats';
    // A source with no rung supplies no signal, so there is nothing for a
    // workout to arm and nothing being derived. Say that, rather than promise
    // a stream that will never start.
    return s.tier == null ? 'Paired · storing what it sends' : 'Waiting for a workout';
  }
  if (s.tier == SourceTier.phone) {
    return s.connected ? 'Reporting steps' : 'No steps arriving';
  }
  if (s.syncing) return 'Syncing';
  return s.connected ? 'Connected' : 'Not connected';
}

String _localizedSourceState(BuildContext c, HealthSource s) {
  final l = AppLocalizations.of(c);
  if (s.deviceId != null) {
    if (s.connected) return l?.devicesStreamingBeats ?? 'Streaming beats';
    return s.tier == null
        ? (l?.devicesStoringWhatItSends ?? 'Paired · storing what it sends')
        : (l?.devicesWaitingForWorkout ?? 'Waiting for a workout');
  }
  if (s.tier == SourceTier.phone) {
    return s.connected
        ? (l?.devicesReportingSteps ?? 'Reporting steps')
        : (l?.devicesNoStepsArriving ?? 'No steps arriving');
  }
  if (s.syncing) return l?.devicesSyncing ?? 'Syncing';
  return s.connected
      ? (l?.devicesConnected ?? 'Connected')
      : (l?.devicesNotConnected ?? 'Not connected');
}

/// One connected source.
class SourceRow extends StatelessWidget {
  final HealthSource s;
  final VoidCallback? onTap;
  const SourceRow(this.s, {super.key, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final battery = s.batteryPct;
    return Surface(
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
          child: Icon(s.icon, size: 24, color: p.ink2),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name,
                style: F.body
                    .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
            Text(s.kind, style: F.over.copyWith(color: p.ink3)),
            const SizedBox(height: 5),
            // Wrap, not Row: at 2x text "Not connected · 78%" is wider than
            // the card and a Flex would simply clip the battery away.
            Wrap(spacing: S.x3, runSpacing: S.x1, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: s.connected ? p.on(C.green) : p.ink3,
                      shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                // Flexible because this string is not fixed: "Not connected"
                // and "No steps arriving" are 10 px wider than the column at
                // 390 pt, and an unflexed Text in a Wrap simply overflows.
                Flexible(
                  child: Text(_localizedSourceState(c, s),
                      style: F.over.copyWith(
                          color: s.connected ? p.on(C.green) : p.ink3)),
                ),
              ]),
              if (battery != null)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      s.charging
                          ? LucideIcons.batteryCharging
                          : LucideIcons.battery,
                      size: 13,
                      color: p.ink3),
                  const SizedBox(width: 3),
                  Text('${battery.round()}%',
                      style: F.over.copyWith(color: p.ink3)),
                ]),
              // IN THE WRAP, not a second trailing pill: this line already
              // wraps at accessibility sizes, and a pill column beside it does
              // not. The band's own page carries the explanation.
              if (s.experimental)
                Text(AppLocalizations.of(c)?.devicesExperimental ?? 'Experimental',
                    style: F.over.copyWith(color: p.on(C.orange))),
            ]),
          ]),
        ),
        const SizedBox(width: S.x2),
        // No pill for an unranked source. A blank one reads as tier zero.
        if (s.tier case final t?)
          Pill(AppLocalizations.of(c)?.devicesTierRank(t.rank) ?? 'Tier ${t.rank}',
              t.accent),
      ]),
    );
  }
}

/// One rung of the ladder, filled or not. An empty rung is information.
class TierRow extends StatelessWidget {
  final SourceTier tier;
  final bool filled;
  const TierRow(this.tier, {super.key, this.filled = false});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Surface(
      elevation: 0,
      color: filled ? p.wash(tier.accent) : p.card2,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(filled ? LucideIcons.badgeCheck : LucideIcons.circleDashed,
            size: 20, color: filled ? p.on(tier.accent) : p.ink3),
        const SizedBox(width: S.x3),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                AppLocalizations.of(c)?.devicesTierRankLabel(
                        tier.rank, sourceTierLabel(c, tier)) ??
                    'Tier ${tier.rank} · ${tier.label}',
                style: F.body.copyWith(
                    color: filled ? p.ink : p.ink2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: S.x1),
            Text(sourceTierDetail(c, tier),
                style: F.cap.copyWith(color: p.ink3, height: 1.5)),
            if (!filled) ...[
              const SizedBox(height: S.x1),
              // A dashed circle and a paler wash are not a statement. Without
              // a word here an empty rung reads exactly like the tier you do
              // have — including to a screen reader, which sees neither.
              Text(AppLocalizations.of(c)?.devicesNothingHereYet ?? 'Nothing here yet',
                  style: F.over.copyWith(color: p.ink3)),
            ],
          ]),
        ),
      ]),
    );
  }
}

// ══════════════════ DEVICE DETAIL ══════════════════

class DeviceDetail extends StatefulWidget {
  final HealthSource s;
  const DeviceDetail(this.s, {super.key});

  @override
  State<DeviceDetail> createState() => _DeviceDetailState();
}

class _DeviceDetailState extends State<DeviceDetail> {
  /// Held, not rebuilt: this screen watches AppState, so a FutureBuilder given
  /// a fresh `batteryHealth()` on every build would rescan the sample table on
  /// every connection tick.
  Map<String, dynamic>? _health;

  /// The same projection the overnight charge warning fires on, read here
  /// rather than recomputed: this screen is where someone asks "how long have I
  /// got", and the answer was already being calculated and only ever spent on a
  /// notification they may have dismissed.
  BatteryForecast? _forecast;

  @override
  void initState() {
    super.initState();
    if (!widget.s.isBand) return;
    LocalDb.batteryHealth().then((h) {
      if (mounted) setState(() => _health = h);
    }).catchError((_) {});
    _loadForecast();
  }

  Future<void> _loadForecast() async {
    try {
      final rows = await LocalDb.recentBandBatterySamples(limit: 400);
      final now = DateTime.now();
      final f = const BatteryForecaster().forecast(
        samples: [
          for (final r in rows)
            if (r['battery_pct'] != null && r['ts'] != null)
              BatterySample(
                tsSec: (r['ts'] as num).toInt(),
                pct: (r['battery_pct'] as num).toDouble(),
                charging: (r['charging'] as num?)?.toInt() == 1,
              ),
        ],
        now: now,
        // Only `predictedEmptyAt` is read below, and it does not depend on the
        // wake time — the projection to a wake time is the notification's
        // question, not this screen's.
        wakeAt: now,
      );
      if (mounted) setState(() => _forecast = f);
    } catch (_) {
      // A projection is a nicety. The screen's real job is the band's state.
    }
  }

  @override
  Widget build(BuildContext c) {
    final s = widget.s;
    final app = s.isBand ? c.watch<AppState>() : null;
    return DeviceDetailView(
      s,
      status: app?.engine.bandStatus,
      health: _health,
      forecast: _forecast,
      onFind: app?.buzzBand,
      liveHr: s.isBand ? app?.liveHr : null,
      onRename: (app != null && app.isConnected)
          ? () => _renameBand(c, app, s.name)
          : null,
      // A sensor is forgotten through its own path: `unpair()` tears down the
      // primary band's link, its restore identity and its trim cursor, none of
      // which a sensor has — pointing this at it would have unpaired the
      // WHOOP from a chest strap's page.
      onSync: switch (s.family) {
        'oura' => () => _syncRing(c),
        'hplus' => () => _syncHPlus(c),
        'pinetime' => () => _syncPineTime(c),
        'qhybrid' => () => _syncQHybrid(c),
        'colmi' => () => _syncColmiRing(c),
        'casio' => () => _syncCasio(c, s.deviceId),
        'jyou' => () => _syncJyou(c),
        _ => null,
      },
      onForget: s.deviceId != null
          ? () => _confirmForgetSensor(c, s)
          : app == null
              ? null
              : () => _confirmForget(c, app, s.name),
    );
  }
}

/// Drain the ring, now, because the user asked. The result is a sentence
/// either way: a sync that silently did nothing is indistinguishable from a
/// ring that had nothing to give, and those need different remedies.
Future<void> _syncRing(BuildContext c) async {
  final l = AppLocalizations.of(c);
  final messenger = ScaffoldMessenger.maybeOf(c);
  messenger?.showSnackBar(
      SnackBar(content: Text(l?.devicesSyncingTheRing ?? 'Syncing the ring…')));
  final ok = await OuraLink.instance.sync();
  if (!c.mounted) return;
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? (l?.devicesSynced ?? 'Synced.')
        : (l?.devicesCouldNotReachRing ??
            'Could not reach the ring. It has to be nearby, and not connected '
                'to another app.')),
  ));
}

/// Connect to the band, now, because the user asked. Same "one sentence
/// either way" shape as [_syncRing] — a sync that reached the band and one
/// that could not are different remedies for the user.
Future<void> _syncHPlus(BuildContext c) async {
  final l = AppLocalizations.of(c);
  final messenger = ScaffoldMessenger.maybeOf(c);
  messenger?.showSnackBar(
      SnackBar(content: Text(l?.devicesSyncing ?? 'Syncing')));
  final ok = await HPlusLink.instance.sync();
  if (!c.mounted) return;
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? (l?.devicesSynced ?? 'Synced.')
        : 'Could not reach the band. It has to be nearby, and not connected '
            'to another app.'),
  ));
}

/// Pull whatever a Jyou band has streamed since the last connect, now,
/// because the user asked. Same shape as [_syncRing] one function up.
Future<void> _syncJyou(BuildContext c) async {
  final messenger = ScaffoldMessenger.maybeOf(c);
  messenger?.showSnackBar(const SnackBar(content: Text('Syncing…')));
  final ok = await JyouLink.instance.sync();
  if (!c.mounted) return;
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? 'Synced.'
        : 'Could not reach the band. It has to be nearby, and not connected '
            'to another app.'),
  ));
}

/// Connect and bank the watch's raw bytes, now, because the user asked. Same
/// shape as [_syncRing] — a sync that silently did nothing is
/// indistinguishable from a watch that had nothing to give, and those need
/// different remedies.
Future<void> _syncPineTime(BuildContext c) async {
  final l = AppLocalizations.of(c);
  final messenger = ScaffoldMessenger.maybeOf(c);
  // `devicesSyncing`/`devicesSynced` are genuinely generic ("Syncing"/
  // "Synced."), unlike `devicesSyncingTheRing`/`devicesCouldNotReachRing`,
  // which name the ring by copy — reusing those here would show the wrong
  // device in the snack bar, so the failure sentence stays untranslated
  // rather than borrowing one that says the wrong thing.
  messenger?.showSnackBar(
      SnackBar(content: Text(l?.devicesSyncing ?? 'Syncing')));
  final ok = await PineTimeLink.instance.sync();
  if (!c.mounted) return;
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? (l?.devicesSynced ?? 'Synced.')
        : 'Could not reach the watch. It has to be nearby, and not connected '
            'to another app.'),
  ));
}

/// Hold a session with the paired watch, now, because the user asked. There
/// is no history to drain here — see `qhybrid_link.dart`'s own header — so
/// this just re-runs the same battery-probe-confirmed window pairing did and
/// banks whatever the watch sends during it.
Future<void> _syncQHybrid(BuildContext c) async {
  final l = AppLocalizations.of(c);
  final messenger = ScaffoldMessenger.maybeOf(c);
  messenger?.showSnackBar(
      SnackBar(content: Text(l?.devicesConnectingWatch ?? 'Connecting…')));
  final ok = await QHybridLink.instance.sync();
  if (!c.mounted) return;
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? (l?.devicesSynced ?? 'Synced.')
        : (l?.devicesCouldNotReachWatch ??
            'Could not reach the watch. It has to be nearby, and not '
                'connected to another app.')),
  ));
}

/// Same as [_syncRing], for a paired Colmi ring — the "sync now" affordance
/// this device was missing entirely (it paired and never synced again).
/// Shares the ring-generic strings above rather than minting Colmi-specific
/// copy for the same sentence.
Future<void> _syncColmiRing(BuildContext c) async {
  final l = AppLocalizations.of(c);
  final messenger = ScaffoldMessenger.maybeOf(c);
  messenger?.showSnackBar(
      SnackBar(content: Text(l?.devicesSyncingTheRing ?? 'Syncing the ring…')));
  final ok = await ColmiLink.instance.sync();
  if (!c.mounted) return;
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? (l?.devicesSynced ?? 'Synced.')
        : (l?.devicesCouldNotReachRing ??
            'Could not reach the ring. It has to be nearby, and not connected '
                'to another app.')),
  ));
}

/// Same shape as [_syncRing] — a separate family behind a separate link, same
/// reason a sync that did nothing needs to say so. [deviceId] is this row's
/// own id: two Casio watches can be paired at once, and without it this
/// always synced whichever one `CasioLink.pairedRow()` happened to see first.
Future<void> _syncCasio(BuildContext c, String? deviceId) async {
  final l = AppLocalizations.of(c);
  final messenger = ScaffoldMessenger.maybeOf(c);
  messenger?.showSnackBar(
      SnackBar(content: Text(l?.devicesSyncing ?? 'Syncing')));
  final ok = await CasioLink.instance.sync(deviceId: deviceId);
  if (!c.mounted) return;
  messenger?.showSnackBar(SnackBar(
    content: Text(ok
        ? (l?.devicesSynced ?? 'Synced.')
        : (l?.devicesCouldNotReachWatch ??
            'Could not reach the watch. It has to be nearby, and not '
                'connected to another app.')),
  ));
}

/// Forget a paired sensor. Same promise as forgetting the band — the source
/// goes, the measurements stay — and it is true for the same reason: every row
/// the sensor wrote keeps its own `device_id`, and nothing here touches them.
Future<void> _confirmForgetSensor(BuildContext c, HealthSource s) async {
  final id = s.deviceId;
  if (id == null) return;
  final app = c.read<AppState>();
  final l = AppLocalizations.of(c);
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(l?.devicesForgetSensor(s.name) ?? 'Forget ${s.name}?'),
      content: Text(
        l?.devicesForgetSensorBody ??
            'It stops being used during workouts and has to be paired again. '
                'Everything already banked on this phone is kept — this removes the '
                'source, not the data.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.devicesKeepItPaired ?? 'Keep it paired')),
        TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l?.devicesForgetIt ?? 'Forget it')),
      ],
    ),
  );
  if (ok != true) return;
  await HrsLink.forgetDevice(id);
  await app.refreshSensors();
  if (c.mounted) backToRoot(c);
}

/// Rename the strap.
///
/// This was in the old UI and did not survive the rebuild, which left the
/// advertising name readable and not writable — and it is the one label a user
/// with two straps needs, since both otherwise read "Your band".
///
/// The band's own limits are the field's limits, checked here so a refusal is
/// immediate instead of a silent truncation 20 characters in: 20 ASCII
/// characters, the charset `cleanDeviceLabel` accepts on the way back, and at
/// least one letter or digit. Anything the strap would reject or mangle is
/// rejected in the sheet, where the user can still fix it.
Future<void> _renameBand(BuildContext c, AppState app, String current) async {
  // Captured before the dialog: `c` is not safe to touch after the await.
  final messenger = ScaffoldMessenger.maybeOf(c);
  final l = AppLocalizations.of(c);
  final ctl = TextEditingController(text: current);
  final err = ValueNotifier<String?>(null);
  final name = await showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(l?.devicesNameThisBand ?? 'Name this band'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<String?>(
          valueListenable: err,
          builder: (_, e, _) => TextField(
            controller: ctl,
            autofocus: true,
            maxLength: 20,
            decoration: InputDecoration(
              hintText: l?.devicesYourBand ?? 'Your band',
              errorText: e,
              helperText: l?.devicesNameCharset ??
                  "Letters, numbers, space, and ' . _ -",
            ),
          ),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(),
            child: Text(l?.actionCancel ?? 'Cancel')),
        TextButton(
          onPressed: () {
            final v = ctl.text.trim();
            if (v.isEmpty) {
              err.value = l?.devicesGiveItAName ?? 'Give it a name';
            } else if (cleanDeviceLabel(v) == null) {
              err.value = l?.devicesNameCharsetError ??
                  "Only letters, numbers, space, and ' . _ -";
            } else {
              Navigator.of(d).pop(v);
            }
          },
          child: Text(l?.actionSave ?? 'Save'),
        ),
      ],
    ),
  );
  ctl.dispose();
  err.dispose();
  if (name == null) return;
  try {
    await app.renameStrap(name);
    messenger?.showSnackBar(
        SnackBar(content: Text(l?.devicesRenamedTo(name) ?? 'Renamed to $name')));
  } catch (e) {
    // The write goes to the strap, so a dropped link loses it. Say that,
    // rather than leaving the old name on screen with no explanation.
    messenger?.showSnackBar(SnackBar(
        content: Text(l?.devicesCouldNotRename(e.toString()) ??
            'Could not rename the band: $e')));
  }
}

/// Forgetting a band is destructive — it ends the only connection to the one
/// sensor in the app that measures anything continuously — and it used to
/// happen on a single tap with no confirmation, leaving this screen still
/// showing the band's battery afterwards. Mirrors the reset confirmation in
/// settings.dart, including the pop: `unpair()` changes the gate underneath
/// this pushed screen, so without it the user is left reading a device page
/// for a device that is gone.
Future<void> _confirmForget(BuildContext c, AppState app, String name) async {
  final l = AppLocalizations.of(c);
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(l?.devicesForgetBand(name) ?? 'Forget $name?'),
      content: Text(
        l?.devicesForgetBandBody ??
            'The band stops syncing and has to be paired again to measure '
                'anything. Everything already banked on this phone is kept — this '
                'removes the source, not the data.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.devicesKeepItPaired ?? 'Keep it paired')),
        TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l?.devicesForgetIt ?? 'Forget it')),
      ],
    ),
  );
  if (ok != true) return;
  await app.unpair();
  if (c.mounted) backToRoot(c);
}

class DeviceDetailView extends StatelessWidget {
  final HealthSource s;
  final VoidCallback? onFind, onForget, onSync;

  /// The beat arriving right now, or null when nothing fresh is streaming.
  /// Passed IN rather than read from a provider here: this view is rendered in
  /// tests with no Provider above it, which is the point of it being a view.
  final int? liveHr;

  /// Rename the band. Null when there is nothing to rename (the phone) or no
  /// link to carry the write — the name lives on the strap, not on the phone,
  /// so an offline rename would be a lie the next connect quietly undoes.
  final VoidCallback? onRename;

  /// The band's own state, from `bandStatusFor`. Null for a non-band source.
  final BandStatus? status;

  /// `LocalDb.batteryHealth()` — the recent `band_battery` series, which is the
  /// one table nothing prunes. Null until it loads, and on a non-band source.
  final Map<String, dynamic>? health;

  /// `BatteryForecaster.forecast` over the same series. Null until it loads and
  /// on a non-band source; an ABSTAINING forecast is a valid value and draws
  /// nothing.
  final BatteryForecast? forecast;

  const DeviceDetailView(this.s,
      {super.key,
      this.onFind,
      this.onForget,
      this.onSync,
      this.onRename,
      this.liveHr,
      this.status,
      this.health,
      this.forecast});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final localizedStatus =
        status == null ? null : localizedBandStatus(c, status!);
    final battery = s.batteryPct;
    final last = s.lastData;
    final fault =
        localizedStatus?.isFault == true ? localizedStatus : null;
    final calibration = calibrationDisclosure(s);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(''),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Center(
                  child: Container(
                    width: 120,
                    height: 120,
                    alignment: Alignment.center,
                    decoration:
                        BoxDecoration(color: p.card2, borderRadius: R.rXxl),
                    child: Icon(s.icon, size: 54, color: p.ink2),
                  ),
                ),
                const SizedBox(height: S.x5),
                Center(child: Text(s.name, style: F.t2.copyWith(color: p.ink))),
                const SizedBox(height: S.x2),
                // A fault names itself in the card below; repeating its title
                // here would say the same thing twice in two type sizes.
                if (fault == null)
                  Center(
                      child: Text(
                          localizedStatus?.title ?? _localizedSourceState(c, s),
                          style: F.cap.copyWith(
                              color: s.connected ? p.on(C.green) : p.ink3))),
                const SizedBox(height: S.x6),
                if (fault != null) ...[
                  StatusCard(fault.title, fault.reason,
                      fix: fault.fix ?? '', icon: LucideIcons.bluetoothOff),
                  const SizedBox(height: S.x5),
                ],
                if (s.tier case final t?) ...[
                  TierRow(t, filled: true),
                  const SizedBox(height: S.x5),
                ],
                // A PAIRED SENSOR'S OWN CARD, not the band block below. It has
                // no advertising name it owns, no battery this app reads and
                // nothing to buzz — and it has the one thing a user needs
                // before they trust the row at all: what is captured, and what
                // is calculated from it. Today the answer to the second is
                // NOTHING, for every sensor, and that has to be on the screen
                // rather than inferred from a metric quietly still abstaining.
                if (!s.isBand && s.deviceId != null) ...[
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: Column(children: [
                      SetRow(LucideIcons.flaskConical, C.orange,
                          l?.devicesSupport ?? 'Support',
                          value: l?.devicesExperimental ?? 'Experimental',
                          sub: l?.devicesSensorExperimentalSub ??
                              'Decoded from the protocol, never checked '
                                  'against the hardware — nobody here owns one.',
                          chevron: false),
                      Divider(color: p.line, height: 1),
                      SetRow(LucideIcons.database, C.teal,
                          l?.devicesWhatItDoes ?? 'What it does',
                          sub: s.tier == null
                              ? (l?.devicesWhatItDoesUnranked ??
                                  'Everything it sends is stored and attributed '
                                      'to it. Nothing in the app is calculated '
                                      'from it yet.')
                              : (l?.devicesWhatItDoesRanked ??
                                  'Beat timing is stored and attributed to it '
                                      'during a workout. Nothing in the app is '
                                      'calculated from it yet.'),
                          chevron: false),
                      Divider(color: p.line, height: 1),
                      SetRow(LucideIcons.refreshCw, C.purple,
                          l?.devicesLastData ?? 'Last data',
                          value: last == null ? '' : formatDayTime(last, l),
                          sub: last == null
                              ? (l?.devicesNothingBankedYet ?? 'Nothing banked yet')
                              : '',
                          chevron: false),
                      // MANUAL, and only for a sensor that holds history.
                      // A strap has no flash and nothing to fetch; a ring
                      // does, and putting it on a schedule would have it
                      // contending for the radio with the band's own link
                      // for no reason a user asked for.
                      if (onSync != null) ...[
                        Divider(color: p.line, height: 1),
                        SetRow(LucideIcons.downloadCloud, C.blue,
                            l?.devicesSyncNow ?? 'Sync now',
                            sub: l?.devicesSyncNowSub ??
                                'Fetch whatever it has been holding',
                            onTap: onSync),
                      ],
                    ]),
                  ),
                  const SizedBox(height: S.x5),
                ],
                // Band rows only. The phone has no radio link and no battery
                // this app can read, so "Not reported since the last
                // connection" named a connection it does not have — on the
                // exact screen someone lands on when phone steps are silently
                // failing, where the answer is the permission, not a battery.
                if (s.isBand)
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: Column(children: [
                      // The name is the band's own advertising name, written
                      // to the strap — not a phone-side label. So it is only
                      // editable on a live link, and the row says so rather
                      // than opening an editor whose save cannot land.
                      SetRow(LucideIcons.tag, C.blue, l?.devicesName ?? 'Name',
                          value: s.name,
                          sub: onRename == null
                              ? (l?.devicesConnectToRename ??
                                  'Connect to the band to change it')
                              : '',
                          chevron: onRename != null,
                          onTap: onRename),
                      Divider(color: p.line, height: 1),
                      SetRow(LucideIcons.batteryMedium, C.green,
                          l?.devicesBattery ?? 'Battery',
                          value: battery == null ? '' : '${battery.round()}%',
                          // L11 — the band's own charge history, on the row
                          // that already exists rather than a new one. Within
                          // THIS band only: `charge_cycles` counts times it went
                          // on the charger, not full cycles, and the millivolts
                          // are the highest reading seen while charging — so
                          // neither is ever put against a cell spec, turned
                          // into a percentage of original capacity, or read as
                          // "replace the battery".
                          //
                          // Both were structurally blank until schema 45: the
                          // voltage had no writer at all, so this line has shown
                          // nothing on every install there has ever been.
                          sub: battery == null
                              ? (l?.devicesBatteryNotReported ??
                                  'Not reported since the last connection')
                              : [
                                  if (s.charging) (l?.devicesCharging ?? 'Charging'),
                                  ?_timeLeft(forecast),
                                  ?_chargeHistory(health),
                                ].join(' · '),
                          chevron: false),
                      Divider(color: p.line, height: 1),
                      // Live, not a stored reading: present only while the
                      // band is actually streaming, and gone the moment it
                      // stops.
                      if (liveHr != null) ...[
                        SetRow(LucideIcons.heartPulse, C.red,
                            l?.devicesHeartRate ?? 'Heart rate',
                            value: '$liveHr bpm',
                            sub: l?.devicesRightNow ?? 'Right now',
                            chevron: false),
                        Divider(color: p.line, height: 1),
                      ],
                      SetRow(LucideIcons.refreshCw, C.purple,
                          l?.devicesLastData ?? 'Last data',
                          value: last == null ? '' : formatDayTime(last, l),
                          sub: last == null
                              ? (l?.devicesNothingBankedYet ?? 'Nothing banked yet')
                              : '',
                          chevron: false),
                      if (calibration != null) ...[
                        Divider(color: p.line, height: 1),
                        SetRow(LucideIcons.sliders, C.teal,
                            l?.devicesCalibration ?? 'Calibration',
                            value: calibration.$1,
                            sub: calibration.$2,
                            chevron: false),
                      ],
                      // WHO HAS CHECKED, not how good the numbers are. Said
                      // here rather than only as a word on the list row,
                      // because "experimental" without the reason reads as a
                      // disclaimer instead of a fact about this band.
                      if (s.experimental) ...[
                        Divider(color: p.line, height: 1),
                        SetRow(LucideIcons.flaskConical, C.orange,
                            l?.devicesSupport ?? 'Support',
                            value: l?.devicesExperimental ?? 'Experimental',
                            sub: l?.devicesBandExperimentalSub ??
                                'This band is decoded but nobody here has worn '
                                    'one. Its numbers have not been checked against '
                                    'the hardware, only against the protocol.',
                            chevron: false),
                      ],
                      if (onFind != null) ...[
                        Divider(color: p.line, height: 1),
                        SetRow(LucideIcons.bellRing, C.orange,
                            l?.devicesBuzzTheBand ?? 'Buzz the band',
                            sub: l?.devicesFindItByFeel ?? 'Find it by feel',
                            chevron: false,
                            onTap: onFind),
                      ],
                    ]),
                  ),
                const SizedBox(height: S.x5),
                if (onForget != null)
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: SetRow(LucideIcons.trash2, C.red,
                        l?.devicesForgetThisBand ?? 'Forget this band',
                        danger: true, chevron: false, onTap: onForget),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// "about 2 days left" — or null on an abstention, which is most of the time
/// and is meant to be: the forecaster refuses on the charger, on too few
/// samples, on too short a span and on an implausible rate, and a battery
/// number the user can read for themselves is better than a made-up deadline.
///
/// Deliberately coarse. The estimate is a median slope through a percentage
/// that only moves in whole points, so it does not support a time of day, and
/// printing one would claim a precision this cannot carry. "About" is doing
/// real work in that sentence.
String? _timeLeft(BatteryForecast? f) {
  final empty = f?.predictedEmptyAt;
  if (empty == null) return null;
  final left = empty.difference(DateTime.now());
  if (left.isNegative) return null;
  if (left.inHours < 1) return 'under an hour left';
  if (left.inHours < 36) return 'about ${left.inHours} h left';
  return 'about ${(left.inHours / 24).round()} days left';
}

/// "12 charges logged, up to 4,180 mV" — or null when there is no history to
/// report yet. Two facts about this band and nothing derived from them: nothing
/// here knows the pack's design capacity, and going on the charger is not a
/// cycle.
String? _chargeHistory(Map<String, dynamic>? h) {
  final cycles = (h?['charge_cycles'] as num?)?.toInt() ?? 0;
  if (cycles <= 0) return null;
  final mv = (h?['full_charge_mv'] as num?)?.toInt();
  return '$cycles charge${cycles == 1 ? '' : 's'} logged'
      '${mv == null ? '' : ', up to $mv mV'}';
}

/// "Thu 4 Sep, 07:12" — local, which is what every day label in this app is.
///
/// It used to render `4/9, 07:12`, which a US reader reads as 9 April. The
/// month name is the whole point; `formatDay` already writes one.
String formatDayTime(DateTime d, [AppLocalizations? l]) {
  final t = '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
  return '${formatDay(d, l)}, $t';
}
