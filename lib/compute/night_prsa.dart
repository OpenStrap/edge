import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';

final _dc = prsaAggregator(deceleration: true);
final _ac = prsaAggregator(deceleration: false);

/// Settled night NN in reference order. Provisional tails only touch copies.
class NightPrsa {
  Object? _dcState = _dc.empty(), _acState = _ac.empty();

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
