import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';

Map<String, Object?> _row(int ts, Object? band) => {
      'counter': ts, 'rec_ts': ts, 'hr': 60, 'ax': 0.1, 'ay': 0.2, 'az': 0.95,
      'device_family': 'gen5', 'device_id': 'd', 'band_sleep_state': band,
    };

void main() {
  test('decoded rows carry the band state; NULL is -1 (absent), never 0', () {
    final sub = substrateFromDecodedPage(
        [_row(1000, 2), _row(1001, null), _row(1002, 3)], const []);
    expect(sub.bandSleepState, [2, -1, 3]);
    expect(sub.bandSleepStateSlice(1, 3), [-1, 3]);
  });

  test('a beat-only second (RR, no row) keeps alignment with -1', () {
    // rec_ts 1001 has an RR row but no decoded row → still one slot.
    final sub = substrateFromDecodedPage([_row(1000, 2), _row(1002, 3)],
        [{'rec_ts': 1001, 'rr_ms': 900}]);
    expect(sub.tsSec, [1000, 1001, 1002]);
    expect(sub.bandSleepState, [2, -1, 3]);
  });

  test('slice() and sliceIdx() both carry it', () {
    final sub = substrateFromDecodedPage(
        [for (var t = 1000; t < 1010; t++) _row(t, t < 1005 ? 2 : 3)], const []);
    expect(sub.sliceIdx(3, 7).bandSleepState, [2, 2, 3, 3]);
    expect(sub.slice(1003, 1007).bandSleepState, [2, 2, 3, 3]);
  });

  test('round-trips through JSON (worker isolate boundary)', () {
    final sub = substrateFromDecodedPage([_row(1000, 2), _row(1001, 3)], const []);
    expect(Substrate.fromJson(sub.toJson()).bandSleepState, [2, 3]);
  });

  test('legacy JSON without the key: all -1, length preserved', () {
    final sub = substrateFromDecodedPage([_row(1000, 2), _row(1001, 3)], const []);
    final m = sub.toJson()..remove('band_sleep_state');
    expect(Substrate.fromJson(m).bandSleepStateSlice(0, 2), [-1, -1]);
  });
}
