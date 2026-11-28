// A ring that counts no steps: the phone's count is still the day's steps.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/oura_inputs.dart';

void main() {
  test('native cards keep the phone\'s steps on a ring day', () {
    final day = <String, dynamic>{
      'device_family': kOuraFamily,
      'scalars': {'steps': 8000, 'strain': 9.0},
    };
    expect(withoutWearableEstimates(day)['scalars'], {'steps': 8000});
  });

  test('the ring column serves the phone\'s steps, unavailable without them',
      () {
    Map<String, Object?> steps(Map day) => resolveCells(
          kOuraColumn,
          day: day,
          crossDay: const {},
          deviceValues: const {},
          method: null,
          family: kOuraFamily,
        )['steps']!;
    final counted = steps({
      'scalars': {'steps': 8000},
    });
    expect(counted['class'], 'ours');
    expect(counted['value'], 8000);
    final none = steps({'scalars': <String, Object?>{}});
    expect(none['class'], 'unavailable');
    expect(none['reason'], 'notDecoded');
  });
}
