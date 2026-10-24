import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';

final _dc = prsaAggregator(deceleration: true);
final _ac = prsaAggregator(deceleration: false);

/// Settled night NN in reference order. Provisional tails only touch copies.
class NightPrsa {
  NightPrsa();
  Object? _dcState = _dc.empty(), _acState = _ac.empty();

  Map<String, dynamic> toJson() => {
    'v': 1, 'dc': _dc.encodeState(_dcState), 'ac': _ac.encodeState(_acState),
  };

  factory NightPrsa.fromJson(Map<String, dynamic> json, int fed) {
    if (json['v'] != 1) throw const FormatException('PRSA version');
    final dc = json['dc'], ac = json['ac'];
    if (dc is! List || ac is! List || dc.first != fed || ac.first != fed) {
      throw const FormatException('PRSA feed count');
    }
    return NightPrsa()
      .._dcState = _dc.decodeState(dc)
      .._acState = _ac.decodeState(ac);
  }

  void fold(List<double> nn) {
    final column = DoubleColumn(Float64List.fromList(nn));
    _dcState = _dc.addSlice(_dcState, column, 0, column.length);
    _acState = _ac.addSlice(_acState, column, 0, column.length);
  }

  (Metric<PrsaResult>, Metric<PrsaResult>) snapshot(List<double> tailNn) {
    final tail = DoubleColumn(Float64List.fromList(tailNn));
    Metric<PrsaResult> finish(
        Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>> agg,
        Object? state) {
      final copy = agg.decodeState(agg.encodeState(state));
      return agg.finish(agg.addSlice(copy, tail, 0, tail.length));
    }
    // Sequential addSlice preserves anchor order; never combine partial sums.
    // #99 prsa_aggregator.dart declares profile/capacity abs+rel 1e-9,
    // confidence abs 1e-12 parity with the batch functions.
    return (finish(_dc, _dcState), finish(_ac, _acState));
  }
}
