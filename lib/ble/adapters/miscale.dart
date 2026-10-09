// Xiaomi Mi scales as [BandAdapter]s: the Mi Body Composition Scale and the
// Mi Smart Scale 2.
//
// THE SESSION, the same on both scales: subscribe, switch a scale reporting
// mode 3 to user mode, set the clock in UTC (a clock found on local time
// means the stored history was stamped local too, so it is kept local and
// every stamp read as local: one record reads the same every session, as
// the history is never deleted and is re-sent each time), read back the stored history
// (ask how many records, have them sent only when there are some, and always
// end with the stop command), then collect live readings until the scale
// goes quiet. Live readings count only once STABILISED (the protocol decoder
// drops the settling ones); stored records carry no live state and are kept
// unless their stamp is implausible. Every notification is archived
// verbatim; each reading becomes a `weight` observation (kg, a comparable
// quantity) and, on the composition scale, a vendor `impedance` observation
// (ohms) taken from the impedance-stable frame of the same weighing.
//
// NOTHING DESTRUCTIVE: the history acknowledgement that deletes the records
// is never sent (see `miscale.dart` in `protocol`), so the scale keeps its
// history and re-sends it next time; observations are upserted by timestamp.
//
// WHAT IT IS NOT: a signal or a body-composition calculation. Weight and
// impedance are shown attributed; with the scale's flag on, a weighing near
// the profile's weight becomes it (`measurement_inputs.dart`).
//
// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project owns one.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';
import 'thermometer.dart' show collectUntilQuiet, wallClockOr, wallClockValid;

/// Weight a person standing on a scale can plausibly weigh, kg.
const double kWeightMinKg = 10, kWeightMaxKg = 300;

class MiScaleAdapter extends BandAdapter {
  @override
  final BandEntry entry;
  final int Function() nowSeconds;
  final Duration firstWait;
  final Duration quiet;

  /// The stored history is keyed by a user id; any stable id reads it.
  final int userId;

  /// How long to wait for the scale's history record count.
  final Duration replyTimeout;

  /// The history ends after this long with no record, when the scale sends
  /// no end marker.
  final Duration historyQuiet;

  /// The history and live collection waits end by this long after the
  /// session starts (the reads and writes keep their own link timeouts), so
  /// the rows are yielded inside the host's session window
  /// (`SessionLink.window`, 60 s): a generator cancelled at that window
  /// before its yield delivers nothing, and the whole weighing is lost.
  final Duration budget;

  MiScaleAdapter(
    this.entry, {
    int Function()? nowSeconds,
    this.userId = 1,
    this.firstWait = const Duration(seconds: 20),
    this.quiet = const Duration(seconds: 5),
    this.replyTimeout = const Duration(seconds: 5),
    this.historyQuiet = const Duration(seconds: 10),
    this.budget = const Duration(seconds: 40),
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  bool get _isScale2 => entry.id == kMiScale2.id;

  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final clock = Stopwatch()..start();
    // (arrival second, bytes, came from the history characteristic)
    final got = <(int, Uint8List, bool)>[];
    // Single-subscription, so live frames that land during the history
    // phase still count once the live wait starts.
    final arrived = StreamController<void>();
    final records = StreamController<void>();
    final count = Completer<int?>();
    final subs = [
      link.notify(_isScale2 ? kMiScaleWeightChar : kMiScaleBodyCompositionChar)
          .listen((r) {
        got.add((r.$1, Uint8List.fromList(r.$2), false));
        arrived.add(null);
      }),
      link.notify(kMiScaleHistoryChar).listen((r) {
        if (miScaleHistoryDone(r.$2)) {
          if (!records.isClosed) unawaited(records.close());
          return;
        }
        got.add((r.$1, Uint8List.fromList(r.$2), true));
        final n = miScaleHistoryCount(r.$2);
        if (n != null && !count.isCompleted) {
          count.complete(n);
        } else if (!records.isClosed) {
          records.add(null);
        }
      }),
    ];
    var utc = true;
    try {
      await _setUserMode(link);
      utc = !await _clockWasLocal(link);
      final now =
          DateTime.fromMillisecondsSinceEpoch(nowSeconds() * 1000, isUtc: utc);
      await link.write(kCurrentTimeChar, miScaleClockValue(now));
      if (await link.write(kMiScaleHistoryChar, miScaleHistoryRequest(userId))) {
        final n =
            await count.future.timeout(replyTimeout, onTimeout: () => null);
        if (n != null &&
            n > 0 &&
            await link.write(kMiScaleHistoryChar, kMiScaleHistorySend)) {
          await collectUntilQuiet(records.stream, historyQuiet, historyQuiet,
              clock: clock, until: budget);
        }
        // Every history session ends with the stop, whatever happened.
        await link.write(kMiScaleHistoryChar, kMiScaleHistoryStop);
      }
      await collectUntilQuiet(arrived.stream, firstWait, quiet,
          clock: clock, until: budget);
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      unawaited(arrived.close());
      if (!records.isClosed) unawaited(records.close());
    }
    final frames = [for (final (_, b, _) in got) b];
    if (frames.isEmpty) return;
    yield SampleBatch(const [], raw: frames);

    // One weight per weighing, keyed by its stamp: the composition scale
    // sends several stable frames of one weighing under one stamp, and the
    // impedance only on a later, impedance-stable one.
    final weights = <int, (DateTime, double)>{};
    final ohms = <int, int>{};
    final nowSec = nowSeconds();
    for (final (atSec, b, history) in got) {
      final readings = switch ((_isScale2, history)) {
        (true, true) => parseMiScale2History(b),
        (true, false) => parseMiScale2Records(b),
        (false, true) => parseMiBodyCompositionRecords(b),
        (false, false) => [?parseMiBodyComposition(b)],
      };
      for (final r in readings) {
        if (r.kg < kWeightMinKg || r.kg > kWeightMaxKg) continue;
        // A stored record with no plausible stamp cannot be placed in time;
        // stamped at arrival it would be banked again every session.
        final at = history
            ? wallClockValid(r.at, nowSec, utc: utc)
            : wallClockOr(r.at, atSec, nowSec, utc: utc);
        if (at == null) continue;
        final key = at.millisecondsSinceEpoch;
        weights.putIfAbsent(key, () => (at, r.kg));
        if (r.impedanceOhm != null) ohms[key] = r.impedanceOhm!;
      }
    }
    final rows = <Observation>[
      for (final MapEntry(:key, value: (at, kg)) in weights.entries) ...[
        _obs(at, 'weight', double.parse(kg.toStringAsFixed(2)), 'kg',
            ours: true),
        if (ohms[key] case final ohm?) _obs(at, 'impedance', ohm, 'ohm'),
      ],
    ];
    if (rows.isNotEmpty) yield VendorScalars(rows);
  }

  /// Whether the scale's clock, read before this session sets it, runs on
  /// the phone's local time rather than UTC: another app that set it local
  /// stamped the stored history local too, and those stamps are read back
  /// as local. Neither or both near (a UTC zone): UTC. A local clock set
  /// before a daylight-saving change reads an hour off local time and is
  /// still local: read as UTC, every stored record would come back shifted
  /// (a second row beside the one banked before), and the clock rewritten
  /// as UTC would keep it so. A local stamp reads back under its own date's
  /// offset, so a record from either side of the change lands right.
  // ponytail: one reading for the whole history; records stamped under both
  // clocks (another app switched it back and forth) keep the newer clock's
  // reading. Our own write never mixes them: it keeps the clock it found.
  // A clock set in another zone (a trip) reads as UTC, as before; telling it
  // apart needs the zone it was set in, which the scale does not keep.
  Future<bool> _clockWasLocal(BandLink link) async {
    final b = await link.read(kCurrentTimeChar);
    final w = b == null ? null : gattDateTime(b, 0);
    if (w == null) return false;
    final at = DateTime.utc(w.year, w.month, w.day, w.hour, w.minute, w.second)
            .millisecondsSinceEpoch ~/
        1000;
    final now = nowSeconds();
    final local = now +
        DateTime.fromMillisecondsSinceEpoch(now * 1000).timeZoneOffset.inSeconds;
    const near = 15 * 60;
    return (at - now).abs() > near &&
        [-3600, 0, 3600].any((dst) => (at - local - dst).abs() <= near);
  }

  /// A scale reporting mode 3 is switched to user mode; the composition
  /// scale also when its mode cannot be read. Best-effort: logged, never
  /// fatal.
  Future<void> _setUserMode(BandLink link) async {
    final m = await link.read(kMiScaleModeChar);
    final mode = m != null && m.length >= 2 ? m[0] | (m[1] << 8) : null;
    if (mode == 3 || (mode == null && !_isScale2)) {
      final ok = await link.write(
          kMiScaleModeChar, miScaleUserModeCommand(composition: !_isScale2));
      link.log('miscale: set user mode: $ok');
    }
  }

  Observation _obs(DateTime at, String name, num value, String unit,
          {bool ours = false}) =>
      Observation(
        at: at,
        sourceKind: ObservationSource.vendor,
        key: ours ? name : null,
        vendorKey: ours ? null : name,
        value: value,
        unit: unit,
        attribution: entry.label,
      );
}
