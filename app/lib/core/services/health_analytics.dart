import 'dart:math';
import 'dart:typed_data';

/// Computes health metrics from raw WHOOP sensor data.
class HealthAnalytics {
  // Rolling HR buffer for HRV approximation (last 60 values = 60 seconds)
  static const _rrBufferMax = 120;

  final List<double> _rrIntervals = []; // in milliseconds

  void addHeartRate(int hr) {
    if (hr <= 0 || hr > 250) return;
    final rr = 60000.0 / hr;
    _rrIntervals.add(rr);
    if (_rrIntervals.length > _rrBufferMax) {
      _rrIntervals.removeAt(0);
    }
  }

  /// rMSSD from buffered R-R intervals (ms). Returns null if <4 samples.
  double? computeHrv() {
    if (_rrIntervals.length < 4) return null;
    double sumSqDiff = 0;
    for (int i = 1; i < _rrIntervals.length; i++) {
      final diff = _rrIntervals[i] - _rrIntervals[i - 1];
      sumSqDiff += diff * diff;
    }
    return sqrt(sumSqDiff / (_rrIntervals.length - 1));
  }

  /// SpO2 estimate from R21 optical channels.
  /// channelC = infrared, channelF = red.
  static double? computeSpo2(Int32List? ir, Int32List? red) {
    if (ir == null || red == null || ir.length < 10 || red.length < 10) return null;

    final irDc = _mean(ir);
    final redDc = _mean(red);
    if (irDc == 0 || redDc == 0) return null;

    final irAc = _stdDev(ir, irDc);
    final redAc = _stdDev(red, redDc);
    if (irAc == 0) return null;

    final ratio = (redAc / redDc) / (irAc / irDc);
    // Empirical formula calibrated for WHOOP-like sensors
    final spo2 = (110.0 - 25.0 * ratio).clamp(85.0, 100.0);
    return spo2;
  }

  /// Recovery score [0-100] from HRV and resting HR baseline.
  /// Simple heuristic: higher HRV relative to personal average = better recovery.
  static double computeRecovery({
    required double? hrv,
    required double? restingHr,
    required double? personalHrvBaseline,
    required double? personalHrBaseline,
  }) {
    if (hrv == null) return 0;
    final base = personalHrvBaseline ?? 40.0;
    final hrBase = personalHrBaseline ?? 60.0;
    double score = (hrv / base) * 50;
    if (restingHr != null && hrBase > 0) {
      score += ((hrBase / restingHr) * 50).clamp(0, 50);
    } else {
      score += 25;
    }
    return score.clamp(0, 100);
  }

  /// Acceleration magnitude from x/y/z samples (mean of magnitudes).
  static double? computeAccelMagnitude(
      List<int>? ax, List<int>? ay, List<int>? az) {
    if (ax == null || ay == null || az == null) return null;
    final len = min(ax.length, min(ay.length, az.length));
    if (len == 0) return null;
    double sum = 0;
    for (int i = 0; i < len; i++) {
      sum += sqrt(ax[i] * ax[i] + ay[i] * ay[i] + az[i] * az[i].toDouble());
    }
    return sum / len;
  }

  void reset() => _rrIntervals.clear();

  static double _mean(Int32List data) {
    if (data.isEmpty) return 0;
    double sum = 0;
    for (final v in data) sum += v;
    return sum / data.length;
  }

  static double _stdDev(Int32List data, double mean) {
    if (data.isEmpty) return 0;
    double sum = 0;
    for (final v in data) {
      final d = v - mean;
      sum += d * d;
    }
    return sqrt(sum / data.length);
  }
}
