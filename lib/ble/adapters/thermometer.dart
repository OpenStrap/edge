// A Bluetooth SIG Health Thermometer (the Femometer Vinca 2 basal thermometer
// and any compliant thermometer) as a [BandAdapter].
//
// THE SESSION: subscribe to Temperature Measurement, set the clock (Current
// Time — optional, a thermometer without it still reports), then collect
// whatever the thermometer indicates until it goes quiet, yielding each one
// as it arrives. Every indication is archived verbatim; each
// plausible reading becomes a `body_temp` observation at the instant the
// thermometer stamped it (or at arrival, when it carried no stamp).
//
// WHAT IT IS NOT: a signal. A spot body temperature is a measured, comparable
// quantity, so it uses our `body_temp` key — but it is an OBSERVATION,
// display-only, never an input to a baseline or a derivation.
//
// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project owns one.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Body temperature a thermometer can plausibly report, degrees C. Outside it
/// is a reading taken off the body (or a decode error), not a temperature.
const double kBodyTempMinC = 30, kBodyTempMaxC = 43;

class ThermometerAdapter extends BandAdapter {
  final int Function() nowSeconds;
  final Duration firstWait;
  final Duration quiet;

  ThermometerAdapter({
    int Function()? nowSeconds,
    this.firstWait = const Duration(seconds: 20),
    this.quiet = const Duration(seconds: 5),
  }) : nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  @override
  BandEntry get entry => kThermometer;

  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // Subscribed before the clock write, buffered until read: a stored reading
    // indicated the moment the subscription lands is not lost.
    final got = StreamController<(int, List<int>)>();
    final sub = link.notify(kHtpTemperatureMeasurement).listen(got.add,
        onDone: got.close, onError: got.addError);
    final it = StreamIterator(got.stream);
    try {
      final now = DateTime.fromMillisecondsSinceEpoch(nowSeconds() * 1000);
      if (!await link.write(kCurrentTimeChar, currentTimeValue(now))) {
        link.log('thermometer: no Current Time; readings keep its own clock.');
      }
      // No Measurement Interval write. A non-zero interval is a persistent
      // periodic-measurement setting: the thermometer would keep measuring
      // and indicating after this session ends, and never go quiet during it.
      // Stored and spot readings are indicated once the subscription is on.
      //
      // Each indication is yielded as it arrives, not batched at the end: the
      // session window can cancel this generator at any point, and whatever
      // was already yielded is kept.
      var wait = firstWait;
      while (await it.moveNext().timeout(wait, onTimeout: () => false)) {
        wait = quiet;
        final (atSec, bytes) = it.current;
        final b = Uint8List.fromList(bytes);
        yield SampleBatch(const [], raw: [b]);
        final row = _observation(b, atSec);
        if (row != null) yield VendorScalars([row]);
      }
    } finally {
      await sub.cancel();
      await it.cancel();
      unawaited(got.close());
    }
  }

  /// One plausible reading as a `body_temp` observation, or null.
  Observation? _observation(List<int> b, int atSec) {
    final m = parseHtpMeasurement(b);
    if (m == null || m.celsius < kBodyTempMinC || m.celsius > kBodyTempMaxC) {
      return null;
    }
    return Observation(
      at: wallClockOr(m.at, atSec, nowSeconds()),
      sourceKind: ObservationSource.vendor,
      key: 'body_temp',
      value: double.parse(m.celsius.toStringAsFixed(2)),
      unit: '°C',
      attribution: kThermometer.label,
    );
  }
}

/// Waits for the first event up to [first], then until [quiet] passes with
/// no new event, and never past [until] (a device that keeps notifying would
/// otherwise hold the session open forever). Shared by the short-session
/// devices.
Future<void> collectUntilQuiet(
    Stream<void> events, Duration first, Duration quiet,
    {Stopwatch? clock, Duration? until}) async {
  final it = StreamIterator(events);
  Duration capped(Duration d) {
    if (clock == null || until == null) return d;
    final left = until - clock.elapsed;
    return left < d ? (left.isNegative ? Duration.zero : left) : d;
  }

  try {
    var wait = first;
    while (await it.moveNext().timeout(capped(wait), onTimeout: () => false)) {
      wait = quiet;
    }
  } finally {
    await it.cancel();
  }
}

/// A device's wall-clock stamp as an instant, or the arrival second when the
/// stamp is absent or implausible (see [wallClockValid]).
DateTime wallClockOr(WallClock? w, int arrivalSec, int nowSec,
        {bool utc = false}) =>
    wallClockValid(w, nowSec, utc: utc) ??
    DateTime.fromMillisecondsSinceEpoch(arrivalSec * 1000);

/// A device's wall-clock stamp as an instant (local time, or UTC when [utc]),
/// or null when it is absent or implausible: before 2018, or more than a day
/// ahead of [nowSec] — a device whose clock was never set.
DateTime? wallClockValid(WallClock? w, int nowSec, {bool utc = false}) {
  if (w == null) return null;
  final t = utc
      ? DateTime.utc(w.year, w.month, w.day, w.hour, w.minute, w.second)
      : DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second);
  if (t.isBefore(DateTime(2018)) ||
      t.millisecondsSinceEpoch ~/ 1000 > nowSec + 86400) {
    return null;
  }
  return t;
}
