import 'package:openstrap_analytics/onehz.dart';

/// Thirty-minute bins anchored at the first corrected beat, like the batch.
/// Keep closed spectral states so every snapshot applies the current night's
/// artifact gate through analytics, including to bins closed on a prior pass.
class NightRespBins {
  NightRespBins();
  double? _origin;
  int _openIndex = 0, _openCount = 0;
  RsaRespStream _open = RsaRespStream();
  final List<({int count, RsaRespStream stream})> _closed = [];

  int _bin(double time, double origin) => ((time - origin) / 1800000.0).floor();

  void _appendRate(List<double> out, Metric<RespEstimate> metric) {
    final rate = metric.present ? metric.value!.brpm : null;
    if (rate != null) out.add(rate);
  }

  /// Returns the number of nonempty bin slices actually folded.
  int fold(List<double> nn, List<double> times) {
    var from = 0, slices = 0;
    void feed(int end) {
      if (end == from) return;
      _open.fold(nn.sublist(from, end), times.sublist(from, end));
      _openCount += end - from;
      slices++;
    }
    for (var i = 0; i < times.length; i++) {
      final index = _bin(times[i], _origin ??= times[i]);
      if (index == _openIndex) continue;
      feed(i);
      if (_openCount >= 60) _closed.add((count: _openCount, stream: _open));
      _open = RsaRespStream();
      _openCount = 0;
      _openIndex = index;
      from = i;
    }
    feed(nn.length);
    return slices;
  }

  List<double> snapshot(List<double> tailNn, List<double> tailTimes,
      {required double artifactFraction}) {
    if (_origin == null && tailNn.isEmpty) return [];
    final origin = _origin ?? tailTimes.first;
    final out = <double>[];
    for (final bin in _closed) {
      _appendRate(out, bin.stream.snapshot(artifactFraction: artifactFraction));
    }
    var i = 0;
    while (i < tailNn.length && _bin(tailTimes[i], origin) == _openIndex) {
      i++;
    }
    if (_openCount + i >= 60) {
      _appendRate(out, _open.snapshot(tailNnMs: tailNn.sublist(0, i),
          tailNnTimesMs: tailTimes.sublist(0, i), artifactFraction: artifactFraction));
    }
    while (i < tailNn.length) {
      final index = _bin(tailTimes[i], origin);
      var end = i + 1;
      while (end < tailNn.length && _bin(tailTimes[end], origin) == index) {
        end++;
      }
      if (end - i >= 60) {
        _appendRate(out, rsaRespRate(tailNn.sublist(i, end),
            tailTimes.sublist(i, end), artifactFraction: artifactFraction));
      }
      i = end;
    }
    return out;
  }
}
